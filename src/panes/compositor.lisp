;;;; Compositor: main entry point and event loop for paned terminal.

(in-package #:pcf-gl/panes)

;;; --------------------------------------------------------------------------
;;; Configuration
;;; --------------------------------------------------------------------------

(defvar *prefix-key* :f12
  "Key that activates pane meta-mode. Press this, then a command key.")

;;; --------------------------------------------------------------------------
;;; Compositor state
;;; --------------------------------------------------------------------------

(defstruct compositor
  "State for the pane compositor."
  ;; Workspaces
  (workspaces   '() :type list)
  (active-index 0   :type fixnum)
  ;; Rendering
  (atlas        nil)
  (display      nil)   ; the single display-grid
  (renderer     nil)
  (palette      nil)
  ;; Dimensions (in cells)
  (cols         80  :type fixnum)
  (rows         24  :type fixnum)
  (cell-w       10  :type fixnum)
  (cell-h       18  :type fixnum)
  (pixel-scale  1   :type fixnum)
  ;; Meta-mode state
  (prefix-active nil :type boolean)
  ;; Cursor blink
  (cursor-blink-on t :type boolean)
  (cursor-blink-time 0.0 :type single-float)
  (cursor-blink-interval 0.5 :type single-float)
  ;; Loop control
  (running      nil :type boolean)
  ;; Pending resize
  (resize-pending nil :type boolean)
  (resize-cols    0   :type fixnum)
  (resize-rows    0   :type fixnum))

(defun active-workspace (comp)
  "Return the currently active workspace."
  (nth (compositor-active-index comp) (compositor-workspaces comp)))

;;; --------------------------------------------------------------------------
;;; Cursor blink
;;; --------------------------------------------------------------------------

(defun update-compositor-blink (comp dt)
  "Update cursor blink state. Returns T if toggled."
  (incf (compositor-cursor-blink-time comp) dt)
  (when (>= (compositor-cursor-blink-time comp)
            (compositor-cursor-blink-interval comp))
    (setf (compositor-cursor-blink-time comp) 0.0
          (compositor-cursor-blink-on comp)
          (not (compositor-cursor-blink-on comp)))
    t))

;;; --------------------------------------------------------------------------
;;; Key handling
;;; --------------------------------------------------------------------------

(defun handle-compositor-key (comp key scancode action mods)
  "Route key events: prefix mode or to focused pane."
  (when (eq action :press)
    (cond
      ;; Prefix key activates meta mode
      ((eq key *prefix-key*)
       (setf (compositor-prefix-active comp) t)
       (return-from handle-compositor-key))
      ;; In meta mode: interpret as compositor command
      ((compositor-prefix-active comp)
       (setf (compositor-prefix-active comp) nil)
       (handle-meta-command comp key mods)
       (return-from handle-compositor-key))))
  ;; Normal mode: delegate to focused pane
  (let* ((ws (active-workspace comp))
         (pane (when ws (focused-pane ws))))
    (when pane
      (pane-handle-key pane key scancode action mods))))

(defun handle-meta-command (comp key mods)
  "Handle a meta-mode command after prefix key."
  (declare (ignore mods))
  (let ((ws (active-workspace comp)))
    (case key
      ;; Focus navigation
      (:right (when ws (focus-next ws)))
      (:left  (when ws (focus-prev ws)))
      (:down  (when ws (focus-next ws)))
      (:up    (when ws (focus-prev ws)))
      ;; Workspace switching (number keys)
      (:1 (switch-workspace comp 0))
      (:2 (switch-workspace comp 1))
      (:3 (switch-workspace comp 2))
      (:4 (switch-workspace comp 3))
      (:5 (switch-workspace comp 4))
      (:6 (switch-workspace comp 5))
      (:7 (switch-workspace comp 6))
      (:8 (switch-workspace comp 7))
      (:9 (switch-workspace comp 8))
      ;; Escape from meta mode (do nothing)
      (:escape nil)
      (otherwise nil))))

(defun switch-workspace (comp index)
  "Switch to workspace at INDEX if it exists."
  (when (< index (length (compositor-workspaces comp)))
    (setf (compositor-active-index comp) index)
    ;; Clear grid and mark for full redraw
    (clear-grid (compositor-display comp)
                :glyph (pcf-gl/atlas:atlas-glyph-index
                        (compositor-atlas comp) 32)
                :swatch 0)))

(defun handle-compositor-char (comp codepoint)
  "Route character input to focused pane."
  (let* ((ws (active-workspace comp))
         (pane (when ws (focused-pane ws))))
    (when pane
      (pane-handle-char pane codepoint))))

;;; --------------------------------------------------------------------------
;;; Resize handling
;;; --------------------------------------------------------------------------

(defun schedule-compositor-resize (comp new-cols new-rows)
  "Schedule a resize for the next loop iteration."
  (setf (compositor-resize-cols comp) new-cols
        (compositor-resize-rows comp) new-rows
        (compositor-resize-pending comp) t))

(defun handle-compositor-resize (comp)
  "Process a pending resize."
  (let ((new-cols (compositor-resize-cols comp))
        (new-rows (compositor-resize-rows comp)))
    (setf (compositor-cols comp) new-cols
          (compositor-rows comp) new-rows
          (compositor-resize-pending comp) nil)
    ;; Resize the display grid
    (pcf-gl/grid:resize-grid (compositor-display comp) new-cols new-rows
                              :blank-glyph (pcf-gl/atlas:atlas-glyph-index
                                            (compositor-atlas comp) 32))
    ;; Note: Pane resizing is the user's responsibility since they provide
    ;; the layout. We mark everything dirty so it gets redrawn.
    (pcf-gl/grid:mark-all-dirty (compositor-display comp))))

;;; --------------------------------------------------------------------------
;;; Main loop
;;; --------------------------------------------------------------------------

(defun run-pane-loop (comp)
  "Main event loop for paned terminal."
  (setf (compositor-running comp) t)
  (let ((last-time (glfw:get-time)))
    (loop :while (and (compositor-running comp)
                      (not (glfw:window-should-close-p)))
          :do
          ;; Delta time for cursor blink
          (let* ((current-time (glfw:get-time))
                 (dt (- current-time last-time))
                 (blink-toggled (update-compositor-blink comp (coerce dt 'single-float))))
            (setf last-time current-time)
            ;; Update global blink state for terminal panes
            (setf *cursor-blink-on* (compositor-cursor-blink-on comp))
            ;; 1. Process I/O for ALL panes in ALL workspaces
            (dolist (ws (compositor-workspaces comp))
              (workspace-process-output ws))
            ;; 2. Check if any terminal died (stop if all are dead)
            (unless (some #'workspace-any-terminal-alive-p
                          (compositor-workspaces comp))
              (setf (compositor-running comp) nil)
              (return))
            ;; 3. Handle pending resize
            (let ((resized nil))
              (when (compositor-resize-pending comp)
                (handle-compositor-resize comp)
                (setf resized t))
              ;; 4. Poll GLFW events
              (glfw:poll-events)
              ;; 5. Check if we need to render
              (let* ((ws (active-workspace comp))
                     (needs-render (or resized
                                       blink-toggled
                                       (and ws (workspace-any-dirty-p ws)))))
                (when needs-render
                  ;; 6. Flush active workspace to grid
                  (when ws
                    (flush-workspace ws (compositor-display comp)))
                  ;; 7. Render
                  (pcf-gl/renderer:render-frame (compositor-renderer comp)
                                                 (compositor-display comp))
                  ;; 8. Swap buffers
                  (glfw:swap-buffers)))))
          ;; Small sleep to avoid burning CPU
          (sleep 0.001))))

;;; --------------------------------------------------------------------------
;;; Entry point
;;; --------------------------------------------------------------------------

(defun run-paned-terminal (&key workspaces
                                (font-path "../terminus-18n.pcf")
                                (cols 80)
                                (rows 24)
                                (pixel-scale nil)
                                (title "pcf-gl panes")
                                (prefix-key :f12))
  "Run a paned terminal with the given WORKSPACES.
   
   WORKSPACES: list of workspace objects (pre-constructed)
   FONT-PATH: path to PCF or BDF font file
   COLS, ROWS: grid dimensions in characters
   PIXEL-SCALE: integer scaling factor (nil = auto-detect)
   TITLE: window title
   PREFIX-KEY: key that activates meta-mode (default :f12)"
  (unless workspaces
    (error "At least one workspace is required"))
  ;; Set global prefix key
  (setf *prefix-key* prefix-key)
  (format t "~&=== pcf-gl panes v0.1 ===~%")
  (format t "~&Loading font ~a ...~%" font-path)
  ;; Load font (support both PCF and BDF)
  (let* ((font (if (search ".bdf" font-path :test #'char-equal)
                   (pcf-gl/pcf:load-bdf font-path)
                   (pcf-gl/pcf:load-pcf font-path)))
         (cell-w (pcf-gl/pcf:bitmap-font-cell-width font))
         (cell-h (pcf-gl/pcf:bitmap-font-cell-height font)))
    (format t "~&Cell ~dx~d, grid ~dx~d~%" cell-w cell-h cols rows)
    ;; Initialize GLFW
    (glfw:initialize)
    (let* ((scale (or pixel-scale 1))
           (win-w (* cols cell-w scale))
           (win-h (* rows cell-h scale)))
      (format t "~&Pixel scale: ~dx, window ~dx~d~%" scale win-w win-h)
      (format t "~&Prefix key: ~a~%" prefix-key)
      (format t "~&Workspaces: ~d~%" (length workspaces))
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
        (let* ((atlas (pcf-gl/atlas:build-atlas (list font)))
               (_ (pcf-gl/atlas:add-cursor-glyphs atlas))
               (display (pcf-gl/grid:make-display-grid :cols cols :rows rows))
               (renderer (pcf-gl/renderer:make-renderer atlas win-w win-h
                                                         :pixel-scale scale))
               (palette (make-xterm-palette)))
          (declare (ignore _))
          ;; Set up palette and default swatches
          (pcf-gl/renderer:set-palette renderer palette)
          (setup-default-swatches display)
          ;; Create compositor state
          (let ((comp (make-compositor
                       :workspaces workspaces
                       :active-index 0
                       :atlas atlas
                       :display display
                       :renderer renderer
                       :palette palette
                       :cols cols
                       :rows rows
                       :cell-w cell-w
                       :cell-h cell-h
                       :pixel-scale scale)))
            ;; Set up GLFW callbacks
            (glfw:def-key-callback key-callback (window key scancode action mods)
              (declare (ignore window))
              (handle-compositor-key comp key scancode action mods))
            (glfw:set-key-callback 'key-callback)
            (glfw:def-char-callback char-callback (window codepoint)
              (declare (ignore window))
              (handle-compositor-char comp codepoint))
            (glfw:set-char-callback 'char-callback)
            (glfw:def-framebuffer-size-callback fb-size-callback (window width height)
              (declare (ignore window))
              (let ((new-cols (floor width (* cell-w scale)))
                    (new-rows (floor height (* cell-h scale))))
                (when (and (> new-cols 0) (> new-rows 0)
                           (or (/= new-cols (compositor-cols comp))
                               (/= new-rows (compositor-rows comp))))
                  (gl:viewport 0 0 width height)
                  (pcf-gl/renderer:update-viewport renderer width height)
                  (schedule-compositor-resize comp new-cols new-rows))))
            (glfw:set-framebuffer-size-callback 'fb-size-callback)
            ;; Initialize all panes with the atlas
            (format t "~&Initializing panes...~%")
            (dolist (ws workspaces)
              (dolist (pane (workspace-panes ws))
                (pane-initialize pane atlas)))
            ;; Clear grid initially
            (clear-grid display
                        :glyph (pcf-gl/atlas:atlas-glyph-index atlas 32)
                        :swatch 0)
            ;; Run main loop
            (unwind-protect
                 (run-pane-loop comp)
              ;; Cleanup
              (format t "~&Shutting down panes...~%")
              (dolist (ws workspaces)
                (destroy-workspace ws))
              (pcf-gl/renderer:destroy-renderer renderer))))))))

;;; --------------------------------------------------------------------------
;;; Helper functions (duplicated from unix-term for independence)
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
                               (220 220 220)  ; 7  light grey
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
  (pcf-gl/grid:set-swatch display 0  0 7 7 0))
