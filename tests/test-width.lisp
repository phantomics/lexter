;;;; tests/test-width.lisp — Character widths from Unicode's tables.
;;;;
;;;; Pure: the generated width table and width policies; no fonts, no GL. They
;;;; test LEXTER-D117's width table and LEXTER-DRAFT-cell-model-revision-D23's
;;;; choice of Unicode 17.0.

(in-package #:lexter-tests)
(in-suite width)

(defun widths (&rest codepoints)
  "The widths of CODEPOINTS under the default policy."
  (mapcar #'lexter/width:char-width codepoints))

(def-test table-is-from-unicode-17 ()
  "The width table is generated from the data of Unicode 17.0."
  (is (string= "17.0.0" lexter/width:+unicode-version+)))

(def-test ideographs-and-emoji-are-wide ()
  "CJK ideographs, full-width forms, and emoji with emoji presentation take two
columns, among them characters added in recent versions of Unicode."
  (assert-that (widths #x4E00 #x3400 #x20000 #xFF21 #x1F600 #x1FAE8)
               (contains 2 2 2 2 2 2)))

(def-test unassigned-ideographs-default-to-wide ()
  "Unassigned code points in the CJK blocks and in planes 2 and 3 are wide, as
EastAsianWidth.txt says they default to."
  (assert-that (widths #x9FFF #x2FFFD #x3FFFD)
               (contains 2 2 2)))

(def-test combining-and-format-characters-take-no-columns ()
  "Combining marks, the zero-width joiner, variation selectors, and Hangul
medial vowels take no columns."
  (assert-that (widths #x0301 #x20DD #x200D #xFE0F #xE0100 #x1160)
               (contains 0 0 0 0 0 0)))

(def-test narrow-characters-take-one-column ()
  "Latin letters, half-width forms, the soft hyphen, and the prepended
concatenation marks take one column."
  (assert-that (widths #x41 #xFF61 #x00AD #x0600)
               (contains 1 1 1 1)))

(def-test ambiguous-characters-follow-the-policy ()
  "Characters of ambiguous East Asian Width are narrow by default and wide
under a policy that makes them so."
  (let ((wide (lexter/width:make-width-policy :ambiguous-width 2)))
    (assert-that (widths #x03B1 #x2500) (contains 1 1))
    (is (= 2 (lexter/width:char-width #x03B1 wide)))
    (is (= 2 (lexter/width:char-width #x2500 wide)))
    (is (= 1 (lexter/width:char-width #x41 wide)))))

(def-test overrides-come-before-the-table ()
  "A policy's overrides decide the width of the code points they cover, before
the table does."
  (let ((policy (lexter/width:make-width-policy
                 :overrides '((#x41 #x42 2) (#x4E00 #x4E00 1)))))
    (is (= 2 (lexter/width:char-width #x41 policy)))
    (is (= 1 (lexter/width:char-width #x4E00 policy)))
    (is (= 1 (lexter/width:char-width #x43 policy)))))

(def-test policies-reject-bad-overrides ()
  "A width policy refuses an override whose width is not 0, 1, or 2."
  (signals error (lexter/width:make-width-policy :overrides '((#x41 #x41 3)))))
