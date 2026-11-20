(in-package #:lexter/unix-term)

;;;; Unix Terminal: the standalone terminal, a compositor holding one workspace
;;;; with one Unix terminal pane (LEXTER-D67).
;;;;
;;;; The compositor owns the window, the atlas, the renderer, the display grid,
;;;; the main loop, input routing, cursor blink, resize, and palette upload; the
;;;; pane owns the PTY, the screen, the VT handler, and key encoding. This file
;;;; keeps the standalone terminal's API, which the test rig and the Origin
;;;; integration use, as a thin layer over them: MAKE-TERMINAL and RUN-TERMINAL,
;;;; the GUI-* protocol, capture, recording, and headless replay.
;;;;
;;;; The compositor has no prefix key here, so every key reaches the shell, and
;;;; its layout function keeps the one pane the size of the window. A terminal
;;;; made with :NO-PTY spawns no child and has a headless compositor, which keeps
;;;; running with no live backend while the test rig feeds its VT handler.

;;; --------------------------------------------------------------------------
;;; Terminal structure
;;; --------------------------------------------------------------------------

(defstruct (unix-terminal (:constructor %make-unix-terminal))
  "The standalone terminal: a compositor and its one Unix terminal pane."
  ;; The compositor with one workspace holding PANE
  (compositor nil)
  ;; The LEXTER/PANES:UTERM-PANE that runs the command
  (pane       nil)
  ;; The command the terminal was made for, reported even when no PTY spawns it
  (command    nil))

;;; --------------------------------------------------------------------------
;;; Construction
;;; --------------------------------------------------------------------------

(defun make-terminal (command &key
                                (args nil)
                                (font-path "../terminus-18n.pcf")
                                fonts
                                (cols 80)
                                (rows 24)
                                (pixel-scale nil)
                                (title "lexter terminal")
                                (visible t)
                                (no-pty nil)
                                (width-policy lexter/width:*default-width-policy*)
                                (atlas-cols nil))
  "Create an uninitialized UNIX-TERMINAL with the given configuration.

The window, OpenGL context, renderer, and PTY are NOT created yet -- call
GUI-INITIALIZE on the result (on the main thread, after GLFW has been
initialized), then drive it with GUI-TICK / GUI-DESTROY. This is the
constructor half of the Approach B iteration API; RUN-TERMINAL is the
standalone convenience wrapper around it.

FONTS, if given, is a pre-loaded font fallback chain (list of bitmap-font
structs) and takes precedence over FONT-PATH; all fonts must share cell
dimensions. Otherwise FONT-PATH is loaded (PCF, or BDF when it ends in .bdf).

NO-PTY, when T, builds a headless replay terminal: no child process is spawned
and COMMAND may be NIL. Drive it by feeding bytes to PROCESS-OUTPUT and reading
back pixels with TERMINAL-CAPTURE (combine with :VISIBLE NIL for a hidden
window).

WIDTH-POLICY decides character widths (LEXTER/WIDTH:MAKE-WIDTH-POLICY); by
default Unicode's tables, with characters of ambiguous width narrow. A user who
changes it makes the same setting in the programs the terminal runs.

ATLAS-COLS fixes the atlas's column count, as a fixture does (LEXTER-D108); by
default it is chosen from the GPU's maximum texture size. A terminal without a
window (TERMINAL-INITIALIZE-WINDOWLESS) needs it."
  (let* ((pane (make-instance 'lexter/panes:uterm-pane
                              :command (unless no-pty command)
                              :args args
                              :col 0 :row 0 :width cols :height rows))
         (workspace (make-instance 'lexter/panes:workspace
                                   :name "terminal" :panes (list pane)))
         (compositor (lexter/panes:make-paned-compositor
                      :workspaces (list workspace)
                      :font-path font-path
                      :fonts fonts
                      :cols cols
                      :rows rows
                      :pixel-scale pixel-scale
                      :title title
                      :prefix-key nil
                      :visible visible
                      :headless no-pty
                      :width-policy width-policy
                      :atlas-cols atlas-cols
                      :layout-fn (lambda (comp new-cols new-rows)
                                   (declare (ignore comp))
                                   (lexter/panes:pane-resize pane new-cols new-rows)))))
    (%make-unix-terminal :compositor compositor :pane pane :command command)))

;;; --------------------------------------------------------------------------
;;; GUI iteration protocol, delegated to the compositor
;;; --------------------------------------------------------------------------

(defmethod gui-initialize ((term unix-terminal))
  "Create TERM's window, OpenGL context, atlas, and renderer, and initialize
its pane, spawning the child unless TERM is headless. Must run on the main
thread, after GLFW:INITIALIZE."
  (gui-initialize (unix-terminal-compositor term))
  term)

(defun terminal-initialize-windowless (term)
  "Make TERM's atlas, display grid, and pane without a window or GL context, so
   that a headless terminal can be fed through PROCESS-OUTPUT and composed with
   TERMINAL-COMPOSE on a machine with no display (LEXTER-D108). TERM needs a
   fixed atlas column count. Release it with GUI-DESTROY. Returns TERM."
  (lexter/panes:compositor-initialize-windowless (unix-terminal-compositor term))
  term)

(defmethod gui-tick ((term unix-terminal))
  "Advance TERM by one frame. Returns T while it is alive."
  (gui-tick (unix-terminal-compositor term)))

(defmethod gui-destroy ((term unix-terminal))
  "Release TERM's PTY, renderer, and window. Idempotent."
  (gui-destroy (unix-terminal-compositor term))
  term)

(defmethod gui-window ((term unix-terminal))
  (gui-window (unix-terminal-compositor term)))

(defmethod gui-alive-p ((term unix-terminal))
  (gui-alive-p (unix-terminal-compositor term)))

(defun run-terminal (command &key
                               (args nil)
                               (font-path "../terminus-18n.pcf")
                               fonts
                               (cols 80)
                               (rows 24)
                               (pixel-scale nil)
                               (title "lexter terminal")
                               (visible t)
                               (stop-flag nil)
                               (width-policy lexter/width:*default-width-policy*))
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
   WIDTH-POLICY: how character widths are decided (see MAKE-TERMINAL)

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
                                     :visible visible :width-policy width-policy)))
    (unwind-protect
         (progn
           (gui-initialize term)
           (run-gui-loop (list term) :stop-flag stop-flag))
      (gui-destroy term)
      (glfw:terminate))))

