;;;; tools/gen-width-table.lisp — Generate src/width-data.lisp, Lexter's table
;;;; of character widths, from the data files of one version of Unicode
;;;; (LEXTER-D117, LEXTER-DRAFT-cell-model-revision-D23).
;;;;
;;;; Run from the repository's root:
;;;;
;;;;   sbcl --non-interactive --load tools/gen-width-table.lisp
;;;;
;;;; The data files are downloaded with curl into tools/ucd-cache/<version>/,
;;;; which git ignores, when they are absent, and checked against the SHA-256
;;;; sums below with sha256sum. Moving to another version of Unicode is a
;;;; deliberate step: change +UNICODE-VERSION+ and the sums together, run this
;;;; file, and review the change to src/width-data.lisp.
;;;;
;;;; The rules, in the order they apply, each overriding the ones before:
;;;;
;;;;   1. Every code point has width 1.
;;;;   2. East Asian Width: W and F give width 2, A marks the code point
;;;;      ambiguous (width 1 unless a width policy makes it 2); the unassigned
;;;;      code points that EastAsianWidth.txt says default to W (the CJK
;;;;      ideograph blocks, and planes 2 and 3) are wide.
;;;;   3. Emoji_Presentation=Yes gives width 2.
;;;;   4. General_Category Mn, Me, and Cf give width 0: combining marks,
;;;;      enclosing marks, and format characters such as the zero-width
;;;;      joiner and the variation selectors.
;;;;   5. Hangul medial vowels and final consonants (U+1160..U+11FF,
;;;;      U+D7B0..U+D7FF) give width 0, since they join the syllable before.
;;;;   6. The soft hyphen U+00AD, and the prepended concatenation marks, which
;;;;      are format characters drawn with a width, give width 1.

(require :uiop)

