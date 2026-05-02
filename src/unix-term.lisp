(in-package #:pcf-gl/unix-term)

;;;; Unix Terminal: main loop tying together PTY, VT parser, model, and renderer.
;;;;
;;;; Single-threaded design using non-blocking I/O:
;;;; 1. Poll PTY for output (with short timeout)
;;;; 2. Parse any output through VT handler → update model
;;;; 3. Poll GLFW events (non-blocking)
;;;; 4. Handle keyboard input → write to PTY
;;;; 5. Flush model to display grid
;;;; 6. Render frame
;;;; 7. Swap buffers

;;; --------------------------------------------------------------------------
;;; Terminal structure
;;; --------------------------------------------------------------------------

(defstruct unix-terminal
  "Unix terminal emulator state."
  ;; Child process
  (pty        nil)
  ;; Terminal model
  (screen     nil)
  (display    nil)
  ;; VT parsing
  (vt-handler nil)
  ;; Rendering
  (atlas      nil)
  (renderer   nil)
  (palette    nil)
  ;; Dimensions
  (cols       80  :type fixnum)
  (rows       24  :type fixnum)
  (pixel-scale 1 :type fixnum)
  ;; I/O buffer
  (read-buffer (make-array 4096 :element-type '(unsigned-byte 8))
               :type (simple-array (unsigned-byte 8) (*)))
  ;; State
  (running    nil :type boolean)
  ;; Cursor blink state
  (cursor-blink-on t :type boolean)
  (cursor-blink-time 0.0 :type single-float)  ; time since last toggle
  (cursor-blink-interval 0.5 :type single-float)  ; seconds per blink phase
  ;; Pending resize
  (resize-pending nil :type boolean)
  (resize-cols    0   :type fixnum)
  (resize-rows    0   :type fixnum))

;;; --------------------------------------------------------------------------
;;; Keyboard input handling
;;; --------------------------------------------------------------------------

(defun bytes (&rest values)
  "Create a (simple-array (unsigned-byte 8) (*)) from VALUES."
  (make-array (length values)
              :element-type '(unsigned-byte 8)
              :initial-contents values))

(defparameter *key-sequences*
  (list
   ;; Arrow keys
   (cons :up        (bytes #x1B #x5B #x41))      ; ESC [ A
   (cons :down      (bytes #x1B #x5B #x42))      ; ESC [ B
   (cons :right     (bytes #x1B #x5B #x43))      ; ESC [ C
   (cons :left      (bytes #x1B #x5B #x44))      ; ESC [ D
   ;; Navigation
   (cons :home      (bytes #x1B #x5B #x48))      ; ESC [ H
   (cons :end       (bytes #x1B #x5B #x46))      ; ESC [ F
   (cons :page-up   (bytes #x1B #x5B #x35 #x7E)) ; ESC [ 5 ~
   (cons :page-down (bytes #x1B #x5B #x36 #x7E)) ; ESC [ 6 ~
   (cons :insert    (bytes #x1B #x5B #x32 #x7E)) ; ESC [ 2 ~
   (cons :delete    (bytes #x1B #x5B #x33 #x7E)) ; ESC [ 3 ~
   ;; Function keys
   (cons :f1        (bytes #x1B #x4F #x50))      ; ESC O P
   (cons :f2        (bytes #x1B #x4F #x51))      ; ESC O Q
   (cons :f3        (bytes #x1B #x4F #x52))      ; ESC O R
   (cons :f4        (bytes #x1B #x4F #x53))      ; ESC O S
   (cons :f5        (bytes #x1B #x5B #x31 #x35 #x7E)) ; ESC [ 1 5 ~
   (cons :f6        (bytes #x1B #x5B #x31 #x37 #x7E)) ; ESC [ 1 7 ~
   (cons :f7        (bytes #x1B #x5B #x31 #x38 #x7E)) ; ESC [ 1 8 ~
   (cons :f8        (bytes #x1B #x5B #x31 #x39 #x7E)) ; ESC [ 1 9 ~
   (cons :f9        (bytes #x1B #x5B #x32 #x30 #x7E)) ; ESC [ 2 0 ~
   (cons :f10       (bytes #x1B #x5B #x32 #x31 #x7E)) ; ESC [ 2 1 ~
   (cons :f11       (bytes #x1B #x5B #x32 #x33 #x7E)) ; ESC [ 2 3 ~
   (cons :f12       (bytes #x1B #x5B #x32 #x34 #x7E)) ; ESC [ 2 4 ~
   ;; Special
   (cons :backspace (bytes #x7F))
   (cons :tab       (bytes #x09))
   (cons :enter     (bytes #x0D))
   (cons :escape    (bytes #x1B)))
  "Mapping from GLFW key symbols to byte sequences.")

(defun key-to-bytes (key mods)
  "Convert a GLFW key press to bytes to send to PTY.
   Returns a byte vector or NIL if the key should be ignored."
  (let ((ctrl-p (member :control mods))
        (shift-p (member :shift mods))
        (alt-p (member :alt mods)))
    (cond
      ;; Control+key combinations
      ((and ctrl-p (symbolp key))
       (let ((name (symbol-name key)))
         (when (and (= (length name) 1)
                    (alpha-char-p (char name 0)))
           ;; Ctrl+A = 0x01, Ctrl+B = 0x02, etc.
           (let ((code (- (char-code (char-upcase (char name 0))) 64)))
             (when (<= 1 code 26)
               (bytes code))))))
      ;; Alt+key - send ESC prefix
      ((and alt-p (symbolp key))
       (let ((name (symbol-name key)))
         (when (and (= (length name) 1)
                    (alpha-char-p (char name 0)))
           (let ((ch (if shift-p
                         (char-upcase (char name 0))
                         (char-downcase (char name 0)))))
             (bytes #x1B (char-code ch))))))
      ;; Special keys
      ((assoc key *key-sequences*)
       (cdr (assoc key *key-sequences*)))
      ;; Regular character keys are handled via char callback
      (t nil))))

(defun handle-key-press (term key scancode action mods)
  "Handle a GLFW key callback."
  (declare (ignore scancode))
  (when (and (member action '(:press :repeat))
             (pty-alive-p (unix-terminal-pty term)))
    ;; Handle Escape specially - close terminal
    (when (and (eq key :escape) (eq action :press) (null mods))
      (setf (unix-terminal-running term) nil)
      (return-from handle-key-press))
    ;; Convert key to bytes
    (let ((bytes (key-to-bytes key mods)))
      (when bytes
        (pty-write (unix-terminal-pty term) bytes)))))

(defun handle-char-input (term codepoint)
  "Handle a GLFW character callback (for regular text input).
   CODEPOINT may be a character or an integer depending on cl-glfw3 version."
  (when (pty-alive-p (unix-terminal-pty term))
    (let* ((code (if (characterp codepoint)
                     (char-code codepoint)
                     codepoint))
           (bytes (babel:string-to-octets (string (code-char code))
                                          :encoding :utf-8)))
      (pty-write (unix-terminal-pty term) bytes))))

;;; --------------------------------------------------------------------------
;;; VT handler callbacks
;;; --------------------------------------------------------------------------

(defun make-vt-callback (term)
  "Create callback function for VT handler events."
  (lambda (type data)
    (case type
      (:bell
       ;; TODO: visual bell or system beep
       nil)
      (:set-title
       (glfw:set-window-title data))
      (:report-cursor
       ;; Send cursor position report back to PTY
       (when (pty-alive-p (unix-terminal-pty term))
         (pty-write-string (unix-terminal-pty term) data)))
      (otherwise
       ;; Log unknown sequences for debugging
       #+nil (format t "~&VT: ~s ~s~%" type data)))))

;;; --------------------------------------------------------------------------
;;; Main loop
;;; --------------------------------------------------------------------------

(defun process-pty-output (term)
  "Read and process any available PTY output."
  (let ((pty (unix-terminal-pty term))
        (buf (unix-terminal-read-buffer term))
        (handler (unix-terminal-vt-handler term)))
    (loop
      ;; Poll with 0 timeout (non-blocking check)
      (let ((status (pty-poll pty 0)))
        (case status
          (:readable
           (let ((n (pty-read pty buf)))
             (when (> n 0)
               (process-output handler buf :start 0 :end n))))
          (:closed
           (setf (unix-terminal-running term) nil)
           (return))
          (otherwise
           (return)))))))

(defun update-cursor-blink (term dt)
  "Update cursor blink state based on elapsed time DT (seconds)."
  (incf (unix-terminal-cursor-blink-time term) dt)
  (when (>= (unix-terminal-cursor-blink-time term)
            (unix-terminal-cursor-blink-interval term))
    (setf (unix-terminal-cursor-blink-time term) 0.0)
    (setf (unix-terminal-cursor-blink-on term)
          (not (unix-terminal-cursor-blink-on term)))))

(defun run-terminal-loop (term)
  "Main event loop."
  (setf (unix-terminal-running term) t)
  (let ((last-time (glfw:get-time)))
    (loop :while (and (unix-terminal-running term)
                      (not (glfw:window-should-close-p)))
          :do
          ;; Calculate delta time for cursor blink
          (let* ((current-time (glfw:get-time))
                 (dt (- current-time last-time)))
            (setf last-time current-time)
            (update-cursor-blink term (coerce dt 'single-float)))
          ;; 1. Process PTY output
          (process-pty-output term)
          ;; 2. Check if child is still alive
          (unless (pty-check-child (unix-terminal-pty term))
            (setf (unix-terminal-running term) nil)
            (return))
          ;; 3. Handle any pending resize
          (when (unix-terminal-resize-pending term)
            (handle-resize term
                           (unix-terminal-resize-cols term)
                           (unix-terminal-resize-rows term))
            (setf (unix-terminal-resize-pending term) nil))
          ;; 4. Poll GLFW events (handles input callbacks)
          (glfw:poll-events)
          ;; 5. Flush model to display grid (with cursor state)
          (flush-to-display (unix-terminal-screen term)
                            (unix-terminal-display term)
                            :atlas (unix-terminal-atlas term)
                            :space-glyph (screen-blank-glyph (unix-terminal-screen term))
                            :cursor-blink-on (unix-terminal-cursor-blink-on term))
          ;; 6. Render frame
          (render-frame (unix-terminal-renderer term)
                        (unix-terminal-display term))
          ;; 7. Swap buffers
          (glfw:swap-buffers)
          ;; Small sleep to avoid burning CPU when idle
          (sleep 0.001))))

;;; --------------------------------------------------------------------------
;;; Resize handling
;;; --------------------------------------------------------------------------

(defun handle-resize (term new-cols new-rows)
  "Handle terminal resize."
  (let ((screen (unix-terminal-screen term))
        (display (unix-terminal-display term))
        (pty (unix-terminal-pty term)))
    ;; Resize model
    (resize-screen screen new-cols new-rows)
    ;; Resize display grid
    (resize-grid display new-cols new-rows)
    ;; Update PTY window size
    (pty-set-size pty new-cols new-rows)
    ;; Update dimensions
    (setf (unix-terminal-cols term) new-cols
          (unix-terminal-rows term) new-rows)))

(defun schedule-resize (term new-cols new-rows)
  "Schedule a resize to be processed in the main loop."
  (setf (unix-terminal-resize-cols term) new-cols
        (unix-terminal-resize-rows term) new-rows
        (unix-terminal-resize-pending term) t))

;;; --------------------------------------------------------------------------
;;; Entry point
;;; --------------------------------------------------------------------------

(defun run-terminal (command &key
                               (args nil)
                               (font-path "../terminus-18n.pcf")
                               (cols 80)
                               (rows 24)
                               (pixel-scale nil)
                               (title "pcf-gl terminal"))
  "Run a terminal emulator with COMMAND.
   
   COMMAND: program to run (e.g. \"/bin/bash\")
   ARGS: list of arguments to pass to command
   FONT-PATH: path to PCF font file
   COLS, ROWS: terminal dimensions in characters
   PIXEL-SCALE: integer scaling factor (nil = auto-detect)
   TITLE: window title"
  (format t "~&Loading font ~a ...~%" font-path)
  (let* ((font   (load-pcf font-path))
         (cell-w (pcf-font-cell-width font))
         (cell-h (pcf-font-cell-height font)))
    (format t "~&Cell ~dx~d, terminal ~dx~d~%" cell-w cell-h cols rows)
    ;; Initialize GLFW
    (glfw:initialize)
    (let* ((scale  (or pixel-scale 1))
           (win-w  (* cols cell-w scale))
           (win-h  (* rows cell-h scale)))
      (format t "~&Pixel scale: ~dx, window ~dx~d~%" scale win-w win-h)
      (glfw:with-init-window
          (:title title
           :width win-w :height win-h
           :resizable t
           :context-version-major 3
           :context-version-minor 3
           :opengl-profile :opengl-core-profile
           :opengl-forward-compat t)
        ;; Set up OpenGL
        (gl:viewport 0 0 win-w win-h)
        ;; Build atlas with cursor glyphs
        (let* ((atlas    (build-atlas (list font)))
               (_        (add-cursor-glyphs atlas))
               ;; Create terminal components
               (screen   (make-screen :cols cols :rows rows))
               (display  (make-display-grid :cols cols :rows rows))
               (renderer (make-renderer atlas win-w win-h :pixel-scale scale))
               (palette  (make-xterm-palette)))
          (declare (ignore _))
          ;; Set up palette
          (set-palette renderer palette)
          ;; Initialize default swatches in display grid
          (setup-default-swatches display)
          ;; Create terminal state
          (let ((term (make-unix-terminal
                       :screen screen
                       :display display
                       :atlas atlas
                       :renderer renderer
                       :palette palette
                       :cols cols
                       :rows rows
                       :pixel-scale scale)))
            ;; Create VT handler (pass atlas for codepoint -> glyph mapping)
            (setf (unix-terminal-vt-handler term)
                  (make-vt-handler screen atlas :callback (make-vt-callback term)))
            ;; Spawn child process
            (format t "~&Spawning: ~a~{ ~a~}~%" command args)
            (setf (unix-terminal-pty term)
                  (pty-fork command :cols cols :rows rows :args args))
            (pty-set-nonblocking (unix-terminal-pty term))
            (format t "~&Child PID: ~d~%" (pty-child-pid (unix-terminal-pty term)))
            ;; Set up GLFW callbacks
            (let ((term-ref term))  ; capture for closures
              ;; Key callback
              (glfw:def-key-callback key-callback (window key scancode action mods)
                (declare (ignore window))
                (handle-key-press term-ref key scancode action mods))
              (glfw:set-key-callback 'key-callback)
              ;; Character callback
              (glfw:def-char-callback char-callback (window codepoint)
                (declare (ignore window))
                (handle-char-input term-ref codepoint))
              (glfw:set-char-callback 'char-callback)
              ;; Framebuffer size callback (for resize)
              (glfw:def-framebuffer-size-callback fb-size-callback (window width height)
                (declare (ignore window))
                (let ((new-cols (floor width (* cell-w scale)))
                      (new-rows (floor height (* cell-h scale))))
                  (when (and (> new-cols 0) (> new-rows 0)
                             (or (/= new-cols (unix-terminal-cols term-ref))
                                 (/= new-rows (unix-terminal-rows term-ref))))
                    (gl:viewport 0 0 width height)
                    (update-viewport renderer width height)
                    (schedule-resize term-ref new-cols new-rows))))
              (glfw:set-framebuffer-size-callback 'fb-size-callback))
            ;; Run main loop
            (unwind-protect
                 (run-terminal-loop term)
              ;; Cleanup
              (format t "~&Shutting down...~%")
              (pty-close (unix-terminal-pty term))
              (destroy-renderer renderer))))))))

;;; --------------------------------------------------------------------------
;;; Helpers
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

(defun setup-default-swatches (display)
  "Initialize default swatches in display grid."
  ;; Swatch 0: black bg, white fg (default)
  (pcf-gl/grid:set-swatch display 0  0 7 7 0))
