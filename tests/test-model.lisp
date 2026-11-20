;;;; tests/test-model.lisp — The screen model's cell, range, and row operations.
;;;;
;;;; Pure: screens in memory, written through the model's API; no GL. They
;;;; cover the operations that move or clear cells (LEXTER-O26, LEXTER-D98),
;;;; and the text grid, styles, and terminal rows of Phase 3 (LEXTER-D119,
;;;; LEXTER-D124, LEXTER-D127).

(in-package #:lexter-tests)
(in-suite model)

(defun blank-p (col row)
  "True when the cell at COL, ROW of *SCREEN* is empty and is no half of a
double-width character."
  (and (= 0 (screen-char *screen* col row))
       (not (lexter/model:cell-wide-p *screen* col row))))

;;; ------------------------------------------------------------
;;; Rows  (LEXTER-O26)
;;; ------------------------------------------------------------

(def-test scroll-up-moves-wide-pair-intact ()
  "LEXTER-O26: scrolling moves a double-width character with its wide flag, and
leaves no flag behind in the row it left."
  (with-clean-terminal (:cols 10 :rows 3)
    (write-wide 0 1)
    (lexter/model:scroll-up *screen*)
    (is (= #x4E00 (screen-char *screen* 0 0)))
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
    (is (= #x4E00 (screen-char *screen* 1 0)))
    (is-true (screen-wide-p *screen* 1 0))
    (is-false (screen-wide-p *screen* 0 0))))

(def-test delete-chars-moves-wide-flag-with-its-glyph ()
  "LEXTER-O26: deleting characters before a double-width character moves its
wide flag along with its glyph."
  (with-clean-terminal (:cols 6 :rows 1)
    (write-wide 2 0)
    (lexter/model:set-cursor-position *screen* 0 0)
    (lexter/model:delete-chars *screen* 1)
    (is (= #x4E00 (screen-char *screen* 1 0)))
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
    (lexter/model:put-char *screen* #x4E00 :wide t)
    (is-false (screen-wide-p *screen* 9 0))))

;;; ------------------------------------------------------------
;;; Blanks  (LEXTER-O28)
;;; ------------------------------------------------------------

(def-test fresh-screen-is-blank-in-the-empty-glyph ()
  "LEXTER-O28: a terminal's fresh screen holds empty cells in style 0, which
are built in the atlas's empty glyph at position 0, not in the glyph of the
space or codepoint 32, so that the blank and the atlas agree."
  (with-clean-terminal (:cols 4 :rows 1)
    (dotimes (col 4)
      (is-true (blank-p col 0) "column ~d" col)
      (is (= 0 (lexter/model:cell-style *screen* col 0)) "column ~d" col))
    (flush)
    (dotimes (col 4)
      (is (= lexter/atlas:+empty-glyph-position+ (grid-glyph *grid* col 0)) "column ~d" col))))

;;; ------------------------------------------------------------
;;; The text grid  (LEXTER-D119, LEXTER-D127)
;;; ------------------------------------------------------------

(def-test a-wide-character-marks-both-of-its-cells ()
  "A double-width character's left cell holds its codepoint, and its right
cell the continuation marker; both set the wide bit and hold its style, so
that each cell describes itself (LEXTER-D119)."
  (with-clean-terminal ()
    (let ((style (write-coloured *screen* 0 0 #x41 0 3)))
      (lexter/model:write-char-at *screen* 2 0 #x4E00 :style style :wide t)
      (is (= #x4E00 (screen-char *screen* 2 0)))
      (is (= lexter/manifests:+continuation-marker+ (screen-char *screen* 3 0)))
      (is-true (lexter/model:cell-continuation-p *screen* 3 0))
      (is-true (lexter/model:cell-wide-p *screen* 2 0))
      (is-true (lexter/model:cell-wide-p *screen* 3 0))
      (is (= style (lexter/model:cell-style *screen* 3 0))))))

(def-test overwriting-a-right-half-blanks-its-left-half ()
  "LEXTER-O26: a character written over the right half of a double-width
character blanks its left half, so that no half of a pair is left alone."
  (with-clean-terminal ()
    (write-wide 0 0)
    (lexter/model:write-char-at *screen* 1 0 #x41)
    (is-true (blank-p 0 0))
    (is (= #x41 (screen-char *screen* 1 0)))
    (is-false (lexter/model:cell-wide-p *screen* 1 0))))

(def-test joined-codepoints-move-and-clear-with-their-cell ()
  "The codepoints that joined a cell move with it when characters are inserted
or rows scroll, and are cleared with it when it is erased (LEXTER-D127)."
  (with-clean-terminal (:cols 5 :rows 3)
    (lexter/model:write-char-at *screen* 0 1 #x65)
    (lexter/model:set-cursor-position *screen* 1 1)
    (lexter/model:join-character *screen* #x0301)
    (lexter/model:set-cursor-position *screen* 0 1)
    (lexter/model:insert-chars *screen* 1)
    (is (equal '(#x65 #x0301) (lexter/model:cell-codepoints *screen* 1 1)))
    (lexter/model:scroll-up *screen*)
    (is (equal '(#x65 #x0301) (lexter/model:cell-codepoints *screen* 1 0)))
    (lexter/model:set-cursor-position *screen* 0 0)
    (lexter/model:erase-in-line *screen* 2)
    (is (null (lexter/model:cell-codepoints *screen* 1 0)))
    (lexter/model:write-char-at *screen* 1 0 #x65)
    (is (equal '(#x65) (lexter/model:cell-codepoints *screen* 1 0)))))

(def-test an-erased-cell-keeps-its-colours-and-drops-its-attributes ()
  "An erased cell is empty, in a style of its colours alone, as the first
edition's erase kept a cell's swatch and cleared its attributes."
  (with-clean-terminal ()
    (let* ((styles (lexter/model:screen-styles *screen*))
           (style (lexter/model:intern-style
                   styles (lexter/model:make-style
                           :foreground (lexter/model:palette-colour 1)
                           :background (lexter/model:palette-colour 4)
                           :bold t :underline t))))
      (lexter/model:write-char-at *screen* 0 0 #x41 :style style)
      (lexter/model:erase-chars *screen* 1)
      (is-true (blank-p 0 0))
      (is (equalp (lexter/model:make-style :foreground (lexter/model:palette-colour 1)
                                           :background (lexter/model:palette-colour 4))
                  (lexter/model:table-style styles (lexter/model:cell-style *screen* 0 0)))))))

;;; ------------------------------------------------------------
;;; Styles  (LEXTER-D118, LEXTER-D125)
;;; ------------------------------------------------------------

(def-test a-style-is-interned-once ()
  "A style is interned once in its terminal's table, and style 0 is the
default: default colours and no attributes (LEXTER-D118)."
  (with-clean-terminal ()
    (let ((styles (lexter/model:screen-styles *screen*)))
      (is (equalp (lexter/model:make-style) (lexter/model:table-style styles 0)))
      (let ((a (lexter/model:intern-style styles (lexter/model:make-style :bold t)))
            (b (lexter/model:intern-style styles (lexter/model:make-style :bold t))))
        (is (= a b))
        (is (/= 0 a))))))

(def-test a-full-style-table-gives-the-default-style ()
  "A style table holds as many styles as a 16-bit id names; once full it
interns nothing more and gives style 0, the default."
  (let ((styles (lexter/model:make-style-table)))
    (loop :for i :from 1 :below lexter/model:+max-styles+
          :do (lexter/model:intern-style
               styles (lexter/model:make-style
                       :foreground (lexter/model:rgb-colour (ldb (byte 8 16) i)
                                                            (ldb (byte 8 8) i)
                                                            (ldb (byte 8 0) i)))))
    (is (= lexter/model:+max-styles+ (lexter/model:style-table-count styles)))
    (is (= 0 (lexter/model:intern-style
              styles (lexter/model:make-style :background (lexter/model:palette-colour 9)))))
    (is (= lexter/model:+max-styles+ (lexter/model:style-table-count styles)))))

(def-test bold-as-bright-is-applied-as-rows-are-built ()
  "Bold text of palette colour 0-7 is drawn in colour 8-15 when the terminal
draws bold as bright, and bold text of the default foreground is not, as in
xterm; the style keeps the colour the host sent (LEXTER-D125)."
  (with-clean-terminal ()
    (let* ((styles (lexter/model:screen-styles *screen*))
           (red (lexter/model:intern-style
                 styles (lexter/model:make-style :bold t
                                                 :foreground (lexter/model:palette-colour 1))))
           (plain (lexter/model:intern-style styles (lexter/model:make-style :bold t))))
      (setf (lexter/model:style-table-bold-as-bright styles) t)
      (lexter/model:write-char-at *screen* 0 0 #x41 :style red)
      (lexter/model:write-char-at *screen* 1 0 #x41 :style plain)
      (flush)
      (is (equal '(0 9 9 0) (grid-cell-colours *grid* 0 0)))
      (is (equal '(0 7 7 0) (grid-cell-colours *grid* 1 0)))
      (is (= (lexter/model:palette-colour 1)
             (lexter/model:style-foreground (lexter/model:table-style styles red)))))))

(def-test a-changed-setting-is-drawn-when-rows-are-built-again ()
  "Changing a presentation setting changes how the rows already written are
drawn once they are built again, since the setting is applied as they are
built (LEXTER-D125)."
  (with-clean-terminal ()
    (feed (csi "1;31m") "A")
    (flush)
    (is (equal '(0 1 1 0) (grid-cell-colours *grid* 0 0)))
    (setf (lexter/vt-handler:vt-handler-bold-as-bright *handler*) t)
    (flush)
    (is (equal '(0 9 9 0) (grid-cell-colours *grid* 0 0)))))

(def-test truecolour-is-kept-and-mapped-as-rows-are-built ()
  "A 24-bit colour is kept in the style as the host sent it, and drawn in the
nearest colour of the 256-colour palette as rows are built (LEXTER-D125)."
  (with-clean-terminal ()
    (feed (csi "38;2;10;200;30m") "A")
    (let ((style (lexter/model:table-style (lexter/model:screen-styles *screen*)
                                           (lexter/model:cell-style *screen* 0 0))))
      (is (equal '(10 200 30) (multiple-value-list
                               (lexter/model:colour-rgb (lexter/model:style-foreground style))))))
    (flush)
    (is (equal (list 0 (lexter/model:rgb-to-256 10 200 30) (lexter/model:rgb-to-256 10 200 30) 0)
               (grid-cell-colours *grid* 0 0)))))

;;; ------------------------------------------------------------
;;; History  (LEXTER-D118)
;;; ------------------------------------------------------------

(def-test history-keeps-text-without-continuations ()
  "A row that leaves the screen's top is kept in its history as its text
cells without the continuations of its wide characters, with the codepoints
that joined its cells and its soft wrap (LEXTER-D118)."
  (with-clean-terminal (:cols 4 :rows 2)
    (feed (string (code-char #x4E00)) "e" (string (code-char #x0301)) "x" "yz")
    (lexter/model:scroll-up *screen*)
    (let ((history (lexter/model:scrollback-line *screen* 0)))
      (is (equal '(#x4E00 #x65 #x78) (lexter/model:history-row-codepoints history)))
      (is-true (lexter/model:history-row-soft-wrap-p history))
      (is (equalp '((1 . #(#x0301)))
                 (mapcar (lambda (entry) (cons (car entry) (coerce (cdr entry) 'simple-vector)))
                         (lexter/model::history-row-clusters history)))))))

(def-test history-rows-are-built-as-screen-rows-are ()
  "A history row is built into the grid by the function that builds the
screen's rows: its wide character is a pair in the grid, at the columns it
took on the screen (LEXTER-D124)."
  (with-clean-terminal (:cols 4 :rows 2)
    (feed "A" (string (code-char #x4E00)) "B")
    (lexter/model:scroll-up *screen*)
    (lexter/model:set-scrollback-viewport *screen* 1)
    (flush)
    (is (= (glyph *atlas* #x41) (grid-glyph *grid* 0 0)))
    (is (= (glyph *atlas* #x4E00) (grid-glyph *grid* 1 0)))
    (is-true (grid-wide-p *grid* 1 0))
    (is-true (grid-continuation-p *grid* 2 0))
    (is (= (glyph *atlas* #x42) (grid-glyph *grid* 3 0)))))
