;;;; tests/test-swatches.lisp — Swatch stores, their tables, and the GPU's copy.
;;;;
;;;; Pure: stores, tables, screens, grids, and panes in memory, and the GPU's
;;;; copy of a store kept as bytes, filled by the renderer's own upload decision
;;;; (helpers.lisp, TEST-GPU); no GL. They cover Phase 2's swatch ranges
;;;; (LEXTER-D99, LEXTER-D100, LEXTER-DRAFT-cell-model-revision-D24) and the
;;;; findings they repair: LEXTER-O20, LEXTER-O22, LEXTER-O23, and LEXTER-O24.

(in-package #:lexter-tests)
(in-suite swatches)

(defun intern-colours (screen bg fg)
  "Intern the swatch of background BG and foreground FG in SCREEN's table, and
return its global index."
  (lexter/swatches:intern-swatch (lexter/model:screen-swatches screen) bg fg fg 0))

(defun frame (gpu &key (screen *screen*) (grid *grid*) (store *store*))
  "Run one frame as the window does: flush SCREEN into GRID with its cursor
shown, then upload STORE to GPU by the renderer's rule."
  (flush :screen screen :grid grid :cursor-visible t)
  (gpu-upload gpu store))

(defun swatch-colours (store index)
  "The four palette indices of global swatch INDEX in STORE, as a list."
  (multiple-value-list (lexter/swatches:store-swatch store index)))

(defun range-of (index)
  "The range of a store that global swatch INDEX lies in."
  (floor index lexter/swatches:+range-size+))

(defun fill-table (table count &optional (key (lambda (i) (list (mod i 256) (+ 16 (floor i 256)) 0 0))))
  "Intern COUNT distinct swatches in TABLE, the Ith with the palette indices
that KEY gives for I, and return the global index of the last."
  (let ((last nil))
    (dotimes (i count last)
      (setf last (apply #'lexter/swatches:intern-swatch table (funcall key i))))))

;;; ------------------------------------------------------------
;;; The findings
;;; ------------------------------------------------------------

(def-test new-swatch-reaches-the-gpu ()
  "LEXTER-O20: a swatch interned while the cursor is shown reaches the GPU's
copy of the store within a few frames, so a cell is never drawn from a swatch
the GPU lacks."
  (with-clean-terminal ()
    (let ((gpu (make-test-gpu)))
      (dotimes (i 3) (frame gpu))
      (write-coloured *screen* 1 0 #x41 0 4)
      (dotimes (i 4) (frame gpu))
      (assert-that (gpu-swatch gpu (grid-swatch *grid* 1 0)) (contains 0 4 4 0)))))

(def-test panes-keep-their-own-colours ()
  "LEXTER-O22: two terminals' screens flushed into one grid each draw in their
own colours, since each table hands out global indices in ranges of its own."
  (let* ((atlas (make-test-atlas))
         (store (lexter/swatches:make-swatch-store))
         (a (make-test-screen :cols 5 :rows 1 :store store))
         (b (make-test-screen :cols 5 :rows 1 :store store))
         (grid (make-test-grid :cols 10 :rows 1)))
    (write-coloured a 0 0 #x41 0 1)
    (write-coloured b 0 0 #x41 0 2)
    (flush :screen a :grid grid :atlas atlas :col-offset 0)
    (flush :screen b :grid grid :atlas atlas :col-offset 5)
    (assert-that (grid-cell-colours grid 0 0 store) (contains 0 1 1 0))
    (assert-that (grid-cell-colours grid 5 0 store) (contains 0 2 2 0))))

(def-test replay-does-not-depend-on-earlier-fixtures ()
  "LEXTER-O23: a terminal reset onto a fresh grid, with the store and the
renderer's records kept, takes the same range and indices as it would first,
and reaches the GPU with its own colours, whatever the fixture before it drew."
  (let* ((atlas (make-test-atlas))
         (store (lexter/swatches:make-swatch-store))
         (gpu (make-test-gpu)))
    (flet ((fixture (colours)
             ;; As TERMINAL-RESET does: a new terminal's table, a fresh grid,
             ;; and the old table's ranges returned when it is replaced
             (let ((screen (make-test-screen :cols 4 :rows 1 :store store))
                   (grid (make-test-grid :cols 4 :rows 1)))
               (loop :for fg :in colours
                     :for col :from 0
                     :do (write-coloured screen col 0 #x41 0 fg))
               (flush :screen screen :grid grid :atlas atlas)
               (gpu-upload gpu store)
               (lexter/swatches:release-swatch-table (lexter/model:screen-swatches screen))
               (loop :for col :below (length colours)
                     :collect (grid-swatch grid col 0)))))
      (let* ((first (fixture '(1 3 5)))
             (second (fixture '(2))))
        (is (= (first first) (first second)))
        (assert-that (gpu-swatch gpu (first second)) (contains 0 2 2 0))))))

(def-test flush-survives-a-full-swatch-table ()
  "LEXTER-O24: a terminal whose table holds more distinct swatches than one
range takes a second range, and a cell built after it is still drawn in its
own colours, from that range."
  (with-clean-terminal ()
    (let ((table (lexter/model:screen-swatches *screen*)))
      (fill-table table 2100)
      (write-coloured *screen* 0 0 #x41 1 2)
      (finishes (flush))
      (assert-that (grid-cell-colours *grid* 0 0) (contains 1 2 2 0))
      (is (= (aref (lexter/swatches:swatch-table-ranges table) 1)
             (range-of (grid-swatch *grid* 0 0)))))))

;;; ------------------------------------------------------------
;;; Ranges and global indices
;;; ------------------------------------------------------------

(def-test global-swatch-zero-is-the-default ()
  "Global swatch 0 is the default colours, background 0 and foreground 7,
because the store's display table takes range 0 when the store is made
(LEXTER-D83)."
  (let ((store (lexter/swatches:make-swatch-store)))
    (is (eq (lexter/swatches:swatch-store-display-table store)
            (lexter/swatches:range-owner store 0)))
    (assert-that (swatch-colours store 0) (contains 0 7 7 0))))

(def-test global-index-is-range-base-plus-offset ()
  "A table's swatches are numbered from its range's base: the first terminal
table of a store takes range 1, so its default swatch is global 2048 and its
next swatch 2049, and a fresh screen's cells are built in that default
swatch."
  (let* ((store (lexter/swatches:make-swatch-store))
         (screen (make-test-screen :cols 3 :rows 1 :store store))
         (grid (make-test-grid :cols 3 :rows 1)))
    (is (= 2048 (lexter/model:default-swatch screen)))
    (flush :screen screen :grid grid :atlas (make-test-atlas))
    (is (= 2048 (grid-swatch grid 2 0)))
    (is (= 2049 (intern-colours screen 0 4)))))

(def-test flush-copies-global-indices-unchanged ()
  "The flush gives a cell the global index its terminal's table holds for the
swatch of its style, unchanged (LEXTER-D100, LEXTER-D124)."
  (with-clean-terminal ()
    (write-coloured *screen* 0 0 #x41 0 4)
    (flush)
    (is (= (intern-colours *screen* 0 4) (grid-swatch *grid* 0 0)))))

(def-test table-takes-another-range-when-it-fills ()
  "A table whose range is full takes the lowest free range for its next
swatch, which keeps its offset there."
  (let* ((store (lexter/swatches:make-swatch-store))
         (a (lexter/swatches:make-swatch-table store))
         (b (lexter/swatches:make-swatch-table store)))
    (declare (ignore b))
    ;; A holds its default; 2047 more fill range 1, and the next opens range 3
    (is (= 1 (range-of (fill-table a 2047))))
    (is (= (* 3 lexter/swatches:+range-size+)
           (lexter/swatches:intern-swatch a 1 2 3 4)))
    (assert-that (coerce (lexter/swatches:swatch-table-ranges a) 'list) (contains 1 3))))

(def-test table-stops-at-four-ranges ()
  "A table holds at most four ranges, 8192 swatches, so that one pane cannot
take the whole store; a table at its limit takes no further range."
  (let* ((store (lexter/swatches:make-swatch-store))
         (table (lexter/swatches:make-swatch-table store)))
    (fill-table table (+ 8191 100) (lambda (i) (list (mod i 256) (floor i 256) 1 2)))
    (is (= 4 (length (lexter/swatches:swatch-table-ranges table))))
    (is (= 8192 (lexter/swatches:swatch-table-count table)))
    (is-true (lexter/swatches:swatch-table-full-p table))))

(def-test full-table-gives-its-nearest-swatch ()
  "A full table interns nothing new: it returns its existing swatch whose four
slots are nearest in colour, by the squared RGB distances in the palette
(LEXTER-DRAFT-cell-model-revision-D24)."
  (let* ((store (lexter/swatches:make-swatch-store :max-table-ranges 1))
         (table (lexter/swatches:make-swatch-table store))
         (near nil))
    ;; Bright blue in every slot but the default's, and one swatch that differs
    ;; from bright red (0 9 9 0) only in its last slot
    (dotimes (i 2046)
      (lexter/swatches:append-swatch table 0 12 12 0))
    (setf near (lexter/swatches:append-swatch table 0 9 9 1))
    (is-true (lexter/swatches:swatch-table-full-p table))
    (is (= near (lexter/swatches:intern-swatch table 0 9 9 0)))
    (is (= 2048 (lexter/swatches:swatch-table-count table)))))

(def-test table-falls-back-when-no-range-is-free ()
  "A table that needs a range when none is free gives its nearest swatch, and a
table made when none is free gives global swatch 0, so drawing never fails."
  (let* ((store (lexter/swatches:make-swatch-store :usable-ranges 2))
         (table (lexter/swatches:make-swatch-table store))
         (late (lexter/swatches:make-swatch-table store)))
    (fill-table table 2047)
    (is (= 1 (range-of (lexter/swatches:intern-swatch table 100 100 0 0))))
    (is (= 1 (length (lexter/swatches:swatch-table-ranges table))))
    (is (= 0 (lexter/swatches:intern-swatch late 0 1 1 0)))
    (is (= 0 (lexter/swatches:swatch-table-default late)))))

(def-test released-ranges-are-reused-lowest-first ()
  "A released table returns its ranges to the store, and the next table made
takes the lowest free range, so allocation is the same on every run."
  (let* ((store (lexter/swatches:make-swatch-store))
         (a (lexter/swatches:make-swatch-table store))
         (b (lexter/swatches:make-swatch-table store)))
    (lexter/swatches:release-swatch-table a)
    (is (null (lexter/swatches:range-owner store 1)))
    (let ((c (lexter/swatches:make-swatch-table store)))
      (assert-that (coerce (lexter/swatches:swatch-table-ranges c) 'list) (contains 1))
      (assert-that (coerce (lexter/swatches:swatch-table-ranges b) 'list) (contains 2)))))

(def-test released-table-interns-nothing ()
  "A table whose ranges have been released signals an error rather than
intern into ranges it no longer owns."
  (let* ((store (lexter/swatches:make-swatch-store))
         (table (lexter/swatches:make-swatch-table store)))
    (lexter/swatches:release-swatch-table table)
    (signals error (lexter/swatches:intern-swatch table 0 1 1 0))))

(def-test alternate-screen-shares-the-table ()
  "A terminal's primary and alternate screens share one swatch table, so a
full-screen program takes no range of its own and colours keep their indices
across the switch (LEXTER-DRAFT-cell-model-revision-D24)."
  (with-clean-terminal ()
    (let ((before (intern-colours *screen* 0 3)))
      (feed (csi "?1049h"))
      (let ((alternate (lexter/vt-handler:vt-handler-screen *handler*)))
        (is-false (eq alternate *screen*))
        (is (eq (lexter/model:screen-swatches *screen*)
                (lexter/model:screen-swatches alternate)))
        (is (= before (intern-colours alternate 0 3)))))))

;;; ------------------------------------------------------------
;;; Uploads
;;; ------------------------------------------------------------

(def-test upload-sends-only-what-a-table-added ()
  "Once a range is uploaded, a frame with no new swatch uploads nothing, and a
new swatch uploads that swatch alone."
  (with-clean-terminal ()
    (let ((gpu (make-test-gpu)))
      (gpu-upload gpu *store*)
      (is (null (gpu-upload gpu *store*)))
      (let* ((swatch (intern-colours *screen* 0 5))
             (spans (gpu-upload gpu *store*)))
        (is (= 1 (length spans)))
        (is (= swatch (first (first spans))))
        (is (= 1 (second (first spans))))))))

(def-test upload-sends-a-whole-range-to-a-new-owner ()
  "A range released and taken by another table is uploaded whole from its
base, though the new table holds no more swatches than the old one did."
  (let* ((store (lexter/swatches:make-swatch-store))
         (gpu (make-test-gpu))
         (old (lexter/swatches:make-swatch-table store)))
    (lexter/swatches:intern-swatch old 0 1 1 0)
    (gpu-upload gpu store)
    (lexter/swatches:release-swatch-table old)
    (let ((new (lexter/swatches:make-swatch-table store)))
      (lexter/swatches:intern-swatch new 0 2 2 0)
      (let ((span (find 1 (gpu-upload gpu store) :key (lambda (s) (range-of (first s))))))
        (is (= lexter/swatches:+range-size+ (first span)))
        (is (= 2 (second span))))
      (assert-that (gpu-swatch gpu (1+ lexter/swatches:+range-size+)) (contains 0 2 2 0)))))

(def-test upload-sends-a-whole-range-after-a-version-bump ()
  "A table changed other than by growing bumps its version, and its range is
uploaded whole at the next frame."
  (let* ((store (lexter/swatches:make-swatch-store))
         (gpu (make-test-gpu))
         (table (lexter/swatches:make-swatch-table store)))
    (lexter/swatches:intern-swatch table 0 1 1 0)
    (gpu-upload gpu store)
    (lexter/swatches:bump-swatch-table-version table)
    (assert-that (mapcar #'second (gpu-upload gpu store)) (contains 2))))

;;; ------------------------------------------------------------
;;; Panes and the display's table
;;; ------------------------------------------------------------

(defun make-test-compositor (&rest panes)
  "A compositor, not initialized, holding one workspace of PANES."
  (lexter/panes:make-paned-compositor
   :workspaces (list (make-instance 'lexter/panes:workspace :panes panes))))

(def-test display-swatches-come-from-the-display-table ()
  "Chrome, decorators, and function panes take their swatches from the
display's table of the compositor that draws them, in range 0; a pane that no
compositor draws gets global swatch 0."
  (let* ((pane (lexter/panes:make-function-pane))
         (loose (lexter/panes:make-function-pane))
         (comp (make-test-compositor pane))
         (store (lexter/panes:compositor-swatch-store comp))
         (swatch (lexter/panes:display-swatch pane 0 11)))
    (is (= 0 (range-of swatch)))
    (is (plusp swatch))
    (assert-that (swatch-colours store swatch) (contains 0 11 11 0))
    (is (= 0 (lexter/panes:display-swatch loose 0 11)))))

(def-test terminal-pane-takes-and-returns-a-table ()
  "A terminal pane takes a table of its own from its compositor's store when
its screen is made, makes it again in the same range when its screen is
replaced, as TERMINAL-RESET does, and returns the range when it is destroyed."
  (let* ((pane (make-instance 'lexter/panes:uterm-pane :width 10 :height 3))
         (comp (make-test-compositor pane))
         (store (lexter/panes:compositor-swatch-store comp))
         (atlas (make-test-atlas)))
    (lexter/panes:pane-initialize pane atlas)
    (let ((table (lexter/model:screen-swatches (lexter/panes:vt-pane-screen pane))))
      (is (eq store (lexter/swatches:swatch-table-store table)))
      (is (eq table (lexter/swatches:range-owner store 1)))
      (lexter/panes:vt-pane-init-screen pane atlas)
      (is-true (lexter/swatches:swatch-table-released table)))
    (let ((table (lexter/model:screen-swatches (lexter/panes:vt-pane-screen pane))))
      (is (eq table (lexter/swatches:range-owner store 1)))
      (lexter/panes:pane-destroy pane)
      (is (null (lexter/swatches:range-owner store 1))))))
