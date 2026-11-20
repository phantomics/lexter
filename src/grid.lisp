(in-package #:lexter/grid)

;;;; The composed grid (LEXTER-D107)
;;;;
;;;; One grid of records holds every text pane and its chrome. Its records are
;;;; a Lisp array of bytes, 32 to a record, row by row, read and written only
;;;; through the accessors over the record's manifests (LEXTER-D129,
;;;; LEXTER-D130). Beside them the grid keeps a drawn row for each row: so far
;;;; its change stamp, taken from one counter global to Lexter whenever a
;;;; record in the row is written (LEXTER-D113). A reader that remembers the
;;;; stamps it took finds the rows changed since.
;;;;
;;;; Records hold global swatch indices into the store whose ranges the swatch
;;;; tables own (swatches.lisp); the grid keeps no swatches of its own
;;;; (LEXTER-D99, LEXTER-D100). Swatch slots by convention:
;;;;   Slot 0 = background
;;;;   Slot 1 = foreground
;;;;   Slot 2 = primary overlay (cursor, layer 1)
;;;;   Slot 3 = secondary overlay (selection, layer 2)
;;;;
;;;; A surface is a grid with text beside its records: a rectangle that the API
;;;; writes (surface.lisp), and copies into the composed grid (LEXTER-D124).
;;;;
;;;; The renderer takes the records as they are, as the instances of one draw
;;;; (LEXTER-D107), uploading the rows whose stamps are newer than those it
;;;; took, as PLAN-RECORD-UPLOADS decides without GL, and deriving each row's
;;;; clock mask as it takes it (LEXTER-D113).

;;; --------------------------------------------------------------------------
;;; Clocks
;;; --------------------------------------------------------------------------

(defconstant +clock-blink+ 1
  "The bit of a row's clock mask set when a cell in it blinks (LEXTER-D94).")

;;; --------------------------------------------------------------------------
;;; Change stamps
;;; --------------------------------------------------------------------------

