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
;;;; Until the renderer draws records (step 6 of Phase 3), BUILD-RENDER-DATA
;;;; turns them into the first edition's instances, and the first edition's
;;;; writers reach the grid through SET-SIMPLE-CELL and SET-CELL-LAYER, which
;;;; write records.

;;; --------------------------------------------------------------------------
;;; Constants
;;; --------------------------------------------------------------------------

;; Simple instance: col(2) row(2) glyph(4) swatch(2) pad(2) = 12
;; (glyph is 32-bit so atlas positions can exceed 65535 for very large fonts;
;;  2 pad bytes keep the next instance's 32-bit glyph 4-byte aligned.)
(defconstant +simple-stride+  12)
;; Layered instance: col(2) row(2) glyph(4) ink(1) bg(1) ts(1) pad(1) swatch(2) pad(2) = 16
(defconstant +layered-stride+ 16)
(defconstant +max-layers+ 3
  "The layers the first edition's layered instances draw.")
(defconstant +swatch-slots+ 4)

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
  ;; --- The first edition's instance buffers, built from the records ---
  (simple-buffer   nil)
  (simple-count    0   :type fixnum)
  (layered-buffer  nil)
  (layered-counts  nil))  ; (simple-array fixnum (3))

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

(defun %stamp-array (rows)
  (make-array rows :element-type '(unsigned-byte 64) :initial-element (next-change-stamp)))

(defun make-display-grid (&key (cols 80) (rows 24))
  "Create a display grid with COLS columns and ROWS rows, every cell a record
   of zeros, a blank in global swatch 0, the default colours (LEXTER-D83).
   Every row is newer than any stamp a reader took before."
  (let ((grid (%make-display-grid :cols cols :rows rows
                                  :records (make-record-array (* cols rows))
                                  :stamps (%stamp-array rows))))
    (%allocate-render-buffers grid)
    grid))

(declaim (inline %idx))
(defun %idx (grid col row)
  (+ (* row (display-grid-cols grid)) col))

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

(defun %first-edition-layers (records index)
  "The layers the first edition draws for record INDEX of RECORDS, a plain
   record, as a list of (glyph selector ink-slot): each layer, and after it a
   layer in its ink for each union mask that cuts it alone, which draws the
   same pixels. Other masks are not drawn until the renderer draws records."
  (multiple-value-bind (n types) (record-type-bits records index)
    (let ((layers '()))
      (dotimes (i (min n +plain-glyph-words+) (nreverse layers))
        (if (or (zerop i) (not (logbitp (1- i) types)))
            (push (list (record-glyph records index i)
                        (record-selector records index i)
                        (record-ink-slot records index i))
                  layers)
            (multiple-value-bind (operation reach) (record-mask records index i)
              (when (and (eq operation :union) (zerop reach) layers)
                (push (list (record-glyph records index i)
                            (record-selector records index i)
                            (third (first layers)))
                      layers))))))))

(defun cell-layered-p (grid col row)
  "True when the first edition draws the cell at COL, ROW with layers: when it
   is more than one glyph layer in ink slot 1 over background slot 0."
  (let ((records (display-grid-records grid))
        (index (%idx grid col row)))
    (and (eq (record-format records index) :plain)
         (not (%simple-record-p records index)))))

(defun %simple-record-p (records index)
  (and (zerop (read-plain-record records index :background-slot))
       (let ((layers (%first-edition-layers records index)))
         (or (null layers)
             (and (null (rest layers))
                  (equal '(0 1) (rest (first layers))))))))

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
;;; The first edition's writers, over records
;;; --------------------------------------------------------------------------
;;;
;;; The function pane, the workspace's decorations, the 3270 pane, and the
;;; demo write the grid through these until steps 4 and 5 of Phase 3 move
;;; them to records. A layer's transparent side maps as LEXTER-D86 has it:
;;; :BG is a selector of 0, :FG a selector of 1, and :NONE on layer 0 gives
;;; the cell its background slot.

(defun %unpair (grid col row)
  "Before the cell at COL, ROW is written, break the double-width pair it is
   half of: a left half keeps its glyph, narrow, and a right half is emptied."
  (let ((records (display-grid-records grid))
        (cols (display-grid-cols grid)))
    (cond ((and (continuation-p grid col row) (plusp col))
           (patch-record-common records (%idx grid (1- col) row) :wide 0 :right-half 0))
          ((and (wide-left-p grid col row) (< (1+ col) cols))
           (let ((right (%idx grid (1+ col) row)))
             (write-plain-record records right
               :swatch (read-record-common records right :swatch)))))))

(defun set-simple-cell (grid col row glyph-idx swatch-idx &key wide)
  "Set the cell at (COL, ROW) to GLYPH-IDX in ink slot 1 over background slot
   0 of SWATCH-IDX. WIDE marks a double-width glyph: the cell is its left half,
   and (COL+1, ROW) its right half, naming the glyph's second column
   (LEXTER-D126)."
  (let ((cols (display-grid-cols grid)))
    (%unpair grid col row)
    (when (and wide (< (1+ col) cols))
      (%unpair grid (1+ col) row))
    (write-text-record grid col row :glyph glyph-idx :swatch swatch-idx
                                    :wide (and wide (< (1+ col) cols)))
    (when (and wide (< (1+ col) cols))
      (write-text-record grid (1+ col) row :glyph (1+ glyph-idx) :swatch swatch-idx
                                           :wide t :right-half t))))

(defun %layers (records index)
  "The glyph words of record INDEX of RECORDS, a plain record of layers, as a
   list of (glyph selector ink-slot), and its background slot."
  (values (loop :for i :below (min (read-plain-record records index :glyph-count)
                                   +plain-glyph-words+)
                :when (record-layer-p records index i)
                  :collect (list (record-glyph records index i)
                                 (record-selector records index i)
                                 (record-ink-slot records index i)))
          (read-plain-record records index :background-slot)))

(defun %write-layers (grid col row layers background)
  "Write the cell at COL, ROW as a plain record of LAYERS, each (glyph
   selector ink-slot), over BACKGROUND, keeping its swatch, palette slot, and
   drawing flags."
  (let* ((records (display-grid-records grid))
         (index (%idx grid col row)))
    (multiple-value-bind (swatch palette wide right-half blink)
        (read-record-common records index :swatch :palette-slot :wide :right-half :blink)
      (write-plain-record records index
        :glyph-count (length layers) :swatch swatch :palette-slot palette
        :background-slot background :wide wide :right-half right-half :blink blink)
      (loop :for (glyph selector ink) :in layers
            :for i :from 0
            :do (setf (record-glyph records index i) glyph
                      (record-selector records index i) selector
                      (record-ink-slot records index i) ink))
      (touch-row grid row))))

(defun set-cell-swatch (grid col row swatch-idx)
  "Set the swatch index of the cell at (COL, ROW)."
  (patch-record-common (display-grid-records grid) (%idx grid col row) :swatch swatch-idx)
  (touch-row grid row))

(defun set-cell-layer (grid col row layer-num glyph-idx ink-slot
                       &key (bg-slot 0) (transparent-side :none))
  "Define layer LAYER-NUM (0-2) at (COL, ROW) as the first edition's layered
   cells had it: INK-SLOT and BG-SLOT are swatch slots, and TRANSPARENT-SIDE
   is :none (opaque), :bg (ink on the glyph's pixels), or :fg (ink off them).
   Layers between those defined are empty."
  (assert (<= 0 layer-num (1- +max-layers+)) (layer-num)
          "Layer number must be 0-~d" (1- +max-layers+))
  (let ((records (display-grid-records grid))
        (index (%idx grid col row)))
    (multiple-value-bind (layers background) (%layers records index)
      (when (null layers)
        (setf layers (list (list 0 0 1))))
      (loop :while (<= (length layers) layer-num)
            :do (setf layers (append layers (list (list 0 0 ink-slot)))))
      (setf (nth layer-num layers)
            (list glyph-idx (if (eq transparent-side :fg) 1 0) ink-slot))
      (when (and (zerop layer-num) (eq transparent-side :none))
        (setf background bg-slot))
      (%write-layers grid col row layers background))))

(defun clear-cell-layers (grid col row)
  "Return the cell at (COL, ROW) to its first layer alone, in ink slot 1 over
   background slot 0."
  (let ((records (display-grid-records grid))
        (index (%idx grid col row)))
    (let ((layers (%layers records index)))
      (%write-layers grid col row
                     (if layers (list (list (first (first layers)) 0 1)) '())
                     0))))

;;; --------------------------------------------------------------------------
;;; The first edition's instances, built from the records
;;; --------------------------------------------------------------------------

(declaim (inline %u16-lo %u16-hi %u32-b0 %u32-b1 %u32-b2 %u32-b3))

(defun %u16-lo (v) (ldb (byte 8 0) v))
(defun %u16-hi (v) (ldb (byte 8 8) v))

;; Little-endian byte extractors for 32-bit glyph indices.
(defun %u32-b0 (v) (ldb (byte 8 0) v))
(defun %u32-b1 (v) (ldb (byte 8 8) v))
(defun %u32-b2 (v) (ldb (byte 8 16) v))
(defun %u32-b3 (v) (ldb (byte 8 24) v))

(defun build-render-data (grid)
  "Build the first edition's instance buffers from every record of GRID, until
   the renderer draws records. A right half is passed over, its left half
   drawn as the whole glyph; a cell of one glyph layer in ink slot 1 over
   background slot 0 is a simple instance, and any other plain cell layered
   instances: its first layer opaque over its background slot, the rest
   transparent where their selectors leave them, each union mask that cuts
   one layer drawn as a layer in that layer's ink, and other masks and blink
   not drawn. A record of another format is a blank.
   Returns (values simple-buffer simple-byte-count layered-buffer layered-layer-counts).
   The returned buffers are the grid's cached buffers - do NOT modify them."
  (let* ((cols   (display-grid-cols grid))
         (rows   (display-grid-rows grid))
         (records (display-grid-records grid))
         (sbuf   (display-grid-simple-buffer grid))
         (lbuf   (display-grid-layered-buffer grid))
         (lc     (display-grid-layered-counts grid))
         (si     0)   ; simple buffer write index
         (sc     0)   ; simple cell count
         ;; Layer write indices: one per layer, offset into lbuf
         (li     (make-array +max-layers+ :element-type 'fixnum :initial-element 0)))
    (declare (type fixnum si sc)
             (type record-array records)
             (type (simple-array (unsigned-byte 8) (*)) sbuf lbuf)
             (type (simple-array fixnum (*)) lc li))
    (dotimes (i +max-layers+) (setf (aref lc i) 0))
    (let ((layer-base (* cols rows +layered-stride+)))
      (dotimes (ln +max-layers+)
        (setf (aref li ln) (* ln layer-base))))
    (labels ((simple (col row glyph swatch)
               (setf (aref sbuf si)       (%u16-lo col)
                     (aref sbuf (+ si 1)) (%u16-hi col)
                     (aref sbuf (+ si 2)) (%u16-lo row)
                     (aref sbuf (+ si 3)) (%u16-hi row)
                     (aref sbuf (+ si 4)) (%u32-b0 glyph)
                     (aref sbuf (+ si 5)) (%u32-b1 glyph)
                     (aref sbuf (+ si 6)) (%u32-b2 glyph)
                     (aref sbuf (+ si 7)) (%u32-b3 glyph)
                     (aref sbuf (+ si 8)) (%u16-lo swatch)
                     (aref sbuf (+ si 9)) (%u16-hi swatch))
               (incf si +simple-stride+)
               (incf sc))
             (layer (ln col row glyph ink bg ts swatch)
               (let ((idx (aref li ln)))
                 (setf (aref lbuf idx)       (%u16-lo col)
                       (aref lbuf (+ idx 1)) (%u16-hi col)
                       (aref lbuf (+ idx 2)) (%u16-lo row)
                       (aref lbuf (+ idx 3)) (%u16-hi row)
                       (aref lbuf (+ idx 4)) (%u32-b0 glyph)
                       (aref lbuf (+ idx 5)) (%u32-b1 glyph)
                       (aref lbuf (+ idx 6)) (%u32-b2 glyph)
                       (aref lbuf (+ idx 7)) (%u32-b3 glyph)
                       (aref lbuf (+ idx 8)) ink
                       (aref lbuf (+ idx 9)) bg
                       (aref lbuf (+ idx 10)) ts
                       (aref lbuf (+ idx 11)) 0
                       (aref lbuf (+ idx 12)) (%u16-lo swatch)
                       (aref lbuf (+ idx 13)) (%u16-hi swatch))
                 (incf (aref li ln) +layered-stride+)
                 (incf (aref lc ln))))
             (layered (index col row sw background)
               ;; Any other plain cell: layered instances, the first layer
               ;; opaque over the background slot
               (let ((layers (%first-edition-layers records index)))
                 (if (and (zerop background) (null (rest layers))
                          (or (null layers) (equal '(0 1) (rest (first layers)))))
                     (simple col row (if layers (first (first layers)) 0) sw)
                     (progn
                       (destructuring-bind (&optional (glyph 0) (selector 0) (ink background))
                           (first layers)
                         ;; Layer 0 is opaque: its ink where it covers, the
                         ;; background slot elsewhere
                         (if (zerop selector)
                             (layer 0 col row glyph ink background 2 sw)
                             (layer 0 col row glyph background ink 2 sw)))
                       (loop :for (glyph selector ink) :in (rest layers)
                             :for ln :from 1 :below +max-layers+
                             :do (layer ln col row glyph ink 0
                                        (if (zerop selector) 0 1) sw)))))))
      (dotimes (row rows)
        (dotimes (col cols)
          (let ((index (%idx grid col row)))
            (multiple-value-bind (format wide right-half swatch background)
                (read-record-common records index :format :wide :right-half :swatch :background-slot)
              (unless (and (= wide 1) (= right-half 1))
                ;; The wide flag rides in bit 15 of the swatch
                (let ((sw (if (= wide 1) (logior swatch #x8000) swatch)))
                  (if (not (eq format :plain))
                      (simple col row 0 sw)
                      ;; Most cells are text: no glyph, or one layer in ink
                      ;; slot 1 over background slot 0, drawn simple
                      (multiple-value-bind (n glyph selector ink)
                          (read-plain-record records index :glyph-count
                                             (:g0 :glyph) (:g0 :selector) (:g0 :ink-slot))
                        (cond ((and (zerop background) (zerop n))
                               (simple col row 0 sw))
                              ((and (zerop background) (= n 1) (zerop selector) (= ink 1))
                               (simple col row glyph sw))
                              (t (layered index col row sw background))))))))))))
    ;; Compact layered data: move each layer's data to be contiguous
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
    (setf (display-grid-simple-count grid) sc)
    (values sbuf (* sc +simple-stride+) lbuf lc)))

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
          (display-grid-stamps grid) (%stamp-array new-rows))
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
    (%allocate-render-buffers grid)
    (touch-all-rows grid)))
