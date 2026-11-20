;;;; tools/check-pixel-fixtures.lisp — Replay the pixel fixtures in
;;;; tests/fixtures/ through the test rig's hidden terminal, and check their
;;;; pixel checksums and the GPU's swatch and palette stores.
;;;;
;;;; Run from the repository's root, with a display:
;;;;
;;;;   sbcl --non-interactive --load tools/check-pixel-fixtures.lisp
;;;;
;;;; The fixtures are .ptyb blobs (LEXTER-0010); the checksums are literals
;;;; here, kept apart from the blobs. They were taken in Phase 2 of the
;;;; cell-model revision on an NVIDIA GL 4.6 driver (LEXTER-DRAFT-swatch-ranges),
;;;; and hold for that driver. Step 3 of Phase 3 changed those of "colours" and
;;;; "palette", whose reverse video the record draws through its background
;;;; slot (LEXTER-D86) where the first edition drew none. Step 7 re-authors
;;;; the fixtures on a pinned llvmpipe, with a cell checksum beside each
;;;; (LEXTER-D108, LEXTER-D112). Each font replays the fixtures in order and
;;;; then in reverse, so that a checksum that depends on the fixture before it
;;;; is found, and after each replay compares the GPU's stores with their
;;;; sources (LEXTER/TEST:CHECK-GPU-STORES).
;;;;
;;;; The fixtures:
;;;;
;;;;   colours  SGR 16-colour, bold, 256-colour and truecolour text, reverse
;;;;            video, cursor movement, and an erased line
;;;;   palette  OSC 4 palette changes, then text in the changed colours
;;;;   cjk      double-width ideographs among narrow text
;;;;   alt      the alternate screen entered and left
;;;;   many     2304 distinct swatches, more than one range holds

(ql:quickload :lexter/test :silent t)

(defpackage #:lexter/pixel-fixtures
  (:use #:cl #:lexter/test))

(in-package #:lexter/pixel-fixtures)

(defparameter *fonts*
  '(("../terminus-18n.pcf"
     ("colours" . #xF6B81E21B5962094) ("palette" . #x59BB514478D43E6C)
     ("cjk" . #xD3758C95BC11B3B5) ("alt" . #x1E7393F293E8303D)
     ("many" . #xFF822E35378CA846))
    ("../unifont-17.0.04.pcf.gz"
     ("colours" . #x1606A08F3D7D35BA) ("palette" . #x406471A041046D3D)
     ("cjk" . #xE04CD998C68F6774) ("alt" . #xF4D9A7010B64A71F)
     ("many" . #xD790B48E4BBF36CD)))
  "For each font, the path of its file and the checksum of each fixture in a
terminal of 40 columns by 8 rows at pixel scale 1.")

(defun fixture-path (name)
  (format nil "tests/fixtures/~a.ptyb" name))

(defun check-font (font fixtures)
  "Replay FIXTURES, an alist of names and checksums, with FONT, in order and
then in reverse, checking each checksum and the GPU's stores."
  (with-terminal-test-config (:font-path font :cols 40 :rows 8 :pixel-scale 1)
    (dolist (order (list fixtures (reverse fixtures)))
      (loop :for (name . checksum) :in order
            :do (test-pixels (fixture-path name) checksum)
                (format t "~&~a ~8a #x~16,'0X  ~d swatches match the GPU~%"
                        (pathname-name font) name checksum (check-gpu-stores))))))

(dolist (entry *fonts*)
  (check-font (first entry) (rest entry)))

(format t "~&All pixel fixtures match.~%")
