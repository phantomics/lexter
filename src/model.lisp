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

(defconstant +max-layers+ 3)
(defconstant +swatch-slots+ 4)

;;; --------------------------------------------------------------------------
;;; Swatch table with interning
;;; --------------------------------------------------------------------------

(defun %make-initial-swatch-data ()
  "Create swatch data array with slot 0 initialized to (0, 7, 7, 0)."
  (let ((data (make-array (* 2048 +swatch-slots+)
                          :element-type '(unsigned-byte 8)
                          :initial-element 0)))
    ;; Initialize slot 0: bg=0 (black), fg=7 (white), ov=7, sec=0
    (setf (aref data 0) 0    ; bg
          (aref data 1) 7    ; fg
          (aref data 2) 7    ; overlay
          (aref data 3) 0)   ; secondary
    data))

(defun %make-initial-swatch-index ()
  "Create swatch index hash with slot 0 pre-registered."
  (let ((ht (make-hash-table :test 'equal)))
    ;; Register the key for (0, 7, 7, 0) -> index 0
    (setf (gethash (%swatch-key 0 7 7 0) ht) 0)
    ht))

(defstruct swatch-table
  "Table of swatches with hash-based interning."
  ;; Flat array: swatch i occupies bytes [i*4 .. i*4+3]
  (data    (%make-initial-swatch-data)
           :type (simple-array (unsigned-byte 8) (*)))
  (count   1 :type fixnum)   ; next free slot (0 is pre-allocated)
  (capacity 2048 :type fixnum)
  ;; Hash: (s0 s1 s2 s3) -> index
  (index   (%make-initial-swatch-index) :type hash-table)
  ;; Generation counter: incremented on each new swatch
  (generation 1 :type fixnum))

(defun %swatch-key (s0 s1 s2 s3)
  (logior s0 (ash s1 8) (ash s2 16) (ash s3 24)))

(defun intern-swatch (table s0 s1 s2 s3)
  "Return the swatch index for (S0 S1 S2 S3), creating if needed."
  (let ((key (%swatch-key s0 s1 s2 s3)))
    (or (gethash key (swatch-table-index table))
        (let ((idx (swatch-table-count table)))
          (when (>= idx (swatch-table-capacity table))
            ;; Grow the table
            (let* ((new-cap (* 2 (swatch-table-capacity table)))
                   (new-data (make-array (* new-cap +swatch-slots+)
                                         :element-type '(unsigned-byte 8)
                                         :initial-element 0)))
              (replace new-data (swatch-table-data table))
              (setf (swatch-table-data table) new-data
                    (swatch-table-capacity table) new-cap)))
          (let ((base (* idx +swatch-slots+))
                (data (swatch-table-data table)))
            (setf (aref data (+ base 0)) s0
                  (aref data (+ base 1)) s1
                  (aref data (+ base 2)) s2
                  (aref data (+ base 3)) s3))
          (setf (gethash key (swatch-table-index table)) idx)
          (incf (swatch-table-count table))
          (incf (swatch-table-generation table))
          idx))))

(defun get-swatch-values (table idx)
  "Return the 4 palette indices for swatch IDX as multiple values."
  (let ((base (* idx +swatch-slots+))
        (data (swatch-table-data table)))
    (values (aref data (+ base 0))
            (aref data (+ base 1))
            (aref data (+ base 2))
            (aref data (+ base 3)))))

;;; --------------------------------------------------------------------------
;;; Color Palette
;;; --------------------------------------------------------------------------

(defun make-default-palette ()
  "Create the standard xterm 256-color palette as a float array.
   Returns a (simple-array single-float (1024)) with RGBA values 0.0-1.0."
  (let ((p (make-array 1024 :element-type 'single-float :initial-element 0.0)))
    (flet ((set-rgb (i r g b)
             (setf (aref p (+ (* i 4) 0)) (/ r 255.0)
                   (aref p (+ (* i 4) 1)) (/ g 255.0)
                   (aref p (+ (* i 4) 2)) (/ b 255.0)
                   (aref p (+ (* i 4) 3)) 1.0))
           (comp6 (v) (if (zerop v) 0 (+ 55 (* 40 v)))))
      ;; Colors 0-15: standard ANSI
      (loop :for (r g b) :in '((0   0   0)    ; 0  black
                               (170 0   0)    ; 1  dark red
                               (0   170 0)    ; 2  dark green
                               (170 85  0)    ; 3  dark yellow
                               (0   0   170)  ; 4  dark blue
                               (170 0   170)  ; 5  dark magenta
                               (0   170 170)  ; 6  dark cyan
                               (170 170 170)  ; 7  light grey
                               (85  85  85)   ; 8  dark grey
                               (255 85  85)   ; 9  bright red
                               (85  255 85)   ; 10 bright green
                               (255 255 85)   ; 11 bright yellow
                               (85  85  255)  ; 12 bright blue
                               (255 85  255)  ; 13 bright magenta
                               (85  255 255)  ; 14 bright cyan
                               (255 255 255)) ; 15 white
            :for i :from 0
            :do (set-rgb i r g b))
      ;; Colors 16-231: 6x6x6 cube
      (loop :for i :from 16 :to 231
            :for n = (- i 16)
            :do (set-rgb i
                         (comp6 (floor n 36))
                         (comp6 (mod (floor n 6) 6))
                         (comp6 (mod n 6))))
      ;; Colors 232-255: greyscale ramp
      (loop :for i :from 232 :to 255
            :for v = (+ 8 (* 10 (- i 232)))
            :do (set-rgb i v v v)))
    p))

(defun set-palette-entry (screen idx r g b &optional (a 1.0))
  "Set palette entry IDX to the given RGBA values (0.0-1.0).
   Increments the palette generation for GPU sync."
  (let ((p (screen-palette screen))
        (base (* idx 4)))
    (setf (aref p (+ base 0)) (coerce r 'single-float)
          (aref p (+ base 1)) (coerce g 'single-float)
          (aref p (+ base 2)) (coerce b 'single-float)
          (aref p (+ base 3)) (coerce a 'single-float)))
  (incf (screen-palette-generation screen)))

(defun set-palette-entry-rgb8 (screen idx r g b)
  "Set palette entry IDX to the given RGB values (0-255).
   Increments the palette generation for GPU sync."
  (set-palette-entry screen idx (/ r 255.0) (/ g 255.0) (/ b 255.0) 1.0))

(defun get-palette-entry (screen idx)
  "Return the RGBA values for palette entry IDX as multiple values."
  (let ((p (screen-palette screen))
        (base (* idx 4)))
    (values (aref p (+ base 0))
            (aref p (+ base 1))
            (aref p (+ base 2))
            (aref p (+ base 3)))))

(defun reset-palette (screen)
  "Reset the screen's palette to the default xterm colors.
   Increments the palette generation for GPU sync."
  (let ((default (make-default-palette))
        (palette (screen-palette screen)))
    (replace palette default)
    (incf (screen-palette-generation screen))))

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
  ;; The glyph index to use for "blank" cells (space character in the atlas)
  ;; This must be set by the caller after atlas lookup.
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
  ;; --- Swatch table ---
  (swatches  nil :type (or null swatch-table))
  ;; --- Cursor state ---
  (cursor-col     0   :type fixnum)
  (cursor-row     0   :type fixnum)
  (cursor-visible t   :type boolean)
  (cursor-style   :block :type keyword)  ; :block, :underline, :bar
  (cursor-blink   t   :type boolean)
  ;; --- Scrolling region (VT only) ---
  (scroll-top    0    :type fixnum)
  (scroll-bottom 23   :type fixnum)  ; inclusive
  ;; --- Mode flags ---
  (mode-flags    0    :type (unsigned-byte 32))
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
  ;; --- Default swatch for new cells ---
  (default-swatch 0 :type fixnum)
  ;; --- Color palette (256 RGBA colors as floats, 1024 total) ---
  (palette nil :type (or null (simple-array single-float (1024))))
  (palette-generation 1 :type fixnum))

;;; --------------------------------------------------------------------------
;;; Constructor
;;; --------------------------------------------------------------------------

(defun make-screen (&key (cols 80) (rows 24) (mode :unix)
                         (scrollback-max 2000))
  "Create a new screen buffer."
  (let* ((n (* cols rows))
         (swatches (make-swatch-table)))
    ;; Intern the default swatch (index 0): black bg, white fg
    (intern-swatch swatches 0 7 7 0)  ; bg=0(black), fg=7(white), overlay=7, secondary=0
    (%make-screen
     :cols            cols
     :rows            rows
     :mode            mode
     :glyphs          (make-array n :element-type '(unsigned-byte 32) :initial-element 32)
     :swatch-indices  (make-array n :element-type '(unsigned-byte 16) :initial-element 0)
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
     :default-swatch  0
     :palette         (make-default-palette)
     :palette-generation 1)))

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
          (if lobj (model-layer-glyph-idx lobj) 32))
        (aref (screen-glyphs screen) (%idx screen col row)))))

(defun cell-swatch (screen col row)
  "Return the swatch index at (COL, ROW)."
  (let ((layers (%get-layered screen col row)))
    (if layers
        ;; For layered cells, we'd need to compute a swatch index
        ;; For now, return the simple-path swatch
        (aref (screen-swatch-indices screen) (%idx screen col row))
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
          ;; Layered: write to topmost layer
          (let* ((ln (model-cell-layers-topmost layers))
                 (lobj (aref (model-cell-layers-layers layers) ln)))
            (if lobj
                (setf (model-layer-glyph-idx lobj) glyph-idx)
                (setf (aref (model-cell-layers-layers layers) ln)
                      (make-model-layer :glyph-idx glyph-idx
                                        :ink-slot 1
                                        :bg-slot 0
                                        :transparent-side (if (zerop ln) :none :bg)))))
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
    ;; For wide chars at the last column, can't fit — write a space and wrap
    (when (and wide (>= col (1- cols)))
      (write-char-at screen col (screen-cursor-row screen)
                     (screen-blank-glyph screen) :swatch swatch)
      (setf col (1- cols)))
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
  "Delete the character at cursor by writing a space on the topmost layer."
  (write-char-at screen (screen-cursor-col screen) (screen-cursor-row screen) 32))

;;; --------------------------------------------------------------------------
;;; Erase operations
;;; --------------------------------------------------------------------------

(defun %erase-cell (screen col row)
  "Erase a single cell on the topmost layer."
  (let ((layers (%get-layered screen col row))
        (blank (screen-blank-glyph screen)))
    (if layers
        ;; Write blank to topmost layer
        (let* ((ln (model-cell-layers-topmost layers))
               (lobj (aref (model-cell-layers-layers layers) ln)))
          (when lobj
            (setf (model-layer-glyph-idx lobj) blank)))
        ;; Simple cell
        (let ((i (%idx screen col row)))
          (setf (aref (screen-glyphs screen) i) blank
                (aref (screen-attrs screen) i) 0)))))

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
       (loop :for col :from cc :below cols :do (%erase-cell screen col cr))
       (%mark-dirty screen cr)
       (loop :for row :from (1+ cr) :below rows
             :do (loop :for col :from 0 :below cols :do (%erase-cell screen col row))
                 (%mark-dirty screen row)))
      (1 ;; Start to cursor
       (loop :for row :from 0 :below cr
             :do (loop :for col :from 0 :below cols :do (%erase-cell screen col row))
                 (%mark-dirty screen row))
       (loop :for col :from 0 :to cc :do (%erase-cell screen col cr))
       (%mark-dirty screen cr))
      (2 ;; Entire screen
       (loop :for row :from 0 :below rows
             :do (loop :for col :from 0 :below cols :do (%erase-cell screen col row))
                 (%mark-dirty screen row)))
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
      (0 (loop :for col :from cc :below cols :do (%erase-cell screen col row)))
      (1 (loop :for col :from 0 :to cc :do (%erase-cell screen col row)))
      (2 (loop :for col :from 0 :below cols :do (%erase-cell screen col row))))
    (%mark-dirty screen row)))

(defun erase-chars (screen n)
  "Erase N characters starting at cursor (replace with spaces)."
  (let ((row (screen-cursor-row screen))
        (cols (screen-cols screen)))
    (loop :for i :from 0 :below n
          :for col = (+ (screen-cursor-col screen) i)
          :while (< col cols)
          :do (%erase-cell screen col row))
    (%mark-dirty screen row)))

;;; --------------------------------------------------------------------------
;;; Insert/delete characters
;;; --------------------------------------------------------------------------

(defun insert-chars (screen n)
  "Insert N blank characters at cursor, shifting rest of line right."
  (let* ((row (screen-cursor-row screen))
         (col (screen-cursor-col screen))
         (cols (screen-cols screen)))
    ;; Shift characters right (simple path only for now)
    (loop :for c :from (1- cols) :downto (+ col n)
          :for src = (- c n)
          :for di = (%idx screen c row)
          :for si = (%idx screen src row)
          :do (setf (aref (screen-glyphs screen) di) (aref (screen-glyphs screen) si)
                    (aref (screen-swatch-indices screen) di) (aref (screen-swatch-indices screen) si)
                    (aref (screen-attrs screen) di) (aref (screen-attrs screen) si)))
    ;; Clear inserted positions
    (let ((blank (screen-blank-glyph screen)))
      (loop :for c :from col :below (min (+ col n) cols)
            :for i = (%idx screen c row)
            :do (setf (aref (screen-glyphs screen) i) blank
                      (aref (screen-attrs screen) i) 0)))
    (%mark-dirty screen row)))

(defun delete-chars (screen n)
  "Delete N characters at cursor, shifting rest of line left."
  (let* ((row (screen-cursor-row screen))
         (col (screen-cursor-col screen))
         (cols (screen-cols screen)))
    ;; Shift characters left
    (loop :for c :from col :below (- cols n)
          :for src = (+ c n)
          :for di = (%idx screen c row)
          :for si = (%idx screen src row)
          :do (setf (aref (screen-glyphs screen) di) (aref (screen-glyphs screen) si)
                    (aref (screen-swatch-indices screen) di) (aref (screen-swatch-indices screen) si)
                    (aref (screen-attrs screen) di) (aref (screen-attrs screen) si)))
    ;; Clear vacated positions
    (let ((blank (screen-blank-glyph screen)))
      (loop :for c :from (max col (- cols n)) :below cols
            :for i = (%idx screen c row)
            :do (setf (aref (screen-glyphs screen) i) blank
                      (aref (screen-attrs screen) i) 0)))
    (%mark-dirty screen row)))

;;; --------------------------------------------------------------------------
;;; Line operations
;;; --------------------------------------------------------------------------

(defun %copy-row (screen src-row dst-row)
  "Copy row data from SRC-ROW to DST-ROW."
  (let ((cols (screen-cols screen)))
    (loop :for col :from 0 :below cols
          :for si = (%idx screen col src-row)
          :for di = (%idx screen col dst-row)
          :do (setf (aref (screen-glyphs screen) di) (aref (screen-glyphs screen) si)
                    (aref (screen-swatch-indices screen) di) (aref (screen-swatch-indices screen) si)
                    (aref (screen-attrs screen) di) (aref (screen-attrs screen) si)))
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
                    (aref (screen-attrs screen) i) 0)
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

(defun scroll-up (screen &optional (n 1))
  "Scroll the scrolling region up by N lines."
  (let ((top (screen-scroll-top screen))
        (bottom (screen-scroll-bottom screen)))
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
  "Scroll the scrolling region down by N lines."
  (let ((top (screen-scroll-top screen))
        (bottom (screen-scroll-bottom screen)))
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
;;; Modes
;;; --------------------------------------------------------------------------

(defun set-mode (screen flag value)
  "Set a mode flag. FLAG is a keyword, VALUE is boolean."
  (declare (ignore screen flag value))
  ;; TODO: implement mode flag storage
  nil)

(defun get-mode (screen flag)
  "Get a mode flag value."
  (declare (ignore screen flag))
  nil)

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
         (new-swatch-indices (make-array new-n :element-type '(unsigned-byte 16) :initial-element 0))
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

(defun flush-to-display (screen display-grid &key (atlas nil) (space-glyph 32)
                                                   (cursor-blink-on t)
                                                   (col-offset 0) (row-offset 0))
  "Copy screen state to the display grid for rendering.
   ATLAS is used to look up cursor glyph indices.
   SPACE-GLYPH is the atlas index for space character.
   CURSOR-BLINK-ON controls whether a blinking cursor is currently visible.
   COL-OFFSET and ROW-OFFSET position the screen within the grid (for panes)."
  (declare (ignore atlas))
  (let ((cols (screen-cols screen))
        (rows (screen-rows screen))
        (swatches (screen-swatches screen))
        (cc (screen-cursor-col screen))
        (cr (screen-cursor-row screen))
        (grid-cols (lexter/grid:display-grid-cols display-grid))
        (grid-rows (lexter/grid:display-grid-rows display-grid)))
    ;; Always mark cursor row dirty so it gets updated every frame
    ;; This ensures cursor blink and movement are always rendered
    (when (< cr rows)
      (setf (sbit (screen-row-dirty screen) cr) 1))
    ;; Sync swatch table only if generation changed
    (let ((model-gen (swatch-table-generation swatches))
          (grid-gen (lexter/grid:swatch-generation display-grid)))
      (when (/= model-gen grid-gen)
        (let ((sw-data (swatch-table-data swatches))
              (sw-count (swatch-table-count swatches)))
          (loop :for i :from 0 :below sw-count
                :for base = (* i +swatch-slots+)
                :do (lexter/grid:set-swatch display-grid i
                                            (aref sw-data (+ base 0))
                                            (aref sw-data (+ base 1))
                                            (aref sw-data (+ base 2))
                                            (aref sw-data (+ base 3)))))
        (setf (lexter/grid:swatch-generation display-grid) model-gen)))
    ;; Copy cells (including clearing old cursor position)
    ;; Bounds: iterate screen coords, but clip to grid bounds after offset
    (loop :for row :from 0 :below rows
          :for grid-row = (+ row row-offset)
          :when (and (= 1 (sbit (screen-row-dirty screen) row))
                     (< grid-row grid-rows))
          :do (loop :for col :from 0 :below cols
                    :for grid-col = (+ col col-offset)
                    :when (< grid-col grid-cols)
                    :do (let ((layers (%get-layered screen col row)))
                          (if layers
                              ;; Layered cell
                              (let ((sw-idx (model-cell-layers-swatch-idx layers)))
                                (lexter/grid:set-cell-swatch display-grid grid-col grid-row sw-idx)
                                (loop :for ln :from 0 :below +max-layers+
                                      :for lobj = (aref (model-cell-layers-layers layers) ln)
                                      :when lobj
                                      :do (lexter/grid:set-cell-layer
                                           display-grid grid-col grid-row ln
                                           (model-layer-glyph-idx lobj)
                                           (model-layer-ink-slot lobj)
                                           :bg-idx (model-layer-bg-slot lobj)
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
                                   :wide (= 1 (sbit (screen-wide-flags screen) i)))))))))
    ;; Handle cursor rendering using reverse video (swap fg/bg)
    (let ((cursor-visible (and (screen-cursor-visible screen)
                               (or (not (screen-cursor-blink screen))
                                   cursor-blink-on)))
          (grid-cc (+ cc col-offset))
          (grid-cr (+ cr row-offset)))
      (when (and (< cc cols) (< cr rows)
                 (< grid-cc grid-cols) (< grid-cr grid-rows))
        ;; Use grid coordinates for cell access
        (let* ((cell-idx (+ (* grid-cr grid-cols) grid-cc))
               (glyph (aref (lexter/grid::display-grid-glyphs display-grid) cell-idx))
               (sw-idx (aref (lexter/grid::display-grid-swatch-indices display-grid) cell-idx)))
          (if cursor-visible
              ;; Cursor ON: create a reversed swatch and use it
              (multiple-value-bind (bg fg ov sec)
                  (lexter/grid:get-swatch display-grid sw-idx)
                ;; Intern a reversed swatch (fg becomes bg, bg becomes fg)
                (let ((rev-sw (intern-swatch swatches fg bg ov sec)))
                  ;; Sync this new swatch to display grid immediately
                  (let* ((sw-data (swatch-table-data swatches))
                         (base (* rev-sw +swatch-slots+)))
                    (lexter/grid:set-swatch display-grid rev-sw
                                            (aref sw-data (+ base 0))
                                            (aref sw-data (+ base 1))
                                            (aref sw-data (+ base 2))
                                            (aref sw-data (+ base 3))))
                  ;; Apply reversed swatch to display grid
                  (lexter/grid:set-simple-cell display-grid grid-cc grid-cr
                                               (if (zerop glyph) space-glyph glyph)
                                               rev-sw)))
              ;; Cursor OFF: restore normal swatch from model
              (let ((model-sw (aref (screen-swatch-indices screen)
                                    (+ (* cr (screen-cols screen)) cc))))
                (lexter/grid:set-simple-cell display-grid grid-cc grid-cr
                                             (if (zerop glyph) space-glyph glyph)
                                             model-sw))))
        ;; Always mark cursor row dirty in grid
        (lexter/grid:mark-row-dirty display-grid grid-cr)))
    ;; Clear model dirty flags
    (fill (screen-row-dirty screen) 0)))
