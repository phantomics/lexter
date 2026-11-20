;;;; tools/check-fixtures.lisp — Replay the fixtures in tests/fixtures/ and
;;;; check their cell checksums, on any machine, and their pixel checksums and
;;;; the GPU's swatch and palette stores, where there is a display.
;;;;
;;;; Run from the repository's root. On the pinned driver, Mesa's llvmpipe
;;;; under a virtual X server:
;;;;
;;;;   xvfb-run -a -s "-screen 0 1024x768x24" \
;;;;     sbcl --non-interactive --load tools/check-fixtures.lisp
;;;;
;;;; With no display, only the cell checksums are checked; on another driver,
;;;; the pixel checksums are compared as a check of that driver (LEXTER-D112).
;;;;
;;;; The fixtures are .ptyb blobs (LEXTER-0010); the checksums are literals
;;;; here, kept apart from the blobs, two for each fixture in each font:
;;;;
;;;;   The cell checksum (LEXTER-D108), of the composed grid's records,
;;;;   normalised, and the palettes they draw in, computed in a terminal with
;;;;   no window. A change in it points to the parser, the handler, the model,
;;;;   the palettes, or composition.
;;;;
;;;;   The pixel checksum, of the frame the renderer draws in a hidden window,
;;;;   taken on the pinned llvmpipe. A change in it alone points to the atlas's
;;;;   texture, the renderer, the shaders, or the uploads. The windowed replay
;;;;   also checks that the grid it drew has the fixture's cell checksum.
;;;;
;;;; Step 7 of Phase 3 of the cell-model revision authored both on llvmpipe,
;;;; Mesa 20.3.5 with LLVM 11.0.1, under Xvfb (LEXTER-DRAFT-dense-cell-model).
;;;; The pixel checksums are those taken on an NVIDIA GL 4.6 driver through
;;;; Phase 2 and steps 1 to 6 of Phase 3, which llvmpipe reproduces, as its
;;;; shader is exact (LEXTER-D110). Each font replays the fixtures in order and
;;;; then in reverse, so that a checksum that depends on the fixture before it
;;;; is found, and after each windowed replay compares the GPU's stores with
;;;; their sources (LEXTER/TEST:CHECK-GPU-STORES).
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

(defpackage #:lexter/fixtures
  (:use #:cl #:lexter/test))

(in-package #:lexter/fixtures)

(defparameter *pinned-renderer* "llvmpipe (LLVM 11.0.1, 256 bits)"
  "The GL renderer string of the driver the pixel checksums are authored on.")

(defparameter *pinned-version* "Mesa 20.3.5"
  "What the GL version string of the pinned driver contains.")

(defparameter *config* '(:cols 40 :rows 8 :pixel-scale 1 :atlas-cols 256)
  "The configuration every fixture is replayed in: a terminal of 40 columns by
8 rows at pixel scale 1, with an atlas of 256 columns, fixed so that glyph
positions do not depend on the GPU (LEXTER-D108).")

(defparameter *fonts*
  '(("../terminus-18n.pcf"
     ("colours" #x8497F5008470B51D #xF6B81E21B5962094)
     ("palette" #x88417D4310714F51 #x59BB514478D43E6C)
     ("cjk"     #x1BBE57F6881CEEDE #x26A2D3A202F76D9D)
     ("alt"     #xA25B4DAC47984CFE #x1E7393F293E8303D)
     ("many"    #x5F222C193809179A #xFF822E35378CA846))
    ("../unifont-17.0.04.pcf.gz"
     ("colours" #x3CF09ED2DD00C215 #x1606A08F3D7D35BA)
     ("palette" #x7F2D385F2BA2986F #x406471A041046D3D)
     ("cjk"     #x1ED0161EFAC4BD17 #xE04CD998C68F6774)
     ("alt"     #xA73AA49ADA56819C #xF4D9A7010B64A71F)
     ("many"    #x9775C34BCCF4D3DA #xD790B48E4BBF36CD)))
  "For each font, the path of its file and, for each fixture, its name, its
cell checksum, and its pixel checksum, in the configuration *CONFIG*.")

(defun fixture-path (name)
  (format nil "tests/fixtures/~a.ptyb" name))

(defun orders (fixtures)
  (list fixtures (reverse fixtures)))

(defun check-cells (font fixtures)
  "Replay FIXTURES with FONT in a terminal with no window, in order and then in
reverse, checking each cell checksum."
  (with-terminal-test-config (:font-path font :window nil
                              :cols (getf *config* :cols) :rows (getf *config* :rows)
                              :pixel-scale (getf *config* :pixel-scale)
                              :atlas-cols (getf *config* :atlas-cols))
    (dolist (order (orders fixtures))
      (loop :for (name cells) :in order
            :do (test-cells (fixture-path name) cells)
                (format t "~&~a ~8a cells  #x~16,'0X~%" (pathname-name font) name cells)))))

(defun pinned-p (renderer version)
  (and (string= renderer *pinned-renderer*) (search *pinned-version* version)))

(defun check-pixels (font fixtures)
  "Replay FIXTURES with FONT in a hidden window, in order and then in reverse,
checking each pixel checksum, the cell checksum of the grid drawn, and the
GPU's stores. On a driver other than the pinned one, a pixel checksum that
differs is reported as that driver's disagreement."
  (with-terminal-test-config (:font-path font
                              :cols (getf *config* :cols) :rows (getf *config* :rows)
                              :pixel-scale (getf *config* :pixel-scale)
                              :atlas-cols (getf *config* :atlas-cols))
    (multiple-value-bind (renderer version) (renderer-description)
      (let ((pinned (pinned-p renderer version)))
        (format t "~&Renderer: ~a, ~a~:[ (not the pinned driver)~;~]~%"
                renderer version pinned)
        (dolist (order (orders fixtures))
          (loop :for (name cells pixels) :in order
                :do (handler-bind ((error (lambda (e)
                                            (unless pinned
                                              (error "~a disagrees with the pinned ~a, ~a:~%~a"
                                                     renderer *pinned-renderer*
                                                     *pinned-version* e)))))
                      (test-pixels (fixture-path name) pixels :cells cells))
                    (format t "~&~a ~8a pixels #x~16,'0X  ~d swatches match the GPU~%"
                            (pathname-name font) name pixels (check-gpu-stores))))))))

(dolist (entry *fonts*)
  (check-cells (first entry) (rest entry)))
(format t "~&All cell checksums match.~%")

(let ((display (uiop:getenv "DISPLAY")))
  (if (and display (plusp (length display)))
      (progn
        (dolist (entry *fonts*)
          (check-pixels (first entry) (rest entry)))
        (format t "~&All pixel fixtures match.~%"))
      (format t "~&No display: pixel checksums not checked. Run under ~
                 xvfb-run for the pinned llvmpipe.~%")))
