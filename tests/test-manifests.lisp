;;;; tests/test-manifests.lisp — The record, the text cell, and the texels.
;;;;
;;;; Pure: arrays of bytes in memory, written and read through the accessors
;;;; over Lexter's SpecOps manifests (LEXTER-D130); no GL. The records are the
;;;; worked records of the cell-model architecture (LEXTER-0016, Appendices),
;;;; compared byte for byte, each 32-bit word little-endian.
;;;;
;;;; In these records swatch #x1234 has the background colour in slot 0 and the
;;;; foreground in slot 1, swatch #x0567 holds red in slot 2, and the palette
;;;; slot is 7. The letter g is at atlas position 103, among the fonts' glyphs,
;;;; which begin at 64; the line glyphs are at 8 + 8 x style + flags
;;;; (LEXTER-D89), so the underline is 9 and the strikethrough 10.

(in-package #:lexter-tests)
(in-suite manifests)

(defparameter *g* 103 "The atlas position of the letter g in these records.")

(defun record-octets (&rest bytes)
  "A 32-byte record holding BYTES, then zeros."
  (let ((v (make-array lexter/manifests:+record-bytes+ :element-type '(unsigned-byte 8)
                                                       :initial-element 0)))
    (replace v bytes)
    v))

(defun record-at (index &optional (records *records*))
  "The 32 bytes of record INDEX of RECORDS."
  (let ((start (* index lexter/manifests:+record-bytes+)))
    (subseq records start (+ start lexter/manifests:+record-bytes+))))

(defun text-cell-at (index &optional (cells *text-cells*))
  "The 8 bytes of text cell INDEX of CELLS."
  (let ((start (* index lexter/manifests:+text-cell-bytes+)))
    (subseq cells start (+ start lexter/manifests:+text-cell-bytes+))))

(defun put-record (index bytes &optional (records *records*))
  "Place the 32 BYTES at record INDEX of RECORDS, as a record already in a grid
would lie, so that a test can read one the accessors did not write."
  (replace records bytes :start1 (* index lexter/manifests:+record-bytes+)))

;;; ------------------------------------------------------------
;;; The worked records
;;; ------------------------------------------------------------

(def-test a-record-of-zeros-is-a-blank-plain-cell ()
  "A record of zeros is a plain cell with no glyphs, in swatch 0, palette slot
0, and background slot 0; a plain record written with every field defaulted is
all zeros, and so is a fresh record array (LEXTER-D83, LEXTER-0016 Appendices)."
  (with-clean-records (:count 2)
    (is (every #'zerop *records*))
    (is (equal '(:plain 0 0 0)
               (multiple-value-list
                (lexter/manifests:read-record-common *records* 0
                                                     :format :swatch :palette-slot :background-slot))))
    (is (eql 0 (lexter/manifests:read-plain-record *records* 0 :glyph-count)))
    (put-record 1 (make-array 32 :element-type '(unsigned-byte 8) :initial-element #xEE))
    (lexter/manifests:write-plain-record *records* 1)
    (is (equalp (record-octets) (record-at 1)))))

(def-test the-letter-g-underlined-in-the-text-s-colour ()
  "The underlined g has two glyph words, the type bit of glyph 1 marking it a
mask: g as a layer in ink slot 1, and the underline glyph 9 cutting it by
union, reaching one layer (LEXTER-D83, LEXTER-D84, LEXTER-D88)."
  (with-clean-records ()
    (lexter/manifests:write-plain-record *records* 2
      :glyph-count 2 :type-1 1 :swatch #x1234 :palette-slot 7
      :g0 (:glyph *g* :ink-slot 1) :g1 (:glyph 9 :operation :union))
    (is (equalp (record-octets 0 #x0A 0 0  #x34 #x12 7 0  *g* 0 0 #x02  9 0 0 0)
                (record-at 2)))
    (is (equal (list 2 1 (list :glyph *g* :selector 0 :ink-slot 1)
                     '(:glyph 9 :selector 0 :operation :union :reach 0))
               (multiple-value-list
                (lexter/manifests:read-plain-record *records* 2 :glyph-count :type-1 :g0 :g1))))))

(def-test the-letter-g-in-reverse-video ()
  "Reverse video sets the background slot to 1 and the text's ink slot to 0,
in the same swatch, so a reversed cell needs no swatch of its own
(LEXTER-D86)."
  (with-clean-records ()
    (lexter/manifests:write-plain-record *records* 0
      :glyph-count 1 :swatch #x1234 :palette-slot 7 :background-slot 1
      :g0 (:glyph *g* :ink-slot 0))
    (is (equalp (record-octets 0 1 0 0  #x34 #x12 7 1  *g* 0 0 0) (record-at 0)))))

(def-test a-red-underline-beneath-g-and-a-strikethrough-in-its-colour ()
  "An SGR 58 underline is a layer beneath the text in a slot of its own, and a
strikethrough beside it a mask on the text: three glyph words, of which only
glyph 2 is a mask (LEXTER-D85, LEXTER-D88)."
  (with-clean-records ()
    (lexter/manifests:write-plain-record *records* 0
      :glyph-count 3 :type-2 1 :swatch #x0567 :palette-slot 7
      :g0 (:glyph 9 :ink-slot 2) :g1 (:glyph *g* :ink-slot 1)
      :g2 (:glyph 10 :operation :union))
    (is (equalp (record-octets 0 #x13 0 0  #x67 #x05 7 0  9 0 0 #x04  *g* 0 0 #x02  10 0 0 0)
                (record-at 0)))))

(def-test a-spelling-checker-s-underline-beneath-g ()
  "A line the terminal never writes, here the underline of line style 1, is a
layer beneath the text in its own colour; both glyph words are layers
(LEXTER-D88, LEXTER-D89)."
  (with-clean-records ()
    (lexter/manifests:write-plain-record *records* 0
      :glyph-count 2 :swatch #x0567 :palette-slot 7
      :g0 (:glyph (+ 8 (* 8 1) 1) :ink-slot 2) :g1 (:glyph *g* :ink-slot 1))
    (is (equalp (record-octets 0 2 0 0  #x67 #x05 7 0  17 0 0 #x04  *g* 0 0 #x02)
                (record-at 0)))))

(def-test a-scroll-bar-thumb-as-a-band-inside-one-cell ()
  "Two masks cut one layer by intersection, the second with its uninked
pixels, to leave a band from two-eighths to six-eighths down the cell; the
bar and the blocks are at atlas positions 200 to 202 (LEXTER-D85)."
  (with-clean-records ()
    (lexter/manifests:write-plain-record *records* 0
      :glyph-count 3 :type-1 1 :type-2 1
      :g0 (:glyph 200 :ink-slot 1)
      :g1 (:glyph 201 :operation :intersection)
      :g2 (:glyph 202 :selector 1 :operation :intersection))
    (is (equalp (record-octets 0 #x1B 0 0  0 0 0 0  200 0 0 #x02  201 0 0 #x02  202 0 0 #x03)
                (record-at 0)))))

(def-test a-mask-reaching-two-layers ()
  "A mask whose reach field is 1 cuts the two layers before it: the left half,
at atlas position 203, reveals g and its coloured underline up to the middle
of the cell (LEXTER-D85)."
  (with-clean-records ()
    (lexter/manifests:write-plain-record *records* 0
      :glyph-count 3 :type-2 1 :swatch #x0567 :palette-slot 7
      :g0 (:glyph 9 :ink-slot 2) :g1 (:glyph *g* :ink-slot 1)
      :g2 (:glyph 203 :operation :intersection :reach 1))
    (is (equalp (record-octets 0 #x13 0 0  #x67 #x05 7 0  9 0 0 #x04  *g* 0 0 #x02  203 0 0 #x0A)
                (record-at 0)))))

(def-test the-letter-g-blinking-over-a-red-underline ()
  "The blink flag is bit 18 of the format word, among the drawing flags common
to every format, and both glyph words are layers (LEXTER-D81, LEXTER-D94)."
  (with-clean-records ()
    (lexter/manifests:write-plain-record *records* 0
      :glyph-count 2 :blink 1 :swatch #x0567 :palette-slot 7
      :g0 (:glyph 9 :ink-slot 2) :g1 (:glyph *g* :ink-slot 1))
    (is (equalp (record-octets 0 2 4 0  #x67 #x05 7 0  9 0 0 #x04  *g* 0 0 #x02)
                (record-at 0)))
    (is (eql 1 (lexter/manifests:read-record-common *records* 0 :blink)))))

;;; ------------------------------------------------------------
;;; Halves and line sizes
;;; ------------------------------------------------------------

(def-test the-halves-of-a-wide-glyph-name-their-own-columns ()
  "The halves of a double-width glyph both set the wide bit, the right half the
right-half bit too, and each names the atlas column it draws: the right half
the glyph's position plus 1 (LEXTER-D81, LEXTER-D126)."
  (with-clean-records ()
    (lexter/manifests:write-plain-record *records* 0
      :glyph-count 1 :wide 1 :swatch #x1234 :g0 (:glyph 300 :ink-slot 1))
    (lexter/manifests:write-plain-record *records* 1
      :glyph-count 1 :wide 1 :right-half 1 :swatch #x1234 :g0 (:glyph 301 :ink-slot 1))
    (is (equalp (record-octets 0 1 1 0  #x34 #x12 0 0  #x2C 1 0 #x02) (record-at 0)))
    (is (equalp (record-octets 0 1 3 0  #x34 #x12 0 0  #x2D 1 0 #x02) (record-at 1)))
    (is (null (lexter/manifests:half-pair-violations
               *records* 0 :wide-first-column-p (lambda (glyph) (= glyph 300)))))))

(def-test a-line-size-and-magnified-half-sit-in-bits-19-to-21 ()
  "The line size is bits 19-20 of the format word and the magnified half bit
21, beside the wide bits, in every format: the right cell of the bottom of a
double-height line sets them to 3 and 1 (LEXTER-D114)."
  (with-clean-records ()
    (lexter/manifests:write-plain-record *records* 0
      :glyph-count 1 :line-size 3 :magnified-half 1 :g0 (:glyph *g* :ink-slot 1))
    (is (equalp (record-octets 0 1 #x38 0  0 0 0 0  *g* 0 0 #x02) (record-at 0)))
    (is (equal '(3 1) (multiple-value-list
                       (lexter/manifests:read-record-common *records* 0
                                                            :line-size :magnified-half))))))

;;; ------------------------------------------------------------
;;; Patches and glyph words chosen when the code runs
;;; ------------------------------------------------------------

(def-test a-patch-changes-only-the-fields-it-names ()
  "Writing one field of a record, here the background slot and the text's ink
slot as the interim block cursor exchanges them, leaves every other field and
record as it was (LEXTER-D84, LEXTER-D130)."
  (with-clean-records ()
    (lexter/manifests:write-plain-record *records* 1
      :glyph-count 2 :type-1 1 :swatch #x1234 :palette-slot 7
      :g0 (:glyph *g* :ink-slot 1) :g1 (:glyph 9 :operation :union))
    (lexter/manifests:patch-plain-record *records* 1 :background-slot 1 (:g0 :ink-slot) 0)
    (is (equalp (record-octets 0 #x0A 0 0  #x34 #x12 7 1  *g* 0 0 0  9 0 0 0) (record-at 1)))
    (is (every #'zerop (record-at 0)))
    (is (every #'zerop (record-at 2)))))

(def-test a-glyph-word-is-reached-by-its-number-when-the-code-runs ()
  "A glyph word whose number is known only when the code runs is read and
written through its number: its glyph and, for a layer, its ink slot; the
topmost layer is found from the glyph count and the type bits (LEXTER-D83,
LEXTER-D85)."
  (with-clean-records ()
    (lexter/manifests:write-plain-record *records* 0
      :glyph-count 3 :type-2 1 :swatch #x0567 :palette-slot 7
      :g0 (:glyph 9 :ink-slot 2) :g1 (:glyph *g* :ink-slot 1)
      :g2 (:glyph 10 :operation :union))
    (is (equal (list 9 *g* 10) (loop :for i :below 3
                                     :collect (lexter/manifests:record-glyph *records* 0 i))))
    (is (equal '(t t nil) (loop :for i :below 3
                                :collect (lexter/manifests:record-layer-p *records* 0 i))))
    (is (eql 1 (lexter/manifests:record-topmost-layer *records* 0)))
    (setf (lexter/manifests:record-ink-slot *records* 0 1) 0)
    (setf (lexter/manifests:record-glyph *records* 0 1) 104)
    (is (equal '(104 0) (list (lexter/manifests:record-glyph *records* 0 1)
                              (lexter/manifests:record-ink-slot *records* 0 1))))
    (is (null (lexter/manifests:record-topmost-layer *records* 1)))))

(def-test a-mask-has-no-ink-slot-to-write ()
  "A mask has no ink slot, so writing one into a glyph word that the type bits
make a mask signals an error and leaves the record as it was (LEXTER-D84)."
  (with-clean-records ()
    (lexter/manifests:write-plain-record *records* 0
      :glyph-count 2 :type-1 1 :g0 (:glyph *g* :ink-slot 1) :g1 (:glyph 9))
    (let ((before (record-at 0)))
      (signals error (setf (lexter/manifests:record-ink-slot *records* 0 1) 1))
      (is (equalp before (record-at 0))))))

;;; ------------------------------------------------------------
;;; Reading any record
;;; ------------------------------------------------------------

(def-test the-shared-view-reads-a-format-it-does-not-build ()
  "The first eight bytes read alike in every format, so a record of a format
not yet built, or of no defined format, is read through the shared view: its
format, drawing flags, and colours (LEXTER-D81, LEXTER-D82)."
  (with-clean-records ()
    (put-record 0 (record-octets 4 1 #x81 #x22  #x34 #x12 9 #x21))
    (put-record 1 (record-octets 9 0 0 0  0 0 0 0))
    (is (equal '(:tiles 1 9 1 #b10) (multiple-value-list
                                     (lexter/manifests:read-record-common
                                      *records* 0 :format :wide :palette-slot :background-slot
                                      :format-flags))))
    (is (eql 9 (lexter/manifests:record-format *records* 1)))))

(def-test a-record-of-another-format-is-not-read-as-plain ()
  "The format byte is a constant of the plain record's manifest, so a record of
another format read as plain signals a failed check at its first byte, rather
than being taken for a plain cell (LEXTER-D82, LEXTER-D130)."
  (with-clean-records ()
    (put-record 1 (record-octets 4 1 0 #x22))
    (let ((c (handler-case (lexter/manifests:read-plain-record *records* 1)
               (specops:manifest-check-failed (c) c))))
      (is (typep c 'specops:manifest-check-failed))
      (is (eql 32 (specops:check-position c))))))

(def-test a-reserved-bit-fails-the-read-s-check ()
  "Reserved bits are constants of the manifests, so a full read of a record
with one set signals a failed check, as the cell checksum relies on reserved
bits being zero (LEXTER-D130, LEXTER-0016 Invariants of a record)."
  (with-clean-records ()
    (put-record 0 (record-octets 0 1 #x40 0  0 0 0 0  *g* 0 0 #x02))
    (signals specops:manifest-check-failed (lexter/manifests:read-plain-record *records* 0))
    (put-record 0 (record-octets 0 1 0 0  0 0 0 0  *g* 0 0 #x22))
    (signals specops:manifest-check-failed (lexter/manifests:read-plain-record *records* 0))))

;;; ------------------------------------------------------------
;;; The invariants that span fields
;;; ------------------------------------------------------------

(def-test every-worked-record-keeps-the-invariants ()
  "The worked records keep the invariants that span fields, which manifests
do not express (LEXTER-D130, LEXTER-0016 Invariants of a record)."
  (with-clean-records ()
    (lexter/manifests:write-plain-record *records* 0
      :glyph-count 3 :type-2 1 :g0 (:glyph 9 :ink-slot 2) :g1 (:glyph *g* :ink-slot 1)
      :g2 (:glyph 203 :operation :intersection :reach 1))
    (lexter/manifests:write-plain-record *records* 1
      :glyph-count 3 :type-1 1 :type-2 1 :g0 (:glyph 200 :ink-slot 1)
      :g1 (:glyph 201 :operation :intersection)
      :g2 (:glyph 202 :selector 1 :operation :intersection))
    (dotimes (i 4)
      (is (null (lexter/manifests:record-invariant-violations *records* i))))))

(def-test a-record-that-breaks-an-invariant-is-reported ()
  "A record is reported for each invariant it breaks: glyph words or type bits
in use beyond its glyph count, a glyph count beyond the plain format's six, a
mask reaching more layers than lie before it, a right half or magnified half
without the flag it qualifies, and a reserved bit set (LEXTER-D83, LEXTER-D85,
LEXTER-D114, LEXTER-0016 Invariants of a record)."
  (with-clean-records (:count 8)
    (flet ((violations (index bytes)
             (put-record index bytes)
             (lexter/manifests:record-invariant-violations *records* index)))
      (is (equal '(:unused-glyph-words) (violations 0 (record-octets 0 1 0 0  0 0 0 0  *g* 0 0 2  9 0 0 0))))
      (is (equal '(:unused-type-bits) (violations 1 (record-octets 0 #x09 0 0  0 0 0 0  *g* 0 0 2))))
      (is (member :glyph-count (violations 2 (record-octets 0 7 0 0))))
      (is (equal '(:reach) (violations 3 (record-octets 0 #x0A 0 0  0 0 0 0  *g* 0 0 2  9 0 0 #x08))))
      (is (equal '(:right-half) (violations 4 (record-octets 0 1 2 0  0 0 0 0  *g* 0 0 2))))
      (is (equal '(:magnified-half) (violations 5 (record-octets 0 1 #x20 0  0 0 0 0  *g* 0 0 2))))
      (is (equal '(:reserved-bits) (violations 6 (record-octets 0 1 0 0  0 0 0 #x04  *g* 0 0 2))))
      (is (equal '(:format) (violations 7 (record-octets 4 1 0 0)))))))

(def-test halves-that-do-not-match-are-reported ()
  "The two halves of a double-width glyph have the wide bit in both and the
right-half bit in the second, the same glyph count and type bits, and the
right half names the second column of each wide glyph the left half names;
a pair that breaks any of these is reported (LEXTER-D126)."
  (with-clean-records ()
    (flet ((pair (left right)
             (put-record 0 left)
             (put-record 1 right)
             (lexter/manifests:half-pair-violations
              *records* 0 :wide-first-column-p (lambda (glyph) (= glyph 300)))))
      (is (equal '(:right-half) (pair (record-octets 0 1 1 0  0 0 0 0  #x2C 1 0 2)
                                      (record-octets 0 1 1 0  0 0 0 0  #x2D 1 0 2))))
      (is (equal '(:left-half) (pair (record-octets 0 1 0 0  0 0 0 0  #x2C 1 0 2)
                                     (record-octets 0 1 3 0  0 0 0 0  #x2D 1 0 2))))
      (is (equal '(:structure) (pair (record-octets 0 1 1 0  0 0 0 0  #x2C 1 0 2)
                                     (record-octets 0 2 3 0  0 0 0 0  #x2D 1 0 2  9 0 0 2))))
      (is (equal '(:columns) (pair (record-octets 0 1 1 0  0 0 0 0  #x2C 1 0 2)
                                   (record-octets 0 1 3 0  0 0 0 0  #x2C 1 0 2)))))))

;;; ------------------------------------------------------------
;;; Copying and clearing records
;;; ------------------------------------------------------------

(def-test records-are-copied-and-cleared-whole ()
  "A run of records is copied from one array to another, as a pane's row is
composed into the grid, and cleared to records of zeros, leaving the records
around it as they were (LEXTER-D107, LEXTER-D129)."
  (with-clean-records ()
    (let ((source (lexter/manifests:make-record-array 3)))
      (dotimes (i 3)
        (lexter/manifests:write-plain-record source i
          :glyph-count 1 :swatch (1+ i) :g0 (:glyph (+ 100 i) :ink-slot 1)))
      (lexter/manifests:copy-records source 1 *records* 2 2)
      (is (every #'zerop (record-at 0)))
      (is (every #'zerop (record-at 1)))
      (is (equalp (record-at 1 source) (record-at 2)))
      (is (equalp (record-at 2 source) (record-at 3)))
      (lexter/manifests:clear-records *records* 2 1)
      (is (every #'zerop (record-at 2)))
      (is (equalp (record-at 2 source) (record-at 3))))))

;;; ------------------------------------------------------------
;;; Text cells
;;; ------------------------------------------------------------

(def-test a-text-cell-is-eight-bytes ()
  "A text cell holds a 32-bit content word, a 16-bit style id, and 16 bits of
flags: the wide bit in bit 0 and the flag of a cell holding more codepoints
than its first in bit 1 (LEXTER-D127, LEXTER-D119)."
  (with-clean-records ()
    (lexter/manifests:write-text-cell *text-cells* 0 :content #x41 :style 5)
    (lexter/manifests:write-text-cell *text-cells* 1 :content #x4E00 :style #x0102 :wide 1)
    (lexter/manifests:write-text-cell *text-cells* 2 :content #x65 :cluster 1)
    (is (equalp #(#x41 0 0 0  5 0  0 0) (text-cell-at 0)))
    (is (equalp #(0 #x4E 0 0  2 1  1 0) (text-cell-at 1)))
    (is (equalp #(#x65 0 0 0  0 0  2 0) (text-cell-at 2)))
    (is (equal '(#x4E00 #x0102 1 0)
               (multiple-value-list
                (lexter/manifests:read-text-cell *text-cells* 1 :content :style :wide :cluster))))))

(def-test a-continuation-is-neither-a-character-nor-a-generated-glyph ()
  "A cell covered by the character before it holds the continuation marker, a
value beyond Unicode distinct from the names of the generated glyphs, 0x110000
to 0x11003F (LEXTER-D119, LEXTER-D89)."
  (with-clean-records ()
    (let ((marker lexter/manifests:+continuation-marker+))
      (is (> marker #x10FFFF))
      (is (not (<= lexter/atlas:+generated-glyph-base+ marker
                   (+ lexter/atlas:+generated-glyph-base+ 63))))
      (lexter/manifests:write-text-cell *text-cells* 0 :content #x4E00 :wide 1)
      (lexter/manifests:write-text-cell *text-cells* 1 :content marker)
      (is (equal '(nil t) (list (lexter/manifests:text-cell-continuation-p *text-cells* 0)
                                (lexter/manifests:text-cell-continuation-p *text-cells* 1)))))))

(def-test a-text-cell-s-reserved-flags-fail-the-read-s-check ()
  "The text cell's flags beyond its two are reserved, and a read of a cell with
one set signals a failed check (LEXTER-D127, LEXTER-D130)."
  (with-clean-records ()
    (replace *text-cells* #(#x41 0 0 0  0 0  4 0))
    (signals specops:manifest-check-failed
      (lexter/manifests:read-text-cell *text-cells* 0))))

;;; ------------------------------------------------------------
;;; Texels
;;; ------------------------------------------------------------

(def-test texels-are-four-bytes-in-their-store-s-order ()
  "A swatch texel holds its four palette indices, slots 0 to 3, and a palette
texel the red, green, blue, and alpha bytes of a colour, in the RGBA8UI order
the GPU's integer stores read (LEXTER-D109, LEXTER-D130)."
  (with-clean-records ()
    (let ((swatches (make-array 8 :element-type '(unsigned-byte 8) :initial-element 0))
          (palette (make-array 8 :element-type '(unsigned-byte 8) :initial-element 0)))
      (lexter/manifests:write-swatch-texel swatches 1 0 7 196 3)
      (lexter/manifests:write-palette-texel palette 1 #x12 #x34 #x56)
      (is (equalp #(0 0 0 0  0 7 196 3) swatches))
      (is (equalp #(0 0 0 0  #x12 #x34 #x56 255) palette))
      (is (equal '(0 7 196 3) (multiple-value-list
                               (lexter/manifests:read-swatch-texel swatches 1))))
      (is (equal '(#x12 #x34 #x56 255) (multiple-value-list
                                        (lexter/manifests:read-palette-texel palette 1)))))))

(def-test the-default-palette-is-written-through-the-palette-texel ()
  "The default palette's colours are palette texels: entry 1, dark red, reads
as 170, 0, 0, opaque, and entry 255, the last of the greyscale ramp, as 238
in each component (LEXTER-D130)."
  (with-clean-records ()
    (let ((palette (lexter/swatches:make-default-palette)))
      (is (equal '(170 0 0 255) (multiple-value-list
                                 (lexter/manifests:read-palette-texel palette 1))))
      (is (equal '(238 238 238 255) (multiple-value-list
                                     (lexter/manifests:read-palette-texel palette 255)))))))
