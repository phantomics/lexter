;;;; Terminal pane: a pane that owns a PTY, screen, and VT handler.
;;;;
;;;; This is the core shell session pane type.

(in-package #:pcf-gl/panes)

;;; --------------------------------------------------------------------------
;;; Constants and key sequences (from unix-term.lisp)
;;; --------------------------------------------------------------------------

(defconstant +esc+ #x1B)

(defun %bytes (&rest values)
  "Create a (simple-array (unsigned-byte 8) (*)) from VALUES."
  (make-array (length values)
              :element-type '(unsigned-byte 8)
              :initial-contents values))

(defparameter *key-sequences*
  (list
   ;; Arrow keys
   (cons :up        (%bytes +esc+ #x5B #x41))
   (cons :down      (%bytes +esc+ #x5B #x42))
   (cons :right     (%bytes +esc+ #x5B #x43))
   (cons :left      (%bytes +esc+ #x5B #x44))
   ;; Navigation
   (cons :home      (%bytes +esc+ #x5B #x48))
   (cons :end       (%bytes +esc+ #x5B #x46))
   (cons :page-up   (%bytes +esc+ #x5B #x35 #x7E))
   (cons :page-down (%bytes +esc+ #x5B #x36 #x7E))
   (cons :insert    (%bytes +esc+ #x5B #x32 #x7E))
   (cons :delete    (%bytes +esc+ #x5B #x33 #x7E))
   ;; Function keys
   (cons :f1        (%bytes +esc+ #x4F #x50))
   (cons :f2        (%bytes +esc+ #x4F #x51))
   (cons :f3        (%bytes +esc+ #x4F #x52))
   (cons :f4        (%bytes +esc+ #x4F #x53))
   (cons :f5        (%bytes +esc+ #x5B #x31 #x35 #x7E))
   (cons :f6        (%bytes +esc+ #x5B #x31 #x37 #x7E))
   (cons :f7        (%bytes +esc+ #x5B #x31 #x38 #x7E))
   (cons :f8        (%bytes +esc+ #x5B #x31 #x39 #x7E))
   (cons :f9        (%bytes +esc+ #x5B #x32 #x30 #x7E))
   (cons :f10       (%bytes +esc+ #x5B #x32 #x31 #x7E))
   (cons :f11       (%bytes +esc+ #x5B #x32 #x33 #x7E))
   (cons :f12       (%bytes +esc+ #x5B #x32 #x34 #x7E))
   ;; Special
   (cons :backspace (%bytes #x7F))
   (cons :tab       (%bytes #x09))
   (cons :enter     (%bytes #x0D))
   (cons :escape    (%bytes +esc+)))
  "Mapping from GLFW key symbols to byte sequences.")

;;; --------------------------------------------------------------------------
;;; Terminal pane class
;;; --------------------------------------------------------------------------

(defclass terminal-pane (pane)
  (;; Configuration (set at construction time)
   (command     :initarg :command
                :accessor terminal-pane-command
                :initform nil
                :documentation "Command to run (e.g. \"/bin/bash\").")
   (args        :initarg :args
                :accessor terminal-pane-args
                :initform nil
                :documentation "Arguments to pass to command.")
   ;; Runtime state (set by pane-initialize)
   (pty         :accessor terminal-pane-pty
                :initform nil
                :documentation "PTY handle for this terminal session.")
   (screen      :accessor terminal-pane-screen
                :initform nil
                :documentation "Screen model for this terminal.")
   (vt-handler  :accessor terminal-pane-vt-handler
                :initform nil
                :documentation "VT parser/handler for this terminal.")
   (initialized :accessor terminal-pane-initialized-p
                :initform nil
                :type boolean
                :documentation "Has pane-initialize been called?")
   ;; I/O buffers
   (read-buffer :accessor terminal-pane-read-buffer
                :initform (make-array 4096 :element-type '(unsigned-byte 8))
                :documentation "Buffer for reading PTY output.")
   (write-buffer :accessor terminal-pane-write-buffer
                 :initform (make-array 8 :element-type '(unsigned-byte 8))
                 :documentation "Buffer for writing to PTY.")
   (uc-scratch   :accessor terminal-pane-uc-scratch
                 :initform (make-string 1)
                 :documentation "Scratch string for Unicode encoding."))
  (:documentation "A pane containing a terminal session (PTY + screen + VT).
   Construct with :command and :args, then call pane-initialize with an atlas."))

;;; --------------------------------------------------------------------------
;;; UTF-8 encoding support
;;; --------------------------------------------------------------------------

(defvar *utf8-mapping*
  (babel::lookup-mapping babel::*string-vector-mappings* :utf-8))

;;; --------------------------------------------------------------------------
;;; Initialization (called by compositor after atlas is ready)
;;; --------------------------------------------------------------------------

(defmethod pane-initialize ((pane terminal-pane) atlas)
  "Initialize terminal pane: create screen, fork PTY, set up VT handler."
  (when (terminal-pane-initialized-p pane)
    (return-from pane-initialize nil))  ; already initialized
  (let* ((width (pane-width pane))
         (height (pane-height pane))
         (command (terminal-pane-command pane))
         (args (terminal-pane-args pane))
         (screen (pcf-gl/model:make-screen :cols width :rows height)))
    ;; Set blank glyph from atlas
    (when atlas
      (let ((space-idx (pcf-gl/atlas:atlas-glyph-index atlas 32)))
        (when space-idx
          (setf (pcf-gl/model:screen-blank-glyph screen) space-idx))))
    ;; Store screen
    (setf (terminal-pane-screen pane) screen)
    ;; Fork PTY if command is provided
    (when command
      (let ((pty (pcf-gl/pty:pty-fork command :cols width :rows height :args args)))
        (pcf-gl/pty:pty-set-nonblocking pty)
        (setf (terminal-pane-pty pane) pty)
        ;; Set up VT handler
        (setf (terminal-pane-vt-handler pane)
              (pcf-gl/vt-handler:make-vt-handler
               screen atlas
               :callback (make-terminal-pane-callback pane)))))
    (setf (terminal-pane-initialized-p pane) t)
    t))

(defun make-terminal-pane-callback (pane)
  "Create callback function for VT handler events."
  (lambda (type data)
    (case type
      (:bell nil)  ; TODO: visual bell
      (:set-title
       (glfw:set-window-title data))
      (:report-cursor
       (when (and (terminal-pane-pty pane)
                  (pcf-gl/pty:pty-alive-p (terminal-pane-pty pane)))
         (pcf-gl/pty:pty-write-string (terminal-pane-pty pane) data)))
      (otherwise nil))))

;;; --------------------------------------------------------------------------
;;; Protocol implementations
;;; --------------------------------------------------------------------------

;; Global cursor blink state, set by compositor
(defvar *cursor-blink-on* t)

(defmethod pane-flush ((pane terminal-pane) grid)
  "Flush terminal screen content to grid at pane's offset."
  (when (terminal-pane-screen pane)
    (pcf-gl/model:flush-to-display
     (terminal-pane-screen pane) grid
     :col-offset (pane-col pane)
     :row-offset (pane-row pane)
     :space-glyph (pcf-gl/model:screen-blank-glyph (terminal-pane-screen pane))
     :cursor-blink-on *cursor-blink-on*)))

(defmethod pane-handle-key ((pane terminal-pane) key scancode action mods)
  "Send key sequence to terminal's PTY."
  (declare (ignore scancode))
  (when (and (terminal-pane-pty pane)
             (member action '(:press :repeat))
             (pcf-gl/pty:pty-alive-p (terminal-pane-pty pane)))
    (let ((n (%key-to-bytes key mods (terminal-pane-write-buffer pane))))
      (unless (zerop n)
        (pcf-gl/pty:pty-write (terminal-pane-pty pane)
                               (terminal-pane-write-buffer pane)
                               :end n)
        t))))

(defun %key-to-bytes (key mods buffer)
  "Convert a GLFW key press to bytes. Returns number of bytes written."
  (let ((ctrl-p  (member :control mods))
        (shift-p (member :shift   mods))
        (alt-p   (member :alt     mods)))
    (cond
      ;; Control+key combinations
      ((and ctrl-p (symbolp key))
       (let ((name (symbol-name key)))
         (when (and (= (length name) 1)
                    (alpha-char-p (char name 0)))
           (let ((code (- (char-code (char-upcase (char name 0))) 64)))
             (when (<= 1 code 26)
               (setf (aref buffer 0) code)
               (return-from %key-to-bytes 1))))))
      ;; Alt+key - send ESC prefix
      ((and alt-p (symbolp key))
       (let ((name (symbol-name key)))
         (when (and (= (length name) 1)
                    (alpha-char-p (char name 0)))
           (let ((ch (if shift-p
                         (char-upcase (char name 0))
                         (char-downcase (char name 0)))))
             (setf (aref buffer 0) +esc+
                   (aref buffer 1) (char-code ch))
             (return-from %key-to-bytes 2)))))
      ;; Special keys from table
      (t (let ((seq-form (assoc key *key-sequences*)))
           (when seq-form
             (loop :for cx :from 0
                   :for byte :across (cdr seq-form)
                   :do (setf (aref buffer cx) byte)
                   :finally (return-from %key-to-bytes cx))))))
    0))

(defmethod pane-handle-char ((pane terminal-pane) codepoint)
  "Send UTF-8 encoded character to terminal's PTY."
  (when (and (terminal-pane-pty pane)
             (pcf-gl/pty:pty-alive-p (terminal-pane-pty pane)))
    (setf (aref (terminal-pane-uc-scratch pane) 0)
          (code-char (if (characterp codepoint) (char-code codepoint) codepoint)))
    (let ((n (funcall (babel::encoder *utf8-mapping*)
                      (terminal-pane-uc-scratch pane) 0 1
                      (terminal-pane-write-buffer pane) 0)))
      (pcf-gl/pty:pty-write (terminal-pane-pty pane)
                             (terminal-pane-write-buffer pane)
                             :end n))
    t))

(defmethod pane-process-output ((pane terminal-pane))
  "Read and process any available PTY output."
  (unless (terminal-pane-pty pane)
    (return-from pane-process-output nil))
  (let ((pty (terminal-pane-pty pane))
        (buf (terminal-pane-read-buffer pane))
        (handler (terminal-pane-vt-handler pane))
        (processed nil))
    (loop
      (let ((status (pcf-gl/pty:pty-poll pty 0)))
        (case status
          (:readable
           (let ((n (pcf-gl/pty:pty-read pty buf)))
             (when (> n 0)
               (pcf-gl/vt-handler:process-output handler buf :start 0 :end n)
               (setf processed t))))
          (otherwise
           (return processed)))))))

(defmethod pane-resize ((pane terminal-pane) new-width new-height)
  "Resize terminal screen and notify PTY."
  (setf (pane-width pane) new-width
        (pane-height pane) new-height)
  (when (terminal-pane-screen pane)
    (pcf-gl/model:resize-screen (terminal-pane-screen pane) new-width new-height))
  (when (terminal-pane-pty pane)
    (pcf-gl/pty:pty-set-size (terminal-pane-pty pane) new-width new-height)))

(defmethod pane-dirty-p ((pane terminal-pane))
  "Check if terminal screen has dirty rows."
  (and (terminal-pane-screen pane)
       (pcf-gl/model:any-row-dirty-p (terminal-pane-screen pane))))

(defmethod pane-destroy ((pane terminal-pane))
  "Close the terminal's PTY."
  (when (terminal-pane-pty pane)
    (pcf-gl/pty:pty-close (terminal-pane-pty pane))))

;;; --------------------------------------------------------------------------
;;; Utility
;;; --------------------------------------------------------------------------

(defun terminal-pane-alive-p (pane)
  "Return T if the terminal's child process is still running."
  (and (terminal-pane-pty pane)
       (pcf-gl/pty:pty-alive-p (terminal-pane-pty pane))))
