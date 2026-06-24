;;;; Compositor: main entry point and event loop for paned terminal.

(in-package #:lexter/panes)

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
  ;; --- Mouse state ---
  ;; Last known cursor position in window pixels (the GLFW mouse-button callback
  ;; carries no coordinates, so we track them from the cursor-pos callback).
  (mouse-x 0.0d0 :type double-float)
  (mouse-y 0.0d0 :type double-float)
  ;; Pane that grabbed the pointer on button-press; receives all motion/release
  ;; until every button is released (drag capture). NIL when idle.
  (mouse-capture-pane nil)
  ;; Currently held xterm button codes (0 left, 1 middle, 2 right).
  (mouse-buttons '() :type list)
  ;; Last window cell a motion event was delivered for (cell-granularity dedupe);
  ;; (col . row) or NIL.
  (mouse-last-cell nil)
  ;; Cursor blink
  (cursor-blink-on t :type boolean)
  (cursor-blink-time 0.0 :type single-float)
  (cursor-blink-interval 0.5 :type single-float)
  ;; Loop control
  (running      nil :type boolean)
  ;; Pending resize
  (resize-pending nil :type boolean)
  (resize-cols    0   :type fixnum)
  (resize-rows    0   :type fixnum)
  ;; --- GUI iteration state (Approach B) ---
  ;; GLFW window + OpenGL context owned by this compositor
  (window       nil)
  (win-w        0   :type fixnum)
  (win-h        0   :type fixnum)
  ;; Frame timing carried across ticks (glfw:get-time is a double)
  (last-tick-time 0.0d0 :type double-float)
  ;; --- Configuration (consumed by gui-initialize) ---
  (fonts        nil :type list)
  (font-path    "../terminus-18n.pcf")
  (title        "lexter panes" :type string)
  (prefix-key   :f12)
  ;; When NIL, the GLFW window is created hidden (offscreen capture / testing).
  (visible      t   :type boolean))

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
                :glyph (lexter/atlas:atlas-glyph-index
                        (compositor-atlas comp) 32)
                :swatch 0)))

(defun handle-compositor-char (comp codepoint)
  "Route character input to focused pane."
  (let* ((ws (active-workspace comp))
         (pane (when ws (focused-pane ws))))
    (when pane
      (pane-handle-char pane codepoint))))

;;; --------------------------------------------------------------------------
;;; Mouse handling
;;; --------------------------------------------------------------------------

;; GLFW decodes mouse buttons to :left / :right / :3(middle); GLFW's button
;; order (0 left, 1 right, 2 middle) differs from xterm's (0 left, 1 middle,
;; 2 right). Map by keyword so we are robust to either decoding.
(defparameter *glfw->xterm-button*
  '((:left . 0) (:1 . 0)
    (:3 . 1) (:middle . 1)
    (:right . 2) (:2 . 2)
    (:4 . 64) (:5 . 65))
  "Maps a cl-glfw3 mouse-button keyword to an xterm button code.")

(defun %glfw-button->xterm (button-kw)
  "Translate a GLFW mouse-button keyword to an xterm button code, or NIL."
  (cdr (assoc button-kw *glfw->xterm-button*)))

(defun compositor-pixel->cell (comp x y)
  "Convert window pixel coordinates X,Y to 0-based window cell (col,row),
   clamped to the grid. Returns (values col row)."
  (let* ((cw (* (compositor-cell-w comp) (compositor-pixel-scale comp)))
         (ch (* (compositor-cell-h comp) (compositor-pixel-scale comp)))
         (col (floor x cw))
         (row (floor y ch)))
    (values (max 0 (min (1- (compositor-cols comp)) col))
            (max 0 (min (1- (compositor-rows comp)) row)))))

(defun compositor-pane-at (comp col row)
  "Return the active-workspace pane whose grid rectangle contains window cell
   (COL,ROW), or NIL. First match wins (panes are expected to be disjoint)."
  (let ((ws (active-workspace comp)))
    (when ws
      (dolist (pane (workspace-panes ws))
        (let ((c0 (pane-col pane)) (r0 (pane-row pane)))
          (when (and (<= c0 col (+ c0 (pane-width pane) -1))
                     (<= r0 row (+ r0 (pane-height pane) -1)))
            (return pane)))))))