(defpackage #:lexter/gen-width-table
  (:use #:cl))
(in-package #:lexter/gen-width-table)

(defparameter +unicode-version+ "17.0.0")

(defparameter +files+
  '(("EastAsianWidth.txt" "ucd/EastAsianWidth.txt"
     "ea7ce50f3444a050333448dffef1cadd9325af55cbb764b4a2280faf52170a33")
    ("DerivedGeneralCategory.txt" "ucd/extracted/DerivedGeneralCategory.txt"
     "d62e5bab70ca74f099343f71224fa051cb1fdd61a1ab45c0488c44cfc0b6102e")
    ("emoji-data.txt" "ucd/emoji/emoji-data.txt"
     "2cb2bb9455cda83e8481541ecf5b6dfda66a3bb89efa3fa7c5297eccf607b72b"))
  "For each data file: its name, its path under the version's directory at
unicode.org, and its SHA-256 sum.")

(defparameter +default-wide+
  '((#x3400 . #x4DBF) (#x4E00 . #x9FFF) (#xF900 . #xFAFF)
    (#x20000 . #x2FFFD) (#x30000 . #x3FFFD))
  "Ranges whose unassigned code points EastAsianWidth.txt defaults to W.")

(defparameter +zero-width-jamo+ '((#x1160 . #x11FF) (#xD7B0 . #xD7FF))
  "Hangul medial vowels and final consonants.")

(defparameter +format-characters-with-width+
  '((#x00AD . #x00AD) (#x0600 . #x0605) (#x06DD . #x06DD) (#x070F . #x070F)
    (#x0890 . #x0891) (#x08E2 . #x08E2) (#x110BD . #x110BD) (#x110CD . #x110CD))
  "The soft hyphen, and the prepended concatenation marks of PropList.txt.")

(defconstant +ambiguous+ 3 "The class of a code point of ambiguous width.")

;;; Fetching and checking

(defun cache-directory ()
  (merge-pathnames (format nil "tools/ucd-cache/~a/" +unicode-version+)
                   (uiop:getcwd)))

(defun sha256 (path)
  (first (uiop:split-string
          (uiop:run-program (list "sha256sum" (namestring path)) :output :string)
          :separator " ")))

(defun data-file (name)
  "The path of the checked data file NAME, downloading it if absent."
  (destructuring-bind (file remote sum) (assoc name +files+ :test #'string=)
    (let ((path (merge-pathnames file (cache-directory))))
      (unless (probe-file path)
        (ensure-directories-exist path)
        (format t "~&Downloading ~a~%" remote)
        (uiop:run-program (list "curl" "-sf" "-o" (namestring path)
                                (format nil "https://www.unicode.org/Public/~a/~a"
                                        +unicode-version+ remote))))
      (unless (string= sum (sha256 path))
        (error "~a does not have the expected SHA-256 sum ~a." path sum))
      path)))

;;; Parsing

(defun parse-range (field)
  "The code point range of FIELD, \"XXXX\" or \"XXXX..YYYY\", as two values."
  (let* ((field (string-trim " " field))
         (dots (search ".." field)))
    (if dots
        (values (parse-integer field :end dots :radix 16)
                (parse-integer field :start (+ dots 2) :radix 16))
        (let ((cp (parse-integer field :radix 16)))
          (values cp cp)))))

(defun map-data-lines (path function)
  "Call FUNCTION with the range start, range end, and trimmed property value
of each data line of PATH."
  (with-open-file (in path :external-format :utf-8)
    (loop :for line = (read-line in nil)
          :while line
          :do (let* ((content (subseq line 0 (or (position #\# line) (length line))))
                     (semi (position #\; content)))
                (when semi
                  (multiple-value-bind (start end) (parse-range (subseq content 0 semi))
                    (funcall function start end
                             (string-trim " " (subseq content (1+ semi))))))))))

;;; The table

(defun build-classes ()
  "A vector of each code point's width class: 0, 1, 2, or +AMBIGUOUS+."
  (let ((classes (make-array #x110000 :element-type '(unsigned-byte 8)
                                      :initial-element 1)))
    (flet ((fill-range (start end class)
             (fill classes class :start start :end (1+ end))))
      (loop :for (start . end) :in +default-wide+ :do (fill-range start end 2))
      (map-data-lines (data-file "EastAsianWidth.txt")
                      (lambda (start end value)
                        (fill-range start end
                                    (cond ((member value '("W" "F") :test #'string=) 2)
                                          ((string= value "A") +ambiguous+)
                                          (t 1)))))
      (map-data-lines (data-file "emoji-data.txt")
                      (lambda (start end value)
                        (when (string= value "Emoji_Presentation")
                          (fill-range start end 2))))
      (map-data-lines (data-file "DerivedGeneralCategory.txt")
                      (lambda (start end value)
                        (when (member value '("Mn" "Me" "Cf") :test #'string=)
                          (fill-range start end 0))))
      (loop :for (start . end) :in +zero-width-jamo+ :do (fill-range start end 0))
      (loop :for (start . end) :in +format-characters-with-width+
            :do (fill-range start end 1)))
    classes))

(defun class-ranges (classes)
  "The runs of CLASSES whose class is not 1, as a list of (start end class)."
  (let ((ranges '()))
    (loop :with start = nil
          :for cp :from 0 :to #x110000
          :for class = (if (< cp #x110000) (aref classes cp) -1)
          :for previous = nil :then (aref classes (1- cp))
          :do (when (and start (/= class previous))
                (push (list start (1- cp) previous) ranges)
                (setf start nil))
              (when (and (null start) (< cp #x110000) (/= class 1))
                (setf start cp)))
    (nreverse ranges)))

(defun write-table (ranges path)
  (with-open-file (out path :direction :output :if-exists :supersede
                            :external-format :utf-8)
    (format out ";;;; src/width-data.lisp — Character widths from Unicode ~a.~%" +unicode-version+)
    (format out ";;;;~%;;;; GENERATED by tools/gen-width-table.lisp; do not edit. The rules are in~%")
    (format out ";;;; the generator's header. Made from these files of~%")
    (format out ";;;; https://www.unicode.org/Public/~a/, by SHA-256:~%;;;;~%" +unicode-version+)
    (loop :for (file remote sum) :in +files+
          :do (format out ";;;;   ~a~%;;;;     ~a~%" remote sum))
    (format out "~%(in-package #:lexter/width)~%~%")
    (format out "(defparameter +unicode-version+ ~s~%  \"The version of Unicode whose data the width table is made from.\")~%~%"
            +unicode-version+)
    (format out "(defparameter *width-table-data*~%  '(")
    (loop :for (start end class) :in ranges
          :for i :from 0
          :do (format out "~:[~%    ~; ~]#x~x #x~x ~d" (plusp (mod i 4)) start end class))
    (format out ")~%  \"The ranges of code points whose width is not 1, as a flat list of~%start, end, and class: 0 for width 0, 2 for width 2, 3 for ambiguous.\")~%")))

(let* ((ranges (class-ranges (build-classes)))
       (path (merge-pathnames "src/width-data.lisp" (uiop:getcwd))))
  (write-table ranges path)
  (format t "~&Wrote ~a: ~d ranges from Unicode ~a.~%" path (length ranges) +unicode-version+))
