(in-package #:lexter/demo)

;;;; Demo entry point.
;;;;
;;;; Renders two scenes in a single GLFW window:
;;;;
;;;; Row 0  — simple path: "Hello from lexter!"  white-on-black
;;;; Row 1  — simple path: a sampling of glyph indices, coloured
;;;; Row 3  — layered path demonstration (3-layer model: base + 2 overlays):
;;;;            layer 0: '#' in colour slot 1 (dark-green) on slot 0 (black)
;;;;            layer 1: 'X' in colour slot 2 (red) with :bg transparent
;;;;                     → red X pixels overlay the green #

;;; --------------------------------------------------------------------------
;;; Standard xterm 256-colour palette
;;; --------------------------------------------------------------------------

;; The renderer gives palette slot 0 the default palette
;; (lexter/swatches:make-default-palette), in which the demo draws.

;;; --------------------------------------------------------------------------
;;; Grid population helpers
;;; --------------------------------------------------------------------------
;;;
;;; The demo writes the composed grid through the API (lexter/surface), by
;;; character, each at its glyph's natural width, so that wide glyphs are
;;; written as their two halves (LEXTER-D117, LEXTER-D126).

(defun demo-swatch (store s0 s1 s2 s3)
  "The global index of the swatch S0-S3 in the display table of STORE, into
   which the demo interns everything it draws, as chrome does
   (LEXTER-DRAFT-cell-model-revision-D24)."
  (intern-swatch (swatch-store-display-table store) s0 s1 s2 s3))

(defun setup-demo-grid (grid atlas store)
  "Populate GRID, whose glyphs come from ATLAS, with the demo scene, its
   swatches interned in STORE."
  (let ((cols (display-grid-cols grid))
        ;; White on black, and grey label text
        (white (demo-swatch store 0 15 0 0))
        (grey (demo-swatch store 0 7 0 0)))
    (fill-cells grid 0 0 cols (display-grid-rows grid))
    ;; Row 0: simple white-on-black text
    (put-string grid 1 0 "Hello from lexter!" :swatch white)
    ;; Row 1: colour sampler, each letter A-Z on black in palette colour i+1
    (loop :for i :from 0 :below (min 32 (- cols 1))
          :do (put-char grid (1+ i) 1 (code-char (+ 65 (mod i 26)))
                        :swatch (demo-swatch store 0 (1+ i) 0 0)))
    ;; Row 3: '#' in dark green over black, and 'X' in bright red over it
    ;; (slots: 0 black, 1 dark green, 2 bright red)
    (put-cell grid 1 3 '((:layer :char #\# :ink-slot 1)
                         (:layer :char #\X :ink-slot 2))
              :swatch (demo-swatch store 0 2 9 0))
    (put-string grid 2 3 "  <- layered: # + X overlay" :swatch grey)
    ;; Row 5: '@' in cyan, and 'A' in dark blue off its glyph's pixels, so that
    ;; the letter shows through it (slots: 0 black, 1 cyan, 2 dark blue)
    (put-cell grid 1 5 '((:layer :char #\@ :ink-slot 1)
                         (:layer :char #\A :selector 1 :ink-slot 2))
              :swatch (demo-swatch store 0 14 4 0))
    (put-string grid 2 5 "  <- layered: @ with A cut-out (:fg)" :swatch grey)
    ;; Row 7: the cursor glyphs
    (let ((green (demo-swatch store 0 10 0 0)))
      (put-glyph grid 1 7 (atlas-glyph-index atlas +cursor-block-glyph+) :swatch green)
      (put-glyph grid 2 7 (atlas-glyph-index atlas +cursor-underline-glyph+) :swatch green)
      (put-glyph grid 3 7 (atlas-glyph-index atlas +cursor-bar-glyph+) :swatch green)
      (put-string grid 4 7 "  <- cursor glyphs: block, underline, bar" :swatch grey))
    ;; Rows 9 and 10: text over a ruled line, as on notebook paper
    (loop :for text :in '("This is a notebook paper string display test."
                          "Another line of notebook paper.")
          :for row :from 9
          :do (loop :for char :across text
                    :for col :from 1
                    :do (put-cell grid col row `((:layer :char #\▂ :ink-slot 1)
                                                 (:layer :char ,char :ink-slot 2))
                                  :swatch (demo-swatch store 0 12 6 0))))
    ;; Row 12: text cut out of a row of bars of varying height
    (let ((text "Foreground transparency text demo.")
          (heights #(1 1 2 5 7 8 7 5 2 1))
          (bars "▁▂▃▄▅▆▇█"))
      (loop :for char :across text
            :for i :from 0
            :do (put-cell grid (+ 1 i) 12
                          `((:layer :char ,(char bars (1- (aref heights (mod i 10)))) :ink-slot 3)
                            (:layer :char ,char :selector 1 :ink-slot 2))
                          :swatch (demo-swatch store 1 12 0 24))))))

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

(defun run-demo (&key (font-path "../terminus-18n.pcf") (pixel-scale nil)
                      (stop-flag nil))
  "Open a GLFW window and render the demo. Press Escape or close to quit.
   PIXEL-SCALE: integer multiplier for nearest-neighbor scaling (1-16).
                If NIL, auto-detects based on monitor DPI.
   STOP-FLAG: a list whose CAR is checked each tick; NIL CAR terminates the loop."
  ;; Load font and determine window size
  (format t "~&Loading font ~a ...~%" font-path)
  (let* ((font     (load-pcf font-path))
         (cell-w   (bitmap-font-cell-width  font))
         (cell-h   (bitmap-font-cell-height font))
         (cols     50)
         (rows     20))
    (format t "~&Cell ~dx~d (native)~%" cell-w cell-h)
    ;; Initialize GLFW to detect HiDPI before creating window
    (glfw:initialize)
    (let* ((scale   (or pixel-scale (detect-hidpi-scale) 1))
           (win-w   (* cols cell-w scale))
           (win-h   (* rows cell-h scale)))
      (format t "~&Pixel scale: ~dx, window ~dx~d (~dx~d cells)~%"
              scale win-w win-h cols rows)
      (glfw:with-init-window
          (:title (format nil "lexter demo (~dx scale)" scale)
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
               (grid     (make-display-grid :cols cols :rows rows :atlas atlas))
               (store    (make-swatch-store))
               ;; Draws in palette slot 0, the default palette
               (renderer (make-renderer atlas win-w win-h :pixel-scale scale)))
          (declare (ignore _))
          (setup-demo-grid grid atlas store)
          ;; Register key callback for Escape
          (glfw:def-key-callback quit-on-escape (window key scancode action mods)
            (declare (ignore scancode mods))
            (when (and (eq key :escape) (eq action :press))
              (glfw:set-window-should-close window t)))
          (glfw:set-key-callback 'quit-on-escape)
          ;; Main loop
          (loop :until (or (glfw:window-should-close-p)
                           (and stop-flag (not (car stop-flag))))
                :do (render-frame renderer grid store)
                    (glfw:swap-buffers)
                    (glfw:poll-events)
                    (sleep 0.1))
          (destroy-renderer renderer))))))

;;; --------------------------------------------------------------------------
;;; CJK demo: double-wide character rendering with zpix.bdf
;;; --------------------------------------------------------------------------

(defun run-cjk-demo (&key (font-path "../zpix.bdf") (pixel-scale nil)
                          (stop-flag nil))
  "Demo for double-wide CJK character rendering using zpix.bdf.
   Press Escape or close window to quit.
   STOP-FLAG: a list whose CAR is checked each tick; NIL CAR terminates the loop."
  (format t "~&Loading BDF font ~a ...~%" font-path)
  (let* ((font     (lexter/pcf:load-bdf font-path :cell-width 7 :cell-height 12))
         (cell-w   (bitmap-font-cell-width  font))
         (cell-h   (bitmap-font-cell-height font))
         (cols     60)
         (rows     12))
    (format t "~&Cell ~dx~d, ~d glyphs (~d wide)~%" cell-w cell-h
            (bitmap-font-glyph-count font)
            (if (bitmap-font-wide-glyphs font)
                (hash-table-count (bitmap-font-wide-glyphs font))
                0))
    (glfw:initialize)
    (let* ((scale   (or pixel-scale 2))
           (win-w   (* cols cell-w scale))
           (win-h   (* rows cell-h scale)))
      (format t "~&Pixel scale: ~dx, window ~dx~d (~dx~d cells)~%"
              scale win-w win-h cols rows)
      (glfw:with-init-window
          (:title "lexter CJK demo"
           :width win-w :height win-h
           :resizable nil
           :context-version-major 3
           :context-version-minor 3
           :opengl-profile :opengl-core-profile
           :opengl-forward-compat t)
        (gl:viewport 0 0 win-w win-h)
        (let* ((atlas    (build-atlas (list font)))
               (_        (add-cursor-glyphs atlas))
               (grid     (make-display-grid :cols cols :rows rows :atlas atlas))
               (store    (make-swatch-store))
               ;; Draws in palette slot 0, the default palette
               (renderer (make-renderer atlas win-w win-h :pixel-scale scale))
               (white    (demo-swatch store 0 15 0 0))
               (yellow   (demo-swatch store 0 11 0 0))
               (cyan     (demo-swatch store 0 14 0 0))
               (green    (demo-swatch store 0 10 0 0)))
          (declare (ignore _))
          ;; Row 0: ASCII text (narrow)
          (put-string grid 1 0 "Hello from lexter!" :swatch white)
          ;; Row 2: CJK text (wide characters)
          (put-string grid 1 2 "新たなる世界" :swatch yellow)
          ;; Row 4: mixed narrow + wide
          (put-string grid 1 4 "CJK: 新たなる世界 (new world)" :swatch cyan)
          ;; Row 6: more CJK
          (put-string grid 1 6 "漢字テスト" :swatch green)
          ;; Row 8: ASCII for comparison
          (put-string grid 1 8 "ABCDEFGHIJKLMNOPQRSTUVWXYZ" :swatch white)
          ;; Key callback
          (glfw:def-key-callback quit-on-escape (window key scancode action mods)
            (declare (ignore scancode mods))
            (when (and (eq key :escape) (eq action :press))
              (glfw:set-window-should-close window t)))
          (glfw:set-key-callback 'quit-on-escape)
          ;; Main loop
          (loop :until (or (glfw:window-should-close-p)
                           (and stop-flag (not (car stop-flag))))
                :do (render-frame renderer grid store)
                    (glfw:swap-buffers)
                    (glfw:poll-events)
                    (sleep 0.1))
          (destroy-renderer renderer))))))