(defun pane-content-cell (pane wincol winrow)
  "Translate window cell (WINCOL,WINROW) into PANE content-space cells.
   Returns (values ccol crow inside-p) where INSIDE-P is true only when the
   point lands within the pane's content area (excluding header/scroll chrome)."
  (let* ((ccol (- wincol (pane-col pane)))
         (crow (- winrow (content-row pane)))
         (inside (and (<= 0 ccol) (< ccol (content-width pane))
                      (<= 0 crow) (< crow (content-height pane)))))
    (values ccol crow inside)))

(defun %compositor-deliver-button (comp pane wincol winrow button action mods)
  "Deliver a button event to PANE in its content space, if inside its content."
  (when pane
    (multiple-value-bind (ccol crow inside) (pane-content-cell pane wincol winrow)
      (when inside
        (pane-handle-mouse-button pane ccol crow button action mods)))))

(defun handle-compositor-mouse-button (comp button-kw action mods)
  "Route a GLFW mouse button event: focus + drag-capture + delivery."
  (let ((button (%glfw-button->xterm button-kw)))
    (when button
      (multiple-value-bind (col row) (compositor-pixel->cell comp
                                                             (compositor-mouse-x comp)
                                                             (compositor-mouse-y comp))
        (cond
          ((eq action :press)
           (pushnew button (compositor-mouse-buttons comp))
           (let ((pane (compositor-pane-at comp col row)))
             ;; Capture the pointer for the drag and focus the pane on click.
             (setf (compositor-mouse-capture-pane comp) pane)
             (when (and pane (pane-focusable pane))
               (let ((ws (active-workspace comp)))
                 (when ws (focus-pane ws pane))))
             (%compositor-deliver-button comp pane col row button :press mods)))
          (t ; :release -> goes to the capturing pane (or pane under cursor)
           (setf (compositor-mouse-buttons comp)
                 (remove button (compositor-mouse-buttons comp)))
           (let ((pane (or (compositor-mouse-capture-pane comp)
                           (compositor-pane-at comp col row))))
             (%compositor-deliver-button comp pane col row button :release mods))
           ;; Release the grab once no buttons remain held.
           (when (null (compositor-mouse-buttons comp))
             (setf (compositor-mouse-capture-pane comp) nil))))))))

(defun handle-compositor-cursor-pos (comp x y)
  "Track the cursor and deliver per-cell motion to the captured / hovered pane."
  (setf (compositor-mouse-x comp) x
        (compositor-mouse-y comp) y)
  (multiple-value-bind (col row) (compositor-pixel->cell comp x y)
    (let ((last (compositor-mouse-last-cell comp)))
      (unless (and last (= (car last) col) (= (cdr last) row))
        (setf (compositor-mouse-last-cell comp) (cons col row))
        (let ((pane (or (compositor-mouse-capture-pane comp)
                        (compositor-pane-at comp col row))))
          (when pane
            (multiple-value-bind (ccol crow inside) (pane-content-cell pane col row)
              (when inside
                ;; GLFW cursor-pos carries no modifier state; pass NIL.
                (pane-handle-mouse-motion pane ccol crow
                                          (compositor-mouse-buttons comp) nil)))))))))

(defun handle-compositor-scroll (comp dx dy)
  "Route a scroll-wheel event to the captured / hovered pane."
  (multiple-value-bind (col row) (compositor-pixel->cell comp
                                                         (compositor-mouse-x comp)
                                                         (compositor-mouse-y comp))
    (let ((pane (or (compositor-mouse-capture-pane comp)
                    (compositor-pane-at comp col row))))
      (when pane
        (multiple-value-bind (ccol crow inside) (pane-content-cell pane col row)
          (when inside
            (pane-handle-scroll pane ccol crow (round dx) (round dy) nil)))))))

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
    (lexter/grid:resize-grid (compositor-display comp) new-cols new-rows
                              :blank-glyph (lexter/atlas:atlas-glyph-index
                                            (compositor-atlas comp) 32))
    ;; Mark all workspaces' decorations dirty (layout changed)
    (dolist (ws (compositor-workspaces comp))
      (mark-decorations-dirty ws))
    ;; Note: Pane resizing is the user's responsibility since they provide
    ;; the layout. We mark everything dirty so it gets redrawn.
    (lexter/grid:mark-all-dirty (compositor-display comp))))

;;; --------------------------------------------------------------------------
;;; Main loop
;;; --------------------------------------------------------------------------

