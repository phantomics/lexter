;;;; tests/test-swatches.lisp — Swatch tables, the grid's copy, and the GPU's.
;;;;
;;;; Pure: screens and grids in memory, and a stand-in for the renderer's
;;;; upload rule (helpers.lisp, TEST-GPU); no GL. Tests of LEXTER-O20,
;;;; LEXTER-O22, LEXTER-O23, and LEXTER-O24 fail until Phase 2 gives each
;;;; swatch table a range of one store (LEXTER-D99, LEXTER-D100).

(in-package #:lexter-tests)
(in-suite swatches)

(defun intern-colours (screen bg fg)
  "Intern the swatch of background BG and foreground FG in SCREEN's table, and
return its index."
  (lexter/model:intern-swatch (lexter/model::screen-swatches screen) bg fg fg 0))

(defun frame (gpu &key (screen *screen*) (grid *grid*))
  "Run one frame as the window does: flush SCREEN into GRID with its cursor
shown, then upload GRID's swatch table to GPU by the renderer's rule."
  (flush :screen screen :grid grid :cursor-visible t)
  (gpu-upload gpu grid))

(def-test new-swatch-reaches-the-gpu ()
  "LEXTER-O20: a swatch interned while the cursor is shown reaches the GPU's
copy of the table within a few frames, so a cell is never drawn from a swatch
the GPU lacks."
  (with-clean-terminal ()
    (let ((gpu (make-test-gpu)))
      (dotimes (i 3) (frame gpu))
      (let ((swatch (intern-colours *screen* 0 4)))
        (lexter/model:write-char-at *screen* 1 0 (glyph *atlas* #x41) :swatch swatch)
        (dotimes (i 4) (frame gpu))
        (assert-that (gpu-swatch gpu swatch) (contains 0 4 4 0))))))

(def-test panes-keep-their-own-colours ()
  "LEXTER-O22: two screens flushed into one grid each draw in their own
colours, though each numbers its swatches from its own table."
  (let* ((atlas (make-test-atlas))
         (a (make-test-screen :cols 5 :rows 1 :atlas atlas))
         (b (make-test-screen :cols 5 :rows 1 :atlas atlas))
         (grid (make-test-grid :cols 10 :rows 1)))
    (lexter/model:write-char-at a 0 0 (glyph atlas #x41) :swatch (intern-colours a 0 1))
    (lexter/model:write-char-at b 0 0 (glyph atlas #x41) :swatch (intern-colours b 0 2))
    (flush :screen a :grid grid :col-offset 0)
    (flush :screen b :grid grid :col-offset 5)
    (assert-that (grid-cell-colours grid 0 0) (contains 0 1 1 0))
    (assert-that (grid-cell-colours grid 5 0) (contains 0 2 2 0))))

(def-test replay-does-not-depend-on-earlier-fixtures ()
  "LEXTER-O23: a terminal reset onto a fresh grid, with the renderer kept,
reaches the GPU with its own colours, whatever the fixture before it drew."
  (let* ((atlas (make-test-atlas))
         (gpu (make-test-gpu)))
    (flet ((fixture (fg)
             (let ((screen (make-test-screen :cols 4 :rows 1 :atlas atlas))
                   (grid (make-test-grid :cols 4 :rows 1)))
               ;; As setup-default-swatches does for each fresh grid
               (lexter/grid:set-swatch grid 0 0 7 7 0)
               (let ((swatch (intern-colours screen 0 fg)))
                 (lexter/model:write-char-at screen 0 0 (glyph atlas #x41) :swatch swatch)
                 (flush :screen screen :grid grid)
                 (gpu-upload gpu grid)
                 swatch))))
      (fixture 1)
      (let ((swatch (fixture 2)))
        (assert-that (gpu-swatch gpu swatch) (contains 0 2 2 0))))))

(def-test flush-survives-a-full-swatch-table ()
  "LEXTER-O24: a screen that interns more distinct swatches than the grid's
table holds is still flushed without error."
  (with-clean-terminal ()
    (let ((last 0))
      (loop :for i :from 1 :to 2100
            :do (setf last (lexter/model:intern-swatch
                            (lexter/model::screen-swatches *screen*)
                            (mod i 256) (floor i 256) 0 0)))
      (lexter/model:write-char-at *screen* 0 0 (glyph *atlas* #x41) :swatch last)
      (finishes (flush)))))
