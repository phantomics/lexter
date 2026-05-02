(in-package #:pcf-gl/model)

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

(defstruct swatch-table
  "Table of swatches with hash-based interning."
  ;; Flat array: swatch i occupies bytes [i*4 .. i*4+3]
  (data    (make-array (* 256 +swatch-slots+)
                       :element-type '(unsigned-byte 8)
                       :initial-element 0)
           :type (simple-array (unsigned-byte 8) (*)))
  (count   1 :type fixnum)   ; next free slot (0 is default)
  (capacity 256 :type fixnum)
  ;; Hash: (s0 s1 s2 s3) -> index
  (index   (make-hash-table :test 'equal) :type hash-table))

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
;;; Cell representation
;;; --------------------------------------------------------------------------

;; Each cell in the model is represented as 3 values packed into the cell array:
;;   - glyph-idx  (uint16)
;;   - swatch-idx (uint16)  
;;   - attrs      (uint32)
;; Plus optional layer data for layered cells.

(defstruct model-layer
  "A layer within a layered cell."
  (glyph-idx   0    :type (unsigned-byte 16))
  (ink-slot    1    :type (unsigned-byte 2))   ; swatch slot for ink
  (bg-slot     0    :type (unsigned-byte 2))   ; swatch slot for bg (layer 0)
  (transparent-side :none :type keyword))

(defstruct model-cell-layers
  "Layered cell data."
  ;; Local swatch: 4 global palette indices (may differ from the default swatch)
  (swatch (make-array +swatch-slots+ :element-type '(unsigned-byte 8) :initial-element 0)
          :type (simple-array (unsigned-byte 8) (4)))
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
  (glyphs        #() :type (simple-array (unsigned-byte 16) (*)))
  (swatch-indices #() :type (simple-array (unsigned-byte 16) (*)))
  (attrs         #() :type (simple-array (unsigned-byte 32) (*)))
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
  (default-swatch 0 :type fixnum))

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
     :glyphs          (make-array n :element-type '(unsigned-byte 16) :initial-element 32)
     :swatch-indices  (make-array n :element-type '(unsigned-byte 16) :initial-element 0)
     :attrs           (make-array n :element-type '(unsigned-byte 32) :initial-element 0)
     :layered-cells   (make-hash-table :test 'equal :size 64)
     :swatches        swatches
     :cursor-col      0
     :cursor-row      0
     :cursor-visible  t
     :cursor-style    :block
     :cursor-blink    t
     :scroll-top      0
     :scroll-bottom   (1- rows)
     :scrollback-enabled t
     :scrollback-max  scrollback-max
     :scrollback-lines (make-array scrollback-max :initial-element nil)
     :scrollback-count 0
     :scrollback-viewport 0
     :row-dirty       (make-array rows :element-type 'bit :initial-element 1)
     :default-swatch  0)))

;;; --------------------------------------------------------------------------
;;; Accessors
;;; --------------------------------------------------------------------------

(declaim (inline %idx %mark-dirty))

(defun %idx (screen col row)
  (+ (* row (screen-cols screen)) col))

(defun %mark-dirty (screen row)
  (when (< row (screen-rows screen))
    (setf (sbit (screen-row-dirty screen) row) 1)))

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
          ;; Copy swatch from table
          (let ((sw-idx (aref (screen-swatch-indices screen) i)))
            (multiple-value-bind (s0 s1 s2 s3)
                (get-swatch-values (screen-swatches screen) sw-idx)
              (let ((sw (model-cell-layers-swatch layers)))
                (setf (aref sw 0) s0
                      (aref sw 1) s1
                      (aref sw 2) s2
                      (aref sw 3) s3))))
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

(defun write-char-at (screen col row glyph-idx &key (swatch nil) (attrs nil))
  "Write a character at (COL, ROW) to the topmost active layer.
   For simple cells, this writes to layer 0.
   For layered cells, this writes to the topmost layer.
   SWATCH and ATTRS, if provided, update those values."
  (let ((layers (%get-layered screen col row)))
    (if layers
        ;; Layered: write to topmost layer
        (let* ((ln (model-cell-layers-topmost layers))
               (lobj (aref (model-cell-layers-layers layers) ln)))
          (if lobj
              (setf (model-layer-glyph-idx lobj) glyph-idx)
              ;; Topmost layer is nil? Create it.
              (setf (aref (model-cell-layers-layers layers) ln)
                    (make-model-layer :glyph-idx glyph-idx
                                      :ink-slot 1
                                      :bg-slot 0
                                      :transparent-side (if (zerop ln) :none :bg)))))
        ;; Simple: write directly
        (let ((i (%idx screen col row)))
          (setf (aref (screen-glyphs screen) i) glyph-idx)
          (when swatch
            (setf (aref (screen-swatch-indices screen) i) swatch))
          (when attrs
            (setf (aref (screen-attrs screen) i) attrs)))))
  (%mark-dirty screen row))

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

(defun put-char (screen glyph-idx &key (swatch nil) (attrs nil) (advance t))
  "Write a character at the cursor position and optionally advance.
   Targets the topmost active layer."
  (write-char-at screen (screen-cursor-col screen) (screen-cursor-row screen)
                 glyph-idx :swatch swatch :attrs attrs)
  (when advance
    (let ((new-col (1+ (screen-cursor-col screen))))
      (if (>= new-col (screen-cols screen))
          ;; Wrap or stay at edge depending on mode
          (setf (screen-cursor-col screen) (1- (screen-cols screen)))
          (setf (screen-cursor-col screen) new-col)))))

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
    (loop :for c :from col :below (min (+ col n) cols)
          :for i = (%idx screen c row)
          :do (setf (aref (screen-glyphs screen) i) 32
                    (aref (screen-attrs screen) i) 0))
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
    (loop :for c :from (max col (- cols n)) :below cols
          :for i = (%idx screen c row)
          :do (setf (aref (screen-glyphs screen) i) 32
                    (aref (screen-attrs screen) i) 0))
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
  "Clear a row to spaces."
  (let ((cols (screen-cols screen))
        (default-sw (screen-default-swatch screen)))
    (loop :for col :from 0 :below cols
          :for i = (%idx screen col row)
          :do (setf (aref (screen-glyphs screen) i) 32
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
         (new-glyphs (make-array new-n :element-type '(unsigned-byte 16) :initial-element 32))
         (new-swatch-indices (make-array new-n :element-type '(unsigned-byte 16) :initial-element 0))
         (new-attrs (make-array new-n :element-type '(unsigned-byte 32) :initial-element 0))
         (new-layered (make-hash-table :test 'equal :size 64))
         (new-dirty (make-array new-rows :element-type 'bit :initial-element 1)))
    ;; Copy existing data
    (loop :for row :from 0 :below (min old-rows new-rows)
          :do (loop :for col :from 0 :below (min old-cols new-cols)
                    :for old-i = (+ (* row old-cols) col)
                    :for new-i = (+ (* row new-cols) col)
                    :do (setf (aref new-glyphs new-i) (aref (screen-glyphs screen) old-i)
                              (aref new-swatch-indices new-i) (aref (screen-swatch-indices screen) old-i)
                              (aref new-attrs new-i) (aref (screen-attrs screen) old-i))))
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
                                                   (cursor-blink-on t))
  "Copy screen state to the display grid for rendering.
   ATLAS is used to look up cursor glyph indices.
   SPACE-GLYPH is the atlas index for space character.
   CURSOR-BLINK-ON controls whether a blinking cursor is currently visible."
  (let ((cols (screen-cols screen))
        (rows (screen-rows screen))
        (swatches (screen-swatches screen))
        (cc (screen-cursor-col screen))
        (cr (screen-cursor-row screen)))
    ;; Always mark cursor row dirty so it gets updated every frame
    ;; This ensures cursor blink and movement are always rendered
    (when (< cr rows)
      (setf (sbit (screen-row-dirty screen) cr) 1))
    ;; First, sync the swatch table
    (let ((sw-data (swatch-table-data swatches))
          (sw-count (swatch-table-count swatches)))
      (loop :for i :from 0 :below sw-count
            :for base = (* i +swatch-slots+)
            :do (pcf-gl/grid:set-swatch display-grid i
                                        (aref sw-data (+ base 0))
                                        (aref sw-data (+ base 1))
                                        (aref sw-data (+ base 2))
                                        (aref sw-data (+ base 3)))))
    ;; Copy cells (including clearing old cursor position)
    (loop :for row :from 0 :below (min rows (pcf-gl/grid:display-grid-rows display-grid))
          :when (= 1 (sbit (screen-row-dirty screen) row))
          :do (loop :for col :from 0 :below (min cols (pcf-gl/grid:display-grid-cols display-grid))
                    :for layers = (%get-layered screen col row)
                    :do (if layers
                            ;; Layered cell
                            (let ((sw (model-cell-layers-swatch layers)))
                              (pcf-gl/grid:set-cell-swatch display-grid col row sw)
                              (loop :for ln :from 0 :below +max-layers+
                                    :for lobj = (aref (model-cell-layers-layers layers) ln)
                                    :when lobj
                                    :do (pcf-gl/grid:set-cell-layer
                                         display-grid col row ln
                                         (model-layer-glyph-idx lobj)
                                         (model-layer-ink-slot lobj)
                                         :bg-idx (model-layer-bg-slot lobj)
                                         :transparent-side (model-layer-transparent-side lobj))))
                            ;; Simple cell - clear any overlay layers first
                            (progn
                              (pcf-gl/grid:clear-cell-layers display-grid col row)
                              (let ((i (%idx screen col row)))
                                (pcf-gl/grid:set-simple-cell
                                 display-grid col row
                                 (let ((g (aref (screen-glyphs screen) i)))
                                   (if (zerop g) space-glyph g))
                                 (aref (screen-swatch-indices screen) i)))))))
    ;; Handle cursor rendering - ALWAYS draw cursor when visible, regardless of dirty state
    (let ((cursor-visible (and (screen-cursor-visible screen)
                               (or (not (screen-cursor-blink screen))
                                   cursor-blink-on))))
      (when (and (< cc cols) (< cr rows))
        (if (not atlas)
            ;; No atlas - just clear any cursor layers
            (pcf-gl/grid:clear-cell-layers display-grid cc cr)
            ;; Have atlas - render cursor
            (let* ((cursor-codepoint (ecase (screen-cursor-style screen)
                                       (:block     pcf-gl/atlas:+cursor-block-glyph+)
                                       (:underline pcf-gl/atlas:+cursor-underline-glyph+)
                                       (:bar       pcf-gl/atlas:+cursor-bar-glyph+)))
                   (cursor-glyph (pcf-gl/atlas:atlas-glyph-index atlas cursor-codepoint)))
              (if (and cursor-visible cursor-glyph)
                  (progn
                    ;; Ensure layer 0 has the base character
                    ;; (This copies from simple glyph array if not already layered)
                    (pcf-gl/grid:set-cell-layer display-grid cc cr 0
                                                (let* ((i (+ (* cr cols) cc))
                                                       (g (aref (pcf-gl/grid::display-grid-glyphs display-grid) i)))
                                                  (if (zerop g) space-glyph g))
                                                1  ; ink-slot = foreground
                                                :bg-idx 0
                                                :transparent-side :none)
                    ;; Draw cursor on layer 1 with foreground color (ink slot 1)
                    ;; The cursor glyph is solid where the cursor should appear
                    (pcf-gl/grid:set-cell-layer display-grid cc cr 1
                                                cursor-glyph
                                                1  ; ink-slot = foreground
                                                :bg-idx 0
                                                :transparent-side :bg))
                  ;; When cursor is NOT visible (blink off), clear cursor cell to simple
                  (pcf-gl/grid:clear-cell-layers display-grid cc cr))))
        ;; Always mark cursor row dirty so renderer updates it
        (pcf-gl/grid:mark-row-dirty display-grid cr)))
    ;; Clear model dirty flags
    (fill (screen-row-dirty screen) 0)))
