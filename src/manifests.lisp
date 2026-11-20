;;;; src/manifests.lisp — Lexter's binary formats, declared as SpecOps manifests.
;;;;
;;;; The record of the cell-model architecture (LEXTER-0016, The Record), the
;;;; text cell (LEXTER-D127), and the texels of the swatch and palette stores
;;;; (LEXTER-D109), each declared once as a manifest in 8-bit units,
;;;; little-endian, so that an array holds the bytes the architecture defines on
;;;; any host (LEXTER-D130). The accessors below are the only readers and
;;;; writers of these formats (LEXTER-D104, LEXTER-D129): they hide that a
;;;; record array is a simple array of bytes, 32 to a record, row by row.
;;;;
;;;; Reserved bits are written as constant digits of the manifests' masques, so
;;;; that a full read checks them. The invariants that span fields, which
;;;; manifests do not express, are checked by RECORD-INVARIANT-VIOLATIONS and
;;;; HALF-PAIR-VIOLATIONS.

(in-package #:lexter/manifests)

;;; --------------------------------------------------------------------------
;;; Sizes and values
;;; --------------------------------------------------------------------------

(defconstant +record-bytes+ 32
  "Bytes in one record: eight 32-bit words.")

(defconstant +plain-glyph-words+ 6
  "Glyph words in a record of the plain format, words 2-7.")

(defconstant +text-cell-bytes+ 8
  "Bytes in one text cell: a content word, a style id, and flags.")

(defconstant +texel-bytes+ 4
  "Bytes in one texel of the swatch or palette store, RGBA8UI.")

(defconstant +continuation-marker+ #xFFFFFFFF
  "The content word of a text cell that the character before it covers: a value
   beyond Unicode, and beyond the names 0x110000 + k of the generated glyphs
   (LEXTER-D119, LEXTER-D89).")

(defenum record-format nil :plain 0 :void 1 :inline-colours 2 :effect 3 :tiles 4)

(defenum mask-operation nil :union 0 :intersection 1 :exclusion 2 :mask-less-coverage 3)

;;; --------------------------------------------------------------------------
;;; The record
;;; --------------------------------------------------------------------------

;; A glyph word: a 24-bit atlas position, then the settings byte of a layer or
;; of a mask (LEXTER-D84). Bit 24, the selector, is the first of either.
(defmanifest glyph-layer (:unit 8 :endian :little)
  (:glyph (:u 3) :default 0)
  (masque "b:00000iis" (s :selector :u :default 0) (i :ink-slot :u :default 0)))

(defmanifest glyph-mask (:unit 8 :endian :little)
  (:glyph (:u 3) :default 0)
  (masque "b:00rrroos" (s :selector :u :default 0)
          (o :operation :u :default :union :enumerate-by mask-operation)
          (r :reach :u :default 0)))

;; The plain format. Word 0: the format, the glyph count and type bits, the
;; drawing flags, and no parameters (LEXTER-D81, LEXTER-D83); word 1: the
;; swatch, the palette slot, and the background slot, with no colour
;; parameters (LEXTER-D87); words 2-7: glyph 0, always a layer, then glyphs
;; 1-5, each a layer or a mask as its type bit says (LEXTER-D85).
(defmanifest plain-record (:unit 8 :endian :little)
  0
  (masque "b:edcbannn" (n :glyph-count :u :default 0)
          (a :type-1 :u :default 0) (b :type-2 :u :default 0) (c :type-3 :u :default 0)
          (d :type-4 :u :default 0) (e :type-5 :u :default 0))
  (masque "b:00mllkrw" (w :wide :u :default 0) (r :right-half :u :default 0)
          (k :blink :u :default 0) (l :line-size :u :default 0)
          (m :magnified-half :u :default 0))
  0
  (:swatch :u16 :default 0)
  (:palette-slot :u8 :default 0)
  (masque "b:000000gg" (g :background-slot :u :default 0))
  (manifest :g0 glyph-layer)
  (:g1 (:case :type-1 (0 (manifest glyph-layer)) (1 (manifest glyph-mask))))
  (:g2 (:case :type-2 (0 (manifest glyph-layer)) (1 (manifest glyph-mask))))
  (:g3 (:case :type-3 (0 (manifest glyph-layer)) (1 (manifest glyph-mask))))
  (:g4 (:case :type-4 (0 (manifest glyph-layer)) (1 (manifest glyph-mask))))
  (:g5 (:case :type-5 (0 (manifest glyph-layer)) (1 (manifest glyph-mask)))))

;; The first eight bytes, which every format reads alike but for its structure
;; and parameters (LEXTER-D81, LEXTER-D87). Bits 22-23 are FORMAT-FLAGS: common
;; flags are allocated from bit 22 upwards, and a format may claim bits from 23
;; downwards, as tiles claim bit 23.
(defmanifest record-common (:unit 8 :endian :little)
  (:format :u8 :default :plain :enumerate-by record-format)
  (:structure :u8 :default 0)
  (masque "b:ffmllkrw" (w :wide :u :default 0) (r :right-half :u :default 0)
          (k :blink :u :default 0) (l :line-size :u :default 0)
          (m :magnified-half :u :default 0) (f :format-flags :u :default 0))
  (:parameters :u8 :default 0)
  (:swatch :u16 :default 0)
  (:palette-slot :u8 :default 0)
  (masque "b:ccccccgg" (g :background-slot :u :default 0)
          (c :colour-parameters :u :default 0)))

;;; --------------------------------------------------------------------------
;;; The text cell
;;; --------------------------------------------------------------------------

;; A content word, a codepoint or the continuation marker; the style id; and
;; the flags: the wide bit, which holds the width the writing path decided,
;; and the flag of a cell that holds more codepoints than its first
;; (LEXTER-D127, LEXTER-D117).
(defmanifest text-cell (:unit 8 :endian :little)
  (:content :u32 :default 0)
  (:style :u16 :default 0)
  (masque "b:00000000000000cw" (w :wide :u :default 0) (c :cluster :u :default 0)))

;;; --------------------------------------------------------------------------
;;; The texels
;;; --------------------------------------------------------------------------

;; A swatch: four palette indices, by convention the background in slot 0 and
;; the foreground in slot 1 (LEXTER-0016, Palettes and Swatches).
(defmanifest swatch-texel (:unit 8 :endian :little)
  (:slot-0 :u8 :default 0) (:slot-1 :u8 :default 0)
  (:slot-2 :u8 :default 0) (:slot-3 :u8 :default 0))

(defmanifest palette-texel (:unit 8 :endian :little)
  (:red :u8 :default 0) (:green :u8 :default 0) (:blue :u8 :default 0)
  (:alpha :u8 :default 255))

;;; --------------------------------------------------------------------------
;;; Record arrays
;;; --------------------------------------------------------------------------

(deftype record-array ()
  "An array of records, 32 bytes each, row by row (LEXTER-D129)."
  '(simple-array (unsigned-byte 8) (*)))

(defun make-record-array (count)
  "A fresh array of COUNT records, each a record of zeros: a blank plain cell
   in global swatch 0, palette slot 0, and background slot 0 (LEXTER-D83)."
  (make-array (* count +record-bytes+) :element-type '(unsigned-byte 8)
                                       :initial-element 0))

(defun record-array-count (records)
  "The number of records RECORDS holds."
  (floor (length records) +record-bytes+))

(declaim (inline %record-start))
(defun %record-start (index)
  (* index +record-bytes+))

(defmacro %without-sub-manifest-warnings (&body body)
  "BODY, a write of the plain record, without the style warnings SBCL gives of
   it: SpecOps 0.2.3 binds variables it never reads in writing a sub-manifest
   that holds a masque, as each glyph word is. Reported to SpecOps."
  `(locally (declare #+sbcl (sb-ext:muffle-conditions style-warning))
     ,@body))

(defmacro write-plain-record (records index &rest fields)
  "Write record INDEX of RECORDS as a plain record of FIELDS, the fields and
   values of the PLAIN-RECORD manifest; a field not given takes its default,
   zero. A glyph word's value is a literal list of its fields, as
   :G0 (:GLYPH g :INK-SLOT 1)."
  `(%without-sub-manifest-warnings
     (marshal plain-record ,records (:at (%record-start ,index)) ,@fields)))

(defmacro patch-plain-record (records index &rest fields)
  "Write only FIELDS into record INDEX of RECORDS, a plain record, leaving its
   other fields as they are (LEXTER-D84). A field of a glyph word is named by a
   path, as (:G0 :INK-SLOT); a glyph word's form is the one its type bit gives,
   in FIELDS or else in the record."
  `(%without-sub-manifest-warnings
     (marshal plain-record ,records (:at (%record-start ,index) :patch t) ,@fields)))

(defmacro read-plain-record (records index &rest keys)
  "Read record INDEX of RECORDS as a plain record: the values of KEYS, fields
   or paths of the PLAIN-RECORD manifest, or with no KEYS the whole record as a
   plist. The constants and reserved bits of what is read are checked."
  `(unmarshal plain-record ,records (:at (%record-start ,index)) ,@keys))

(defmacro read-record-common (records index &rest keys)
  "Read the values of KEYS, fields of the RECORD-COMMON manifest, from the
   first eight bytes of record INDEX of RECORDS, whatever its format."
  `(unmarshal record-common ,records (:at (%record-start ,index)) ,@keys))

(defmacro patch-record-common (records index &rest fields)
  "Write only FIELDS of the RECORD-COMMON manifest into record INDEX of
   RECORDS, whatever its format, leaving the rest of the record as it is."
  `(marshal record-common ,records (:at (%record-start ,index) :patch t) ,@fields))

(defun record-format (records index)
  "The format of record INDEX of RECORDS: a keyword of RECORD-FORMAT, or the
   integer of a format byte that names none (LEXTER-D82)."
  (read-record-common records index :format))

(defun copy-records (from from-index to to-index count)
  "Copy COUNT records of FROM, from record FROM-INDEX, into TO at TO-INDEX."
  (replace to from :start1 (%record-start to-index)
                   :start2 (%record-start from-index)
                   :end2 (%record-start (+ from-index count))))

(defun clear-records (records start count)
  "Make COUNT records of RECORDS, from record START, records of zeros."
  (fill records 0 :start (%record-start start) :end (%record-start (+ start count))))

;;; --------------------------------------------------------------------------
;;; Glyph words by number
;;; --------------------------------------------------------------------------

(eval-when (:compile-toplevel :load-toplevel :execute)
  (defun %glyph-key (n)
    (intern (format nil "G~D" n) :keyword)))

(defmacro %case-glyph-word (i (key &key (from 0)) form)
  "FORM for glyph word I of a plain record, known when the code runs, with KEY
   standing in FORM for the word's field, :G0 to :G5; from glyph FROM, as 1
   for a field only a mask has, since glyph 0 is always a layer."
  `(ecase ,i
     ,@(loop :for n :from from :below +plain-glyph-words+
             :collect `(,n ,(subst (%glyph-key n) key form)))))

(defun record-glyph (records index i)
  "The atlas position of glyph I of record INDEX of RECORDS, a plain record."
  (%case-glyph-word i (word)
    (read-plain-record records index (word :glyph))))

(defun (setf record-glyph) (glyph records index i)
  (%case-glyph-word i (word)
    (patch-plain-record records index (word :glyph) glyph))
  glyph)

(defun record-ink-slot (records index i)
  "The ink slot of glyph I of record INDEX of RECORDS, a plain record; glyph I
   must be a layer, as a mask has none."
  (%case-glyph-word i (word)
    (read-plain-record records index (word :ink-slot))))

(defun (setf record-ink-slot) (slot records index i)
  (%case-glyph-word i (word)
    (patch-plain-record records index (word :ink-slot) slot))
  slot)

(defun %type-bits (records index)
  "The glyph count of record INDEX of RECORDS, and its type bits as an integer
   whose bit I-1 is set when glyph I is a mask."
  (multiple-value-bind (n a b c d e)
      (read-plain-record records index :glyph-count :type-1 :type-2 :type-3 :type-4 :type-5)
    (values n (logior a (ash b 1) (ash c 2) (ash d 3) (ash e 4)))))

(defun record-layer-p (records index i)
  "True when glyph I of record INDEX of RECORDS, a plain record, is a layer:
   glyph 0 always, and another when its type bit is 0 (LEXTER-D83)."
  (or (zerop i)
      (not (logbitp (1- i) (nth-value 1 (%type-bits records index))))))

(defun record-topmost-layer (records index)
  "The number of the last layer among the glyphs in use of record INDEX of
   RECORDS, a plain record, the one whose ink slot a covered pixel takes when
   every layer covers it; or NIL when it has no glyphs."
  (multiple-value-bind (n types) (%type-bits records index)
    (loop :for i :from (1- (min n +plain-glyph-words+)) :downto 0
          :when (or (zerop i) (not (logbitp (1- i) types)))
            :return i)))

;;; --------------------------------------------------------------------------
;;; Invariants that span fields
;;; --------------------------------------------------------------------------

(defun record-invariant-violations (records index)
  "The invariants that record INDEX of RECORDS breaks, as a list of keywords,
   empty when it keeps them all (LEXTER-0016, Invariants of a record):
   :FORMAT, a format other than plain, the only one built; :RESERVED-BITS, a
   reserved bit set; :GLYPH-COUNT, more glyphs than the plain format's six;
   :UNUSED-TYPE-BITS and :UNUSED-GLYPH-WORDS, a type bit or a glyph word in use
   beyond the glyph count; :REACH, a mask that reaches more layers than lie
   before it; :RIGHT-HALF, a right-half bit without the wide bit; and
   :MAGNIFIED-HALF, a magnified half without a line size."
  (unless (eq (record-format records index) :plain)
    (return-from record-invariant-violations (list :format)))
  (let ((violations '())
        (start (%record-start index)))
    (handler-case (read-plain-record records index)
      (manifest-check-failed ()
        (push :reserved-bits violations)))
    (multiple-value-bind (n types) (%type-bits records index)
      (when (> n +plain-glyph-words+)
        (push :glyph-count violations))
      (let ((n (min n +plain-glyph-words+))
            (layers 0))
        (when (plusp (ldb (byte 5 (max 0 (1- n))) types))
          (push :unused-type-bits violations))
        (loop :for i :from n :below +plain-glyph-words+
              :for word := (+ start 8 (* 4 i))
              :unless (every #'zerop (subseq records word (+ word 4)))
                :do (push :unused-glyph-words violations)
                    (return))
        (dotimes (i n)
          (if (or (zerop i) (not (logbitp (1- i) types)))
              (incf layers)
              (let ((reach (%case-glyph-word i (word :from 1)
                             (unmarshal plain-record records (:at start :check nil)
                                        (word :reach)))))
                (when (> (1+ reach) layers)
                  (push :reach violations)))))))
    (multiple-value-bind (wide right-half line-size magnified-half)
        (unmarshal record-common records (:at start :check nil)
                   :wide :right-half :line-size :magnified-half)
      (when (and (= right-half 1) (= wide 0))
        (push :right-half violations))
      (when (and (= magnified-half 1) (= line-size 0))
        (push :magnified-half violations)))
    (nreverse violations)))

(defun half-pair-violations (records left &key (wide-first-column-p (constantly nil)))
  "The invariants that records LEFT and LEFT + 1 of RECORDS, the two halves of
   a double-width glyph, break, as a list of keywords (LEXTER-D126): :LEFT-HALF
   or :RIGHT-HALF, a half without the wide bit, or with the wrong right-half
   bit; :STRUCTURE, halves of different glyph counts or type bits; and
   :COLUMNS, a glyph word of the left half naming the first column of a wide
   glyph, by WIDE-FIRST-COLUMN-P of its atlas position, where the same word of
   the right half does not name the second."
  (let ((violations '()))
    (multiple-value-bind (wide right-half structure)
        (read-record-common records left :wide :right-half :structure)
      (unless (and (= wide 1) (= right-half 0))
        (push :left-half violations))
      (multiple-value-bind (wide right-half right-structure)
          (read-record-common records (1+ left) :wide :right-half :structure)
        (unless (and (= wide 1) (= right-half 1))
          (push :right-half violations))
        (if (/= structure right-structure)
            (push :structure violations)
            (dotimes (i (min (ldb (byte 3 0) structure) +plain-glyph-words+))
              (let ((glyph (record-glyph records left i)))
                (when (and (funcall wide-first-column-p glyph)
                           (/= (record-glyph records (1+ left) i) (1+ glyph)))
                  (push :columns violations)
                  (return)))))))
    (nreverse violations)))

;;; --------------------------------------------------------------------------
;;; Text cells
;;; --------------------------------------------------------------------------

(deftype text-array ()
  "An array of text cells, 8 bytes each, row by row (LEXTER-D127)."
  '(simple-array (unsigned-byte 8) (*)))

(defun make-text-array (count)
  "A fresh array of COUNT text cells, each of zeros."
  (make-array (* count +text-cell-bytes+) :element-type '(unsigned-byte 8)
                                          :initial-element 0))

(defun text-array-count (cells)
  "The number of text cells CELLS holds."
  (floor (length cells) +text-cell-bytes+))

(declaim (inline %text-cell-start))
(defun %text-cell-start (index)
  (* index +text-cell-bytes+))

(defmacro write-text-cell (cells index &rest fields)
  "Write text cell INDEX of CELLS from FIELDS, the fields and values of the
   TEXT-CELL manifest; a field not given takes its default, zero."
  `(marshal text-cell ,cells (:at (%text-cell-start ,index)) ,@fields))

(defmacro patch-text-cell (cells index &rest fields)
  "Write only FIELDS into text cell INDEX of CELLS."
  `(marshal text-cell ,cells (:at (%text-cell-start ,index) :patch t) ,@fields))

(defmacro read-text-cell (cells index &rest keys)
  "Read the values of KEYS, fields of the TEXT-CELL manifest, from text cell
   INDEX of CELLS, or with no KEYS the whole cell as a plist."
  `(unmarshal text-cell ,cells (:at (%text-cell-start ,index)) ,@keys))

(defun text-cell-continuation-p (cells index)
  "True when text cell INDEX of CELLS is covered by the character before it."
  (= (read-text-cell cells index :content) +continuation-marker+))

;;; --------------------------------------------------------------------------
;;; Texels
;;; --------------------------------------------------------------------------

(declaim (inline write-swatch-texel read-swatch-texel
                 write-palette-texel read-palette-texel))

(defun write-swatch-texel (bytes index s0 s1 s2 s3)
  "Write swatch INDEX of BYTES, a swatch store's data, with the palette
   indices S0-S3 of its four slots."
  (declare (type (simple-array (unsigned-byte 8) (*)) bytes))
  (marshal swatch-texel bytes (:at (* index +texel-bytes+))
           :slot-0 s0 :slot-1 s1 :slot-2 s2 :slot-3 s3)
  (values))

(defun read-swatch-texel (bytes index)
  "The palette indices of the four slots of swatch INDEX of BYTES."
  (declare (type (simple-array (unsigned-byte 8) (*)) bytes))
  (unmarshal swatch-texel bytes (:at (* index +texel-bytes+))
             :slot-0 :slot-1 :slot-2 :slot-3))

(defun write-palette-texel (bytes index red green blue &optional (alpha 255))
  "Write entry INDEX of BYTES, a palette, with the colour RED, GREEN, BLUE,
   and ALPHA."
  (declare (type (simple-array (unsigned-byte 8) (*)) bytes))
  (marshal palette-texel bytes (:at (* index +texel-bytes+))
           :red red :green green :blue blue :alpha alpha)
  (values))

(defun read-palette-texel (bytes index)
  "The red, green, blue, and alpha bytes of entry INDEX of BYTES, a palette."
  (declare (type (simple-array (unsigned-byte 8) (*)) bytes))
  (unmarshal palette-texel bytes (:at (* index +texel-bytes+))
             :red :green :blue :alpha))
