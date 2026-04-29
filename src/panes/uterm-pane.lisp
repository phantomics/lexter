;;;; Unix terminal pane: a pane that owns a PTY and uses VT emulation.
;;;;
;;;; This is the Unix shell session pane type (VT100/xterm emulation).
;;;; Inherits screen/VT/key handling from vt-pane, adds PTY-specific I/O.

(in-package #:lexter/panes)

;;; --------------------------------------------------------------------------
;;; Unix terminal pane class
;;; --------------------------------------------------------------------------

(defclass uterm-pane (vt-pane)
  (;; Configuration (set at construction time)
   (command     :initarg :command
                :accessor uterm-pane-command
                :initform nil
                :documentation "Command to run (e.g. \"/bin/bash\").")
   (args        :initarg :args
                :accessor uterm-pane-args
                :initform nil
                :documentation "Arguments to pass to command.")
   ;; Runtime state (set by pane-initialize)
   (pty         :accessor uterm-pane-pty
                :initform nil
                :documentation "PTY handle for this terminal session."))
  (:documentation "A pane containing a Unix terminal session (PTY + VT).
   Construct with :command and :args, then call pane-initialize with an atlas."))

;;; --------------------------------------------------------------------------
;;; Abstract interface implementations (PTY backend)
;;; --------------------------------------------------------------------------

(defmethod vt-pane-write-bytes ((pane uterm-pane) buffer &key end)
  "Write bytes to the PTY."
  (when (uterm-pane-pty pane)
    (lexter/pty:pty-write (uterm-pane-pty pane) buffer :end end)))

(defmethod vt-pane-read-bytes ((pane uterm-pane) buffer)
  "Read available bytes from the PTY. Returns count or 0."
  (let ((pty (uterm-pane-pty pane)))
    (unless pty
      (return-from vt-pane-read-bytes 0))
    (let ((status (lexter/pty:pty-poll pty 0)))
      (case status
        (:readable
         (lexter/pty:pty-read pty buffer))
        (otherwise 0)))))

(defmethod vt-pane-backend-alive-p ((pane uterm-pane))
  "Return T if the PTY's child process is still running."
  (and (uterm-pane-pty pane)
       (lexter/pty:pty-alive-p (uterm-pane-pty pane))))

(defmethod vt-pane-backend-destroy ((pane uterm-pane))
  "Close the PTY."
  (when (uterm-pane-pty pane)
    (lexter/pty:pty-close (uterm-pane-pty pane))))

(defmethod vt-pane-backend-resize ((pane uterm-pane) cols rows)
  "Notify the PTY of a terminal size change."
  (when (uterm-pane-pty pane)
    (lexter/pty:pty-set-size (uterm-pane-pty pane) cols rows)))

(defmethod vt-pane-write-string ((pane uterm-pane) string)
  "Write a string to the PTY (for cursor reports etc)."
  (when (and (uterm-pane-pty pane)
             (lexter/pty:pty-alive-p (uterm-pane-pty pane)))
    (lexter/pty:pty-write-string (uterm-pane-pty pane) string)))

;;; --------------------------------------------------------------------------
;;; Initialization
;;; --------------------------------------------------------------------------

(defmethod pane-initialize ((pane uterm-pane) atlas)
  "Initialize terminal pane: create screen, fork PTY, set up VT handler."
  (when (vt-pane-initialized-p pane)
    (return-from pane-initialize nil))  ; already initialized
  ;; Initialize screen and VT handler (shared code)
  (vt-pane-init-screen pane atlas)
  ;; Fork PTY if command is provided
  (let ((command (uterm-pane-command pane)))
    (when command
      (let* ((width (pane-width pane))
             (height (pane-height pane))
             (args (uterm-pane-args pane))
             (pty (lexter/pty:pty-fork command :cols width :rows height :args args)))
        (lexter/pty:pty-set-nonblocking pty)
        (setf (uterm-pane-pty pane) pty))))
  t)

;;; --------------------------------------------------------------------------
;;; Convenience accessors (for backward compatibility)
;;; --------------------------------------------------------------------------

(defun uterm-pane-screen (pane)
  "Return the screen for this uterm-pane."
  (vt-pane-screen pane))

(defun uterm-pane-vt-handler (pane)
  "Return the VT handler for this uterm-pane."
  (vt-pane-vt-handler pane))

(defun uterm-pane-alive-p (pane)
  "Return T if the terminal's child process is still running."
  (vt-pane-backend-alive-p pane))