(defmethod gui-tick ((comp compositor))
  "Advance the compositor by one frame (Approach B iteration API).
   Makes the compositor's GL context current, processes I/O for every pane in
   every workspace, and renders the active workspace if needed. Does NOT poll
   GLFW events -- the dispatcher does that once for all windows. Returns T while
   still alive, NIL when all terminals have died or the window is closing."
  (let ((window (compositor-window comp)))
    (when window
      (glfw:make-context-current window))
    ;; Delta time for cursor blink (carried across ticks)
    (let* ((current-time (glfw:get-time))
           (dt (- current-time (compositor-last-tick-time comp)))
           (blink-toggled (update-compositor-blink comp (coerce dt 'single-float))))
      (setf (compositor-last-tick-time comp) current-time)
      ;; Update global blink state for terminal panes
      (setf *cursor-blink-on* (compositor-cursor-blink-on comp))
      ;; 1. Process I/O for ALL panes in ALL workspaces
      (dolist (ws (compositor-workspaces comp))
        (workspace-process-output ws))
      ;; 2. Check if any terminal died (stop if all are dead)
      (cond
        ((not (some #'workspace-any-terminal-alive-p
                    (compositor-workspaces comp)))
         (setf (compositor-running comp) nil))
        (t
         ;; 3. Handle pending resize
         (let ((resized nil))
           (when (compositor-resize-pending comp)
             (handle-compositor-resize comp)
             (setf resized t))
           ;; 4. Check if we need to render
           (let* ((ws (active-workspace comp))
                  (needs-render (or resized
                                    blink-toggled
                                    (and ws (workspace-any-dirty-p ws)))))
             (when needs-render
               ;; 5. Flush active workspace to grid
               (when ws
                 (flush-workspace ws (compositor-display comp))
                 ;; 5b. Sync focused pane's palette to renderer
                 (let ((pane (focused-pane ws)))
                   (when pane
                     (multiple-value-bind (palette gen slot) (pane-palette pane)
                       (when palette
                         (let ((s (or slot 0)))
                           ;; Upload palette data to slot if changed
                           (lexter/renderer:upload-palette
                            (compositor-renderer comp) palette gen s)
                           ;; Set active palette slot for rendering
                           (lexter/renderer:set-active-palette-slot
                            (compositor-renderer comp) s)))))))
               ;; 6. Render
               (lexter/renderer:render-frame (compositor-renderer comp)
                                             (compositor-display comp))
               ;; 6b. Present offscreen buffer to the window (no-op unless
               ;; offscreen rendering is enabled).
               (lexter/renderer:present-offscreen (compositor-renderer comp))
               ;; 7. Swap buffers
               (glfw:swap-buffers window)))))))
    ;; Liveness: alive while running, has a window, and not asked to close.
    (and (compositor-running comp)
         window
         (not (glfw:window-should-close-p window)))))

;;; --------------------------------------------------------------------------
;;; Entry point
;;; --------------------------------------------------------------------------

(defun make-paned-compositor (&key workspaces
                                   (font-path "../terminus-18n.pcf")
                                   fonts
                                   (cols 80)
                                   (rows 24)
                                   (pixel-scale nil)
                                   (title "lexter panes")
                                   (prefix-key :f12)
                                   (visible t))
  "Create an uninitialized COMPOSITOR for the given WORKSPACES.

The window, OpenGL context, and renderer are NOT created yet -- call
GUI-INITIALIZE on the result (on the main thread, after GLFW has been
initialized), then drive it with GUI-TICK / GUI-DESTROY. This is the
constructor half of the Approach B iteration API; RUN-PANED-TERMINAL is the
standalone convenience wrapper around it.

WORKSPACES: list of workspace objects (pre-constructed)
FONT-PATH:  path to PCF or BDF font file (used if FONTS is nil)
FONTS:      list of pre-loaded bitmap-font structs (overrides FONT-PATH)
COLS, ROWS: grid dimensions in characters
PIXEL-SCALE: integer scaling factor (nil = 1x)
TITLE:      window title
PREFIX-KEY: key that activates meta-mode (default :f12)"
  (unless workspaces
    (error "At least one workspace is required"))
  (make-compositor :workspaces workspaces
                   :active-index 0
                   :cols cols
                   :rows rows
                   :pixel-scale (or pixel-scale 1)
                   :fonts fonts
                   :font-path font-path
                   :title title
                   :prefix-key prefix-key
                   :visible visible))

(defmethod gui-initialize ((comp compositor))
  "Create COMP's GLFW window, OpenGL context, renderer, and initialize all panes.
Must run on the main thread, after GLFW:INITIALIZE. GLFW:CREATE-WINDOW makes the
new context current, so the atlas/renderer GL objects belong to it."
  ;; Set global prefix key
  (setf *prefix-key* (compositor-prefix-key comp))
  (format t "~&=== lexter panes v0.1 ===~%")
  (let* ((font-path (compositor-font-path comp))
         (font-list (or (compositor-fonts comp)
                        (progn
                          (format t "~&Loading font ~a ...~%" font-path)
                          (list (if (search ".bdf" font-path :test #'char-equal)
                                    (lexter/pcf:load-bdf font-path)
                                    (lexter/pcf:load-pcf font-path))))))
         (primary (first font-list))
         (cell-w (lexter/pcf:bitmap-font-cell-width primary))
         (cell-h (lexter/pcf:bitmap-font-cell-height primary))
         (cols (compositor-cols comp))
         (rows (compositor-rows comp))
         (scale (compositor-pixel-scale comp))
         (win-w (* cols cell-w scale))
         (win-h (* rows cell-h scale)))
    (format t "~&Cell ~dx~d, grid ~dx~d~%" cell-w cell-h cols rows)
    (format t "~&Pixel scale: ~dx, window ~dx~d~%" scale win-w win-h)
    (format t "~&Prefix key: ~a~%" (compositor-prefix-key comp))
    (format t "~&Workspaces: ~d~%" (length (compositor-workspaces comp)))
    ;; Create the window (this makes its GL context current).
    (let ((win (glfw:create-window
                :title (compositor-title comp)
                :width win-w :height win-h
                :resizable t
                :visible (compositor-visible comp)
                :context-version-major 3
                :context-version-minor 3
                :opengl-profile :opengl-core-profile
                :opengl-forward-compat t)))
      (gl:viewport 0 0 win-w win-h)
      ;; Build atlas with all fonts, then add cursor glyphs, then renderer.
      (let ((atlas (lexter/atlas:build-atlas font-list)))
        (lexter/atlas:add-cursor-glyphs atlas)
        (let ((display (lexter/grid:make-display-grid :cols cols :rows rows))
              (renderer (lexter/renderer:make-renderer atlas win-w win-h
                                                       :pixel-scale scale))
              (palette (make-xterm-palette)))
          ;; Set up palette and default swatches
          (lexter/renderer:set-palette renderer palette)
          (setup-default-swatches display)
          ;; Populate the persistent compositor object.
          (setf (compositor-window   comp) win
                (compositor-atlas    comp) atlas
                (compositor-display  comp) display
                (compositor-renderer comp) renderer
                (compositor-palette  comp) palette
                (compositor-cell-w   comp) cell-w
                (compositor-cell-h   comp) cell-h
                (compositor-win-w    comp) win-w
                (compositor-win-h    comp) win-h)
          ;; Set up GLFW callbacks, bound to this compositor's window.
          ;; (Single-window for now; multi-window dispatch via a window->object
          ;;  registry is a deferred, registry-ready extension.)
          (glfw:def-key-callback key-callback (window key scancode action mods)
            (declare (ignore window))
            (handle-compositor-key comp key scancode action mods))
          (glfw:set-key-callback 'key-callback win)
          (glfw:def-char-callback char-callback (window codepoint)
            (declare (ignore window))
            (handle-compositor-char comp codepoint))
          (glfw:set-char-callback 'char-callback win)
          ;; Mouse callbacks (button, motion, wheel).
          (glfw:def-mouse-button-callback mouse-button-callback (window button action mod-keys)
            (declare (ignore window))
            (handle-compositor-mouse-button comp button action mod-keys))
          (glfw:set-mouse-button-callback 'mouse-button-callback win)
          (glfw:def-cursor-pos-callback cursor-pos-callback (window x y)
            (declare (ignore window))
            (handle-compositor-cursor-pos comp x y))
          (glfw:set-cursor-position-callback 'cursor-pos-callback win)
          (glfw:def-scroll-callback scroll-callback (window x y)
            (declare (ignore window))
            (handle-compositor-scroll comp x y))
          (glfw:set-scroll-callback 'scroll-callback win)
          (glfw:def-framebuffer-size-callback fb-size-callback (window width height)
            (declare (ignore window))
            (let ((new-cols (floor width (* cell-w scale)))
                  (new-rows (floor height (* cell-h scale))))
              (when (and (> new-cols 0) (> new-rows 0)
                         (or (/= new-cols (compositor-cols comp))
                             (/= new-rows (compositor-rows comp))))
                (gl:viewport 0 0 width height)
                (lexter/renderer:update-viewport (compositor-renderer comp)
                                                 width height)
                (schedule-compositor-resize comp new-cols new-rows))))
          (glfw:set-framebuffer-size-callback 'fb-size-callback win)
          ;; Initialize all panes with the atlas
          (format t "~&Initializing panes...~%")
          (dolist (ws (compositor-workspaces comp))
            (dolist (pane (workspace-panes ws))
              (pane-initialize pane atlas)))
          ;; Clear grid initially
          (clear-grid display
                      :glyph (lexter/atlas:atlas-glyph-index atlas 32)
                      :swatch 0)
          (setf (compositor-running comp) t
                (compositor-last-tick-time comp) (glfw:get-time))
          comp)))))

(defmethod gui-destroy ((comp compositor))
  "Release COMP's panes, renderer, and GLFW window. Idempotent."
  (let ((window (compositor-window comp)))
    (when window
      (format t "~&Shutting down panes...~%")
      (dolist (ws (compositor-workspaces comp))
        (destroy-workspace ws))
      (when (compositor-renderer comp)
        (glfw:make-context-current window)
        (lexter/renderer:destroy-renderer (compositor-renderer comp)))
      (glfw:destroy-window window)
      (setf (compositor-window comp) nil
            (compositor-running comp) nil)))
  comp)

(defmethod gui-window ((comp compositor))
  (compositor-window comp))

(defmethod gui-alive-p ((comp compositor))
  (and (compositor-running comp)
       (compositor-window comp)
       t))

(defun run-paned-terminal (&key workspaces
                                (font-path "../terminus-18n.pcf")
                                fonts
                                (cols 80)
                                (rows 24)
                                (pixel-scale nil)
                                (title "lexter panes")
                                (prefix-key :f12)
                                (visible t)
                                (stop-flag nil))
  "Run a paned terminal with the given WORKSPACES as a standalone, blocking call.

   WORKSPACES: list of workspace objects (pre-constructed)
   FONT-PATH: path to PCF or BDF font file (used if FONTS is nil)
   FONTS: list of pre-loaded bitmap-font structs (overrides FONT-PATH)
   COLS, ROWS: grid dimensions in characters
   PIXEL-SCALE: integer scaling factor (nil = 1x)
   TITLE: window title
   PREFIX-KEY: key that activates meta-mode (default :f12)
   STOP-FLAG: a list whose CAR is checked each tick; NIL CAR terminates the loop

   This is a thin wrapper over the iteration API: it owns the GLFW
   initialize/terminate lifecycle, builds the compositor with
   MAKE-PANED-COMPOSITOR, GUI-INITIALIZEs it, and drives it through the
   single-window dispatcher RUN-GUI-LOOP. To embed Lexter panes in an external
   main-thread dispatcher (e.g. Origin's), use MAKE-PANED-COMPOSITOR +
   GUI-INITIALIZE / GUI-TICK / GUI-DESTROY directly instead."
  (glfw:initialize)
  (let ((comp (make-paned-compositor :workspaces workspaces
                                     :font-path font-path :fonts fonts
                                     :cols cols :rows rows
                                     :pixel-scale pixel-scale
                                     :title title :prefix-key prefix-key
                                     :visible visible)))
    (unwind-protect
         (progn
           (gui-initialize comp)
           (run-gui-loop (list comp) :stop-flag stop-flag))
      (gui-destroy comp)
      (glfw:terminate))))

;;; --------------------------------------------------------------------------
;;; Screenshot capture (testing)
;;; --------------------------------------------------------------------------

(defun compositor-capture (comp)
  "Render COMP's active workspace into the offscreen buffer and return it as an
   (H W 3) (unsigned-byte 8) array, row 0 = top of the image.

   Forces a full flush + render regardless of dirty state, so the result is
   deterministic and does not depend on the window being visible (create the
   compositor with :VISIBLE NIL for tests). COMP must already be GUI-INITIALIZEd;
   its GL context is made current here."
  (let ((window   (compositor-window comp))
        (renderer (compositor-renderer comp))
        (ws       (active-workspace comp)))
    (when window (glfw:make-context-current window))
    (lexter/renderer:enable-offscreen renderer)
    (when ws
      (flush-workspace ws (compositor-display comp))
      (let ((pane (focused-pane ws)))
        (when pane
          (multiple-value-bind (palette gen slot) (pane-palette pane)
            (when palette
              (let ((s (or slot 0)))
                (lexter/renderer:upload-palette renderer palette gen s)
                (lexter/renderer:set-active-palette-slot renderer s)))))))
    (lexter/renderer:render-frame renderer (compositor-display comp))
    (lexter/renderer:capture-pixels renderer)))

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
  (lexter/grid:set-swatch display 0  0 7 7 0))
