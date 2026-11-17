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
