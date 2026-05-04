(in-package #:lexter/grid)

;;;; Display grid for GPU rendering.
;;;;
;;;; This is the lowest-level display abstraction — it holds cell data in
;;;; a format ready for GPU upload.  The terminal model writes to this grid
;;;; via a flush operation.
;;;;
;;;; Key features:
;;;;   - Per-row dirty tracking for incremental updates
;;;;   - Swatch table: 4-slot colour schemes (bg, fg, overlay1, overlay2)
;;;;   - Simple path (1 layer) and layered path (up to 3 layers)
;;;;
;;;; Swatch slots by convention:
;;;;   Slot 0 = background
;;;;   Slot 1 = foreground
;;;;   Slot 2 = primary overlay (cursor, layer 1)
;;;;   Slot 3 = secondary overlay (selection, layer 2)

;;; --------------------------------------------------------------------------
;;; Constants
;;; --------------------------------------------------------------------------

(defconstant +simple-stride+  8)
;; Layered instance: col(2) row(2) glyph(2) ink(1) bg(1) ts(1) pad(1) palette(4) = 14
(defconstant +layered-stride+ 14)
(defconstant +max-layers+ 3)
(defconstant +swatch-slots+ 4)

;;; --------------------------------------------------------------------------
;;; Structures
;;; --------------------------------------------------------------------------

(defstruct cell-layer
  "One layer within a layered cell."
  (glyph-idx        0    :type (unsigned-byte 16))
  (ink-idx          0    :type (unsigned-byte 2))   ; swatch slot for ink
  (bg-idx           0    :type (unsigned-byte 2))   ; swatch slot for bg (layer 0 only)
  ;; :none = fully opaque both sides (layer 0)
  ;; :bg   = mask=0 pixels transparent, mask=1 uses ink
  ;; :fg   = mask=1 pixels transparent, mask=0 uses ink
  (transparent-side :none :type keyword))

(defstruct cell-location
  "A cell using the layered rendering path."
  ;; Swatch: 4 global-palette indices (slots 0-3)
  (swatch (make-array +swatch-slots+ :element-type '(unsigned-byte 8) :initial-element 0)
          :type (simple-array (unsigned-byte 8) (4)))
  ;; Layers 0-2; NIL = empty/inactive
  (layers (make-array +max-layers+ :initial-element nil) :type simple-vector))

(defstruct (display-grid (:constructor %make-display-grid))
  "GPU display grid with dirty tracking and swatch support."
  (cols          80  :type fixnum)
  (rows          24  :type fixnum)
  ;; --- Swatch table ---
  ;; Each swatch is 4 consecutive bytes (global palette indices for slots 0-3).
  ;; swatch-data[i*4 + slot] = palette index for swatch i, slot s
  (swatch-count  256 :type fixnum)
  (swatch-data   #() :type (simple-array (unsigned-byte 8) (*)))
  ;; --- Simple path storage (per-cell) ---
  (glyphs        #() :type (simple-array (unsigned-byte 16) (*)))
  (swatch-indices #() :type (simple-array (unsigned-byte 16) (*)))
  ;; --- Layered path storage (sparse) ---
  (layered-cells (make-hash-table :test 'equal) :type hash-table)
  (layered-flags #*  :type simple-bit-vector)
  ;; --- Dirty tracking (per-row) ---
  (row-dirty     #*  :type simple-bit-vector)
  ;; --- Swatch sync tracking ---
  (swatch-generation 0 :type fixnum)  ; last synced generation from model
  ;; --- Cached render buffers (persistent, updated incrementally) ---
  (simple-buffer   nil)
  (simple-count    0   :type fixnum)
  (layered-buffer  nil)
  (layered-counts  nil))  ; (simple-array fixnum (3))

;;; --------------------------------------------------------------------------
;;; Constructor
;;; --------------------------------------------------------------------------

(defun %allocate-render-buffers (grid)
  "Allocate or reallocate render buffers for GRID's current size."
  (let ((n (* (display-grid-cols grid) (display-grid-rows grid))))
    (setf (display-grid-simple-buffer grid)
          (make-array (* n +simple-stride+)
                      :element-type '(unsigned-byte 8)
                      :initial-element 0)
          (display-grid-simple-count grid) 0
          (display-grid-layered-buffer grid)
          (make-array (* n +layered-stride+ +max-layers+)
                      :element-type '(unsigned-byte 8)
                      :initial-element 0)
          (display-grid-layered-counts grid)
          (make-array +max-layers+ :element-type 'fixnum :initial-element 0))))

(defun make-display-grid (&key (cols 80) (rows 24) (swatch-count 256))
  "Create a display grid with COLS columns, ROWS rows, and SWATCH-COUNT swatches."
  (let* ((n (* cols rows))
         (grid (%make-display-grid
                :cols           cols
                :rows           rows
                :swatch-count   swatch-count
                :swatch-data    (make-array (* swatch-count +swatch-slots+)
                                            :element-type '(unsigned-byte 8)
                                            :initial-element 0)
                :glyphs         (make-array n :element-type '(unsigned-byte 16) :initial-element 0)
                :swatch-indices (make-array n :element-type '(unsigned-byte 16) :initial-element 0)
                :layered-cells  (make-hash-table :test 'equal :size 64)
                :layered-flags  (make-array n :element-type 'bit :initial-element 0)
                :row-dirty      (make-array rows :element-type 'bit :initial-element 1)
                :simple-buffer  nil
                :simple-count   0
                :layered-buffer nil
                :layered-counts (make-array +max-layers+ :element-type 'fixnum :initial-element 0))))
    (%allocate-render-buffers grid)
    grid))

;;; --------------------------------------------------------------------------
;;; Swatch API
;;; --------------------------------------------------------------------------

(defun set-swatch (grid swatch-idx slot0 slot1 slot2 slot3)
  "Define swatch SWATCH-IDX with the given palette indices for slots 0-3."
  (let ((base (* swatch-idx +swatch-slots+))
        (data (display-grid-swatch-data grid)))
    (setf (aref data (+ base 0)) slot0
          (aref data (+ base 1)) slot1
          (aref data (+ base 2)) slot2
          (aref data (+ base 3)) slot3)))

(defun get-swatch (grid swatch-idx)
  "Return the 4 palette indices for SWATCH-IDX as multiple values."
  (let ((base (* swatch-idx +swatch-slots+))
        (data (display-grid-swatch-data grid)))
    (values (aref data (+ base 0))
            (aref data (+ base 1))
            (aref data (+ base 2))
            (aref data (+ base 3)))))

(defun swatch-as-array (grid swatch-idx)
  "Return a fresh 4-element array with the swatch's palette indices."
  (let ((arr (make-array +swatch-slots+ :element-type '(unsigned-byte 8)))
        (base (* swatch-idx +swatch-slots+))
        (data (display-grid-swatch-data grid)))
    (dotimes (i +swatch-slots+ arr)
      (setf (aref arr i) (aref data (+ base i))))))

;;; --------------------------------------------------------------------------
;;; Dirty tracking
;;; --------------------------------------------------------------------------

(declaim (inline %idx mark-row-dirty))

(defun %idx (grid col row)
  (+ (* row (display-grid-cols grid)) col))

(defun mark-row-dirty (grid row)
  "Mark ROW as needing re-render."
  (setf (sbit (display-grid-row-dirty grid) row) 1))

(defun mark-all-dirty (grid)
  "Mark all rows dirty (for full redraw after resize etc.)."
  (fill (display-grid-row-dirty grid) 1))

(defun clear-dirty-flags (grid)
  "Clear all dirty flags after a successful render."
  (fill (display-grid-row-dirty grid) 0))

(defun row-dirty-p (grid row)
  (= 1 (sbit (display-grid-row-dirty grid) row)))

(defun swatch-generation (grid)
  "Return the last-synced swatch generation for GRID."
  (display-grid-swatch-generation grid))

(defun (setf swatch-generation) (value grid)
  "Set the last-synced swatch generation for GRID."
  (setf (display-grid-swatch-generation grid) value))

;;; --------------------------------------------------------------------------
;;; Simple path API
;;; --------------------------------------------------------------------------

(defun set-simple-cell (grid col row glyph-idx swatch-idx)
  "Set a simple (single-layer) cell at (COL, ROW).
   If the cell was layered, that state is cleared."
  (let ((i (%idx grid col row)))
    (setf (aref (display-grid-glyphs grid) i) glyph-idx
          (aref (display-grid-swatch-indices grid) i) swatch-idx
          (sbit (display-grid-layered-flags grid) i) 0)
    (remhash (cons col row) (display-grid-layered-cells grid))
    (mark-row-dirty grid row)))

;;; --------------------------------------------------------------------------
;;; Layered path API
;;; --------------------------------------------------------------------------

(defun %ensure-layered (grid col row)
  "Return the CELL-LOCATION for (COL, ROW), creating if necessary.
   A new location copies the cell's current swatch."
  (let ((key (cons col row)))
    (or (gethash key (display-grid-layered-cells grid))
        (let* ((i   (%idx grid col row))
               (loc (make-cell-location))
               (sw-idx (aref (display-grid-swatch-indices grid) i)))
          ;; Copy swatch data into local swatch
          (multiple-value-bind (s0 s1 s2 s3) (get-swatch grid sw-idx)
            (let ((sw (cell-location-swatch loc)))
              (setf (aref sw 0) s0
                    (aref sw 1) s1
                    (aref sw 2) s2
                    (aref sw 3) s3)))
          ;; Bootstrap layer 0 with current glyph
          (setf (aref (cell-location-layers loc) 0)
                (make-cell-layer :glyph-idx (aref (display-grid-glyphs grid) i)
                                 :ink-idx   1   ; fg = slot 1
                                 :bg-idx    0   ; bg = slot 0
                                 :transparent-side :none))
          (setf (sbit (display-grid-layered-flags grid) i) 1
                (gethash key (display-grid-layered-cells grid)) loc)
          (mark-row-dirty grid row)
          loc))))

(defun set-cell-swatch (grid col row swatch-array)
  "Set the per-cell swatch for a layered cell.
   SWATCH-ARRAY is a 4-element array of palette indices.
   The cell is promoted to layered mode if not already."
  (%ensure-layered grid col row)
  (let ((loc (gethash (cons col row) (display-grid-layered-cells grid))))
    (replace (cell-location-swatch loc) swatch-array)
    (mark-row-dirty grid row)))

(defun set-cell-layer (grid col row layer-num glyph-idx ink-idx
                       &key (bg-idx 0) (transparent-side :none))
  "Define layer LAYER-NUM (0-2) at (COL, ROW).
   INK-IDX/BG-IDX are swatch slot indices (0-3).
   TRANSPARENT-SIDE: :none (opaque), :bg (ink on mask=1), :fg (ink on mask=0)."
  (assert (<= 0 layer-num (1- +max-layers+)) (layer-num)
          "Layer number must be 0-~d" (1- +max-layers+))
  (%ensure-layered grid col row)
  (let ((loc (gethash (cons col row) (display-grid-layered-cells grid))))
    (setf (aref (cell-location-layers loc) layer-num)
          (make-cell-layer :glyph-idx        glyph-idx
                           :ink-idx          ink-idx
                           :bg-idx           bg-idx
                           :transparent-side transparent-side))
    (mark-row-dirty grid row)))

(defun clear-cell-layers (grid col row)
  "Return the cell at (COL, ROW) to simple mode."
  (let ((i (%idx grid col row)))
    (setf (sbit (display-grid-layered-flags grid) i) 0)
    (remhash (cons col row) (display-grid-layered-cells grid))
    (mark-row-dirty grid row)))

(defun cell-layered-p (grid col row)
  (= 1 (sbit (display-grid-layered-flags grid) (%idx grid col row))))

;;; --------------------------------------------------------------------------
;;; Render data builder
;;; --------------------------------------------------------------------------

(declaim (inline %u16-lo %u16-hi))

(defun %u16-lo (v) (ldb (byte 8 0) v))
(defun %u16-hi (v) (ldb (byte 8 8) v))

(defun build-render-data (grid &key force-full)
  "Build GPU instance buffers using pre-allocated storage.
   If FORCE-FULL is true, rebuild everything.  Otherwise, only rebuild dirty rows.
   Returns (values simple-buffer simple-byte-count layered-buffer layered-layer-counts).
   The returned buffers are the grid's cached buffers - do NOT modify them."
  (declare (ignore force-full))
  (let* ((cols   (display-grid-cols grid))
         (rows   (display-grid-rows grid))
         (sbuf   (display-grid-simple-buffer grid))
         (lbuf   (display-grid-layered-buffer grid))
         (lc     (display-grid-layered-counts grid))
         (swatch-data (display-grid-swatch-data grid))
         (si     0)   ; simple buffer write index
         (sc     0)   ; simple cell count
         ;; Layer write indices: one per layer, offset into lbuf
         (li     (make-array +max-layers+ :element-type 'fixnum :initial-element 0)))
    (declare (type fixnum si sc)
             (type (simple-array (unsigned-byte 8) (*)) sbuf lbuf swatch-data)
             (type (simple-array fixnum (*)) lc li))
    ;; Reset layer counts
    (dotimes (i +max-layers+) (setf (aref lc i) 0))
    ;; Calculate layer base offsets in the merged buffer
    ;; Each layer gets cols*rows*stride bytes max, but we write compactly
    ;; and track actual counts. We'll compact at the end.
    (let ((layer-base (* cols rows +layered-stride+)))
      (dotimes (ln +max-layers+)
        (setf (aref li ln) (* ln layer-base))))
    ;; Iterate all cells
    (dotimes (row rows)
      (dotimes (col cols)
        (let ((i (%idx grid col row)))
          (if (zerop (sbit (display-grid-layered-flags grid) i))
              ;; --- Simple cell: write directly into sbuf ---
              (let* ((sw-idx (aref (display-grid-swatch-indices grid) i))
                     (sw-base (* sw-idx +swatch-slots+))
                     (fg (aref swatch-data (+ sw-base 1)))
                     (bg (aref swatch-data (+ sw-base 0))))
                (setf (aref sbuf si)       (%u16-lo col)
                      (aref sbuf (+ si 1)) (%u16-hi col)
                      (aref sbuf (+ si 2)) (%u16-lo row)
                      (aref sbuf (+ si 3)) (%u16-hi row))
                (let ((glyph (aref (display-grid-glyphs grid) i)))
                  (setf (aref sbuf (+ si 4)) (%u16-lo glyph)
                        (aref sbuf (+ si 5)) (%u16-hi glyph)))
                (setf (aref sbuf (+ si 6)) fg
                      (aref sbuf (+ si 7)) bg)
                (incf si +simple-stride+)
                (incf sc))
              ;; --- Layered cell ---
              (let ((loc (gethash (cons col row) (display-grid-layered-cells grid))))
                (when loc
                  (let ((sw (cell-location-swatch loc)))
                    (dotimes (ln +max-layers+)
                      (let ((layer (aref (cell-location-layers loc) ln)))
                        (when layer
                          (let* ((idx (aref li ln))
                                 (ts  (ecase (cell-layer-transparent-side layer)
                                        (:none 2) (:bg 0) (:fg 1)))
                                 (glyph (cell-layer-glyph-idx layer)))
                            (setf (aref lbuf idx)       (%u16-lo col)
                                  (aref lbuf (+ idx 1)) (%u16-hi col)
                                  (aref lbuf (+ idx 2)) (%u16-lo row)
                                  (aref lbuf (+ idx 3)) (%u16-hi row)
                                  (aref lbuf (+ idx 4)) (%u16-lo glyph)
                                  (aref lbuf (+ idx 5)) (%u16-hi glyph)
                                  (aref lbuf (+ idx 6)) (cell-layer-ink-idx layer)
                                  (aref lbuf (+ idx 7)) (cell-layer-bg-idx layer)
                                  (aref lbuf (+ idx 8)) ts
                                  (aref lbuf (+ idx 9)) 0
                                  (aref lbuf (+ idx 10)) (aref sw 0)
                                  (aref lbuf (+ idx 11)) (aref sw 1)
                                  (aref lbuf (+ idx 12)) (aref sw 2)
                                  (aref lbuf (+ idx 13)) (aref sw 3))
                            (incf (aref li ln) +layered-stride+)
                            (incf (aref lc ln)))))))))))))
    ;; Compact layered data: move each layer's data to be contiguous
    ;; Layer 0 is already at offset 0, so we only need to move layers 1+
    (let ((layer-max (* cols rows +layered-stride+))
          (dst (* (aref lc 0) +layered-stride+)))
      (loop :for ln :from 1 :below +max-layers+
            :for count := (aref lc ln)
            :when (> count 0)
              :do (let ((src (* ln layer-max))
                        (len (* count +layered-stride+)))
                    (replace lbuf lbuf :start1 dst :end1 (+ dst len)
                                       :start2 src :end2 (+ src len))
                    (incf dst len))))
    ;; Store counts and clear dirty flags
    (setf (display-grid-simple-count grid) sc)
    (clear-dirty-flags grid)
    ;; Return buffers and counts
    (values sbuf (* sc +simple-stride+) lbuf lc)))

;;; --------------------------------------------------------------------------
;;; Resize
;;; --------------------------------------------------------------------------

(defun resize-grid (grid new-cols new-rows &key (blank-glyph 0))
  "Resize the grid to NEW-COLS x NEW-ROWS. Existing content is preserved
   where possible; new cells are initialized to swatch 0 and BLANK-GLYPH."
  (let* ((old-cols (display-grid-cols grid))
         (old-rows (display-grid-rows grid))
         (new-n    (* new-cols new-rows))
         (new-glyphs (make-array new-n :element-type '(unsigned-byte 16) :initial-element blank-glyph))
         (new-swatch-indices (make-array new-n :element-type '(unsigned-byte 16) :initial-element 0))
         (new-layered-flags  (make-array new-n :element-type 'bit :initial-element 0))
         (new-row-dirty (make-array new-rows :element-type 'bit :initial-element 1))
         (new-layered-cells (make-hash-table :test 'equal :size 64)))
    ;; Copy existing simple data
    (dotimes (row (min old-rows new-rows))
      (dotimes (col (min old-cols new-cols))
        (let ((old-i (+ (* row old-cols) col))
              (new-i (+ (* row new-cols) col)))
          (setf (aref new-glyphs new-i) (aref (display-grid-glyphs grid) old-i)
                (aref new-swatch-indices new-i) (aref (display-grid-swatch-indices grid) old-i)))))
    ;; Copy existing layered cells that still fit
    (maphash (lambda (key loc)
               (destructuring-bind (col . row) key
                 (when (and (< col new-cols) (< row new-rows))
                   (let ((new-i (+ (* row new-cols) col)))
                     (setf (sbit new-layered-flags new-i) 1
                           (gethash key new-layered-cells) loc)))))
             (display-grid-layered-cells grid))
    ;; Update struct
    (setf (display-grid-cols grid) new-cols
          (display-grid-rows grid) new-rows
          (display-grid-glyphs grid) new-glyphs
          (display-grid-swatch-indices grid) new-swatch-indices
          (display-grid-layered-flags grid) new-layered-flags
          (display-grid-row-dirty grid) new-row-dirty
          (display-grid-layered-cells grid) new-layered-cells)
    ;; Reallocate render buffers for new size
    (%allocate-render-buffers grid)
    grid))
