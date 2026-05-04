;;;; VT terminal base pane: shared infrastructure for VT100/xterm emulation.
;;;;
;;;; This provides the screen model, VT handler, key encoding, and grid rendering
;;;; that is common to all VT-style terminal panes. Subclasses provide the I/O backend.

(in-package #:lexter/panes)

;;; --------------------------------------------------------------------------
;;; Constants and key sequences
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

;; Global cursor blink state, set by compositor
(defvar *cursor-blink-on* t)

;;; --------------------------------------------------------------------------
;;; VT terminal base pane class
;;; --------------------------------------------------------------------------

(defclass vt-pane (pane)
  (;; Runtime state (set by pane-initialize or subclass)
   (screen      :accessor vt-pane-screen
                :initform nil
                :documentation "Screen model for this terminal.")
   (vt-handler  :accessor vt-pane-vt-handler
                :initform nil
                :documentation "VT parser/handler for this terminal.")
   (initialized :accessor vt-pane-initialized-p
                :initform nil
                :type boolean
                :documentation "Has pane-initialize been called?")
   ;; I/O buffers
   (read-buffer :accessor vt-pane-read-buffer
                :initform (make-array 4096 :element-type '(unsigned-byte 8))
                :documentation "Buffer for reading backend output.")
   (write-buffer :accessor vt-pane-write-buffer
                 :initform (make-array 8 :element-type '(unsigned-byte 8))
                 :documentation "Buffer for writing to backend.")
   (uc-scratch   :accessor vt-pane-uc-scratch
                 :initform (make-string 1)
                 :documentation "Scratch string for Unicode encoding."))
  (:documentation "Base class for VT100/xterm-style terminal panes.
   Provides screen model, VT handler, key encoding, and grid rendering.
   Subclasses implement the I/O backend via abstract methods."))

;;; --------------------------------------------------------------------------
;;; Abstract interface (subclasses must implement these)
;;; --------------------------------------------------------------------------

(defgeneric vt-pane-write-bytes (pane buffer &key end)
  (:documentation "Write bytes to the backend. BUFFER is an octet vector,
   END is the number of bytes to write (defaults to length of buffer)."))

(defgeneric vt-pane-read-bytes (pane buffer)
  (:documentation "Read available bytes from backend into BUFFER.
   Returns number of bytes read, or 0 if nothing available."))

(defgeneric vt-pane-backend-alive-p (pane)
  (:documentation "Return T if the backend connection is still alive."))

(defgeneric vt-pane-backend-destroy (pane)
  (:documentation "Tear down the backend connection."))

(defgeneric vt-pane-backend-resize (pane cols rows)
  (:documentation "Notify the backend of a terminal size change."))

(defgeneric vt-pane-write-string (pane string)
  (:documentation "Write a string to the backend (for cursor reports etc)."))

;;; --------------------------------------------------------------------------
;;; UTF-8 encoding support
;;; --------------------------------------------------------------------------

(defvar *utf8-mapping*
  (babel::lookup-mapping babel::*string-vector-mappings* :utf-8))

;;; --------------------------------------------------------------------------
;;; Key encoding
;;; --------------------------------------------------------------------------

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

;;; --------------------------------------------------------------------------
;;; VT handler callback factory
;;; --------------------------------------------------------------------------

(defun make-vt-pane-callback (pane)
  "Create callback function for VT handler events."
  (lambda (type data)
    (case type
      (:bell nil)  ; TODO: visual bell
      (:set-title
       (glfw:set-window-title data))
      (:report-cursor
       (when (vt-pane-backend-alive-p pane)
         (vt-pane-write-string pane data)))
      (otherwise nil))))

;;; --------------------------------------------------------------------------
;;; Initialization helper
;;; --------------------------------------------------------------------------

(defun vt-pane-init-screen (pane atlas &key (encoding :utf8) bold-as-bright)
  "Initialize the screen and VT handler for a vt-pane. Called by subclasses.
   ENCODING is :utf8 (default) or :cp437 (for BBS/DOS compatibility).
   BOLD-AS-BRIGHT when T promotes fg colors 0-7 to 8-15 when bold is set."
  (let* ((width (pane-width pane))
         (height (pane-height pane))
         (screen (lexter/model:make-screen :cols width :rows height)))
    ;; Set blank glyph from atlas
    (when atlas
      (let ((space-idx (lexter/atlas:atlas-glyph-index atlas 32)))
        (when space-idx
          (setf (lexter/model:screen-blank-glyph screen) space-idx))))
    ;; Store screen
    (setf (vt-pane-screen pane) screen)
    ;; Set up VT handler
    (setf (vt-pane-vt-handler pane)
          (lexter/vt-handler:make-vt-handler
           screen atlas
           :callback (make-vt-pane-callback pane)
           :encoding encoding
           :bold-as-bright bold-as-bright))
    (setf (vt-pane-initialized-p pane) t)
    screen))

;;; --------------------------------------------------------------------------
;;; Protocol implementations (shared by all VT panes)
;;; --------------------------------------------------------------------------

(defmethod pane-flush ((pane vt-pane) grid)
  "Flush terminal screen content to grid at pane's offset."
  (when (vt-pane-screen pane)
    (lexter/model:flush-to-display
     (vt-pane-screen pane) grid
     :col-offset (pane-col pane)
     :row-offset (pane-row pane)
     :space-glyph (lexter/model:screen-blank-glyph (vt-pane-screen pane))
     :cursor-blink-on *cursor-blink-on*)))

(defmethod pane-handle-key ((pane vt-pane) key scancode action mods)
  "Send key sequence to terminal's backend."
  (declare (ignore scancode))
  (when (and (member action '(:press :repeat))
             (vt-pane-backend-alive-p pane))
    (let ((n (%key-to-bytes key mods (vt-pane-write-buffer pane))))
      (unless (zerop n)
        (vt-pane-write-bytes pane (vt-pane-write-buffer pane) :end n)
        t))))

(defmethod pane-handle-char ((pane vt-pane) codepoint)
  "Send UTF-8 encoded character to terminal's backend."
  (when (vt-pane-backend-alive-p pane)
    (setf (aref (vt-pane-uc-scratch pane) 0)
          (code-char (if (characterp codepoint) (char-code codepoint) codepoint)))
    (let ((n (funcall (babel::encoder *utf8-mapping*)
                      (vt-pane-uc-scratch pane) 0 1
                      (vt-pane-write-buffer pane) 0)))
      (vt-pane-write-bytes pane (vt-pane-write-buffer pane) :end n))
    t))

(defmethod pane-process-output ((pane vt-pane))
  "Read and process any available backend output."
  (unless (vt-pane-backend-alive-p pane)
    (return-from pane-process-output nil))
  (let ((buf (vt-pane-read-buffer pane))
        (handler (vt-pane-vt-handler pane))
        (processed nil))
    (loop
      (let ((n (vt-pane-read-bytes pane buf)))
        (cond
          ((and n (> n 0))
           (lexter/vt-handler:process-output handler buf :start 0 :end n)
           (setf processed t))
          (t
           (return processed)))))))

(defmethod pane-resize ((pane vt-pane) new-width new-height)
  "Resize terminal screen and notify backend."
  (setf (pane-width pane) new-width
        (pane-height pane) new-height)
  (when (vt-pane-screen pane)
    (lexter/model:resize-screen (vt-pane-screen pane) new-width new-height))
  (vt-pane-backend-resize pane new-width new-height))

(defmethod pane-dirty-p ((pane vt-pane))
  "Check if terminal screen has dirty rows."
  (and (vt-pane-screen pane)
       (lexter/model:any-row-dirty-p (vt-pane-screen pane))))

(defmethod pane-destroy ((pane vt-pane))
  "Destroy the terminal's backend connection."
  (vt-pane-backend-destroy pane))

(defmethod pane-alive-p ((pane vt-pane))
  "Return T if the terminal's backend is still alive."
  (vt-pane-backend-alive-p pane))
