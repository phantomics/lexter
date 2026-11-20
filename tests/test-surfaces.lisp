;;;; tests/test-surfaces.lisp — The API, and surfaces composed into the grid.
;;;;
;;;; Pure: surfaces and grids in memory, on a test atlas packed without GL. They
;;;; cover step 4 of Phase 3: the calls by which chrome, decorators, function
;;;; panes, and applications write records, and the text beside them on a
;;;; surface (LEXTER-D124); the halves the API writes for wide glyphs
;;;; (LEXTER-D126); a surface's copy into the composed grid (LEXTER-D107); and
;;;; the checks of debugging builds (LEXTER-D130). The tests of LEXTER-O27's
;;;; layered cells, retired with the screen's layers in step 2, return here as
;;;; tests of surfaces.

(in-package #:lexter-tests)
(in-suite surfaces)

(defun surface-record (col row &optional (surface *surface*))
  "The record at COL, ROW of SURFACE, read in full as a plist."
  (grid-record surface col row))

;;; ------------------------------------------------------------
;;; Characters
;;; ------------------------------------------------------------

(def-test a-character-is-written-with-its-text ()
  "A character written through the API is a record of one glyph layer, its
glyph from the atlas, in the swatch and slots asked for and the surface's
palette slot, and the surface's text cell beside it holds its codepoint
(LEXTER-D124)."
  (with-clean-surface (:palette-slot 5)
    (is (= 1 (lexter/surface:put-char *surface* 0 0 #\A :swatch 9 :ink-slot 2)))
    (let ((record (surface-record 0 0)))
      (is (= 1 (getf record :glyph-count)))
      (is (equal (list :glyph (glyph *atlas* #x41) :selector 0 :ink-slot 2) (getf record :g0)))
      (is (= 9 (getf record :swatch)))
      (is (= 5 (getf record :palette-slot))))
    (is (= #x41 (lexter/surface:surface-char *surface* 0 0)))))

(def-test a-character-takes-its-glyph-s-natural-width ()
  "A character is written at its glyph's natural width by default
(LEXTER-D117): a wide glyph as two halves, the right half naming the glyph's
second column and holding the continuation marker in the text (LEXTER-D126)."
  (with-clean-surface ()
    (let ((wide (glyph *atlas* #x4E00)))
      (is (= 2 (lexter/surface:put-char *surface* 1 0 (code-char #x4E00))))
      (is-true (grid-wide-p *surface* 1 0))
      (is-true (grid-continuation-p *surface* 2 0))
      (is (= wide (grid-glyph *surface* 1 0)))
      (is (= (1+ wide) (grid-glyph *surface* 2 0)))
      (is (= #x4E00 (lexter/surface:surface-char *surface* 1 0)))
      (is (= lexter/manifests:+continuation-marker+ (lexter/surface:surface-char *surface* 2 0))))))

(def-test an-uncovered-character-is-the-no-glyph-glyph ()
  "A character that no font covers is written with the \"no glyph\" glyph,
and its text kept (LEXTER-D122)."
  (with-clean-surface ()
    (lexter/surface:put-char *surface* 0 0 (code-char #xE9))
    (is (= lexter/atlas:+no-glyph-position+ (grid-glyph *surface* 0 0)))
    (is (= #xE9 (lexter/surface:surface-char *surface* 0 0)))))

(def-test a-string-advances-by-widths-and-stops-at-the-edge ()
  "A string is written character by character, each advancing by its width,
as far as the row reaches, and its text reads back without continuations."
  (with-clean-surface (:cols 5)
    (is (= 5 (lexter/surface:put-string *surface* 0 0
                                        (format nil "A~cBAB" (code-char #x4E00)))))
    (is (string= (format nil "A~cBA" (code-char #x4E00))
                 (lexter/surface:surface-string *surface* 0)))))

(def-test an-underlined-character-is-cut-by-the-line-glyph ()
  "An underlined character is cut by the single underline as a union mask, in
its colour (LEXTER-D88)."
  (with-clean-surface ()
    (lexter/surface:put-char *surface* 0 0 #\A :underline t)
    (let ((record (surface-record 0 0)))
      (is (= 2 (getf record :glyph-count)))
      (is (= 1 (getf record :type-1)))
      (is (= (lexter/atlas:line-glyph-position 0 1) (getf (getf record :g1) :glyph))))))

;;; ------------------------------------------------------------
;;; Cells of several glyphs
;;; ------------------------------------------------------------

(def-test a-cell-of-layers-and-masks-is-written-in-order ()
  "A cell of several glyphs is written in the order given, each layer followed
by the masks that cut it, with their selectors, ink slots, operations, and
reaches; its text is the character of its last layer (LEXTER-D85)."
  (with-clean-surface ()
    (lexter/surface:put-cell *surface* 0 0
                             '((:layer :char #\A :ink-slot 1)
                               (:layer :char #\B :selector 1 :ink-slot 2)
                               (:mask :glyph 9 :operation :intersection :reach 1))
                             :swatch 3 :background-slot 1)
    (let ((record (surface-record 0 0)))
      (is (= 3 (getf record :glyph-count)))
      (is (= 1 (getf record :type-2)))
      (is (= 1 (getf record :background-slot)))
      (is (equal (list :glyph (glyph *atlas* #x42) :selector 1 :ink-slot 2) (getf record :g1)))
      (is (equal '(:glyph 9 :selector 0 :operation :intersection :reach 1) (getf record :g2))))
    (is (= #x42 (lexter/surface:surface-char *surface* 0 0)))))

(def-test a-narrow-glyph-over-a-wide-one-is-split-half-to-half ()
  "A narrow glyph over a wide one is written in both halves: the wide glyph's
words name its own column in each half, and the narrow glyph names itself, so
that each half draws it whole; the halves match (LEXTER-D126)."
  (with-clean-surface ()
    (let ((wide (glyph *atlas* #x4E00))
          (narrow (glyph *atlas* #x41)))
      (is (= 2 (lexter/surface:put-cell *surface* 0 0
                                        `((:layer :char ,(code-char #x4E00) :ink-slot 1)
                                          (:layer :char #\A :ink-slot 2)))))
      (is (equal (list wide narrow) (list (grid-glyph *surface* 0 0)
                                          (lexter/grid:cell-glyph *surface* 0 0 1))))
      (is (equal (list (1+ wide) narrow) (list (grid-glyph *surface* 1 0)
                                               (lexter/grid:cell-glyph *surface* 1 0 1))))
      (is (null (lexter/manifests:half-pair-violations
                 (lexter/grid:display-grid-records *surface*) 0
                 :wide-first-column-p (lambda (g) (= g wide))))))))

(def-test writing-over-half-a-pair-empties-the-other-half ()
  "LEXTER-O26: a cell written over either half of a double-width glyph empties
the other half, in its record and its text, so that no half is left alone."
  (with-clean-surface ()
    (lexter/surface:put-char *surface* 0 0 (code-char #x4E00))
    (lexter/surface:put-char *surface* 1 0 #\A)
    (is (= 0 (getf (surface-record 0 0) :glyph-count)))
    (is (= 0 (getf (surface-record 0 0) :wide)))
    (is (= 0 (lexter/surface:surface-char *surface* 0 0)))
    (is (= #x41 (lexter/surface:surface-char *surface* 1 0)))))

(def-test a-filled-cell-is-solid-in-its-background-slot ()
  "A filled cell has no glyphs, and every pixel takes its background slot, as
a solid cell does (LEXTER-D86)."
  (with-clean-surface ()
    (lexter/surface:put-char *surface* 1 1 #\A)
    (lexter/surface:fill-cells *surface* 0 0 3 2 :swatch 4 :background-slot 1)
    (let ((record (surface-record 1 1)))
      (is (= 0 (getf record :glyph-count)))
      (is (= 1 (getf record :background-slot)))
      (is (= 4 (getf record :swatch))))
    (is (= 0 (lexter/surface:surface-char *surface* 1 1)))))

;;; ------------------------------------------------------------
;;; Composing  (LEXTER-D107, LEXTER-O27)
;;; ------------------------------------------------------------

(def-test a-surface-is-copied-into-the-grid-at-its-place ()
  "A surface is copied into the composed grid with its origin at the place
given, its records unchanged, and each row written takes a new stamp; the
rest of the grid is left as it was (LEXTER-D107, LEXTER-D113)."
  (with-clean-surface (:cols 3 :rows 1 :palette-slot 2)
    (lexter/surface:put-string *surface* 0 0 "AB" :swatch 7)
    (let ((before (lexter/grid:row-stamp *grid* 1)))
      (lexter/surface:compose-surface *surface* *grid* 2 1)
      (is (equal (surface-record 0 0) (grid-record *grid* 2 1)))
      (is (equal (surface-record 1 0) (grid-record *grid* 3 1)))
      (is (> (lexter/grid:row-stamp *grid* 1) before))
      (is (= 0 (getf (grid-record *grid* 1 1) :glyph-count))))))

(def-test a-pair-cut-by-the-grid-s-edge-loses-its-right-half ()
  "A surface copied where its wide glyph's right half falls past the grid's
edge leaves the left half alone, no longer wide, rather than a half pair
(LEXTER-O26)."
  (with-clean-surface (:cols 3 :rows 1)
    (lexter/surface:put-char *surface* 0 0 (code-char #x4E00))
    (lexter/surface:compose-surface *surface* *grid* 5 0)
    (is-false (grid-wide-p *grid* 5 0))))

(def-test a-cleared-layer-is-cleared-in-the-grid ()
  "LEXTER-O27: a layer that a surface's cell loses is gone from the grid once
the surface is copied again, since the cell is written whole."
  (with-clean-surface ()
    (lexter/surface:put-cell *surface* 0 0 '((:layer :char #\A) (:layer :char #\B :ink-slot 2)))
    (lexter/surface:compose-surface *surface* *grid* 0 0)
    (lexter/surface:put-char *surface* 0 0 #\A)
    (lexter/surface:compose-surface *surface* *grid* 0 0)
    (is (= 1 (getf (grid-record *grid* 0 0) :glyph-count)))))

(def-test a-layered-cell-is-drawn-in-its-new-swatch ()
  "LEXTER-O27: a cell of several layers written again in another swatch is
drawn in that swatch once the surface is copied."
  (with-clean-surface ()
    (lexter/surface:put-cell *surface* 0 0 '((:layer :char #\A) (:layer :char #\B)) :swatch 3)
    (lexter/surface:put-cell *surface* 0 0 '((:layer :char #\A) (:layer :char #\B)) :swatch 6)
    (lexter/surface:compose-surface *surface* *grid* 0 0)
    (is (= 6 (grid-swatch *grid* 0 0)))))

;;; ------------------------------------------------------------
;;; Checks in debugging builds  (LEXTER-D130)
;;; ------------------------------------------------------------

(def-test a-record-that-breaks-an-invariant-is-refused-when-checking ()
  "While records are checked, as in debugging builds, the API signals an error
on a record it writes that breaks an invariant, here a mask that reaches more
layers than lie before it; without the checks it writes it (LEXTER-D130)."
  (with-clean-surface ()
    (let ((specs '((:layer :char #\A) (:mask :glyph 9 :reach 3))))
      (let ((lexter/manifests:*check-records* t))
        (signals error (lexter/surface:put-cell *surface* 0 0 specs))
        (finishes (lexter/surface:put-cell *surface* 0 0 '((:layer :char #\A))))
        (finishes (lexter/surface:put-char *surface* 1 0 (code-char #x4E00))))
      (let ((lexter/manifests:*check-records* nil))
        (finishes (lexter/surface:put-cell *surface* 0 0 specs))))))

;;; ------------------------------------------------------------
;;; Writers on the API
;;; ------------------------------------------------------------

(def-test a-function-pane-writes-its-surface-and-copies-it ()
  "A function pane's render function writes the pane's surface in its own
coordinates, and the pane's flush copies the surface into the grid at the
pane's place; a pane not marked dirty is not written again (LEXTER-D124)."
  (let* ((atlas (make-test-atlas))
         (grid (make-test-grid :cols 8 :rows 3))
         (calls 0)
         (pane (lexter/panes:make-function-pane
                :col 2 :row 1 :width 4 :height 1
                :render-fn (lambda (pane surface)
                             (declare (ignore pane))
                             (incf calls)
                             (lexter/surface:put-string surface 0 0 "AB")))))
    (lexter/panes:pane-initialize pane atlas)
    (lexter/panes:pane-flush pane grid)
    (is (= (glyph atlas #x41) (grid-glyph grid 2 1)))
    (is (= (glyph atlas #x42) (grid-glyph grid 3 1)))
    (is (string= "AB  " (lexter/surface:surface-string
                         (lexter/panes:function-pane-surface pane) 0)))
    (lexter/panes:pane-flush pane grid)
    (is (= 1 calls))))

(def-test a-pane-string-is-written-by-codepoint ()
  "A function pane's string is written by codepoint, its glyphs looked up in
the atlas, not taken as atlas positions."
  (let* ((atlas (make-test-atlas))
         (pane (lexter/panes:make-function-pane :width 3 :height 1)))
    (lexter/panes:pane-initialize pane atlas)
    (lexter/panes::write-pane-string pane 0 0 "B")
    (is (= (glyph atlas #x42) (grid-glyph (lexter/panes:function-pane-surface pane) 0 0)))))

(def-test the-grid-keeps-no-layered-api ()
  "LEXTER-D124: the first edition's layered API is gone from the grid, its
writers now writing through the API; SET-SIMPLE-CELL stays for the 3270 pane
until step 5 of Phase 3."
  (dolist (name '("SET-CELL-LAYER" "SET-CELL-SWATCH" "CLEAR-CELL-LAYERS" "CELL-LAYERED-P"))
    (is (null (find-symbol name '#:lexter/grid)) "~a" name)))
