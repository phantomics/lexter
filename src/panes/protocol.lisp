;;;; Pane protocol: base class and generic functions
;;;;
;;;; This file defines the abstract interface that all pane types implement.
;;;; Concrete implementations are in terminal-pane.lisp and function-pane.lisp.

(in-package #:lexter/panes)

;;; --------------------------------------------------------------------------
;;; Base pane class
;;; --------------------------------------------------------------------------

(defclass pane ()
  ((col       :initarg :col
              :accessor pane-col
              :initform 0
              :type fixnum
              :documentation "Grid column offset for this pane.")
   (row       :initarg :row
              :accessor pane-row
              :initform 0
              :type fixnum
              :documentation "Grid row offset for this pane.")
   (width     :initarg :width
              :accessor pane-width
              :initform 80
              :type fixnum
              :documentation "Pane width in cells.")
   (height    :initarg :height
              :accessor pane-height
              :initform 24
              :type fixnum
              :documentation "Pane height in cells.")
   (focusable :initarg :focusable
              :accessor pane-focusable
              :initform t
              :type boolean
              :documentation "Can this pane receive keyboard focus?")
   (workspace :accessor pane-workspace
              :initform nil
              :documentation "Back-reference to containing workspace, if any.")
   (input-redirect :accessor pane-input-redirect
                   :initform nil
                    :documentation "Function to redirect input to, or NIL for normal routing.
                     Signatures:
                       (funcall redirect pane :key key scancode action mods)
                       (funcall redirect pane :char codepoint)
                       (funcall redirect pane :mouse-button col row button action mods)
                       (funcall redirect pane :mouse-motion col row buttons mods)
                       (funcall redirect pane :scroll col row dx dy mods)
                     Used for modal dialogs and other input interception. An
                     active redirect captures pointer (including wheel) events
                     as well as keyboard events."))
  (:documentation "Base class for all pane types."))

;;; --------------------------------------------------------------------------
;;; Generic function protocol
;;; --------------------------------------------------------------------------

(defgeneric pane-flush (pane grid)
  (:documentation
   "Flush pane content into its region of GRID.
    Called for each pane in the active workspace before rendering."))

(defgeneric pane-handle-key (pane key scancode action mods)
  (:documentation
   "Handle a key event directed at this pane.
    KEY is a GLFW key keyword, ACTION is :press/:release/:repeat.
    MODS is a list of modifier keywords.
    Return T if handled, NIL to fall through to default behavior."))

(defgeneric pane-handle-char (pane codepoint)
  (:documentation
   "Handle a character input event directed at this pane.
    CODEPOINT is a Unicode codepoint (integer).
    Return T if handled, NIL to fall through to default behavior."))

(defgeneric pane-handle-mouse-button (pane col row button action mods)
  (:documentation
   "Handle a mouse button event directed at this pane.
    COL/ROW are 0-based cells in the pane's own content space (the compositor
    has already subtracted the pane's grid offset). BUTTON is an xterm button
    code (0 left, 1 middle, 2 right, 64/65 wheel). ACTION is :press/:release.
    MODS is a list of modifier keywords. Return T if handled."))

(defgeneric pane-handle-mouse-motion (pane col row buttons mods)
  (:documentation
   "Handle pointer motion (one event per cell change) directed at this pane.
    COL/ROW are 0-based pane-content cells. BUTTONS is the list of currently
    held xterm button codes (NIL when none). Return T if handled."))

(defgeneric pane-handle-scroll (pane col row dx dy mods)
  (:documentation
   "Handle a scroll-wheel event directed at this pane. COL/ROW are 0-based
    pane-content cells. DX/DY are integer wheel deltas (DY>0 = up). Return T
    if handled."))

(defgeneric pane-process-output (pane)
  (:documentation
   "Process any pending I/O for this pane.
    Called every loop iteration for ALL panes across ALL workspaces,
    not just the active one. This keeps background sessions responsive.
    Return T if any output was processed."))

(defgeneric pane-resize (pane new-width new-height)
  (:documentation
   "Resize this pane to new dimensions.
    For terminal panes, this resizes the screen and notifies the PTY."))

(defgeneric pane-dirty-p (pane)
  (:documentation
   "Return T if this pane has changes that need re-flushing."))

(defgeneric pane-destroy (pane)
  (:documentation
   "Clean up resources owned by this pane.
    For terminal panes, closes the PTY. Called on workspace teardown."))

(defgeneric pane-alive-p (pane)
  (:documentation
   "Return T if this pane has an active session.
    For Unix terminals, this means the PTY child is alive.
    For 3270 panes, this means the connection is active.
    Used to determine when to exit the compositor loop."))

(defgeneric pane-initialize (pane atlas)
  (:documentation
   "Initialize a pane with the given ATLAS.
    Called by the compositor after the GL context and atlas are ready.
    For terminal panes, this forks the PTY and creates the VT handler.
    For function panes, this is typically a no-op."))

(defgeneric pane-palette (pane)
  (:documentation
   "Return the pane's color palette as (values palette-array generation slot).
    PALETTE-ARRAY is a 1024-element single-float array (256 x RGBA).
    GENERATION is the palette's modification counter for change detection.
    SLOT is the GPU palette slot index (0-3) for palette paging, or NIL for default.
    For terminal panes, returns the screen's palette data.
    Returns NIL for panes without custom palettes (uses default)."))

(defgeneric scroll-state (pane)
  (:documentation
   "Return scroll state as (values total-lines viewport-offset visible-rows).
    TOTAL-LINES is the total content height including scrollback.
    VIEWPORT-OFFSET is how many lines the viewport is scrolled back (0 = bottom).
    VISIBLE-ROWS is the number of visible rows in the pane.
    Returns NIL if the pane has no scrollable content."))

(defgeneric content-width (pane)
  (:documentation
   "Return the effective content width of the pane.
    For panes with scroll bars, this is pane-width minus the scroll bar column.
    For regular panes, this equals pane-width."))

(defgeneric content-height (pane)
  (:documentation
   "Return the effective content height of the pane.
    For panes with headers/footers, this is pane-height minus reserved rows.
    For regular panes, this equals pane-height."))

(defgeneric content-row (pane)
  (:documentation
   "Return the grid row where content starts.
    For panes with headers, this is pane-row plus header height.
    For regular panes, this equals pane-row."))

;;; --------------------------------------------------------------------------
;;; Default method implementations
;;; --------------------------------------------------------------------------

(defmethod pane-handle-key ((pane pane) key scancode action mods)
  "Default: not handled."
  (declare (ignore key scancode action mods))
  nil)

(defmethod pane-handle-char ((pane pane) codepoint)
  "Default: not handled."
  (declare (ignore codepoint))
  nil)

(defmethod pane-handle-mouse-button ((pane pane) col row button action mods)
  "Default: not handled."
  (declare (ignore col row button action mods))
  nil)

(defmethod pane-handle-mouse-motion ((pane pane) col row buttons mods)
  "Default: not handled."
  (declare (ignore col row buttons mods))
  nil)

(defmethod pane-handle-scroll ((pane pane) col row dx dy mods)
  "Default: not handled."
  (declare (ignore col row dx dy mods))
  nil)

(defmethod pane-process-output ((pane pane))
  "Default: no I/O to process."
  nil)

(defmethod pane-resize ((pane pane) new-width new-height)
  "Default: just update dimension slots."
  (setf (pane-width pane) new-width
        (pane-height pane) new-height))

(defmethod pane-dirty-p ((pane pane))
  "Default: not dirty."
  nil)

(defmethod pane-destroy ((pane pane))
  "Default: nothing to clean up."
  nil)

(defmethod pane-alive-p ((pane pane))
  "Default: always alive (for static panes like function-pane)."
  t)

(defmethod pane-initialize ((pane pane) atlas)
  "Default: no initialization needed."
  (declare (ignore atlas))
  nil)

(defmethod pane-palette ((pane pane))
  "Default: no palette (use default)."
  nil)

(defmethod scroll-state ((pane pane))
  "Default: no scrollable content."
  nil)

(defmethod content-width ((pane pane))
  "Default: full pane width."
  (pane-width pane))

(defmethod content-height ((pane pane))
  "Default: full pane height."
  (pane-height pane))

(defmethod content-row ((pane pane))
  "Default: pane row (no header offset)."
  (pane-row pane))

;;; --------------------------------------------------------------------------
;;; Input redirect support
;;; --------------------------------------------------------------------------

(defvar *redirect-suppressed* nil
  "When T, input redirect is bypassed and events reach the pane's normal handler.
   Bound dynamically by pane-forward-key and pane-forward-char to allow redirect
   functions to forward events through to the pane without re-triggering themselves.")

(defmethod pane-handle-key :around ((pane pane) key scancode action mods)
  "Check for input redirect before normal key handling.
   Redirect is bypassed when *redirect-suppressed* is true."
  (let ((redirect (pane-input-redirect pane)))
    (if (and redirect (not *redirect-suppressed*))
        (funcall redirect pane :key key scancode action mods)
        (call-next-method))))

(defmethod pane-handle-char :around ((pane pane) codepoint)
  "Check for input redirect before normal char handling.
   Redirect is bypassed when *redirect-suppressed* is true."
  (let ((redirect (pane-input-redirect pane)))
    (if (and redirect (not *redirect-suppressed*))
        (funcall redirect pane :char codepoint)
        (call-next-method))))

(defmethod pane-handle-mouse-button :around ((pane pane) col row button action mods)
  "Divert mouse button events to an active input redirect."
  (let ((redirect (pane-input-redirect pane)))
    (if (and redirect (not *redirect-suppressed*))
        (funcall redirect pane :mouse-button col row button action mods)
        (call-next-method))))

(defmethod pane-handle-mouse-motion :around ((pane pane) col row buttons mods)
  "Divert pointer motion events to an active input redirect."
  (let ((redirect (pane-input-redirect pane)))
    (if (and redirect (not *redirect-suppressed*))
        (funcall redirect pane :mouse-motion col row buttons mods)
        (call-next-method))))

(defmethod pane-handle-scroll :around ((pane pane) col row dx dy mods)
  "Divert scroll-wheel events to an active input redirect (so a modal redirect
   captures the wheel as well as buttons and keys)."
  (let ((redirect (pane-input-redirect pane)))
    (if (and redirect (not *redirect-suppressed*))
        (funcall redirect pane :scroll col row dx dy mods)
        (call-next-method))))

;;; --------------------------------------------------------------------------
;;; Input forwarding (for use by redirect functions)
;;; --------------------------------------------------------------------------

(defun pane-forward-key (pane key scancode action mods)
  "Forward a key event to the pane's normal handler, bypassing any input redirect.
   Intended for use within redirect functions that want to pass events through
   to the pane after inspecting or transforming them."
  (let ((*redirect-suppressed* t))
    (pane-handle-key pane key scancode action mods)))

(defun pane-forward-char (pane codepoint)
  "Forward a char event to the pane's normal handler, bypassing any input redirect.
   Intended for use within redirect functions that want to pass events through
   to the pane after inspecting or transforming them."
  (let ((*redirect-suppressed* t))
    (pane-handle-char pane codepoint)))

(defun pane-forward-mouse-button (pane col row button action mods)
  "Forward a mouse button event to the pane's normal handler, bypassing redirect."
  (let ((*redirect-suppressed* t))
    (pane-handle-mouse-button pane col row button action mods)))

(defun pane-forward-mouse-motion (pane col row buttons mods)
  "Forward a pointer motion event to the pane's normal handler, bypassing redirect."
  (let ((*redirect-suppressed* t))
    (pane-handle-mouse-motion pane col row buttons mods)))

(defun pane-forward-scroll (pane col row dx dy mods)
  "Forward a scroll event to the pane's normal handler, bypassing redirect."
  (let ((*redirect-suppressed* t))
    (pane-handle-scroll pane col row dx dy mods)))
