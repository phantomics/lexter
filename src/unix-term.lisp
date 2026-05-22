(in-package #:lexter/unix-term)

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

(defconstant +esc+ #x1B)

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
  ;; Dimensions
  (cols       80  :type fixnum)
  (rows       24  :type fixnum)
  (pixel-scale 1 :type fixnum)
  ;; I/O buffer
  (read-buffer (make-array 4096 :element-type '(unsigned-byte 8))
               :type (simple-array (unsigned-byte 8) (*)))
  ;; Buffer to hold Unicode code points and escape codes for writing
  (write-buffer (make-array 8 :element-type '(unsigned-byte 8)))
  ;; Unicode character scratch string
  (uc-scratch-string (make-string 1))
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
   (cons :up        (bytes +esc+ #x5B #x41))           ; ESC [ A
   (cons :down      (bytes +esc+ #x5B #x42))           ; ESC [ B
   (cons :right     (bytes +esc+ #x5B #x43))           ; ESC [ C
   (cons :left      (bytes +esc+ #x5B #x44))           ; ESC [ D
   ;; Navigation
   (cons :home      (bytes +esc+ #x5B #x48))           ; ESC [ H
   (cons :end       (bytes +esc+ #x5B #x46))           ; ESC [ F
   (cons :page-up   (bytes +esc+ #x5B #x35 #x7E))      ; ESC [ 5 ~
   (cons :page-down (bytes +esc+ #x5B #x36 #x7E))      ; ESC [ 6 ~
   (cons :insert    (bytes +esc+ #x5B #x32 #x7E))      ; ESC [ 2 ~
   (cons :delete    (bytes +esc+ #x5B #x33 #x7E))      ; ESC [ 3 ~
   ;; Function keys
   (cons :f1        (bytes +esc+ #x4F #x50))           ; ESC O P
   (cons :f2        (bytes +esc+ #x4F #x51))           ; ESC O Q
   (cons :f3        (bytes +esc+ #x4F #x52))           ; ESC O R
   (cons :f4        (bytes +esc+ #x4F #x53))           ; ESC O S
   (cons :f5        (bytes +esc+ #x5B #x31 #x35 #x7E)) ; ESC [ 1 5 ~
   (cons :f6        (bytes +esc+ #x5B #x31 #x37 #x7E)) ; ESC [ 1 7 ~
   (cons :f7        (bytes +esc+ #x5B #x31 #x38 #x7E)) ; ESC [ 1 8 ~
   (cons :f8        (bytes +esc+ #x5B #x31 #x39 #x7E)) ; ESC [ 1 9 ~
   (cons :f9        (bytes +esc+ #x5B #x32 #x30 #x7E)) ; ESC [ 2 0 ~
   (cons :f10       (bytes +esc+ #x5B #x32 #x31 #x7E)) ; ESC [ 2 1 ~
   (cons :f11       (bytes +esc+ #x5B #x32 #x33 #x7E)) ; ESC [ 2 3 ~
   (cons :f12       (bytes +esc+ #x5B #x32 #x34 #x7E)) ; ESC [ 2 4 ~
   ;; Special
   (cons :backspace (bytes #x7F))
   (cons :tab       (bytes #x09))
   (cons :enter     (bytes #x0D))
   (cons :escape    (bytes +esc+)))
  "Mapping from GLFW key symbols to byte sequences.")

(defun key-to-bytes (key mods buffer)
  "Convert a GLFW key press to bytes to send to PTY.
   Returns a byte vector or NIL if the key should be ignored."
  (let ((ctrl-p  (member :control mods))
        (shift-p (member :shift   mods))
        (alt-p   (member :alt     mods)))
    (cond
      ;; Control+key combinations
      ((and ctrl-p (symbolp key))
       (let ((name (symbol-name key)))
         (when (and (= (length name) 1)
                    (alpha-char-p (char name 0)))
           ;; Ctrl+A = 0x01, Ctrl+B = 0x02, etc.
           (let ((code (- (char-code (char-upcase (char name 0))) 64)))
             (when (<= 1 code 26)
               (setf (aref buffer 0) code)
               1))))) ;; one-byte code
      ;; Alt+key - send ESC prefix
      ((and alt-p (symbolp key))
       (let ((name (symbol-name key)))
         (when (and (= (length name) 1)
                    (alpha-char-p (char name 0)))
           (let ((ch (if shift-p ;; shift key capitalizes letters
                         (char-upcase   (char name 0))
                         (char-downcase (char name 0)))))
             (setf (aref buffer 0) +esc+ ;; ESC prefix
                   (aref buffer 1) (char-code ch))
             2)))) ;; two-byte code
      (t (let ((seq-form (assoc key *key-sequences*)))
           ;; Special keys
           (if seq-form (loop :for cx :from 0 :for char :across (rest seq-form)
                              :do (setf (aref buffer cx) char) :finally (return cx))
               0)))))) ;; Regular character keys are handled via char callback, thus return 0

(defun handle-key-press (term key scancode action mods)
  "Handle a GLFW key callback."
  (declare (ignore scancode))
  (when (and (member action '(:press :repeat))
             (pty-alive-p (unix-terminal-pty term)))
    ;; Handle Escape specially - close terminal
    ;; (when (and (eq key :escape) (eq action :press) (null mods))
    ;;   (setf (unix-terminal-running term) nil)
    ;;   (return-from handle-key-press))
    ;; Convert key to bytes
    (let ((n (key-to-bytes key mods (unix-terminal-write-buffer term))))
      (unless (zerop n)
        (pty-write (unix-terminal-pty term)
                   (unix-terminal-write-buffer term)
                   :end n)))))

(defvar *utf8-mapping*
  (babel::lookup-mapping babel::*string-vector-mappings* :utf-8))

(defun handle-char-input (term codepoint)
  "Handle a GLFW character callback (for regular text input).
   CODEPOINT may be a character or an integer depending on cl-glfw3 version."
  (when (pty-alive-p (unix-terminal-pty term))
    (setf (aref (unix-terminal-uc-scratch-string term) 0)
          (code-char (if (characterp codepoint) (char-code codepoint) codepoint)))
    ;; write the first character in scratch-string to the start of the buffer
    (let ((n (funcall (babel::encoder *utf8-mapping*)
                      ;; write the first (only) scratch string char...
                      (unix-terminal-uc-scratch-string term) 0 1
                      ;; into the buffer starting at 0 
                      (unix-terminal-write-buffer term) 0)))
      (pty-write (unix-terminal-pty term)
                 (unix-terminal-write-buffer term) :end n))))

;; (defun handle-char-input2 (term codepoint)
;;   "Handle a GLFW character callback (for regular text input).
;;    CODEPOINT may be a character or an integer depending on cl-glfw3 version."
;;   (when (pty-alive-p (unix-terminal-pty term))
;;     (let* ((code (if (characterp codepoint)
;;                      (char-code codepoint)
;;                      codepoint))
;;            (bytes (babel:string-to-octets (string (code-char code))
;;                                           :encoding :utf-8)))
;;       (pty-write (unix-terminal-pty term) bytes))))

;;; --------------------------------------------------------------------------
;;; VT handler callbacks
;;; --------------------------------------------------------------------------

(defun make-vt-callback (term) ;; echo -e '\033[6n'
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
         ;; (format nil "~c[~d;~dR" #\Escape
         ;;         (1+ (cursor-row screen))
         ;;         (1+ (cursor-col screen)))
         ;; (pty-write-string )
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
  "Update cursor blink state based on elapsed time DT (seconds).
   Returns T if the blink state toggled, NIL otherwise."
  (incf (unix-terminal-cursor-blink-time term) dt)
  (when (>= (unix-terminal-cursor-blink-time term)
            (unix-terminal-cursor-blink-interval term))
    (setf (unix-terminal-cursor-blink-time term) 0.0
          (unix-terminal-cursor-blink-on term)
          (not (unix-terminal-cursor-blink-on term)))
    t))

(defun run-terminal-loop (term &key stop-flag)
  "Main event loop.
   STOP-FLAG, if provided, is a list whose CAR is checked each tick.
   When (CAR STOP-FLAG) is NIL, the loop terminates."
  (setf (unix-terminal-running term) t)
  (let ((last-time (glfw:get-time)))
    (loop :while (and (unix-terminal-running term)
                      (not (glfw:window-should-close-p))
                      (or (null stop-flag) (car stop-flag)))
          :do
          ;; Calculate delta time for cursor blink
          (let* ((current-time (glfw:get-time))
                 (dt (- current-time last-time))
                 (blink-toggled (update-cursor-blink term (coerce dt 'single-float))))
            (setf last-time current-time)
            ;; 1. Process PTY output
            (process-pty-output term)
            ;; 2. Check if child is still alive
            (unless (pty-check-child (unix-terminal-pty term))
              (setf (unix-terminal-running term) nil)
              (return))
            ;; 3. Handle any pending resize (always needs render)
            (let ((resized nil))
              (when (unix-terminal-resize-pending term)
                (handle-resize term
                               (unix-terminal-resize-cols term)
                               (unix-terminal-resize-rows term))
                (setf (unix-terminal-resize-pending term) nil
                      resized t))
              ;; 4. Poll GLFW events (handles input callbacks)
              (glfw:poll-events)
              ;; 5. Check if we need to render
              ;; Render if: any dirty rows, cursor blink toggled, or resized
              (let ((needs-render (or resized
                                      blink-toggled
                                      (any-row-dirty-p (unix-terminal-screen term)))))
                (when needs-render
                  ;; 6. Flush model to display grid (with cursor state)
                  (flush-to-display (unix-terminal-screen term)
                                    (unix-terminal-display term)
                                    :atlas (unix-terminal-atlas term)
                                    :space-glyph (screen-blank-glyph (unix-terminal-screen term))
                                    :cursor-blink-on (unix-terminal-cursor-blink-on term))
                  ;; 6b. Sync palette if changed
                  (let ((screen (unix-terminal-screen term)))
                    (upload-palette (unix-terminal-renderer term)
                                    (screen-palette screen)
                                    (screen-palette-generation screen)))
                  ;; 7. Render frame
                  (render-frame (unix-terminal-renderer term)
                                (unix-terminal-display term))
                  ;; 8. Swap buffers
                  (glfw:swap-buffers)))))
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
    ;; Resize display grid (use the screen's blank glyph)
    (resize-grid display new-cols new-rows
                 :blank-glyph (screen-blank-glyph screen))
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
                               (title "lexter terminal")
                               (stop-flag nil))
  "Run a terminal emulator with COMMAND.
   
   COMMAND: program to run (e.g. \"/bin/bash\")
   ARGS: list of arguments to pass to command
   FONT-PATH: path to PCF font file
   COLS, ROWS: terminal dimensions in characters
   PIXEL-SCALE: integer scaling factor (nil = auto-detect)
   TITLE: window title
   STOP-FLAG: a list whose CAR is checked each tick; NIL CAR terminates the loop"
  (format t "~&=== lexter terminal v0.5 ===~%")
  (format t "~&Loading font ~a ...~%" font-path)
  (let* ((font   (load-pcf font-path))
         (cell-w (bitmap-font-cell-width font))
         (cell-h (bitmap-font-cell-height font)))
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
               (renderer (make-renderer atlas win-w win-h :pixel-scale scale)))
          (declare (ignore _))
          ;; Upload initial palette from screen
          (upload-palette renderer
                          (screen-palette screen)
                          (screen-palette-generation screen))
          ;; Initialize default swatches in display grid
          (setup-default-swatches display)
          ;; Create terminal state
          (let ((term (make-unix-terminal
                       :screen screen
                       :display display
                       :atlas atlas
                       :renderer renderer
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
                 (run-terminal-loop term :stop-flag stop-flag)
              ;; Cleanup
              (format t "~&Shutting down...~%")
              (pty-close (unix-terminal-pty term))
              (destroy-renderer renderer))))))))

;;; --------------------------------------------------------------------------
;;; Helpers
;;; --------------------------------------------------------------------------

;; Note: Palette is now created by lexter/model:make-default-palette and stored
;; on the screen struct. No local palette function needed.

(defun setup-default-swatches (display)
  "Initialize default swatches in display grid."
  ;; Swatch 0: black bg, white fg (default)
  (lexter/grid:set-swatch display 0  0 7 7 0))
