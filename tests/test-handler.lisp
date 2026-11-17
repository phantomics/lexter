;;;; tests/test-handler.lisp — The VT handler: bytes from a host made into cells.
;;;;
;;;; Pure: a screen and handler fed bytes in memory, with a packed test atlas;
;;;; no PTY, no GL. Tests of LEXTER-O19 fail until Phase 1 repairs the
;;;; handler's double-width writes (LEXTER-D98, LEXTER-D117); tests of
;;;; LEXTER-O21, LEXTER-O29, and LEXTER-O33 fail until the terminal-fixes plan
;;;; repairs the handler (LEXTER-D68, LEXTER-D69, LEXTER-D70).

(in-package #:lexter-tests)
(in-suite handler)

(defparameter *u4e00-bytes* '(#xE4 #xB8 #x80)
  "The UTF-8 bytes of U+4E00, a character of width 2.")

;;; ------------------------------------------------------------
;;; Narrow characters
;;; ------------------------------------------------------------

(def-test print-narrow-character-advances-one ()
  "A narrow character is written at the cursor, and the cursor moves one
column."
  (with-clean-terminal ()
    (feed "A")
    (is (= (glyph *atlas* #x41) (screen-glyph *screen* 0 0)))
    (is (= 1 (lexter/model:cursor-col *screen*)))))

;;; ------------------------------------------------------------
;;; Double-width characters  (LEXTER-O19)
;;; ------------------------------------------------------------

(def-test print-wide-character-writes-a-pair ()
  "LEXTER-O19: a character of width 2 is written as a pair, its glyph in the
left cell marked as the left half of a double-width character."
  (with-clean-terminal ()
    (apply #'feed *u4e00-bytes*)
    (is (= (glyph *atlas* #x4E00) (screen-glyph *screen* 0 0)))
    (is-true (screen-wide-p *screen* 0 0))
    (is-false (screen-wide-p *screen* 1 0))))

(def-test print-wide-character-advances-two ()
  "LEXTER-O19: printing a character of width 2 moves the cursor two columns,
so the next character does not overwrite its right half."
  (with-clean-terminal ()
    (apply #'feed *u4e00-bytes*)
    (is (= 2 (lexter/model:cursor-col *screen*)))
    (feed "A")
    (is (= (glyph *atlas* #x41) (screen-glyph *screen* 2 0)))
    (is-true (screen-wide-p *screen* 0 0))))

(def-test wide-character-in-last-column-wraps-first ()
  "LEXTER-O19: a character of width 2 that would begin in the last column
wraps to the next row first, leaving the last column blank, since a pair
cannot be split across rows (LEXTER-D98)."
  (with-clean-terminal (:cols 10 :rows 3)
    (feed (csi 1 ";" 10 "H"))
    (apply #'feed *u4e00-bytes*)
    (is (= (lexter/model:screen-blank-glyph *screen*) (screen-glyph *screen* 9 0)))
    (is-false (screen-wide-p *screen* 9 0))
    (is (= (glyph *atlas* #x4E00) (screen-glyph *screen* 0 1)))
    (is-true (screen-wide-p *screen* 0 1))
    (is (= 2 (lexter/model:cursor-col *screen*)))
    (is (= 1 (lexter/model:cursor-row *screen*)))))

;;; ------------------------------------------------------------
;;; Host input at the boundary  (LEXTER-O21)
;;; ------------------------------------------------------------

(def-test rgb-to-256-stays-in-the-palette ()
  "LEXTER-O21: every 24-bit colour maps to an index of the 256-colour palette,
the light greys at the top of the ramp included."
  (is (<= 0 (lexter/vt-handler::rgb-to-256 248 248 248) 255))
  (is (<= 0 (lexter/vt-handler::rgb-to-256 255 255 255) 255)))

(def-test truecolour-grey-does-not-stop-the-parse ()
  "LEXTER-O21: a 24-bit light grey from the host is drawn in a palette colour,
and the text after it is written; the parse is not abandoned partway through
the buffer."
  (with-clean-terminal ()
    (finishes (feed (csi "38;2;248;248;248m") "A"))
    (is (= (glyph *atlas* #x41) (screen-glyph *screen* 0 0)))))

(def-test indexed-colour-out-of-range-is-ignored ()
  "LEXTER-O21: an indexed colour above 255 is ignored, and the current colour
stays as it was (LEXTER-D68)."
  (with-clean-terminal ()
    (feed (csi "31m"))
    (finishes (feed (csi "38;5;300m")))
    (is (= 1 (lexter/vt-handler::vt-handler-current-fg *handler*)))))

(def-test tab-after-widening-reaches-the-new-stops ()
  "LEXTER-O21: after the terminal is widened, a tab beyond the old width moves
to the next of the tab stops every eight columns of the new width."
  (with-clean-terminal (:cols 10 :rows 3)
    (lexter/vt-handler:vt-handler-resize-all *handler* 40 3)
    (feed (csi 1 ";" 12 "H"))
    (finishes (feed 9))
    (is (= 16 (lexter/model:cursor-col *screen*)))))

;;; ------------------------------------------------------------
;;; Autowrap within the scrolling region  (LEXTER-O33)
;;; ------------------------------------------------------------

(def-test autowrap-scrolls-within-the-region ()
  "LEXTER-O33: text that wraps at the right margin on the bottom row of the
scrolling region scrolls the region, as a line feed does, and the cursor stays
inside it (LEXTER-D69)."
  (with-clean-terminal (:cols 5 :rows 10)
    (feed (csi "1;5r") (csi "5;5H") "AB")
    (is (= 4 (lexter/model:cursor-row *screen*)))
    (is (= (glyph *atlas* #x42) (screen-glyph *screen* 0 4)))
    (is (= (glyph *atlas* #x41) (screen-glyph *screen* 4 3)))
    (is (= (lexter/model:screen-blank-glyph *screen*) (screen-glyph *screen* 0 5)))))

;;; ------------------------------------------------------------
;;; The alternate screen  (LEXTER-O29)
;;; ------------------------------------------------------------

(def-test alternate-screen-keeps-the-palette ()
  "LEXTER-O29: a palette entry the host redefines before entering the
alternate screen holds on the alternate screen too, since the two screens
share one palette (LEXTER-D70)."
  (with-clean-terminal ()
    (feed #x1B "]4;1;rgb:00/ff/00" #x1B "\\")
    (feed (csi "?1049h"))
    (let ((alternate (lexter/vt-handler:vt-handler-screen *handler*)))
      (is-false (eq alternate *screen*))
      (is (equalp (multiple-value-list (lexter/model:get-palette-entry *screen* 1))
                  (multiple-value-list (lexter/model:get-palette-entry alternate 1)))))))

;;; ------------------------------------------------------------
;;; Widths from the table  (LEXTER-D117, LEXTER-DRAFT-cell-model-revision-D23)
;;; ------------------------------------------------------------

(defmacro with-terminal-on-atlas ((atlas-form &key (cols 10) (rows 3)) &body body)
  "Run BODY as WITH-CLEAN-TERMINAL does, but on the atlas ATLAS-FORM makes."
  `(let* ((*atlas*   ,atlas-form)
          (*screen*  (make-test-screen :cols ,cols :rows ,rows :atlas *atlas*))
          (*handler* (lexter/vt-handler:make-vt-handler *screen* *atlas*))
          (*grid*    (make-test-grid :cols ,cols :rows ,rows)))
     ,@body))

(def-test zero-width-character-is-dropped ()
  "A character of width 0, such as a combining mark, is dropped and does not
move the cursor, until the text grid of Phase 3 gives it a cell to join."
  (with-clean-terminal ()
    (feed "A" (string (code-char #x0301)) "B")
    (is (= (glyph *atlas* #x42) (screen-glyph *screen* 1 0)))
    (is (= 2 (lexter/model:cursor-col *screen*)))))

(def-test uncovered-character-draws-the-no-glyph-glyph ()
  "A character that no font covers is written at its width from the table with
the \"no glyph\" glyph, and moves the cursor by its width."
  (with-clean-terminal ()
    (feed (string (code-char #xE9)))
    (is (= lexter/atlas:+no-glyph-position+ (screen-glyph *screen* 0 0)))
    (is (= 1 (lexter/model:cursor-col *screen*)))
    (feed (string (code-char #x1F600)))
    (is (= lexter/atlas:+no-glyph-position+ (screen-glyph *screen* 1 0)))
    (is-true (screen-wide-p *screen* 1 0))
    (is (= 3 (lexter/model:cursor-col *screen*)))))

(def-test width-comes-from-the-table-not-the-font ()
  "A character's width is the table's, whatever its glyph's: an ideograph
whose glyph is narrow still takes two columns, and a Latin letter whose glyph
is wide takes one."
  (with-terminal-on-atlas ((make-test-atlas
                            :fonts (list (make-test-font :narrow '(#x4E00 #x20) :wide '(#x41)))))
    (feed (string (code-char #x4E00)))
    (is-true (screen-wide-p *screen* 0 0))
    (is (= 2 (lexter/model:cursor-col *screen*)))
    (feed "A")
    (is-false (screen-wide-p *screen* 2 0))
    (is (= 3 (lexter/model:cursor-col *screen*)))))

(def-test ambiguous-character-follows-the-atlas-policy ()
  "A character of ambiguous width takes the width that the atlas's width
policy gives it."
  (with-terminal-on-atlas ((make-test-atlas
                            :fonts (list (make-test-font :narrow '(#x03B1 #x20) :wide '()))
                            :width-policy (lexter/width:make-width-policy :ambiguous-width 2)))
    (feed (string (code-char #x03B1)))
    (is-true (screen-wide-p *screen* 0 0))
    (is (= 2 (lexter/model:cursor-col *screen*)))))
