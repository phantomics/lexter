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
  (resize-rows    0   :type fixnum)
  ;; --- GUI iteration state (Approach B) ---
  ;; GLFW window + OpenGL context owned by this terminal
  (window     nil)
  ;; Font and cell metrics (kept for the resize callback and teardown)
  (font       nil)
  (cell-w     1   :type fixnum)
  (cell-h     1   :type fixnum)
  (win-w      0   :type fixnum)
  (win-h      0   :type fixnum)
  ;; Frame timing carried across ticks (glfw:get-time is a double)
  (last-tick-time 0.0d0 :type double-float)
  ;; --- Configuration (consumed by gui-initialize) ---
  (command    nil)
  (args       nil)
  ;; FONTS: a pre-loaded fallback chain (list of bitmap-font structs). When
  ;; non-NIL it takes precedence over FONT-PATH. All fonts in the chain must
  ;; share cell dimensions (build-atlas enforces this).
  (fonts      nil :type list)
  (font-path  "../terminus-18n.pcf")
  (title      "lexter terminal" :type string)
  ;; When NIL, the GLFW window is created hidden (useful for offscreen capture
  ;; / headless-ish testing).
  (visible    t   :type boolean))

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
  "Convert a GLFW key press to bytes written into BUFFER.
   Returns the number of bytes written (0 if the key produces no output).
   Always returns an integer: an unhandled modifier combination (e.g. a
   Ctrl/Alt chord with a non-alphabetic or multi-character key, as produced by
   desktop-switch shortcuts) yields 0 rather than NIL. Proper modifier-encoded
   sequences for special keys are not yet implemented -- such chords are simply
   swallowed for now."
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
               (return-from key-to-bytes 1)))))) ;; one-byte code
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
             (return-from key-to-bytes 2))))) ;; two-byte code
      ;; Special keys from table
      (t (let ((seq-form (assoc key *key-sequences*)))
           (when seq-form
             (loop :for cx :from 0 :for char :across (rest seq-form)
                   :do (setf (aref buffer cx) char)
                   :finally (return-from key-to-bytes cx))))))
    ;; Unhandled (regular character keys go through the char callback, and any
    ;; modifier chord that produced no bytes falls through here): 0.
    0))

