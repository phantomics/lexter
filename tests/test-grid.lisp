;;;; tests/test-grid.lisp — The flush into the display grid, and its buffers.
;;;;
;;;; Pure: screens flushed into display grids in memory, and instance buffers
;;;; built as byte arrays; nothing is uploaded, and no GL. They cover the
;;;; flush, the cursor, and the grid's operations (LEXTER-O19, LEXTER-O26,
;;;; LEXTER-O28; LEXTER-D98, LEXTER-D101). The tests of LEXTER-O27, of layered
;;;; cells in a screen, were retired when screens stopped holding them
;;;; (LEXTER-D124); their invariants return with the API's surfaces.

(in-package #:lexter-tests)
(in-suite grid)

(defun simple-instances (grid)
  "Build GRID's render data and return its simple instances as a list of
(col row glyph swatch-field), the swatch field with its wide bit."
  (multiple-value-bind (buffer byte-count) (lexter/grid:build-render-data grid)
    (loop :for base :from 0 :below byte-count :by lexter/grid:+simple-stride+
          :collect (flet ((u16 (at) (logior (aref buffer (+ base at))
                                            (ash (aref buffer (+ base at 1)) 8))))
                     (list (u16 0) (u16 2)
                           (logior (u16 4) (ash (u16 6) 16))
                           (u16 8))))))

;;; ------------------------------------------------------------
;;; Double-width glyphs  (LEXTER-O19, LEXTER-O26)
;;; ------------------------------------------------------------

(def-test flush-keeps-wide-pair ()
  "LEXTER-O19: flushing a double-width character marks its left cell wide and
its right cell as the continuation in the grid."
  (with-clean-terminal ()
    (write-wide 0 0)
    (flush)
    (is (= (glyph *atlas* #x4E00) (grid-glyph *grid* 0 0)))
    (is-true (grid-wide-p *grid* 0 0))
    (is-true (grid-continuation-p *grid* 1 0))))

(def-test render-data-draws-wide-glyph-once ()
  "LEXTER-O19: the instance buffer holds one instance for a double-width
character, with the wide bit set, and none for its right half."
  (with-clean-terminal (:cols 10 :rows 3)
    (write-wide 0 0)
    (flush)
    (let* ((instances (simple-instances *grid*))
           (left (find-if (lambda (i) (and (= 0 (first i)) (= 0 (second i)))) instances)))
      (assert-that instances (has-length (1- (* 10 3))))
      (is-true left)
      (is-true (and left (logbitp 15 (fourth left)))))))

(def-test cursor-on-wide-cell-keeps-pair ()
  "LEXTER-O19: drawing the cursor on a double-width character keeps it a pair
in the grid."
  (with-clean-terminal ()
    (write-wide 0 0)
    (lexter/model:set-cursor-position *screen* 0 0)
    (flush :cursor-visible t)
    (is-true (grid-wide-p *grid* 0 0))
    (is-true (grid-continuation-p *grid* 1 0))))

(def-test resize-grid-keeps-wide-pair ()
  "LEXTER-O26: resizing the grid keeps the wide and continuation flags of the
cells that remain."
  (let ((grid (make-test-grid :cols 10 :rows 2)))
    (lexter/grid:set-simple-cell grid 0 0 100 0 :wide t)
    (lexter/grid:resize-grid grid 12 2)
    (is-true (grid-wide-p grid 0 0))
    (is-true (grid-continuation-p grid 1 0))))

;;; ------------------------------------------------------------
;;; Blanks  (LEXTER-O28)
;;; ------------------------------------------------------------

(def-test clear-grid-writes-the-empty-glyph ()
  "LEXTER-O28: clearing the grid fills it with the atlas's empty glyph at
position 0, not with codepoint 32."
  (let ((grid (make-test-grid :cols 4 :rows 2)))
    (lexter/panes:clear-grid grid)
    (dotimes (row 2)
      (dotimes (col 4)
        (is (= 0 (grid-glyph grid col row)) "cell ~d,~d" col row)))))
