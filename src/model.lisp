(in-package #:lexter/model)

;;;; Terminal Model
;;;;
;;;; This is the logical terminal state — independent of the display layer.
;;;; It maintains:
;;;;   - A screen buffer (cells with glyph, swatch, attributes)
;;;;   - Cursor state
;;;;   - Scrolling region
;;;;   - Mode flags
;;;;   - Scrollback buffer
;;;;   - Swatch interning
;;;;
;;;; The model is backend-agnostic: both Unix VT and 3270 backends can write
;;;; to it, as can a CL application for custom console interfaces.

;;; --------------------------------------------------------------------------
;;; Constants
;;; --------------------------------------------------------------------------

;; Universal attribute bits (0-7)
(defconstant +attr-bold+       #b00000001)
(defconstant +attr-underline+  #b00000010)
(defconstant +attr-blink+      #b00000100)
(defconstant +attr-reverse+    #b00001000)
(defconstant +attr-invisible+  #b00010000)
;; Bits 5-7 reserved for future universal attributes
;; Bits 8-31 are mode-specific (Unix, 3270, application)

;; +MAX-LAYERS+ and +SWATCH-SLOTS+ are the grid's, imported (LEXTER-O36).

;;; --------------------------------------------------------------------------
;;; Swatches and palettes
;;; --------------------------------------------------------------------------
;;;
;;; Swatch tables, their stores, and the default palette are in swatches.lisp
;;; (LEXTER-D99). A screen's table hands out global indices, which its cells
;;; hold and the flush copies unchanged (LEXTER-D100). Palettes are RGBA bytes,
;;; as the GPU's integer store holds them (LEXTER-D109).

;;; --------------------------------------------------------------------------
;;; Cell representation
;;; --------------------------------------------------------------------------

;; Each cell in the model is represented as 3 values packed into the cell array:
;;   - glyph-idx  (uint16)
;;   - swatch-idx (uint16)  
;;   - attrs      (uint32)
;; Plus optional layer data for layered cells.

(defstruct model-layer
  "A layer within a layered cell."
  (glyph-idx   0    :type (unsigned-byte 32))
  (ink-slot    1    :type (unsigned-byte 2))   ; swatch slot for ink
  (bg-slot     0    :type (unsigned-byte 2))   ; swatch slot for bg (layer 0)
  (transparent-side :none :type keyword))

(defstruct model-cell-layers
  "Layered cell data."
  ;; Swatch index into the screen's swatch table (same as simple cells)
  (swatch-idx 0 :type (unsigned-byte 16))
  ;; Layers 0-2
  (layers (make-array +max-layers+ :initial-element nil) :type simple-vector)
  ;; Which layer is topmost (highest active layer number)
  (topmost 0 :type (integer 0 2)))

;;; --------------------------------------------------------------------------
;;; Screen buffer
;;; --------------------------------------------------------------------------

(defstruct (screen (:constructor %make-screen))
  "Terminal screen state."
  (cols      80  :type fixnum)
  (rows      24  :type fixnum)
  (mode      :unix :type keyword)  ; :unix, :3270, :application
  ;; The glyph index of blank cells: the atlas's empty glyph, position 0
  ;; (LEXTER-D89), which every atlas reserves.
  (blank-glyph 0 :type fixnum)
  ;; --- Cell data (simple path) ---
  ;; Indexed by (row * cols + col)
  ;; Glyph indices are atlas positions, which can exceed 16 bits for very large
  ;; fonts (e.g. Unifont's atlas has ~107k cells), so they are stored as 32-bit.
  (glyphs        #() :type (simple-array (unsigned-byte 32) (*)))
  (swatch-indices #() :type (simple-array (unsigned-byte 16) (*)))
  (attrs         #() :type (simple-array (unsigned-byte 32) (*)))
  ;; --- Wide character flags ---
  ;; 1 = left half of double-wide char; right half has glyph=0, same swatch
  (wide-flags    #*  :type simple-bit-vector)
  ;; --- Layered cells (sparse) ---
  (layered-cells (make-hash-table :test 'equal) :type hash-table)
  ;; --- Swatch table: the terminal's, shared by its primary and alternate
  ;; screens (LEXTER-DRAFT-cell-model-revision-D24) ---
  (swatches  nil :type (or null swatch-table))
  ;; --- Cursor state ---
  (cursor-col     0   :type fixnum)
  (cursor-row     0   :type fixnum)
  (cursor-visible t   :type boolean)
  (cursor-style   :block :type keyword)  ; :block, :underline, :bar
  (cursor-blink   nil :type boolean)
  ;; --- Scrolling region (VT only) ---
  (scroll-top    0    :type fixnum)
  (scroll-bottom 23   :type fixnum)  ; inclusive
  ;; --- Saved cursor (for DECSC/DECRC) ---
  (saved-cursor-col 0 :type fixnum)
  (saved-cursor-row 0 :type fixnum)
  ;; --- Scrollback ---
  (scrollback-enabled t :type boolean)
  (scrollback-max   2000 :type fixnum)
  (scrollback-lines nil)   ; ring buffer, implemented separately
  (scrollback-count 0 :type fixnum)
  (scrollback-viewport 0 :type fixnum)  ; 0 = viewing live screen
  ;; --- Per-row dirty flags (for flush optimization) ---
  (row-dirty     #*  :type simple-bit-vector)
  ;; --- Default swatch for new cells: the global index of the table's
  ;; default swatch ---
  (default-swatch 0 :type fixnum)
  ;; --- Color palette (256 RGBA colors as bytes, 1024 total) ---
  (palette nil :type (or null palette))
  (palette-generation 1 :type fixnum))

;;; --------------------------------------------------------------------------
;;; Constructor
;;; --------------------------------------------------------------------------

(defun make-screen (&key (cols 80) (rows 24) (mode :unix)
                         (scrollback-max 2000) swatches palette)
  "Create a new screen buffer whose cells take their swatches from SWATCHES, a
   swatch table, and whose colours are PALETTE, a palette the screen copies.
   Without SWATCHES the screen has a table of its own, in a store of its own;
   a terminal's screens share their terminal's table, from the store of the
   compositor that draws them (LEXTER-DRAFT-cell-model-revision-D24). Without
   PALETTE the screen has the default palette. Every cell starts in the
   table's default swatch."
  (let* ((n (* cols rows))
         (swatches (or swatches (make-swatch-table (make-swatch-store))))
         (default (swatch-table-default swatches)))
    (%make-screen
     :cols            cols
     :rows            rows
     :mode            mode
     :glyphs          (make-array n :element-type '(unsigned-byte 32) :initial-element 0)
     :swatch-indices  (make-array n :element-type '(unsigned-byte 16) :initial-element default)
     :attrs           (make-array n :element-type '(unsigned-byte 32) :initial-element 0)
     :wide-flags      (make-array n :element-type 'bit :initial-element 0)
     :layered-cells   (make-hash-table :test 'equal :size 64)
     :swatches        swatches
     :cursor-col      0
     :cursor-row      0
     :cursor-visible  t
     :cursor-style    :block
     :cursor-blink    nil ;; t
     :scroll-top      0
     :scroll-bottom   (1- rows)
     :scrollback-enabled t
     :scrollback-max  scrollback-max
     :scrollback-lines (make-array scrollback-max :initial-element nil)
     :scrollback-count 0
     :scrollback-viewport 0
     :row-dirty       (make-array rows :element-type 'bit :initial-element 1)
     :default-swatch  default
     :palette         (if palette (copy-seq palette) (make-default-palette))
     :palette-generation 1)))

;;; --------------------------------------------------------------------------
;;; Palettes
;;; --------------------------------------------------------------------------

(defun set-palette-entry (screen idx r g b &optional (a 255))
  "Set palette entry IDX to the given RGBA bytes (0-255).
   Increments the palette generation for GPU sync."
  (let ((p (screen-palette screen))
        (base (* idx 4)))
    (setf (aref p (+ base 0)) r
          (aref p (+ base 1)) g
          (aref p (+ base 2)) b
          (aref p (+ base 3)) a))
  (incf (screen-palette-generation screen)))

(defun set-palette-entry-rgb8 (screen idx r g b)
  "Set palette entry IDX to the given RGB bytes (0-255), opaque.
   Increments the palette generation for GPU sync."
  (set-palette-entry screen idx r g b 255))

(defun get-palette-entry (screen idx)
  "Return the RGBA bytes of palette entry IDX as multiple values."
  (let ((p (screen-palette screen))
        (base (* idx 4)))
    (values (aref p (+ base 0))
            (aref p (+ base 1))
            (aref p (+ base 2))
            (aref p (+ base 3)))))

(defun reset-palette (screen)
  "Reset the screen's palette to the default xterm colors.
   Increments the palette generation for GPU sync."
  (replace (screen-palette screen) (make-default-palette))
  (incf (screen-palette-generation screen)))

;;; --------------------------------------------------------------------------
;;; Accessors
;;; --------------------------------------------------------------------------

(declaim (inline %idx %mark-dirty))

(defun %idx (screen col row)
  (+ (* row (screen-cols screen)) col))

(defun %mark-dirty (screen row)
  (when (< row (screen-rows screen))
    (setf (sbit (screen-row-dirty screen) row) 1)))

(defun any-row-dirty-p (screen)
  "Return T if any row in SCREEN is marked dirty."
  (not (zerop (count 1 (screen-row-dirty screen)))))

(defun mark-screen-dirty (screen)
  "Mark every row of SCREEN dirty so the next FLUSH-TO-DISPLAY repaints the
   whole screen. Used after an alternate-screen buffer swap, where the shared
   display grid still holds the previous buffer's content and must be fully
   re-copied from the now-active buffer."
  (fill (screen-row-dirty screen) 1)
  screen)

(defun default-swatch (screen)
  (screen-default-swatch screen))

(defun (setf default-swatch) (value screen)
  (setf (screen-default-swatch screen) value))

;;; --------------------------------------------------------------------------
;;; Cursor accessors
;;; --------------------------------------------------------------------------

(defun cursor-col (screen) (screen-cursor-col screen))
(defun cursor-row (screen) (screen-cursor-row screen))
(defun cursor-visible-p (screen) (screen-cursor-visible screen))
(defun cursor-style (screen) (screen-cursor-style screen))
(defun cursor-blink-p (screen) (screen-cursor-blink screen))

(defun set-cursor-position (screen col row)
  "Move cursor to (COL, ROW), clamped to screen bounds."
  (let ((old-row (screen-cursor-row screen)))
    (setf (screen-cursor-col screen) (max 0 (min col (1- (screen-cols screen))))
          (screen-cursor-row screen) (max 0 (min row (1- (screen-rows screen)))))
    (%mark-dirty screen old-row)
    (%mark-dirty screen (screen-cursor-row screen))))

(defun set-cursor-style (screen style)
  "Set cursor style: :block, :underline, or :bar."
  (setf (screen-cursor-style screen) style)
  (%mark-dirty screen (screen-cursor-row screen)))

(defun set-cursor-visible (screen visible)
  (setf (screen-cursor-visible screen) visible)
  (%mark-dirty screen (screen-cursor-row screen)))

;;; --------------------------------------------------------------------------
;;; Cell access
;;; --------------------------------------------------------------------------

(defun %get-layered (screen col row)
  "Return the MODEL-CELL-LAYERS for (COL,ROW) or NIL if simple."
  (gethash (cons col row) (screen-layered-cells screen)))

(defun cell-layered-p (screen col row)
  (not (null (%get-layered screen col row))))

(defun topmost-layer (screen col row)
  "Return the topmost active layer number at (COL, ROW).
   For simple cells, returns 0."
  (let ((layers (%get-layered screen col row)))
    (if layers
        (model-cell-layers-topmost layers)
        0)))

(defun cell-glyph (screen col row &optional (layer nil))
  "Return the glyph at (COL, ROW).
   If LAYER is NIL, returns the topmost layer's glyph.
   Otherwise returns the glyph at the specified layer."
  (let ((layers (%get-layered screen col row)))
    (if layers
        (let* ((ln (or layer (model-cell-layers-topmost layers)))
               (lobj (aref (model-cell-layers-layers layers) ln)))
          (if lobj (model-layer-glyph-idx lobj) (screen-blank-glyph screen)))
        (aref (screen-glyphs screen) (%idx screen col row)))))

(defun cell-swatch (screen col row)
  "Return the swatch index at (COL, ROW)."
  (let ((layers (%get-layered screen col row)))
    (if layers
        (model-cell-layers-swatch-idx layers)
        (aref (screen-swatch-indices screen) (%idx screen col row)))))

(defun cell-attrs (screen col row)
  "Return the attribute word at (COL, ROW)."
  (aref (screen-attrs screen) (%idx screen col row)))

;;; --------------------------------------------------------------------------
;;; Layer management
;;; --------------------------------------------------------------------------

(defun %ensure-layered (screen col row)
  "Ensure (COL, ROW) is in layered mode, creating if needed."
  (let ((key (cons col row)))
    (or (gethash key (screen-layered-cells screen))
        (let* ((i (%idx screen col row))
               (layers (make-model-cell-layers)))
          ;; Copy swatch index (same table lookup as simple cells)
          (setf (model-cell-layers-swatch-idx layers)
                (aref (screen-swatch-indices screen) i))
          ;; Initialize layer 0 from current cell
          (setf (aref (model-cell-layers-layers layers) 0)
                (make-model-layer :glyph-idx (aref (screen-glyphs screen) i)
                                  :ink-slot  1
                                  :bg-slot   0
                                  :transparent-side :none))
          (setf (model-cell-layers-topmost layers) 0)
          (setf (gethash key (screen-layered-cells screen)) layers)
          layers))))

(defun set-layer (screen col row layer-num glyph-idx
                  &key (ink-slot 1) (bg-slot 0) (transparent-side :none))
  "Set a specific layer at (COL, ROW).
   LAYER-NUM 0 is the base layer; 1-2 are overlay layers."
  (assert (<= 0 layer-num (1- +max-layers+)))
  (let ((layers (%ensure-layered screen col row)))
    (setf (aref (model-cell-layers-layers layers) layer-num)
          (make-model-layer :glyph-idx glyph-idx
                            :ink-slot ink-slot
                            :bg-slot bg-slot
                            :transparent-side transparent-side))
    ;; Update topmost
    (when (> layer-num (model-cell-layers-topmost layers))
      (setf (model-cell-layers-topmost layers) layer-num))
    (%mark-dirty screen row)))

(defun clear-overlay-layers (screen col row)
  "Clear layers 1 and 2, leaving layer 0 intact.
   The cell remains layered but topmost becomes 0."
  (let ((layers (%get-layered screen col row)))
    (when layers
      (setf (aref (model-cell-layers-layers layers) 1) nil
            (aref (model-cell-layers-layers layers) 2) nil
            (model-cell-layers-topmost layers) 0)
      (%mark-dirty screen row))))

;;; --------------------------------------------------------------------------
;;; Write operations
;;; --------------------------------------------------------------------------

(defun write-char-at (screen col row glyph-idx &key (swatch nil) (attrs nil) wide)
  "Write a character at (COL, ROW) to the topmost active layer.
   For simple cells, this writes to layer 0.
   For layered cells, this writes to the topmost layer.
   SWATCH and ATTRS, if provided, update those values.
   WIDE, when T, marks this as a double-wide character: it occupies (COL,ROW) and
   (COL+1,ROW). The right half is cleared and acts as a continuation cell."
  (let* ((cols (screen-cols screen))
         (i (%idx screen col row)))
    ;; A pair never begins in the last column, where its right half would fall
    ;; outside the row (LEXTER-O26)
    (when (and wide (>= col (1- cols)))
      (setf wide nil))
    ;; If overwriting the right half of an existing wide char, clear the left half
    (when (and (> col 0)
               (= 1 (sbit (screen-wide-flags screen) (%idx screen (1- col) row))))
      (let ((left-i (%idx screen (1- col) row)))
        (setf (sbit (screen-wide-flags screen) left-i) 0
              (aref (screen-glyphs screen) left-i) (screen-blank-glyph screen))))
    ;; If this cell was wide, clear its old continuation
    (when (= 1 (sbit (screen-wide-flags screen) i))
      (let ((next-col (1+ col)))
        (when (< next-col cols)
          (let ((next-i (%idx screen next-col row)))
            (setf (aref (screen-glyphs screen) next-i) (screen-blank-glyph screen))))))
    (let ((layers (%get-layered screen col row)))
      (if layers
          ;; Layered: write to topmost layer, and give the cell the swatch and
          ;; attributes as a simple cell takes them (LEXTER-O27)
          (let* ((ln (model-cell-layers-topmost layers))
                 (lobj (aref (model-cell-layers-layers layers) ln)))
            (if lobj
                (setf (model-layer-glyph-idx lobj) glyph-idx)
                (setf (aref (model-cell-layers-layers layers) ln)
                      (make-model-layer :glyph-idx glyph-idx
                                        :ink-slot 1
                                        :bg-slot 0
                                        :transparent-side (if (zerop ln) :none :bg))))
            (when swatch
              (setf (model-cell-layers-swatch-idx layers) swatch
                    (aref (screen-swatch-indices screen) i) swatch))
            (when attrs
              (setf (aref (screen-attrs screen) i) attrs)))
          ;; Simple: write directly
          (progn
            (setf (aref (screen-glyphs screen) i) glyph-idx)
            (when swatch
              (setf (aref (screen-swatch-indices screen) i) swatch))
            (when attrs
              (setf (aref (screen-attrs screen) i) attrs)))))
    ;; Set/clear wide flag
    (setf (sbit (screen-wide-flags screen) i) (if wide 1 0))
    ;; Handle wide: mark continuation cell
    (when wide
      (let ((next-col (1+ col)))
        (when (< next-col cols)
          (let ((next-i (%idx screen next-col row)))
            (setf (aref (screen-glyphs screen) next-i) 0
                  (sbit (screen-wide-flags screen) next-i) 0)
            (when swatch
              (setf (aref (screen-swatch-indices screen) next-i) swatch))))))
    (%mark-dirty screen row)))

(defun write-string-at (screen col row string &key (swatch nil) (attrs nil)
                                                   (codepoint-fn #'char-code))
  "Write STRING starting at (COL, ROW).
   CODEPOINT-FN converts each character to a glyph index."
  (loop :for c :across string
        :for x :from col
        :while (< x (screen-cols screen))
        :do (write-char-at screen x row (funcall codepoint-fn c)
                           :swatch swatch :attrs attrs)))

;;; --------------------------------------------------------------------------
;;; Cursor-relative write (targets topmost layer)
;;; --------------------------------------------------------------------------

(defun put-char (screen glyph-idx &key (swatch nil) (attrs nil) (advance t) wide)
  "Write a character at the cursor position and optionally advance.
   Targets the topmost active layer.
   WIDE, when T, writes a double-wide character and advances by 2."
  (let ((col (screen-cursor-col screen))
        (cols (screen-cols screen)))
    ;; A wide char cannot begin in the last column: blank it and write the pair
    ;; at the start of the next row, scrolling at the bottom (LEXTER-O26)
    (when (and wide (>= col (1- cols)) (> cols 1))
      (write-char-at screen col (screen-cursor-row screen)
                     (screen-blank-glyph screen) :swatch swatch)
      (line-feed screen)
      (setf col 0))
    (write-char-at screen col (screen-cursor-row screen)
                   glyph-idx :swatch swatch :attrs attrs :wide wide)
    (when advance
      (let ((advance-by (if wide 2 1)))
        (let ((new-col (+ col advance-by)))
          (if (>= new-col cols)
              ;; Wrap or stay at edge depending on mode
              (setf (screen-cursor-col screen) (1- cols))
              (setf (screen-cursor-col screen) new-col)))))))

(defun delete-char (screen)
  "Delete the character at cursor by writing the blank on the topmost layer."
  (write-char-at screen (screen-cursor-col screen) (screen-cursor-row screen)
                 (screen-blank-glyph screen)))

;;; --------------------------------------------------------------------------
;;; Erase operations
;;; --------------------------------------------------------------------------
;;;
;;; A cell's glyph, swatch, attributes, wide flag, and layered entry move and
;;; clear together, and every range operation repairs a double-width pair it
;;; cuts at its edges, as a terminal blanks the other half of a pair when one
;;; half is overwritten (LEXTER-D98, LEXTER-O26). In the first edition a pair is
;;; a left half marked wide and a right half holding glyph 0, the empty glyph.

(declaim (inline %wide-left-p))
(defun %wide-left-p (screen col row)
  "True when the cell at COL, ROW is the left half of a double-width pair."
  (and (< -1 col (screen-cols screen))
       (= 1 (sbit (screen-wide-flags screen) (%idx screen col row)))))

(defun %blank-cell (screen col row)
  "Blank the simple cell at COL, ROW: the blank glyph, no attributes, not
   wide. Its swatch is kept, and a layered entry is left to the caller."
  (let ((i (%idx screen col row)))
    (setf (aref (screen-glyphs screen) i) (screen-blank-glyph screen)
          (aref (screen-attrs screen) i) 0
          (sbit (screen-wide-flags screen) i) 0)))

(defun %repair-pair-edges (screen row start end)
  "Before an operation changes columns START to END - 1 of ROW, blank the half
   of a pair that would be left outside the range: the left half at START - 1
   of a pair whose right half is START, and the right half at END of a pair
   whose left half is END - 1."
  (let ((cols (screen-cols screen)))
    (when (and (< 0 start cols) (%wide-left-p screen (1- start) row))
      (%blank-cell screen (1- start) row))
    (when (and (< 0 end cols) (%wide-left-p screen (1- end) row))
      (%blank-cell screen end row)
      (setf (sbit (screen-wide-flags screen) (%idx screen (1- end) row)) 0))))

(defun %erase-cell (screen col row)
  "Erase a single cell on the topmost layer, and its wide flag."
  (let ((layers (%get-layered screen col row))
        (blank (screen-blank-glyph screen))
        (i (%idx screen col row)))
    (setf (sbit (screen-wide-flags screen) i) 0)
    (if layers
        ;; Write blank to topmost layer
        (let* ((ln (model-cell-layers-topmost layers))
               (lobj (aref (model-cell-layers-layers layers) ln)))
          (when lobj
            (setf (model-layer-glyph-idx lobj) blank)))
        ;; Simple cell
        (setf (aref (screen-glyphs screen) i) blank
              (aref (screen-attrs screen) i) 0))))

(defun %erase-range (screen row start end)
  "Erase columns START to END - 1 of ROW, repairing a pair cut at either edge."
  (let ((end (min end (screen-cols screen))))
    (when (< start end)
      (%repair-pair-edges screen row start end)
      (loop :for col :from start :below end :do (%erase-cell screen col row)))
    (%mark-dirty screen row)))

(defun erase-in-display (screen mode)
  "Erase parts of the display.
   MODE 0: cursor to end of screen
   MODE 1: start of screen to cursor  
   MODE 2: entire screen
   MODE 3: entire screen + scrollback"
  (let ((cols (screen-cols screen))
        (rows (screen-rows screen))
        (cc (screen-cursor-col screen))
        (cr (screen-cursor-row screen)))
    (ecase mode
      (0 ;; Cursor to end
       (%erase-range screen cr cc cols)
       (loop :for row :from (1+ cr) :below rows :do (%erase-range screen row 0 cols)))
      (1 ;; Start to cursor
       (loop :for row :from 0 :below cr :do (%erase-range screen row 0 cols))
       (%erase-range screen cr 0 (1+ cc)))
      (2 ;; Entire screen
       (loop :for row :from 0 :below rows :do (%erase-range screen row 0 cols)))
      (3 ;; Entire screen + scrollback
       (erase-in-display screen 2)
       (setf (screen-scrollback-count screen) 0
             (screen-scrollback-viewport screen) 0)))))

(defun erase-in-line (screen mode)
  "Erase parts of the current line.
   MODE 0: cursor to end of line
   MODE 1: start of line to cursor
   MODE 2: entire line"
  (let ((cols (screen-cols screen))
        (row (screen-cursor-row screen))
        (cc (screen-cursor-col screen)))
    (ecase mode
      (0 (%erase-range screen row cc cols))
      (1 (%erase-range screen row 0 (1+ cc)))
      (2 (%erase-range screen row 0 cols)))))

(defun erase-chars (screen n)
  "Erase N characters starting at cursor (replace with blanks)."
  (let ((cc (screen-cursor-col screen)))
    (%erase-range screen (screen-cursor-row screen) cc (+ cc n))))

;;; --------------------------------------------------------------------------
;;; Insert/delete characters
;;; --------------------------------------------------------------------------

(defun %move-cell (screen src-col dst-col row)
  "Copy the cell at SRC-COL to DST-COL of ROW whole: its glyph, swatch,
   attributes, wide flag, and layered entry."
  (let ((si (%idx screen src-col row))
        (di (%idx screen dst-col row))
        (table (screen-layered-cells screen)))
    (setf (aref (screen-glyphs screen) di) (aref (screen-glyphs screen) si)
          (aref (screen-swatch-indices screen) di) (aref (screen-swatch-indices screen) si)
          (aref (screen-attrs screen) di) (aref (screen-attrs screen) si)
          (sbit (screen-wide-flags screen) di) (sbit (screen-wide-flags screen) si))
    (let ((layers (gethash (cons src-col row) table)))
      (if layers
          (setf (gethash (cons dst-col row) table) layers)
          (remhash (cons dst-col row) table)))))

(defun %clear-cell-whole (screen col row)
  "Make the cell at COL, ROW a blank simple cell, removing any layered entry."
  (%blank-cell screen col row)
  (remhash (cons col row) (screen-layered-cells screen)))

(defun insert-chars (screen n)
  "Insert N blank characters at cursor, shifting rest of line right."
  (let* ((row (screen-cursor-row screen))
         (col (screen-cursor-col screen))
         (cols (screen-cols screen))
         (n (min n (- cols col))))
    (when (plusp n)
      ;; A pair cut at the cursor loses its left half
      (%repair-pair-edges screen row col col)
      ;; Shift cells right, whole
      (loop :for c :from (1- cols) :downto (+ col n)
            :do (%move-cell screen (- c n) c row))
      ;; Clear inserted positions
      (loop :for c :from col :below (+ col n)
            :do (%clear-cell-whole screen c row))
      ;; A pair whose right half was pushed off the end loses its left half
      (when (%wide-left-p screen (1- cols) row)
        (%blank-cell screen (1- cols) row)))
    (%mark-dirty screen row)))

(defun delete-chars (screen n)
  "Delete N characters at cursor, shifting rest of line left."
  (let* ((row (screen-cursor-row screen))
         (col (screen-cursor-col screen))
         (cols (screen-cols screen))
         (n (min n (- cols col))))
    (when (plusp n)
      ;; A pair cut at either edge of the deleted range loses its other half
      (%repair-pair-edges screen row col (+ col n))
      ;; Shift cells left, whole
      (loop :for c :from col :below (- cols n)
            :do (%move-cell screen (+ c n) c row))
      ;; Clear vacated positions
      (loop :for c :from (- cols n) :below cols
            :do (%clear-cell-whole screen c row)))
    (%mark-dirty screen row)))

;;; --------------------------------------------------------------------------
;;; Line operations
;;; --------------------------------------------------------------------------

(defun %copy-row (screen src-row dst-row)
  "Copy row data from SRC-ROW to DST-ROW: glyphs, swatches, attributes, wide
   flags, and layered entries."
  (let* ((cols (screen-cols screen))
         (src (%idx screen 0 src-row))
         (dst (%idx screen 0 dst-row)))
    (replace (screen-glyphs screen) (screen-glyphs screen)
             :start1 dst :start2 src :end2 (+ src cols))
    (replace (screen-swatch-indices screen) (screen-swatch-indices screen)
             :start1 dst :start2 src :end2 (+ src cols))
    (replace (screen-attrs screen) (screen-attrs screen)
             :start1 dst :start2 src :end2 (+ src cols))
    (replace (screen-wide-flags screen) (screen-wide-flags screen)
             :start1 dst :start2 src :end2 (+ src cols))
    ;; Handle layered cells
    (loop :for col :from 0 :below cols
          :for src-key = (cons col src-row)
          :for dst-key = (cons col dst-row)
          :for layers = (gethash src-key (screen-layered-cells screen))
          :do (if layers
                  (setf (gethash dst-key (screen-layered-cells screen)) layers)
                  (remhash dst-key (screen-layered-cells screen))))
    (%mark-dirty screen dst-row)))

(defun %clear-row (screen row)
  "Clear a row to blank cells."
  (let ((cols (screen-cols screen))
        (blank (screen-blank-glyph screen))
        (default-sw (screen-default-swatch screen)))
    (loop :for col :from 0 :below cols
          :for i = (%idx screen col row)
          :do (setf (aref (screen-glyphs screen) i) blank
                    (aref (screen-swatch-indices screen) i) default-sw
                    (aref (screen-attrs screen) i) 0
                    (sbit (screen-wide-flags screen) i) 0)
              (remhash (cons col row) (screen-layered-cells screen)))
    (%mark-dirty screen row)))

(defun insert-lines (screen n)
  "Insert N blank lines at cursor row, scrolling lines down within scroll region."
  (let ((top (screen-cursor-row screen))
        (bottom (screen-scroll-bottom screen)))
    (loop :for row :from bottom :downto (+ top n)
          :do (%copy-row screen (- row n) row))
    (loop :for row :from top :below (min (+ top n) (1+ bottom))
          :do (%clear-row screen row))))

(defun delete-lines (screen n)
  "Delete N lines at cursor row, scrolling lines up within scroll region."
  (let ((top (screen-cursor-row screen))
        (bottom (screen-scroll-bottom screen)))
    (loop :for row :from top :to (- bottom n)
          :do (%copy-row screen (+ row n) row))
    (loop :for row :from (max top (1+ (- bottom n))) :to bottom
          :do (%clear-row screen row))))

;;; --------------------------------------------------------------------------
;;; Scrolling
;;; --------------------------------------------------------------------------

(defun %save-to-scrollback (screen row)
  "Save a row to scrollback before it scrolls off."
  (when (screen-scrollback-enabled screen)
    (let* ((max (screen-scrollback-max screen))
           (count (screen-scrollback-count screen))
           (lines (screen-scrollback-lines screen))
           (cols (screen-cols screen))
           ;; Save as a simple list: (glyph swatch attrs) per cell
           (line (make-array cols)))
      (loop :for col :from 0 :below cols
            :for i = (%idx screen col row)
            :do (setf (aref line col)
                      (list (aref (screen-glyphs screen) i)
                            (aref (screen-swatch-indices screen) i)
                            (aref (screen-attrs screen) i))))
      ;; Ring buffer insert
      (let ((idx (mod count max)))
        (setf (aref lines idx) line))
      (setf (screen-scrollback-count screen) (1+ count)))))

(defun line-feed (screen)
  "Move the cursor down one row, keeping its column, as a line feed does: on
   the scrolling region's bottom margin the region scrolls up; elsewhere the
   cursor moves down, stopping on the screen's last row. Every path that moves
   to the next line, autowrap included, goes through here, so that the
   region's rule has one home (LEXTER-D69)."
  (let ((row (screen-cursor-row screen)))
    (cond ((= row (screen-scroll-bottom screen))
           (scroll-up screen))
          ((< row (1- (screen-rows screen)))
           (set-cursor-position screen (screen-cursor-col screen) (1+ row))))))

(defun reverse-line-feed (screen)
  "Move the cursor up one row, keeping its column, as a reverse index does: on
   the scrolling region's top margin the region scrolls down; elsewhere the
   cursor moves up, stopping on the screen's first row (LEXTER-D69)."
  (let ((row (screen-cursor-row screen)))
    (cond ((= row (screen-scroll-top screen))
           (scroll-down screen))
          ((plusp row)
           (set-cursor-position screen (screen-cursor-col screen) (1- row))))))

(defun scroll-up (screen &optional (n 1))
  "Scroll the scrolling region up by N lines. More lines than the region holds
   scroll it as its height does (LEXTER-D68)."
  (let* ((top (screen-scroll-top screen))
         (bottom (screen-scroll-bottom screen))
         (n (min n (1+ (- bottom top)))))
    (loop :repeat n :do
      ;; Save top line to scrollback if at actual top
      (when (zerop top)
        (%save-to-scrollback screen top))
      ;; Shift lines up
      (loop :for row :from top :below bottom
            :do (%copy-row screen (1+ row) row))
      ;; Clear bottom line
      (%clear-row screen bottom))))

(defun scroll-down (screen &optional (n 1))
  "Scroll the scrolling region down by N lines. More lines than the region
   holds scroll it as its height does (LEXTER-D68)."
  (let* ((top (screen-scroll-top screen))
         (bottom (screen-scroll-bottom screen))
         (n (min n (1+ (- bottom top)))))
    (loop :repeat n :do
      ;; Shift lines down
      (loop :for row :from bottom :above top
            :do (%copy-row screen (1- row) row))
      ;; Clear top line
      (%clear-row screen top))))

(defun set-scrolling-region (screen top bottom)
  "Set the scrolling region (VT DECSTBM). TOP and BOTTOM are 0-indexed, inclusive."
  (setf (screen-scroll-top screen) (max 0 top)
        (screen-scroll-bottom screen) (min bottom (1- (screen-rows screen)))))

;;; --------------------------------------------------------------------------
;;; Scrollback access
;;; --------------------------------------------------------------------------

(defun scrollback-lines (screen)
  "Return the number of lines in scrollback."
  (min (screen-scrollback-count screen) (screen-scrollback-max screen)))

(defun scrollback-line (screen n)
  "Return scrollback line N (0 = most recent). Returns NIL if out of range."
  (let* ((count (scrollback-lines screen))
         (max (screen-scrollback-max screen))
         (total (screen-scrollback-count screen))
         (lines (screen-scrollback-lines screen)))
    (when (< n count)
      (let ((idx (mod (- total 1 n) max)))
        (aref lines idx)))))

(defun scrollback-viewport-offset (screen)
  (screen-scrollback-viewport screen))

(defun set-scrollback-viewport (screen offset)
  "Set scrollback viewport offset. 0 = live screen, >0 = looking at history."
  (setf (screen-scrollback-viewport screen)
        (max 0 (min offset (scrollback-lines screen)))))

;;; --------------------------------------------------------------------------
;;; Resize
;;; --------------------------------------------------------------------------

(defun resize-screen (screen new-cols new-rows)
  "Resize the screen. Preserves content where possible."
  (let* ((old-cols (screen-cols screen))
         (old-rows (screen-rows screen))
         (new-n (* new-cols new-rows))
         (blank (screen-blank-glyph screen))
         (new-glyphs (make-array new-n :element-type '(unsigned-byte 32) :initial-element blank))
         (new-swatch-indices (make-array new-n :element-type '(unsigned-byte 16)
                                                :initial-element (screen-default-swatch screen)))
         (new-attrs (make-array new-n :element-type '(unsigned-byte 32) :initial-element 0))
         (new-wide-flags (make-array new-n :element-type 'bit :initial-element 0))
         (new-layered (make-hash-table :test 'equal :size 64))
         (new-dirty (make-array new-rows :element-type 'bit :initial-element 1)))
    ;; Copy existing data
    (loop :for row :from 0 :below (min old-rows new-rows)
          :do (loop :for col :from 0 :below (min old-cols new-cols)
                    :for old-i = (+ (* row old-cols) col)
                    :for new-i = (+ (* row new-cols) col)
                     :do (setf (aref new-glyphs new-i) (aref (screen-glyphs screen) old-i)
                               (aref new-swatch-indices new-i) (aref (screen-swatch-indices screen) old-i)
                               (aref new-attrs new-i) (aref (screen-attrs screen) old-i)
                               (sbit new-wide-flags new-i) (sbit (screen-wide-flags screen) old-i))))
    ;; A pair cut by a narrower right edge loses its left half (LEXTER-O26)
    (when (< new-cols old-cols)
      (loop :for row :from 0 :below (min old-rows new-rows)
            :for i = (+ (* row new-cols) (1- new-cols))
            :when (= 1 (sbit new-wide-flags i))
              :do (setf (sbit new-wide-flags i) 0
                        (aref new-glyphs i) blank)))
    ;; Copy layered cells that fit
    (maphash (lambda (key layers)
               (destructuring-bind (col . row) key
                 (when (and (< col new-cols) (< row new-rows))
                   (setf (gethash key new-layered) layers))))
             (screen-layered-cells screen))
    ;; Update
    (setf (screen-cols screen) new-cols
          (screen-rows screen) new-rows
          (screen-glyphs screen) new-glyphs
          (screen-swatch-indices screen) new-swatch-indices
          (screen-attrs screen) new-attrs
          (screen-wide-flags screen) new-wide-flags
          (screen-layered-cells screen) new-layered
          (screen-row-dirty screen) new-dirty
          (screen-scroll-bottom screen) (1- new-rows))
    ;; Clamp cursor
    (setf (screen-cursor-col screen) (min (screen-cursor-col screen) (1- new-cols))
          (screen-cursor-row screen) (min (screen-cursor-row screen) (1- new-rows)))
    screen))

;;; --------------------------------------------------------------------------
;;; Flush to display grid
;;; --------------------------------------------------------------------------

(defun %flush-cell (screen display-grid col row grid-col grid-row space-glyph)
  "Copy the cell at COL, ROW of SCREEN to GRID-COL, GRID-ROW of DISPLAY-GRID:
   a layered cell whole, its absent layers included, or a simple cell whose
   glyph 0 is drawn as SPACE-GLYPH. A double-width pair whose right half would
   fall past the grid's right edge is clipped to its left half."
  (let ((layers (%get-layered screen col row)))
    (if layers
        ;; Layered cell: rebuilt from nothing, so that a layer the model has
        ;; cleared is cleared in the grid too (LEXTER-O27)
        (let ((sw-idx (model-cell-layers-swatch-idx layers)))
          (lexter/grid:clear-cell-layers display-grid grid-col grid-row)
          (lexter/grid:set-cell-swatch display-grid grid-col grid-row sw-idx)
          (loop :for ln :from 0 :below +max-layers+
                :for lobj = (aref (model-cell-layers-layers layers) ln)
                :when lobj
                :do (lexter/grid:set-cell-layer
                     display-grid grid-col grid-row ln
                     (model-layer-glyph-idx lobj)
                     (model-layer-ink-slot lobj)
                     :bg-slot (model-layer-bg-slot lobj)
                     :transparent-side (model-layer-transparent-side lobj))))
        ;; Simple cell - clear any overlay layers first
        (progn
          (lexter/grid:clear-cell-layers display-grid grid-col grid-row)
          (let ((i (%idx screen col row)))
            (lexter/grid:set-simple-cell
             display-grid grid-col grid-row
             (let ((g (aref (screen-glyphs screen) i)))
               (if (zerop g) space-glyph g))
             (aref (screen-swatch-indices screen) i)
             :wide (and (= 1 (sbit (screen-wide-flags screen) i))
                        (< (1+ grid-col) (lexter/grid:display-grid-cols display-grid)))))))))

(defun %check-row-pairs (screen row)
  "Blank any left half of a pair in ROW of SCREEN that has no right half: one
   in the last column, or one whose next cell holds a glyph or begins a pair of
   its own. A safety net under the operations that keep pairs (LEXTER-D98)."
  (let ((cols (screen-cols screen)))
    (loop :for col :from 0 :below cols
          :for i = (%idx screen col row)
          :when (and (= 1 (sbit (screen-wide-flags screen) i))
                     (or (= col (1- cols))
                         (/= 0 (aref (screen-glyphs screen) (1+ i)))
                         (= 1 (sbit (screen-wide-flags screen) (1+ i)))))
            :do (setf (sbit (screen-wide-flags screen) i) 0
                      (aref (screen-glyphs screen) i) (screen-blank-glyph screen)))))

(defun %flush-history-row (screen display-grid line grid-row col-offset space-glyph)
  "Write the history LINE, a vector of (glyph swatch attrs) for each cell as
   %SAVE-TO-SCROLLBACK keeps it, to GRID-ROW of DISPLAY-GRID from COL-OFFSET, as
   simple cells, a glyph 0 drawn as SPACE-GLYPH. A line narrower than SCREEN,
   left by a resize, is padded with blanks in the screen's default swatch."
  (let ((grid-cols (lexter/grid:display-grid-cols display-grid))
        (width (if line (length line) 0)))
    (loop :for col :from 0 :below (screen-cols screen)
          :for grid-col = (+ col col-offset)
          :when (< grid-col grid-cols)
          :do (destructuring-bind (glyph swatch &rest attrs)
                  (if (< col width)
                      (aref line col)
                      (list 0 (screen-default-swatch screen) 0))
                (declare (ignore attrs))
                (lexter/grid:set-simple-cell display-grid grid-col grid-row
                                             (if (zerop glyph) space-glyph glyph)
                                             swatch)))))

(defun flush-to-display (screen display-grid &key (atlas nil) (space-glyph 0)
                                                   (cursor-blink-on t)
                                                   (col-offset 0) (row-offset 0))
  "Copy screen state to the display grid for rendering.
   ATLAS is used to look up cursor glyph indices.
   SPACE-GLYPH is the atlas index for space character.
   CURSOR-BLINK-ON controls whether a blinking cursor is currently visible.
   COL-OFFSET and ROW-OFFSET position the screen within the grid (for panes).
   While the screen's scrollback viewport is above 0, the grid shows history
   above the top rows of the screen, every row is repainted, and no cursor is
   drawn."
  (declare (ignore atlas))
  (let ((cols (screen-cols screen))
        (rows (screen-rows screen))
        (cc (screen-cursor-col screen))
        (cr (screen-cursor-row screen))
        (grid-cols (lexter/grid:display-grid-cols display-grid))
        (grid-rows (lexter/grid:display-grid-rows display-grid)))
    ;; Always mark cursor row dirty so it gets updated every frame
    ;; This ensures cursor blink and movement are always rendered
    (when (< cr rows)
      (setf (sbit (screen-row-dirty screen) cr) 1))
    ;; Cells hold global swatch indices, which mean the same in the grid and
    ;; on the GPU, so they are copied unchanged and no table is copied into
    ;; the grid (LEXTER-D100).
    ;; Copy cells (including clearing old cursor position). Row D of the pane
    ;; shows, with the viewport V lines back, history line V-1-D while that is
    ;; 0 or more, and otherwise the screen's row D-V. At V = 0 that is the
    ;; screen itself, and only its dirty rows are copied; above 0 the view is
    ;; shifted, so every row is repainted (LEXTER-DRAFT-pane-profiles-D5).
    ;; Each pair is written once, from its left half, which marks the right
    ;; half as its continuation in the grid (LEXTER-D98).
    ;; Bounds: iterate screen coords, but clip to grid bounds after offset
    (let ((viewport (screen-scrollback-viewport screen)))
      (loop :for row :from 0 :below rows
            :for grid-row = (+ row row-offset)
            :for history-line = (- viewport 1 row)
            :when (and (or (plusp viewport)
                           (= 1 (sbit (screen-row-dirty screen) row)))
                       (< grid-row grid-rows))
            :do (if (and (plusp viewport) (>= history-line 0))
                    (%flush-history-row screen display-grid
                                        (scrollback-line screen history-line)
                                        grid-row col-offset space-glyph)
                    (let ((source-row (- row viewport)))
                      (%check-row-pairs screen source-row)
                      (loop :for col :from 0 :below cols
                            :for grid-col = (+ col col-offset)
                            :when (and (< grid-col grid-cols)
                                       (not (%wide-left-p screen (1- col) source-row)))
                            :do (%flush-cell screen display-grid col source-row
                                             grid-col grid-row space-glyph))))))
    ;; No cursor is drawn while the view is scrolled back into the history.
    (when (plusp (screen-scrollback-viewport screen))
      (fill (screen-row-dirty screen) 0)
      (return-from flush-to-display nil))
    ;; The cursor is drawn by exchanging the ink and background slots of its
    ;; cell's layer 0 in the grid, keeping the cell's swatch, layers, and wide
    ;; flag, so that it interns no swatch and breaks no pair (LEXTER-D101). The
    ;; cursor's row is copied from the model at every flush, which removes it
    ;; from where it was.
    (let ((cursor-visible (and (screen-cursor-visible screen)
                               (or (not (screen-cursor-blink screen))
                                   cursor-blink-on)))
          (grid-cc (+ cc col-offset))
          (grid-cr (+ cr row-offset)))
      (when (and cursor-visible
                 (< cc cols) (< cr rows)
                 (< grid-cc grid-cols) (< grid-cr grid-rows))
        ;; On the right half of a pair, the cursor covers the pair's left half
        (when (and (> grid-cc col-offset)
                   (lexter/grid:continuation-p display-grid grid-cc grid-cr))
          (decf grid-cc))
        (lexter/grid:exchange-cell-slots display-grid grid-cc grid-cr)))
    ;; Clear model dirty flags
    (fill (screen-row-dirty screen) 0)))
