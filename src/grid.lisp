(in-package #:pcf-gl/grid)

;;;; Terminal cell grid with a fast simple path and a sparse layered path.
;;;;
;;;; Simple path  — one character per cell, fg+bg from the global 256-colour
;;;;                palette.  Eight bytes per instance in the GPU buffer.
;;;; Layered path — up to 4 stacked characters per cell, each referencing a
;;;;                per-cell 4-colour local palette whose entries are global
;;;;                palette indices (uint8).  Twelve bytes per instance.

;;; --------------------------------------------------------------------------
;;; Structures
;;; --------------------------------------------------------------------------

(defstruct cell-layer
  "One layer within a layered cell."
  (glyph-idx        0    :type (unsigned-byte 16))
  (ink-idx          0    :type (unsigned-byte 2))   ; index into cell's local palette
  (bg-idx           0    :type (unsigned-byte 2))   ; layer-0 only
  ;; :none = fully opaque both sides (always layer 0)
  ;; :bg   = mask=0 pixels are transparent; mask=1 pixels use ink-idx colour
  ;; :fg   = mask=1 pixels are transparent; mask=0 pixels use ink-idx colour
  (transparent-side :none :type keyword))

(defstruct cell-location
  "A cell position that uses the layered rendering path."
  ;; 4 global-palette indices defining this cell's local 4-colour palette
  (palette (make-array 4 :element-type '(unsigned-byte 8) :initial-element 0)
           :type (simple-array (unsigned-byte 8) (4)))
  ;; Layers 0-3; NIL = empty slot
  (layers  (make-array 4 :initial-element nil) :type simple-vector))

;; Use an internal constructor name so we can provide a friendlier public one.
(defstruct (terminal-grid (:constructor %make-terminal-grid))
  (cols          80  :type fixnum)
  (rows          24  :type fixnum)
  ;; Simple path: flat arrays indexed by (row * cols + col)
  (glyphs        #() :type (simple-array (unsigned-byte 16) (*)))
  (fg-colors     #() :type (simple-array (unsigned-byte 8)  (*)))
  (bg-colors     #() :type (simple-array (unsigned-byte 8)  (*)))
  ;; Layered path: sparse hash table keyed by (col . row)
  (layered-cells (make-hash-table :test 'equal) :type hash-table)
  ;; One bit per cell: 0 = simple, 1 = layered
  (layered-flags #*  :type simple-bit-vector))

(defun make-terminal-grid (&key (cols 80) (rows 24))
  "Create a TERMINAL-GRID with COLS columns and ROWS rows."
  (let ((n (* cols rows)))
    (%make-terminal-grid
     :cols          cols
     :rows          rows
     :glyphs        (make-array n :element-type '(unsigned-byte 16) :initial-element 0)
     :fg-colors     (make-array n :element-type '(unsigned-byte 8)  :initial-element 7)
     :bg-colors     (make-array n :element-type '(unsigned-byte 8)  :initial-element 0)
     :layered-cells (make-hash-table :test 'equal :size 64)
     :layered-flags (make-array n :element-type 'bit :initial-element 0))))

;;; --------------------------------------------------------------------------
;;; Helpers
;;; --------------------------------------------------------------------------

(declaim (inline %idx))
(defun %idx (grid col row)
  (+ (* row (terminal-grid-cols grid)) col))

;;; --------------------------------------------------------------------------
;;; Simple path API
;;; --------------------------------------------------------------------------

(defun set-simple-cell (grid col row glyph-idx fg-idx bg-idx)
  "Place a single character at (COL, ROW) using the global palette indices
   FG-IDX and BG-IDX.  If the cell was in layered mode, that state is cleared."
  (let ((i (%idx grid col row)))
    (setf (aref (terminal-grid-glyphs    grid) i) glyph-idx
          (aref (terminal-grid-fg-colors grid) i) fg-idx
          (aref (terminal-grid-bg-colors grid) i) bg-idx
          (sbit (terminal-grid-layered-flags grid) i) 0)
    (remhash (cons col row) (terminal-grid-layered-cells grid))))

;;; --------------------------------------------------------------------------
;;; Layered path API
;;; --------------------------------------------------------------------------

(defun %ensure-layered (grid col row)
  "Return the CELL-LOCATION for (COL, ROW), creating one if necessary.
   A new location is bootstrapped from the cell's current simple state."
  (let ((key (cons col row)))
    (or (gethash key (terminal-grid-layered-cells grid))
        (let* ((i   (%idx grid col row))
               (loc (make-cell-location)))
          ;; Copy existing simple colours into palette slots 0 and 1
          (setf (aref (cell-location-palette loc) 0)
                (aref (terminal-grid-fg-colors grid) i)
                (aref (cell-location-palette loc) 1)
                (aref (terminal-grid-bg-colors grid) i))
          ;; Copy existing glyph into layer 0
          (setf (aref (cell-location-layers loc) 0)
                (make-cell-layer :glyph-idx        (aref (terminal-grid-glyphs grid) i)
                                 :ink-idx          0
                                 :bg-idx           1
                                 :transparent-side :none))
          ;; Mark cell as layered
          (setf (sbit (terminal-grid-layered-flags grid) i) 1
                (gethash key (terminal-grid-layered-cells grid)) loc)
          loc))))

(defun set-cell-palette (grid col row colors)
  "Set the per-cell 4-colour local palette for (COL, ROW).
   COLORS is a list of up to 4 global palette indices (integers 0-255).
   The cell is promoted to layered mode if it was not already."
  (%ensure-layered grid col row)
  (let ((loc (gethash (cons col row) (terminal-grid-layered-cells grid))))
    (loop :for idx :in colors
          :for slot :from 0 :below 4
          :do (setf (aref (cell-location-palette loc) slot) (logand idx #xFF)))))

(defun set-cell-layer (grid col row layer-num glyph-idx ink-idx
                       &key (bg-idx 0) (transparent-side :none))
  "Define layer LAYER-NUM (0-3) at (COL, ROW).
   INK-IDX / BG-IDX are 0-3 indices into the cell's local 4-colour palette.
   TRANSPARENT-SIDE: :none (layer 0, both sides opaque),
                     :bg   (mask=0 pixels transparent; ink on mask=1),
                     :fg   (mask=1 pixels transparent; ink on mask=0)."
  (assert (<= 0 layer-num 3) (layer-num) "Layer number must be 0-3")
  (%ensure-layered grid col row)
  (let ((loc (gethash (cons col row) (terminal-grid-layered-cells grid))))
    (setf (aref (cell-location-layers loc) layer-num)
          (make-cell-layer :glyph-idx        glyph-idx
                           :ink-idx          ink-idx
                           :bg-idx           bg-idx
                           :transparent-side transparent-side))))

(defun clear-cell-layers (grid col row)
  "Return the cell at (COL, ROW) to simple mode.
   The simple-path arrays (glyph, fg, bg) retain their last values."
  (setf (sbit (terminal-grid-layered-flags grid) (%idx grid col row)) 0)
  (remhash (cons col row) (terminal-grid-layered-cells grid)))

(defun cell-layered-p (grid col row)
  (= 1 (sbit (terminal-grid-layered-flags grid) (%idx grid col row))))

;;; --------------------------------------------------------------------------
;;; Render data builder
;;; --------------------------------------------------------------------------
;;;
;;; Produces packed byte arrays ready for glBufferSubData.
;;;
;;; Simple instance record (8 bytes):
;;;   int16 col | int16 row | uint16 glyph | uint8 fg | uint8 bg
;;;
;;; Layered instance record (12 bytes):
;;;   int16 col | int16 row | uint16 glyph | uint8 ink-idx | uint8 bg-idx
;;;   | uint8 transparent-side (0=:bg 1=:fg 2=:none) | uint8 pad
;;;   | uint8[4] cell-palette (4 global palette indices)
;;;
;;; Layered instances are sorted by layer depth so the renderer can draw
;;; each layer with a single offset+count glDrawArraysInstanced call.

(defconstant +simple-stride+  8)
;; Layered instance layout (14 bytes):
;;   int16 col | int16 row | uint16 glyph | uint8 ink | uint8 bg
;;   | uint8 trans-side | uint8 pad | uint8[4] local-palette
(defconstant +layered-stride+ 14)

(declaim (inline %u16-lo %u16-hi))
(defun %u16-lo (v) (ldb (byte 8 0) v))
(defun %u16-hi (v) (ldb (byte 8 8) v))

(defun build-render-data (grid)
  "Returns (values simple-data simple-count layered-data layered-layer-counts).
   simple-data   — (simple-array (unsigned-byte 8) (*))
   layered-data  — same, layer-0 instances first, then 1, 2, 3
   layered-layer-counts — (simple-array fixnum (4))"
  (let* ((cols  (terminal-grid-cols grid))
         (rows  (terminal-grid-rows grid))
         (n     (* cols rows))
         ;; Pre-allocate worst-case capacity (filled via fill-pointer)
         (sbuf  (make-array (* n +simple-stride+)
                            :element-type '(unsigned-byte 8) :fill-pointer 0))
         (lbufs (loop :repeat 4
                      :collect (make-array (* n +layered-stride+)
                                           :element-type '(unsigned-byte 8)
                                           :fill-pointer 0)))
         (sc    0)
         (lc    (make-array 4 :element-type 'fixnum :initial-element 0)))
    (dotimes (row rows)
      (dotimes (col cols)
        (let ((i (%idx grid col row)))
          (if (zerop (sbit (terminal-grid-layered-flags grid) i))
              ;; --- simple path ---
              (progn
                (%emit-u16 sbuf col)
                (%emit-u16 sbuf row)
                (%emit-u16 sbuf (aref (terminal-grid-glyphs    grid) i))
                (vector-push (aref (terminal-grid-fg-colors grid) i) sbuf)
                (vector-push (aref (terminal-grid-bg-colors grid) i) sbuf)
                (incf sc))
              ;; --- layered path ---
              (let ((loc (gethash (cons col row) (terminal-grid-layered-cells grid))))
                (when loc
                  (let ((pal (cell-location-palette loc)))
                    (dotimes (ln 4)
                      (let ((layer (aref (cell-location-layers loc) ln)))
                        (when layer
                          (let ((buf (nth ln lbufs))
                                (ts  (ecase (cell-layer-transparent-side layer)
                                       (:none 2) (:bg 0) (:fg 1))))
                            (%emit-u16 buf col)
                            (%emit-u16 buf row)
                            (%emit-u16 buf (cell-layer-glyph-idx layer))
                            (vector-push (cell-layer-ink-idx layer) buf)
                            (vector-push (cell-layer-bg-idx  layer) buf)
                            (vector-push ts buf)
                            (vector-push 0  buf)  ; pad to 12
                            ;; Per-cell palette (4 bytes)
                            (vector-push (aref pal 0) buf)
                            (vector-push (aref pal 1) buf)
                            (vector-push (aref pal 2) buf)
                            (vector-push (aref pal 3) buf)
                            (incf (aref lc ln)))))))))))))
    ;; Merge layer buckets into one contiguous buffer (layer 0 first)
    (let* ((total (* (reduce #'+ lc) +layered-stride+))
           (lmerge (make-array total :element-type '(unsigned-byte 8))))
      (let ((dst 0))
        (dolist (lb lbufs)
          (let ((len (fill-pointer lb)))
            (replace lmerge lb :start1 dst :end2 len)
            (incf dst len))))
      (let* ((used  (* sc +simple-stride+))
             (sresult (make-array used :element-type '(unsigned-byte 8))))
        (replace sresult sbuf :end2 used)
        (values sresult sc lmerge lc)))))

(defun %emit-u16 (vec value)
  (vector-push (%u16-lo value) vec)
  (vector-push (%u16-hi value) vec))