;;; --------------------------------------------------------------------------
;;; Accessors, read through the compositor and the pane
;;; --------------------------------------------------------------------------

(defun unix-terminal-window (term)
  "TERM's GLFW window, or NIL before GUI-INITIALIZE or after GUI-DESTROY."
  (lexter/panes:compositor-window (unix-terminal-compositor term)))

(defun unix-terminal-renderer (term)
  "TERM's renderer, or NIL before GUI-INITIALIZE."
  (lexter/panes:compositor-renderer (unix-terminal-compositor term)))

(defun unix-terminal-vt-handler (term)
  "The VT handler of TERM's pane, or NIL before its screen is made."
  (lexter/panes:vt-pane-vt-handler (unix-terminal-pane term)))

(defun unix-terminal-cols (term)
  "TERM's width in columns; it follows the window when the window is resized."
  (lexter/panes:compositor-cols (unix-terminal-compositor term)))

(defun unix-terminal-rows (term)
  "TERM's height in rows; it follows the window when the window is resized."
  (lexter/panes:compositor-rows (unix-terminal-compositor term)))

(defun unix-terminal-pixel-scale (term)
  "TERM's integer pixel scale."
  (lexter/panes:compositor-pixel-scale (unix-terminal-compositor term)))

(defun (setf unix-terminal-pixel-scale) (value term)
  (setf (lexter/panes:compositor-pixel-scale (unix-terminal-compositor term)) value))

(defun unix-terminal-title (term)
  "TERM's window title, as configured."
  (lexter/panes:compositor-title (unix-terminal-compositor term)))

(defun (setf unix-terminal-title) (value term)
  (setf (lexter/panes:compositor-title (unix-terminal-compositor term)) value))

