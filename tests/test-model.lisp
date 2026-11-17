;;;; tests/test-model.lisp — The screen model's cell, range, and row operations.
;;;;
;;;; Pure: screens in memory, written through the model's API; no GL. Tests of
;;;; LEXTER-O26 and LEXTER-O27 fail until Phase 1 repairs the operations
;;;; that move or clear cells (LEXTER-D98) and layered cells (LEXTER-D97).

(in-package #:lexter-tests)
(in-suite model)

(defun blank-p (col row)
  "True when the cell at COL, ROW of *SCREEN* holds the blank glyph and is not
marked wide."
  (and (= (lexter/model:screen-blank-glyph *screen*) (screen-glyph *screen* col row))
       (not (screen-wide-p *screen* col row))))

;;; ------------------------------------------------------------
;;; Rows  (LEXTER-O26)
;;; ------------------------------------------------------------

(def-test scroll-up-moves-wide-pair-intact ()
  "LEXTER-O26: scrolling moves a double-width character with its wide flag, and
leaves no flag behind in the row it left."
  (with-clean-terminal (:cols 10 :rows 3)
    (write-wide 0 1)
    (lexter/model:scroll-up *screen*)
    (is (= (glyph *atlas* #x4E00) (screen-glyph *screen* 0 0)))
    (is-true (screen-wide-p *screen* 0 0))
    (is-false (screen-wide-p *screen* 0 1))))

;;; ------------------------------------------------------------
;;; Ranges within a row  (LEXTER-O26)
;;; ------------------------------------------------------------

(def-test insert-chars-moves-wide-flag-with-its-glyph ()
  "LEXTER-O26: inserting blanks before a double-width character moves its wide
flag along with its glyph."
  (with-clean-terminal (:cols 4 :rows 1)
    (write-wide 0 0)
    (lexter/model:set-cursor-position *screen* 0 0)
    (lexter/model:insert-chars *screen* 1)
    (is (= (glyph *atlas* #x4E00) (screen-glyph *screen* 1 0)))
    (is-true (screen-wide-p *screen* 1 0))
    (is-false (screen-wide-p *screen* 0 0))))

(def-test delete-chars-moves-wide-flag-with-its-glyph ()
  "LEXTER-O26: deleting characters before a double-width character moves its
wide flag along with its glyph."
  (with-clean-terminal (:cols 6 :rows 1)
    (write-wide 2 0)
    (lexter/model:set-cursor-position *screen* 0 0)
    (lexter/model:delete-chars *screen* 1)
    (is (= (glyph *atlas* #x4E00) (screen-glyph *screen* 1 0)))
    (is-true (screen-wide-p *screen* 1 0))
    (is-false (screen-wide-p *screen* 2 0))))

(def-test erase-in-line-from-right-half-erases-the-pair ()
  "LEXTER-O26: an erase that begins at the right half of a double-width
character erases its left half too, so no half of a pair is left on its own."
  (with-clean-terminal (:cols 10 :rows 1)
    (write-wide 0 0)
    (lexter/model:set-cursor-position *screen* 1 0)
    (lexter/model:erase-in-line *screen* 0)
    (is-true (blank-p 0 0))))

(def-test erase-in-display-clears-wide-flags ()
  "LEXTER-O26: erasing the whole display leaves no cell marked wide."
  (with-clean-terminal (:cols 10 :rows 3)
    (write-wide 0 0)
    (write-wide 4 2)
    (lexter/model:erase-in-display *screen* 2)
    (is-true (blank-p 0 0))
    (is-true (blank-p 4 2))))

(def-test put-char-never-starts-a-pair-in-the-last-column ()
  "LEXTER-O26: a double-width character never begins in the last column, where
its right half would fall outside the row."
  (with-clean-terminal (:cols 10 :rows 2)
    (lexter/model:set-cursor-position *screen* 9 0)
    (lexter/model:put-char *screen* (glyph *atlas* #x4E00) :wide t)
    (is-false (screen-wide-p *screen* 9 0))))

;;; ------------------------------------------------------------
;;; Blanks  (LEXTER-O28)
;;; ------------------------------------------------------------

(def-test fresh-screen-is-blank-in-the-empty-glyph ()
  "LEXTER-O28: a terminal's screen takes its blank from the atlas's empty
glyph at position 0, not from the glyph of the space or from codepoint 32, so
that the blank and the atlas agree."
  (with-clean-terminal (:cols 4 :rows 1)
    (is (= 0 (lexter/model:screen-blank-glyph *screen*)))
    (dotimes (col 4)
      (is (= 0 (screen-glyph *screen* col 0)) "column ~d" col))))

;;; ------------------------------------------------------------
;;; Layered cells  (LEXTER-O27)
;;; ------------------------------------------------------------

(def-test write-char-at-on-layered-cell-keeps-its-swatch ()
  "LEXTER-O27: writing a character with a new swatch into a layered cell gives
the cell that swatch, as it does a simple cell."
  (with-clean-terminal ()
    (let ((swatch (lexter/model:intern-swatch
                   (lexter/model::screen-swatches *screen*) 0 4 4 0)))
      (lexter/model:set-layer *screen* 0 0 0 (glyph *atlas* #x41))
      (lexter/model:write-char-at *screen* 0 0 (glyph *atlas* #x42) :swatch swatch)
      (is (= swatch (lexter/model:cell-swatch *screen* 0 0))))))
