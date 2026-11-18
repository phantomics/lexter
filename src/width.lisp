(in-package #:lexter/width)

;;;; Character widths for the VT path (LEXTER-D117).
;;;;
;;;; A program on a byte stream counts columns by Unicode's tables, so the VT
;;;; handler decides each character's width by them too: the table in
;;;; width-data.lisp, generated from one version of Unicode's data
;;;; (LEXTER-DRAFT-cell-model-revision-D23), read through a WIDTH-POLICY, which
;;;; may make characters of ambiguous width wide and override the width of
;;;; single code points or ranges. A user who changes the policy makes the same
;;;; setting in the programs that run in the terminal. Nothing here needs GL or
;;;; a font.

(defstruct (width-policy (:constructor %make-width-policy))
  "How character widths are decided: the width of characters of ambiguous East
Asian Width, and overrides, each (START END WIDTH), consulted first."
  (ambiguous-width 1 :type (member 1 2) :read-only t)
  (overrides '() :type list :read-only t))

(defun make-width-policy (&key (ambiguous-width 1) overrides)
  "Make a width policy. AMBIGUOUS-WIDTH, 1 or 2, is the width of characters of
ambiguous East Asian Width. OVERRIDES is a list of (START END WIDTH), each
giving the code points START to END, inclusive, a WIDTH of 0, 1, or 2; the first
that covers a code point wins."
  (dolist (override overrides)
    (destructuring-bind (start end width) override
      (check-type start (integer 0 #x10FFFF))
      (check-type end (integer 0 #x10FFFF))
      (check-type width (member 0 1 2))
      (assert (<= start end) () "Override ~S has its start after its end." override)))
  (%make-width-policy :ambiguous-width ambiguous-width :overrides (copy-list overrides)))

(defvar *default-width-policy* (make-width-policy)
  "The width policy of Unicode's tables with no changes: ambiguous characters
narrow, no overrides. It is never modified; a terminal that wants another
policy makes its own.")

;;; The table, as three parallel vectors searched by bisection

(defun %make-table (data)
  (let* ((n (floor (length data) 3))
         (starts (make-array n :element-type '(unsigned-byte 32)))
         (ends (make-array n :element-type '(unsigned-byte 32)))
         (classes (make-array n :element-type '(unsigned-byte 8))))
    (loop :for (start end class) :on data :by #'cdddr
          :for i :from 0
          :do (setf (aref starts i) start (aref ends i) end (aref classes i) class))
    (values starts ends classes)))

(defvar *width-starts* nil "The first code point of each range.")
(defvar *width-ends* nil "The last code point of each range.")
(defvar *width-classes* nil "The class of each range: 0, 2, or 3 (ambiguous).")

(setf (values *width-starts* *width-ends* *width-classes*)
      (%make-table *width-table-data*))

(defun unicode-width-class (codepoint)
  "The width class Unicode's table gives CODEPOINT: 0, 1, 2, or 3 for
ambiguous."
  (let ((starts *width-starts*)
        (low 0)
        (high (1- (length *width-starts*))))
    (declare (type (simple-array (unsigned-byte 32) (*)) starts)
             (type fixnum low high))
    (loop :while (<= low high)
          :do (let ((mid (floor (+ low high) 2)))
                (cond ((< codepoint (aref starts mid)) (setf high (1- mid)))
                      ((> codepoint (aref *width-ends* mid)) (setf low (1+ mid)))
                      (t (return-from unicode-width-class
                           (aref *width-classes* mid))))))
    1))

(defun char-width (codepoint &optional (policy *default-width-policy*))
  "The number of columns, 0, 1, or 2, that CODEPOINT takes under POLICY."
  (or (loop :for (start end width) :in (width-policy-overrides policy)
            :when (<= start codepoint end) :return width)
      (let ((class (unicode-width-class codepoint)))
        (if (= class 3)
            (width-policy-ambiguous-width policy)
            class))))