(defun terminal-screen (term)
  "The screen TERM shows now: its VT handler's active screen, the alternate one
while a program such as vim holds it; NIL before the screen is made. Readers
ask for it here rather than keeping a screen of their own (LEXTER-D70)."
  (let ((handler (unix-terminal-vt-handler term)))
    (and handler (lexter/vt-handler:vt-handler-screen handler))))

(defun terminal-pty (term)
  "TERM's PTY, or NIL for a headless terminal or before GUI-INITIALIZE."
  (lexter/panes:uterm-pane-pty (unix-terminal-pane term)))

;;; --------------------------------------------------------------------------
;;; Raw-input recording (test rig authoring)
;;; --------------------------------------------------------------------------

(defun terminal-start-recording (term)
  "Begin recording the raw byte stream this terminal receives from its PTY.
   Used to author screenshot-test fixtures from a live session. Returns TERM."
  (lexter/vt-handler:start-recording (unix-terminal-vt-handler term))
  term)

(defun terminal-stop-recording (term)
  "Stop recording and return the captured bytes as a fresh simple
   (unsigned-byte 8) vector (or NIL if recording was not active)."
  (lexter/vt-handler:stop-recording (unix-terminal-vt-handler term)))

;;; --------------------------------------------------------------------------
;;; Screenshot capture (testing)
;;; --------------------------------------------------------------------------

(defun terminal-compose (term)
  "Compose TERM's screen into its display grid, whatever was flushed before, and
   return the grid. Needs no GL."
  (lexter/panes:compositor-compose (unix-terminal-compositor term)))

(defun terminal-capture (term)
  "Render TERM's current screen into the offscreen buffer and return it as an
   (H W 3) (unsigned-byte 8) array, row 0 = top of the image.

   Forces a full flush + render regardless of dirty state, so the result is
   deterministic and does not depend on the window being visible -- ideal for
   tests (create the terminal with :VISIBLE NIL). TERM must already be
   GUI-INITIALIZEd; its GL context is made current here."
  (lexter/panes:compositor-capture (unix-terminal-compositor term)))

;;; --------------------------------------------------------------------------
;;; Headless replay support (test rig)
;;; --------------------------------------------------------------------------

(defun terminal-config-plist (term)
  "Return the durable test-config plist describing TERM, suitable for pasting
   into a WITH-TERMINAL-TEST-CONFIG form. CELL-WIDTH/CELL-HEIGHT come from the
   loaded font and are informational (the font determines them)."
  (let ((comp (unix-terminal-compositor term)))
    (list :font-path   (lexter/panes:compositor-font-path comp)
          :cols        (lexter/panes:compositor-cols comp)
          :rows        (lexter/panes:compositor-rows comp)
          :cell-width  (lexter/panes:compositor-cell-w comp)
          :cell-height (lexter/panes:compositor-cell-h comp)
          :pixel-scale (lexter/panes:compositor-pixel-scale comp)
          :atlas-cols  (lexter/atlas:atlas-cols (lexter/panes:compositor-atlas comp)))))

(defun terminal-reset (term)
  "Reset TERM to a blank initial screen, reusing its window, atlas, and
   renderer: the pane gets a new screen and VT handler, and the compositor a
   new display grid. Intended for headless replay so successive fixtures each
   start from a clean slate without rebuilding the (expensive) GL atlas. A
   terminal without a window has no renderer to upload its palette to.
   Returns TERM."
  (let* ((comp (unix-terminal-compositor term))
         (screen (lexter/panes:vt-pane-init-screen (unix-terminal-pane term)
                                                   (lexter/panes:compositor-atlas comp))))
    (lexter/panes:compositor-reset-display comp)
    (let ((slot (lexter/panes:vt-pane-drawn-palette-slot (unix-terminal-pane term))))
      (when (and (plusp slot) (lexter/panes:compositor-renderer comp))
        (lexter/renderer:upload-palette (lexter/panes:compositor-renderer comp)
                                        (lexter/model:screen-palette screen)
                                        (lexter/model:screen-palette-generation screen)
                                        slot)))
    term))
