(in-package #:pcf-gl/demo)

;;;; Demo entry point.
;;;;
;;;; Renders two scenes in a single GLFW window:
;;;;
;;;; Row 0  — simple path: "Hello from pcf-gl!"  white-on-black
;;;; Row 1  — simple path: a sampling of glyph indices, coloured
;;;; Row 3  — layered path demonstration (3-layer model: base + 2 overlays):
;;;;            layer 0: '#' in colour slot 1 (dark-green) on slot 0 (black)
;;;;            layer 1: 'X' in colour slot 2 (red) with :bg transparent
;;;;                     → red X pixels overlay the green #

;;; --------------------------------------------------------------------------
;;; Standard xterm 256-colour palette
;;; --------------------------------------------------------------------------

(defun make-xterm-palette ()
  "Return a (simple-array single-float (1024)) with the standard xterm colours."
  (let ((p (make-array 1024 :element-type 'single-float :initial-element 0.0)))
    (flet ((set-rgb (i r g b)
             (setf (aref p (+ (* i 4) 0)) (/ r 255.0)
                   (aref p (+ (* i 4) 1)) (/ g 255.0)
                   (aref p (+ (* i 4) 2)) (/ b 255.0)
                   (aref p (+ (* i 4) 3)) 1.0))
           (comp6 (v) (if (zerop v) 0 (+ 55 (* 40 v)))))
      ;; Colours 0-15: standard ANSI
      (loop :for (r g b) :in '((0   0   0)    ; 0  black
                               (170 0   0)    ; 1  dark red
                               (0   170 0)    ; 2  dark green
                               (170 85  0)    ; 3  dark yellow
                               (0   0   170)  ; 4  dark blue
                               (170 0   170)  ; 5  dark magenta
                               (0   170 170)  ; 6  dark cyan
                               (170 170 170)  ; 7  light grey
                               (85  85  85)   ; 8  dark grey
                               (255 85  85)   ; 9  bright red
                               (85  255 85)   ; 10 bright green
                               (255 255 85)   ; 11 bright yellow
                               (85  85  255)  ; 12 bright blue
                               (255 85  255)  ; 13 bright magenta
                               (85  255 255)  ; 14 bright cyan
                               (255 255 255)) ; 15 white
            :for i :from 0
            :do (set-rgb i r g b))
      ;; Colours 16-231: 6x6x6 cube
      (loop :for i :from 16 :to 231
            :for n = (- i 16)
            :do (set-rgb i
                         (comp6 (floor n 36))
                         (comp6 (mod (floor n 6) 6))
                         (comp6 (mod n 6))))
      ;; Colours 232-255: greyscale ramp
      (loop :for i :from 232 :to 255
            :for v = (+ 8 (* 10 (- i 232)))
            :do (set-rgb i v v v)))
    p))

;;; --------------------------------------------------------------------------
;;; Grid population helpers
;;; --------------------------------------------------------------------------

(defun write-string-simple (grid atlas str col row swatch-idx)
  "Write STR into GRID starting at (COL, ROW) using the simple path.
   SWATCH-IDX is the swatch table index (fg/bg are defined in the swatch)."
  (loop :for ch :across str
        :for c :from col
        :for glyph-idx = (atlas-glyph-index atlas (char-code ch))
        :when glyph-idx
        :do (set-simple-cell grid c row glyph-idx swatch-idx)))

(defun setup-demo-swatches (grid)
  "Set up swatch table for the demo.
   Swatch 0: black bg, white fg (default)
   Swatches 1-32: black bg, palette colours 1-32 as fg (for colour sampler)
   Swatch 100: black bg, grey fg (for labels)"
  ;; Default swatch 0: black bg (palette 0), white fg (palette 15)
  (set-swatch grid 0  0 15 0 0)
  ;; Colour sampler swatches 1-32
  (loop :for i :from 1 :to 32
        :do (set-swatch grid i  0 i 0 0))
  ;; Grey label text
  (set-swatch grid 100  0 7 0 0))

(defun setup-demo-grid (grid atlas)
  "Populate GRID with the demo scene."
  (let ((cols (display-grid-cols grid)))
    ;; Initialize swatches
    (setup-demo-swatches grid)
    ;; Row 0: simple white-on-black text (swatch 0)
    (write-string-simple grid atlas "Hello from pcf-gl!" 1 0 0)
    ;; Row 1: colour sampler — each character in a different swatch
    (loop :for i :from 0 :below (min 32 (- cols 1))
          :for ch-code = (+ 65 (mod i 26))       ; A-Z cycling
          :for glyph-idx = (atlas-glyph-index atlas ch-code)
          :when glyph-idx
          :do (set-simple-cell grid (1+ i) 1 glyph-idx (1+ i)))
    ;; Row 3: layered demonstration
    ;; Cell (1,3): '#' on layer 0 in dark-green/black,
    ;;             'X' on layer 1 in bright-red with transparent background
    (let ((hash-glyph (atlas-glyph-index atlas (char-code #\#)))
          (x-glyph    (atlas-glyph-index atlas (char-code #\X))))
      (when (and hash-glyph x-glyph)
        ;; Per-cell swatch: slot 0=black(0) slot 1=dark-green(2)
        ;;                  slot 2=bright-red(9) slot 3=unused
        (set-cell-swatch grid 1 3 #(0 2 9 0))
        ;; Layer 0: '#' — ink=slot1(dark-green), bg=slot0(black)
        (set-cell-layer grid 1 3 0 hash-glyph 1 :bg-idx 0 :transparent-side :none)
        ;; Layer 1: 'X' — ink=slot2(bright-red), bg transparent
        (set-cell-layer grid 1 3 1 x-glyph    2 :transparent-side :bg)))
    ;; Row 3 label (swatch 100 = grey text)
    (write-string-simple grid atlas "  <- layered: # + X overlay" 2 3 100)
    ;; Row 5: a second layered example — block on layer 0, letter cut-out on layer 1 (:fg)
    (let ((block-glyph  (atlas-glyph-index atlas (char-code #\@)))
          (letter-glyph (atlas-glyph-index atlas (char-code #\A))))
      (when (and block-glyph letter-glyph)
        ;; Per-cell swatch: slot 0=black slot 1=bright-cyan(14) slot 2=dark-blue(4) slot 3=unused
        (set-cell-swatch grid 1 5 #(0 14 4 0))
        ;; Layer 0: '@' solid, cyan-on-black
        (set-cell-layer grid 1 5 0 block-glyph 1 :bg-idx 0 :transparent-side :none)
        ;; Layer 1: 'A' with :fg transparent — the letter pixels are cut out,
        ;;          revealing black from layer 0 through the letter shape
        (set-cell-layer grid 1 5 1 letter-glyph 2 :transparent-side :fg)))
    (write-string-simple grid atlas "  <- layered: @ with A cut-out (:fg)" 2 5 100)
    ;; Row 7: cursor glyph demo (if cursor glyphs were added)
    (let ((block-cursor (atlas-glyph-index atlas +cursor-block-glyph+))
          (underline-cursor (atlas-glyph-index atlas +cursor-underline-glyph+))
          (bar-cursor (atlas-glyph-index atlas +cursor-bar-glyph+)))
      (when block-cursor
        ;; Swatch 101: black bg, bright green fg (for cursor display)
        (set-swatch grid 101  0 10 0 0)
        (set-simple-cell grid 1 7 block-cursor 101)
        (set-simple-cell grid 2 7 underline-cursor 101)
        (set-simple-cell grid 3 7 bar-cursor 101)
        (write-string-simple grid atlas "  <- cursor glyphs: block, underline, bar" 4 7 100)))))

;;; --------------------------------------------------------------------------
;;; HiDPI / scaling helpers
;;; --------------------------------------------------------------------------

(defun detect-hidpi-scale ()
  "Detect a reasonable pixel scale based on primary monitor DPI.
   Returns 1 for standard displays, 2+ for HiDPI.
   Falls back to 1 if detection fails."
  ;; Try to use GLFW's content scale API (GLFW 3.3+)
  ;; Different cl-glfw3 versions may have different bindings
  (handler-case
      (let ((monitor (glfw:get-primary-monitor)))
        (when monitor
          ;; cl-glfw3's binding returns multiple values or a list
          ;; Try the multiple-value approach first
          (multiple-value-bind (xscale yscale)
              (glfw:get-monitor-content-scale monitor)
            (when (and xscale yscale)
              (return-from detect-hidpi-scale
                (max 1 (round (max xscale yscale))))))))
    (error () nil))
  ;; Fallback: return 1 (no scaling)
  1)

;;; --------------------------------------------------------------------------
;;; Entry point
;;; --------------------------------------------------------------------------

(defun run-demo (&key (font-path "../terminus-18n.pcf") (pixel-scale nil))
  "Open a GLFW window and render the demo. Press Escape or close to quit.
   PIXEL-SCALE: integer multiplier for nearest-neighbor scaling (1-16).
                If NIL, auto-detects based on monitor DPI."
  ;; Load font and determine window size
  (format t "~&Loading font ~a ...~%" font-path)
  (let* ((font     (load-pcf font-path))
         (cell-w   (pcf-font-cell-width  font))
         (cell-h   (pcf-font-cell-height font))
         (cols     50)
         (rows     10))
    (format t "~&Cell ~dx~d (native)~%" cell-w cell-h)
    ;; Initialize GLFW to detect HiDPI before creating window
    (glfw:initialize)
    (let* ((scale   (or pixel-scale (detect-hidpi-scale) 1))
           (win-w   (* cols cell-w scale))
           (win-h   (* rows cell-h scale)))
      (format t "~&Pixel scale: ~dx, window ~dx~d (~dx~d cells)~%"
              scale win-w win-h cols rows)
      (glfw:with-init-window
          (:title (format nil "pcf-gl demo (~dx scale)" scale)
           :width win-w :height win-h
           :resizable nil
           :context-version-major 3
           :context-version-minor 3
           :opengl-profile :opengl-core-profile
           :opengl-forward-compat t)
        (gl:viewport 0 0 win-w win-h)
        ;; Build atlas, add cursor glyphs, then grid & renderer
        (let* ((atlas    (build-atlas (list font)))
               (_        (add-cursor-glyphs atlas))
               (grid     (make-display-grid :cols cols :rows rows))
               (renderer (make-renderer atlas win-w win-h :pixel-scale scale))
               (palette  (make-xterm-palette)))
          (declare (ignore _))
          (set-palette renderer palette)
          (setup-demo-grid grid atlas)
          ;; Register key callback for Escape
          (glfw:def-key-callback quit-on-escape (window key scancode action mods)
            (declare (ignore scancode mods))
            (when (and (eq key :escape) (eq action :press))
              (glfw:set-window-should-close window t)))
          (glfw:set-key-callback 'quit-on-escape)
          ;; Main loop
          (loop :until (glfw:window-should-close-p)
                :do (render-frame renderer grid)
                    (glfw:swap-buffers)
                    (glfw:poll-events))
          (destroy-renderer renderer))))))