(declaim (type (unsigned-byte 62) *change-counter*))
(defvar *change-counter* 0
  "The last change stamp taken: one counter global to Lexter, so that a stamp
   orders every write to every grid (LEXTER-D113).")

(declaim (inline next-change-stamp))
(defun next-change-stamp ()
  "Take a new change stamp."
  (incf *change-counter*))

;;; --------------------------------------------------------------------------
;;; The grid
;;; --------------------------------------------------------------------------

(defstruct (display-grid (:constructor %make-display-grid))
  "The composed grid: its records, row by row, and a drawn row for each row."
  (cols          80  :type fixnum)
  (rows          24  :type fixnum)
  (records (make-record-array 0) :type record-array)
  ;; The drawn rows' change stamps (LEXTER-D113)
  (stamps  (make-array 0 :element-type '(unsigned-byte 64)) :type (simple-array (unsigned-byte 64) (*)))
  ;; The drawn rows' clock masks, which the renderer derives from the
  ;; records as it takes each row (LEXTER-D113)
  (clock-masks (make-array 0 :element-type '(unsigned-byte 8))
               :type (simple-array (unsigned-byte 8) (*)))
  ;; The atlas whose glyphs the API writes by codepoint, and the palette slot
  ;; its records draw in
  (atlas nil)
  (palette-slot 0 :type (unsigned-byte 8)))

(defun %clock-mask-array (rows)
  (make-array rows :element-type '(unsigned-byte 8) :initial-element 0))

(defun %stamp-array (rows)
  (make-array rows :element-type '(unsigned-byte 64) :initial-element (next-change-stamp)))

(defun make-display-grid (&key (cols 80) (rows 24) atlas)
  "Create a display grid with COLS columns and ROWS rows, every cell a record
   of zeros, a blank in global swatch 0, the default colours (LEXTER-D83),
   whose API writes take glyphs from ATLAS. Every row is newer than any stamp
   a reader took before."
  (%make-display-grid :cols cols :rows rows :atlas atlas
                      :records (make-record-array (* cols rows))
                      :stamps (%stamp-array rows)
                      :clock-masks (%clock-mask-array rows)))

(defstruct (surface (:include display-grid) (:constructor %make-surface))
  "A rectangle of records with text beside them, written only through the
   API, whose rows are copied into the composed grid (LEXTER-D124). Its text
   cells hold each character's codepoint and wide bit, in style 0, for
   selection, copying, and search (LEXTER-D119)."
  (text (make-text-array 0) :type text-array))

(defun make-surface (&key (cols 1) (rows 1) atlas (palette-slot 0))
  "Make a surface of COLS by ROWS, every record of zeros and every text cell
   empty, whose glyphs come from ATLAS and whose records draw in
   PALETTE-SLOT."
  (%make-surface :cols cols :rows rows :atlas atlas :palette-slot palette-slot
                 :records (make-record-array (* cols rows))
                 :text (make-text-array (* cols rows))
                 :stamps (%stamp-array rows)
                 :clock-masks (%clock-mask-array rows)))

(defun resize-surface (surface cols rows)
  "Give SURFACE COLS by ROWS cells, all empty, and new stamps in every row."
  (setf (display-grid-cols surface) cols
        (display-grid-rows surface) rows
        (display-grid-records surface) (make-record-array (* cols rows))
        (surface-text surface) (make-text-array (* cols rows))
        (display-grid-stamps surface) (%stamp-array rows)
        (display-grid-clock-masks surface) (%clock-mask-array rows))
  surface)

(declaim (inline %idx))
(defun %idx (grid col row)
  (+ (* row (display-grid-cols grid)) col))

(defun cell-index (grid col row)
  "The index of the record at COL, ROW of GRID in its array of records."
  (%idx grid col row))

(defun row-stamp (grid row)
  "The change stamp of ROW of GRID: the stamp taken when a record in it was
   last written."
  (aref (display-grid-stamps grid) row))

(defun touch-row (grid row)
  "Give ROW of GRID a new change stamp, so that every reader takes it again."
  (setf (aref (display-grid-stamps grid) row) (next-change-stamp)))

(defun touch-all-rows (grid)
  "Give every row of GRID a new change stamp, as replacing the grid, changing
   the workspace, or resizing does (LEXTER-D113)."
  (fill (display-grid-stamps grid) (next-change-stamp))
  grid)

;;; --------------------------------------------------------------------------
;;; Writing records
;;; --------------------------------------------------------------------------

(defun write-text-record (grid col row &key (glyph 0) (visible t) (swatch 0)
                                            (palette-slot 0) (background-slot 0)
                                            (ink-slot 1) underline-glyph
                                            wide right-half blink)
  "Write the cell at COL, ROW of GRID as a cell of text, in the plain format:
   GLYPH as one layer in INK-SLOT, cut by UNDERLINE-GLYPH as a union mask when
   it is given, so that the underline takes the text's colour (LEXTER-D88);
   no glyphs at all when VISIBLE is false or GLYPH is 0. SWATCH, PALETTE-SLOT,
   and BACKGROUND-SLOT are the header word's; WIDE and RIGHT-HALF place the
   cell in a double-width character, and BLINK sets its blink flag."
  (let ((records (display-grid-records grid))
        (index (%idx grid col row))
        (wide (if wide 1 0))
        (right-half (if right-half 1 0))
        (blink (if blink 1 0)))
    (cond ((or (not visible) (and (zerop glyph) (null underline-glyph)))
           (write-plain-record records index
             :wide wide :right-half right-half :blink blink
             :swatch swatch :palette-slot palette-slot :background-slot background-slot))
          ((null underline-glyph)
           (write-plain-record records index
             :glyph-count 1 :wide wide :right-half right-half :blink blink
             :swatch swatch :palette-slot palette-slot :background-slot background-slot
             :g0 (:glyph glyph :ink-slot ink-slot)))
          (t
           (write-plain-record records index
             :glyph-count 2 :type-1 1 :wide wide :right-half right-half :blink blink
             :swatch swatch :palette-slot palette-slot :background-slot background-slot
             :g0 (:glyph glyph :ink-slot ink-slot)
             :g1 (:glyph underline-glyph :operation :union))))
    (touch-row grid row)))

(defun clear-cell (grid col row)
  "Make the cell at COL, ROW of GRID a record of zeros."
  (clear-records (display-grid-records grid) (%idx grid col row) 1)
  (touch-row grid row))

;;; --------------------------------------------------------------------------
;;; Reading records
;;; --------------------------------------------------------------------------

(defun continuation-p (grid col row)
  "True when the cell at COL, ROW is the right half of a double-width glyph."
  (multiple-value-bind (wide right-half)
      (read-record-common (display-grid-records grid) (%idx grid col row) :wide :right-half)
    (and (= wide 1) (= right-half 1))))

(defun wide-left-p (grid col row)
  "True when the cell at COL, ROW is the left half of a double-width glyph."
  (multiple-value-bind (wide right-half)
      (read-record-common (display-grid-records grid) (%idx grid col row) :wide :right-half)
    (and (= wide 1) (= right-half 0))))

(defun cell-glyph (grid col row &optional (i 0))
  "The atlas position of glyph I of the plain record at COL, ROW, or 0 when it
   has fewer glyphs."
  (let ((records (display-grid-records grid))
        (index (%idx grid col row)))
    (if (< i (read-plain-record records index :glyph-count))
        (record-glyph records index i)
        0)))

(defun cell-swatch (grid col row)
  "The global swatch index of the cell at COL, ROW."
  (read-record-common (display-grid-records grid) (%idx grid col row) :swatch))

;;; --------------------------------------------------------------------------
;;; The interim cursor
;;; --------------------------------------------------------------------------

(defun exchange-cell-slots (grid col row)
  "Draw the cell at COL, ROW as the block cursor until the overlay list draws
   it (LEXTER-D101, LEXTER-D93): its background slot exchanged with its
   topmost layer's ink slot, in both halves of a double-width glyph so that
   the halves still match (LEXTER-D126). A cell with no layer takes slot 1,
   the foreground, as its background. Its swatch is kept, so no reversed
   swatch is interned."
  (let ((records (display-grid-records grid)))
    (flet ((exchange (c)
             (let* ((index (%idx grid c row))
                    (top (and (eq (record-format records index) :plain)
                              (record-topmost-layer records index)))
                    (background (read-record-common records index :background-slot)))
               (if top
                   (let ((ink (record-ink-slot records index top)))
                     (setf (record-ink-slot records index top) background)
                     (patch-record-common records index :background-slot ink))
                   (patch-record-common records index :background-slot 1)))))
      (exchange col)
      (cond ((and (wide-left-p grid col row) (< (1+ col) (display-grid-cols grid)))
             (exchange (1+ col)))
            ((and (continuation-p grid col row) (plusp col))
             (exchange (1- col)))))
    (touch-row grid row)))

;;; --------------------------------------------------------------------------
;;; Uploads (the renderer's decision, without GL)
;;; --------------------------------------------------------------------------

(defstruct (record-upload-state (:constructor make-record-upload-state ()))
  "What a renderer last took of a grid: the grid, its size, and each row's
   change stamp as it took it (LEXTER-D113)."
  (grid nil)
  (cols 0 :type fixnum)
  (rows 0 :type fixnum)
  (stamps (make-array 0 :element-type '(unsigned-byte 64))
          :type (simple-array (unsigned-byte 64) (*))))

(defun %derive-clock-mask (grid row)
  "The clock mask of ROW of GRID, from its records: +CLOCK-BLINK+ when a cell
   in it blinks (LEXTER-D94)."
  (let ((records (display-grid-records grid))
        (base (%idx grid 0 row)))
    (if (loop :for col :below (display-grid-cols grid)
              :thereis (= 1 (read-record-common records (+ base col) :blink)))
        +clock-blink+
        0)))

(defun plan-record-uploads (grid state)
  "The rows of GRID that a renderer whose last uploads STATE records must
   upload, as a list of spans (first-row count), and STATE updated to hold
   them as taken: every row when GRID is not the grid STATE last took or its
   size has changed, and otherwise each run of rows whose change stamps are
   newer than those taken (LEXTER-D113). The clock mask of each row taken is
   derived from its records. The second value is true when the whole grid is
   to be uploaded."
  (let* ((rows (display-grid-rows grid))
         (cols (display-grid-cols grid))
         (stamps (display-grid-stamps grid))
         (whole (not (and (eq grid (record-upload-state-grid state))
                          (= cols (record-upload-state-cols state))
                          (= rows (record-upload-state-rows state))))))
    (when whole
      (setf (record-upload-state-grid state) grid
            (record-upload-state-cols state) cols
            (record-upload-state-rows state) rows
            (record-upload-state-stamps state)
            (make-array rows :element-type '(unsigned-byte 64) :initial-element 0)))
    (let ((taken (record-upload-state-stamps state))
          (spans '())
          (start nil))
      (dotimes (row rows)
        (let ((newer (or whole (> (aref stamps row) (aref taken row)))))
          (when newer
            (setf (aref taken row) (aref stamps row)
                  (aref (display-grid-clock-masks grid) row) (%derive-clock-mask grid row))
            (unless start (setf start row)))
          (when (and start (not newer))
            (push (list start (- row start)) spans)
            (setf start nil))))
      (when start
        (push (list start (- rows start)) spans))
      (values (nreverse spans) whole))))

;;; --------------------------------------------------------------------------
;;; Resize
;;; --------------------------------------------------------------------------

(defun resize-grid (grid new-cols new-rows &key (blank-glyph 0))
  "Resize the grid to NEW-COLS x NEW-ROWS. Existing records are kept where
   they fit; new cells are BLANK-GLYPH in global swatch 0, and every row takes
   a new change stamp."
  (let* ((old-cols (display-grid-cols grid))
         (old-rows (display-grid-rows grid))
         (old (display-grid-records grid))
         (new (make-record-array (* new-cols new-rows))))
    (setf (display-grid-cols grid) new-cols
          (display-grid-rows grid) new-rows
          (display-grid-records grid) new
          (display-grid-stamps grid) (%stamp-array new-rows)
          (display-grid-clock-masks grid) (%clock-mask-array new-rows))
    (dotimes (row new-rows)
      (dotimes (col new-cols)
        (if (and (< row old-rows) (< col old-cols))
            (copy-records old (+ (* row old-cols) col) new (%idx grid col row) 1)
            (unless (zerop blank-glyph)
              (write-text-record grid col row :glyph blank-glyph)))))
    ;; A pair cut by a narrower right edge loses its left half's flag (LEXTER-O26)
    (when (< new-cols old-cols)
      (dotimes (row (min old-rows new-rows))
        (when (wide-left-p grid (1- new-cols) row)
          (patch-record-common new (%idx grid (1- new-cols) row) :wide 0))))
    (touch-all-rows grid)))
