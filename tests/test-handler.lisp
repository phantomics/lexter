;;;; tests/test-handler.lisp — The VT handler's writing of characters.
;;;;
;;;; Pure: a screen and handler fed bytes in memory, with a packed test atlas;
;;;; no PTY, no GL. Tests of LEXTER-O19 fail until Phase 1 repairs the
;;;; handler's double-width writes (LEXTER-D98, LEXTER-D117).

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