(defun handle-key-press (term key scancode action mods)
  "Handle a GLFW key callback."
  (declare (ignore scancode))
  (when (and (member action '(:press :repeat))
             (pty-alive-p (unix-terminal-pty term)))
    ;; Handle Escape specially - close terminal
    ;; (when (and (eq key :escape) (eq action :press) (null mods))
    ;;   (setf (unix-terminal-running term) nil)
    ;;   (return-from handle-key-press))
    ;; Convert key to bytes. KEY-TO-BYTES always returns an integer; the OR is
    ;; a defensive guard so a future change can never feed NIL into PLUSP.
    (let ((n (or (key-to-bytes key mods (unix-terminal-write-buffer term)) 0)))
      (when (plusp n)
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

(defmethod gui-tick ((term unix-terminal))
  "Advance the terminal by one frame (Approach B iteration API).
   Makes the terminal's GL context current, processes PTY output, and renders
   if needed. Does NOT poll GLFW events -- the dispatcher does that once for all
   windows. Returns T while the terminal is still alive, NIL when it should be
   torn down."
  (let ((window (unix-terminal-window term)))
    (when window
      (glfw:make-context-current window))
    ;; Calculate delta time for cursor blink (carried across ticks)
    (let* ((current-time (glfw:get-time))
           (dt (- current-time (unix-terminal-last-tick-time term)))
           (blink-toggled (update-cursor-blink term (coerce dt 'single-float))))
      (setf (unix-terminal-last-tick-time term) current-time)
      ;; 1. Process PTY output
      (process-pty-output term)
      ;; 2. Check if child is still alive
      (cond
        ((not (pty-check-child (unix-terminal-pty term)))
         (setf (unix-terminal-running term) nil))
        (t
         ;; 3. Handle any pending resize (always needs render)
         (let ((resized nil))
           (when (unix-terminal-resize-pending term)
             (handle-resize term
                            (unix-terminal-resize-cols term)
                            (unix-terminal-resize-rows term))
             (setf (unix-terminal-resize-pending term) nil
                   resized t))
           ;; 4. Check if we need to render. Render the *active* screen, which
           ;; the VT handler may have swapped to the alternate buffer (vim etc).
           (let* ((screen (vt-handler-screen (unix-terminal-vt-handler term)))
                  (needs-render (or resized
                                    blink-toggled
                                    (any-row-dirty-p screen))))
             (when needs-render
               ;; 5. Flush model to display grid (with cursor state)
               (flush-to-display screen
                                 (unix-terminal-display term)
                                 :atlas (unix-terminal-atlas term)
                                 :space-glyph (screen-blank-glyph screen)
                                 :cursor-blink-on (unix-terminal-cursor-blink-on term))
               ;; 5b. Sync palette if changed (active screen owns the palette)
               (upload-palette (unix-terminal-renderer term)
                               (screen-palette screen)
                               (screen-palette-generation screen))
               ;; 6. Render frame
               (render-frame (unix-terminal-renderer term)
                             (unix-terminal-display term))
               ;; 6b. Present offscreen buffer to the window (no-op unless the
               ;; offscreen render target is enabled).
               (present-offscreen (unix-terminal-renderer term))
               ;; 7. Swap buffers
               (glfw:swap-buffers window)))))))
    ;; Liveness: alive while running, has a window, and not asked to close.
    (and (unix-terminal-running term)
         window
         (not (glfw:window-should-close-p window)))))

;;; --------------------------------------------------------------------------
;;; Resize handling
;;; --------------------------------------------------------------------------

(defun handle-resize (term new-cols new-rows)
  "Handle terminal resize."
  (let ((handler (unix-terminal-vt-handler term))
        (display (unix-terminal-display term))
        (pty (unix-terminal-pty term)))
    ;; Resize model -- both the primary and alternate buffers, so returning
    ;; from the alternate screen after a resize shows a correctly-sized primary.
    (vt-handler-resize-all handler new-cols new-rows)
    ;; Resize display grid (use the active screen's blank glyph)
    (resize-grid display new-cols new-rows
                 :blank-glyph (screen-blank-glyph (vt-handler-screen handler)))
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

(defun make-terminal (command &key
                                (args nil)
                                (font-path "../terminus-18n.pcf")
                                fonts
                                (cols 80)
                                (rows 24)
                                (pixel-scale nil)
                                (title "lexter terminal")
                                (visible t))
  "Create an uninitialized UNIX-TERMINAL with the given configuration.

The window, OpenGL context, renderer, and PTY are NOT created yet -- call
GUI-INITIALIZE on the result (on the main thread, after GLFW has been
initialized), then drive it with GUI-TICK / GUI-DESTROY. This is the
constructor half of the Approach B iteration API; RUN-TERMINAL is the
standalone convenience wrapper around it.

FONTS, if given, is a pre-loaded font fallback chain (list of bitmap-font
structs) and takes precedence over FONT-PATH; all fonts must share cell
dimensions. Otherwise FONT-PATH is loaded (PCF, or BDF when it ends in .bdf)."
  (make-unix-terminal :command command
                      :args args
                      :font-path font-path
                      :fonts fonts
                      :cols cols
                      :rows rows
                      :pixel-scale (or pixel-scale 1)
                      :title title
                      :visible visible))

(defmethod gui-initialize ((term unix-terminal))
  "Create TERM's GLFW window, OpenGL context, renderer, VT handler, and PTY.
Must run on the main thread, after GLFW:INITIALIZE. GLFW:CREATE-WINDOW makes
the new context current, so the atlas/renderer GL objects belong to it."
  (let* ((command   (unix-terminal-command term))
         (args      (unix-terminal-args term))
         (font-path (unix-terminal-font-path term))
         (cols      (unix-terminal-cols term))
         (rows      (unix-terminal-rows term))
         (scale     (unix-terminal-pixel-scale term)))
    (format t "~&=== lexter terminal v0.6 ===~%")
    ;; Use a provided font fallback chain, or load one from FONT-PATH (BDF when
    ;; the path ends in .bdf, otherwise PCF).
    (let* ((font-list (or (unix-terminal-fonts term)
                          (progn
                            (format t "~&Loading font ~a ...~%" font-path)
                            (list (if (search ".bdf" font-path :test #'char-equal)
                                      (load-bdf font-path)
                                      (load-pcf font-path))))))
           (font   (first font-list))
           (cell-w (bitmap-font-cell-width font))
           (cell-h (bitmap-font-cell-height font))
           (win-w  (* cols cell-w scale))
           (win-h  (* rows cell-h scale)))
      (format t "~&Cell ~dx~d, terminal ~dx~d (~d font~:p)~%"
              cell-w cell-h cols rows (length font-list))
      (format t "~&Pixel scale: ~dx, window ~dx~d~%" scale win-w win-h)
      ;; Create the window (this makes its GL context current).
      (let ((win (glfw:create-window
                  :title (unix-terminal-title term)
                  :width win-w :height win-h
                  :resizable t
                  :visible (unix-terminal-visible term)
                  :context-version-major 3
                  :context-version-minor 3
                  :opengl-profile :opengl-core-profile
                  :opengl-forward-compat t)))
        (gl:viewport 0 0 win-w win-h)
        ;; Build atlas over the whole fallback chain, then the renderer (in this
        ;; context).
        (let ((atlas (build-atlas font-list)))
          (add-cursor-glyphs atlas)
          (let ((screen   (make-screen :cols cols :rows rows))
                (display  (make-display-grid :cols cols :rows rows))
                (renderer (make-renderer atlas win-w win-h :pixel-scale scale)))
            ;; Upload initial palette from screen.
            (upload-palette renderer
                            (screen-palette screen)
                            (screen-palette-generation screen))
            (setup-default-swatches display)
            ;; Populate the persistent terminal object.
            (setf (unix-terminal-window   term) win
                  (unix-terminal-fonts    term) font-list
                  (unix-terminal-font     term) font
                  (unix-terminal-cell-w   term) cell-w
                  (unix-terminal-cell-h   term) cell-h
                  (unix-terminal-win-w    term) win-w
                  (unix-terminal-win-h    term) win-h
                  (unix-terminal-screen   term) screen
                  (unix-terminal-display  term) display
                  (unix-terminal-atlas    term) atlas
                  (unix-terminal-renderer term) renderer)
            ;; Create VT handler (pass atlas for codepoint -> glyph mapping).
            (setf (unix-terminal-vt-handler term)
                  (make-vt-handler screen atlas :callback (make-vt-callback term)))
            ;; Spawn child process.
            (format t "~&Spawning: ~a~{ ~a~}~%" command args)
            (setf (unix-terminal-pty term)
                  (pty-fork command :cols cols :rows rows :args args))
            (pty-set-nonblocking (unix-terminal-pty term))
            (format t "~&Child PID: ~d~%" (pty-child-pid (unix-terminal-pty term)))
            ;; Set up GLFW callbacks, bound to this terminal's window.
            ;; (Single-window for now; multi-window dispatch via a window->object
            ;;  registry is a deferred, registry-ready extension.)
            (let ((term-ref term))
              (glfw:def-key-callback key-callback (window key scancode action mods)
                (declare (ignore window))
                (handle-key-press term-ref key scancode action mods))
              (glfw:set-key-callback 'key-callback win)
              (glfw:def-char-callback char-callback (window codepoint)
                (declare (ignore window))
                (handle-char-input term-ref codepoint))
              (glfw:set-char-callback 'char-callback win)
              (glfw:def-framebuffer-size-callback fb-size-callback (window width height)
                (declare (ignore window))
                (let ((new-cols (floor width (* cell-w scale)))
                      (new-rows (floor height (* cell-h scale))))
                  (when (and (> new-cols 0) (> new-rows 0)
                             (or (/= new-cols (unix-terminal-cols term-ref))
                                 (/= new-rows (unix-terminal-rows term-ref))))
                    (gl:viewport 0 0 width height)
                    (update-viewport (unix-terminal-renderer term-ref) width height)
                    (schedule-resize term-ref new-cols new-rows))))
              (glfw:set-framebuffer-size-callback 'fb-size-callback win))
            (setf (unix-terminal-running term) t
                  (unix-terminal-last-tick-time term) (glfw:get-time))
            term))))))

(defmethod gui-destroy ((term unix-terminal))
  "Release TERM's PTY, renderer, and GLFW window. Idempotent."
  (let ((window (unix-terminal-window term)))
    (when window
      (format t "~&Shutting down...~%")
      (when (unix-terminal-pty term)
        (pty-close (unix-terminal-pty term)))
      (when (unix-terminal-renderer term)
        (glfw:make-context-current window)
        (destroy-renderer (unix-terminal-renderer term)))
      (glfw:destroy-window window)
      (setf (unix-terminal-window term) nil
            (unix-terminal-running term) nil)))
  term)

(defmethod gui-window ((term unix-terminal))
  (unix-terminal-window term))

(defmethod gui-alive-p ((term unix-terminal))
  (and (unix-terminal-running term)
       (unix-terminal-window term)
       t))

(defun run-terminal (command &key
                               (args nil)
                               (font-path "../terminus-18n.pcf")
                               fonts
                               (cols 80)
                               (rows 24)
                               (pixel-scale nil)
                               (title "lexter terminal")
                               (visible t)
                               (stop-flag nil))
  "Run a terminal emulator with COMMAND as a standalone, blocking call.

   COMMAND: program to run (e.g. \"/bin/bash\")
   ARGS: list of arguments to pass to command
   FONT-PATH: path to a PCF (or .bdf) font file, used when FONTS is NIL
   FONTS: a pre-loaded font fallback chain (list of bitmap-font structs);
          takes precedence over FONT-PATH. All fonts must share cell
          dimensions. Example:
          (run-terminal \"/bin/bash\"
            :fonts (list (lexter/pcf:load-pcf \"unifont.pcf\")))
   COLS, ROWS: terminal dimensions in characters
   PIXEL-SCALE: integer scaling factor (nil = 1x)
   TITLE: window title
   STOP-FLAG: a list whose CAR is checked each tick; NIL CAR terminates the loop

   This is a thin wrapper over the iteration API: it owns the GLFW
   initialize/terminate lifecycle, builds the terminal with MAKE-TERMINAL,
   GUI-INITIALIZEs it, and drives it through the single-window dispatcher
   RUN-GUI-LOOP. To embed Lexter in an external main-thread dispatcher (e.g.
   Origin's), use MAKE-TERMINAL + GUI-INITIALIZE / GUI-TICK / GUI-DESTROY
   directly instead."
  (glfw:initialize)
  (let ((term (make-terminal command :args args :font-path font-path :fonts fonts
                                     :cols cols :rows rows
                                     :pixel-scale pixel-scale :title title
                                     :visible visible)))
    (unwind-protect
         (progn
           (gui-initialize term)
           (run-gui-loop (list term) :stop-flag stop-flag))
      (gui-destroy term)
      (glfw:terminate))))

;;; --------------------------------------------------------------------------
;;; Screenshot capture (testing)
;;; --------------------------------------------------------------------------

(defun terminal-capture (term)
  "Render TERM's current screen into the offscreen buffer and return it as an
   (H W 3) (unsigned-byte 8) array, row 0 = top of the image.

   Forces a full flush + render regardless of dirty state, so the result is
   deterministic and does not depend on the window being visible -- ideal for
   tests (create the terminal with :VISIBLE NIL). TERM must already be
   GUI-INITIALIZEd; its GL context is made current here."
  (let ((window   (unix-terminal-window term))
        (renderer (unix-terminal-renderer term))
        (screen   (vt-handler-screen (unix-terminal-vt-handler term))))
    (when window (glfw:make-context-current window))
    (enable-offscreen renderer)
    ;; Force a full repaint of the active screen.
    (mark-screen-dirty screen)
    (flush-to-display screen (unix-terminal-display term)
                      :atlas (unix-terminal-atlas term)
                      :space-glyph (screen-blank-glyph screen)
                      :cursor-blink-on (unix-terminal-cursor-blink-on term))
    (upload-palette renderer
                    (screen-palette screen)
                    (screen-palette-generation screen))
    (render-frame renderer (unix-terminal-display term))
    (capture-pixels renderer)))

;;; --------------------------------------------------------------------------
;;; Helpers
;;; --------------------------------------------------------------------------

;; Note: Palette is now created by lexter/model:make-default-palette and stored
;; on the screen struct. No local palette function needed.

(defun setup-default-swatches (display)
  "Initialize default swatches in display grid."
  ;; Swatch 0: black bg, white fg (default)
  (lexter/grid:set-swatch display 0  0 7 7 0))
