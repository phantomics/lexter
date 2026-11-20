;;;; tests/test-atlas.lisp — Packing the glyph atlas, and its reserved positions.
;;;;
;;;; Pure: fonts are built in memory and atlases packed with PACK-ATLAS; no GL
;;;; context, no files. The packing tests hold now
;;;; (LEXTER-DRAFT-cell-model-revision-D22); the reserved positions are
;;;; LEXTER-O28's repair (LEXTER-D89), and fail until Phase 1 lands it.

(in-package #:lexter-tests)
(in-suite atlas)

(defun font-codepoints (font)
  "The codepoints FONT covers."
  (loop :for cp :being :the :hash-keys :of (lexter/pcf:bitmap-font-encoding font)
        :collect cp))

;;; ------------------------------------------------------------
;;; Packing without GL
;;; ------------------------------------------------------------

(def-test pack-atlas-needs-no-gl ()
  "An atlas is packed from a font chain with no GL context, and has no texture
until it is uploaded."
  (let ((atlas (lexter/atlas:pack-atlas (list (make-test-font)) :cols 16)))
    (is (= 0 (lexter/atlas:atlas-texture-id atlas)))
    (is (= 16 (lexter/atlas:atlas-cols atlas)))))

(def-test pack-atlas-covers-every-codepoint ()
  "Every codepoint of the font chain has a glyph in the packed atlas."
  (let* ((font (make-test-font))
         (atlas (lexter/atlas:pack-atlas (list font) :cols 16)))
    (dolist (cp (font-codepoints font))
      (is-true (lexter/atlas:atlas-glyph-index atlas cp)
               "U+~4,'0X has no glyph" cp))))

(def-test pack-atlas-is-deterministic ()
  "Packing the same font chain with the same column count gives every codepoint
the same position, so positions do not depend on the machine."
  (let* ((font (make-test-font))
         (a (lexter/atlas:pack-atlas (list font) :cols 16))
         (b (lexter/atlas:pack-atlas (list font) :cols 16)))
    (dolist (cp (font-codepoints font))
      (is (eql (lexter/atlas:atlas-glyph-index a cp)
               (lexter/atlas:atlas-glyph-index b cp))))))

(def-test pack-atlas-first-font-wins ()
  "Where two fonts of the chain cover a codepoint, the atlas holds the first
font's glyph."
  (let* ((font-a (make-test-font :narrow '(#x41) :wide '()))
         (font-b (make-test-font :narrow '(#x41 #x42) :wide '()))
         (atlas (lexter/atlas:pack-atlas (list font-a font-b) :cols 16))
         (pixels (lexter/atlas::atlas-position-pixels atlas)))
    (is (eq (aref (lexter/pcf:bitmap-font-bitmaps font-a) 0)
            (gethash (glyph atlas #x41) pixels)))))

(def-test pack-atlas-keeps-wide-glyph-on-one-row ()
  "A double-width glyph takes two adjacent columns of one atlas row, moving to
the next row rather than straddling the edge."
  (let* ((cols 3)
         (atlas (lexter/atlas:pack-atlas
                 (list (make-test-font :narrow '(#x41 #x42) :wide '(#x4E00)))
                 :cols cols))
         (position (glyph atlas #x4E00)))
    (is-true (lexter/atlas:atlas-glyph-wide-p atlas position))
    (is (<= (mod position cols) (- cols 2)))))

(def-test pack-atlas-rejects-mixed-cell-sizes ()
  "A font chain whose fonts differ in cell size cannot be packed."
  (signals error
    (lexter/atlas:pack-atlas (list (make-test-font)
                                   (make-test-font :cell-width 5))
                             :cols 16)))

(def-test add-cursor-glyphs-to-packed-atlas-needs-no-gl ()
  "Cursor glyphs are added to an atlas that has only been packed without
uploading a texture."
  (let ((atlas (lexter/atlas:pack-atlas (list (make-test-font)) :cols 16)))
    (finishes (lexter/atlas:add-cursor-glyphs atlas))
    (is (= 0 (lexter/atlas:atlas-texture-id atlas)))))

(def-test atlas-columns-fit-the-texture-limit ()
  "The column count chosen for a font chain keeps the atlas no wider than the
GPU's maximum texture size allows."
  (let* ((fonts (list (make-test-font)))
         (cols (lexter/atlas:atlas-columns-for fonts 64)))
    (is (<= 2 cols (floor 64 *test-cell-width*)))))

;;; ------------------------------------------------------------
;;; Reserved positions  (LEXTER-O28, LEXTER-D89)
;;; ------------------------------------------------------------

(def-test font-glyphs-begin-at-position-64 ()
  "LEXTER-O28: atlas positions 0-63 are reserved for the empty glyph and the
generated glyphs, so every glyph of a font is packed at position 64 or above."
  (let* ((font (make-test-font))
         (atlas (make-test-atlas :fonts (list font))))
    (dolist (cp (font-codepoints font))
      (is (<= 64 (glyph atlas cp))
          "U+~4,'0X is packed at position ~d" cp (glyph atlas cp)))))

(def-test generated-glyphs-are-named-beyond-unicode ()
  "LEXTER-O28: the cursor glyphs take positions 1-4 and are named
0x110001-0x110004, beyond Unicode, so that no host can print one and no font
can displace one; nothing is keyed by the private-use codepoints."
  (let ((atlas (make-test-atlas)))
    (loop :for k :from 1 :to 4
          :do (is (eql k (lexter/atlas:atlas-glyph-index atlas (+ #x110000 k)))
                  "generated glyph ~d" k))
    (dolist (cp '(#xE000 #xE001 #xE002))
      (is (null (lexter/atlas:atlas-glyph-index atlas cp))
          "U+~4,'0X is keyed in the atlas" cp))))

;;; ------------------------------------------------------------
;;; Generated glyphs  (LEXTER-D89, LEXTER-DRAFT-cell-model-revision-D23)
;;; ------------------------------------------------------------

(def-test generated-glyphs-take-their-reserved-positions ()
  "The empty glyph, the four cursor glyphs, the replacement glyph, and the
\"no glyph\" glyph take positions 0 to 6; the empty glyph has no ink, and the
replacement glyph and the \"no glyph\" glyph differ from each other."
  (let* ((atlas (make-test-atlas))
         (pixels (lexter/atlas::atlas-position-pixels atlas)))
    (loop :for name :in (list lexter/atlas:+empty-glyph+ lexter/atlas:+cursor-block-glyph+
                              lexter/atlas:+cursor-underline-glyph+ lexter/atlas:+cursor-bar-glyph+
                              lexter/atlas:+cursor-outline-glyph+ lexter/atlas:+replacement-glyph+
                              lexter/atlas:+no-glyph-glyph+)
          :for position :from 0
          :do (is (eql position (lexter/atlas:atlas-glyph-index atlas name))))
    (is-true (every #'zerop (gethash 0 pixels)))
    (is-false (equalp (gethash 5 pixels) (gethash 6 pixels)))
    (is-true (some #'plusp (gethash 6 pixels)))))

(def-test the-single-underline-is-line-glyph-9 ()
  "The single underline is generated at atlas position 9, line style 0 with
the underline flag, named 0x110009 beyond Unicode: rows of ink just below the
baseline, across the whole cell, and nothing above it (LEXTER-D89)."
  (let* ((atlas (make-test-atlas))
         (pixels (atlas-pixels atlas 9))
         (width *test-cell-width*)
         (ascent (1- *test-cell-height*)))
    (is (= 9 (lexter/atlas:line-glyph-position 0 1)))
    (is (eql 9 (lexter/atlas:atlas-glyph-index atlas lexter/atlas:+underline-glyph+)))
    (is-true (every #'plusp (subseq pixels (* ascent width) (* (1+ ascent) width))))
    (is-true (every #'zerop (subseq pixels 0 (* ascent width))))))

;;; ------------------------------------------------------------
;;; Fitting glyphs to widths  (LEXTER-D117)
;;; ------------------------------------------------------------

(defun inked-pixels (width height inked)
  "A WIDTH-by-HEIGHT bitmap with ink at each (column . row) of INKED."
  (let ((pixels (make-array (* width height) :element-type '(unsigned-byte 8)
                                             :initial-element 0)))
    (loop :for (col . row) :in inked
          :do (setf (aref pixels (+ (* row width) col)) 255))
    pixels))

(defun make-font-of (glyphs &key (cell-width *test-cell-width*) (cell-height *test-cell-height*))
  "A font in memory of GLYPHS, each (codepoint pixels wide-p)."
  (let ((bitmaps (make-array (length glyphs)))
        (encoding (make-hash-table))
        (wide-glyphs (make-hash-table)))
    (loop :for (cp pixels wide-p) :in glyphs
          :for index :from 0
          :do (setf (aref bitmaps index) pixels
                    (gethash cp encoding) index)
              (when wide-p (setf (gethash index wide-glyphs) t)))
    (lexter/pcf::make-bitmap-font :cell-width cell-width :cell-height cell-height
                                  :ascent (1- cell-height) :glyph-count (length glyphs)
                                  :bitmaps bitmaps :encoding encoding
                                  :wide-glyphs wide-glyphs)))

(defun atlas-pixels (atlas position)
  "The pixels the atlas keeps at POSITION."
  (gethash position (lexter/atlas::atlas-position-pixels atlas)))

(def-test narrow-glyph-is-centred-in-a-wide-entry ()
  "A character of width 2 whose only glyph is narrow is drawn from a wide entry
holding the glyph centred, from column cell-width / 2."
  (let* ((w *test-cell-width*) (h *test-cell-height*)
         (atlas (lexter/atlas:pack-atlas
                 (list (make-font-of (list (list #x4E00 (inked-pixels w h '((0 . 0))) nil))))
                 :cols 16))
         (position (lexter/atlas:atlas-glyph-index atlas #x4E00 2)))
    (is-true (lexter/atlas:atlas-glyph-wide-p atlas position))
    (is (= 255 (aref (atlas-pixels atlas position) (floor w 2))))
    (is (= 1 (count 255 (atlas-pixels atlas position))))))

(def-test wide-glyph-with-narrow-ink-is-cropped-to-its-ink ()
  "A character of width 1 whose only glyph is wide, with ink that fits one
cell, is drawn from a narrow entry: the window of one cell centred on the ink."
  (let* ((w *test-cell-width*) (h *test-cell-height*)
         (glyph (inked-pixels (* 2 w) h '((3 . 1) (4 . 1))))
         (atlas (lexter/atlas:pack-atlas (list (make-font-of (list (list #x03B1 glyph t))))
                                         :cols 16))
         (position (lexter/atlas:atlas-glyph-index atlas #x03B1 1)))
    (is-false (lexter/atlas:atlas-glyph-wide-p atlas position))
    (is (equalp (inked-pixels w h '((1 . 1) (2 . 1))) (atlas-pixels atlas position)))))

(def-test wide-glyph-with-wide-ink-draws-the-replacement-glyph ()
  "A character of width 1 whose only glyph is wide, with ink wider than one
cell, is drawn as the replacement glyph, not as a fragment."
  (let* ((w *test-cell-width*) (h *test-cell-height*)
         (glyph (inked-pixels (* 2 w) h '((0 . 0) (7 . 0))))
         (atlas (lexter/atlas:pack-atlas (list (make-font-of (list (list #x03B1 glyph t))))
                                         :cols 16)))
    (is (= lexter/atlas:+replacement-glyph-position+
           (lexter/atlas:atlas-glyph-index atlas #x03B1 1)))))

(def-test chain-supplies-a-glyph-of-the-right-width ()
  "When the first font's glyph has the wrong width, the first font in the chain
whose glyph has the right width supplies it, unchanged."
  (let* ((w *test-cell-width*) (h *test-cell-height*)
         (narrow (inked-pixels w h '((0 . 0))))
         (atlas (lexter/atlas:pack-atlas
                 (list (make-font-of (list (list #x03B1 (inked-pixels (* 2 w) h '((0 . 0) (7 . 0))) t)))
                       (make-font-of (list (list #x03B1 narrow nil))))
                 :cols 16)))
    (is (eq narrow (atlas-pixels atlas (lexter/atlas:atlas-glyph-index atlas #x03B1 1))))))

(def-test natural-glyph-is-kept-for-writers-that-ask-no-width ()
  "Asked for no width, the atlas gives the glyph of the first font that covers
the character, at its natural width, as Lexter's own writers draw it."
  (let* ((w *test-cell-width*) (h *test-cell-height*)
         (atlas (lexter/atlas:pack-atlas
                 (list (make-font-of (list (list #x03B1 (inked-pixels (* 2 w) h '((3 . 1))) t))))
                 :cols 16)))
    (is-true (lexter/atlas:atlas-glyph-wide-p atlas (lexter/atlas:atlas-glyph-index atlas #x03B1)))
    (is-false (lexter/atlas:atlas-glyph-wide-p atlas (lexter/atlas:atlas-glyph-index atlas #x03B1 1)))))

(def-test fitting-follows-the-width-policy ()
  "An atlas packed for a policy that makes ambiguous characters wide fits a
narrow glyph of an ambiguous character to two columns."
  (let* ((w *test-cell-width*) (h *test-cell-height*)
         (atlas (lexter/atlas:pack-atlas
                 (list (make-font-of (list (list #x03B1 (inked-pixels w h '((0 . 0))) nil))))
                 :cols 16
                 :width-policy (lexter/width:make-width-policy :ambiguous-width 2))))
    (is-true (lexter/atlas:atlas-glyph-wide-p atlas (lexter/atlas:atlas-glyph-index atlas #x03B1 2)))))
