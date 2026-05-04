;;;; Telnet pane: a VT terminal pane that connects over telnet/raw TCP.
;;;;
;;;; Uses the shared vt-pane infrastructure for VT100/xterm emulation,
;;;; with the telnet client providing the network I/O backend.

(in-package #:lexter/telnet-pane)

;;; --------------------------------------------------------------------------
;;; Telnet pane class
;;; --------------------------------------------------------------------------

(defclass telnet-pane (lexter/panes:vt-pane)
  (;; Connection configuration
   (host     :initarg :host
             :accessor telnet-pane-host
             :initform nil
             :type (or null string)
             :documentation "Host to connect to.")
   (port     :initarg :port
             :accessor telnet-pane-port
             :initform 23
             :type (unsigned-byte 16)
             :documentation "Port to connect to.")
   (mode     :initarg :mode
             :accessor telnet-pane-mode
             :initform :telnet
             :type keyword
             :documentation "Connection mode: :telnet or :raw.")
   (encoding :initarg :encoding
             :accessor telnet-pane-encoding
             :initform :utf8
             :type keyword
             :documentation "Character encoding: :utf8 or :cp437.")
   (bold-as-bright :initarg :bold-as-bright
                   :accessor telnet-pane-bold-as-bright
                   :initform t
                   :type boolean
                   :documentation "When T, bold promotes fg 0-7 to bright 8-15.")
   (ttype    :initarg :ttype
             :accessor telnet-pane-ttype
             :initform "ANSI"
             :type string
             :documentation "Terminal type to report via TTYPE negotiation.")
   ;; Runtime state
   (client   :accessor telnet-pane-client
             :initform nil
             :documentation "Telnet client instance."))
  (:documentation "A pane that provides VT terminal emulation over telnet or raw TCP.
   Construct with :host, :port, :mode, :encoding, :ttype, then call pane-initialize."))

;;; --------------------------------------------------------------------------
;;; Constructor helper
;;; --------------------------------------------------------------------------

(defun make-telnet-pane (&key host (port 23) (mode :telnet) (encoding :utf8)
                              (bold-as-bright t)
                              (ttype "ANSI") (width 80) (height 24)
                              (col 0) (row 0))
  "Create a new telnet-pane with the given configuration."
  (make-instance 'telnet-pane
                 :host host
                 :port port
                 :mode mode
                 :encoding encoding
                 :bold-as-bright bold-as-bright
                 :ttype ttype
                 :width width
                 :height height
                 :col col
                 :row row))

;;; --------------------------------------------------------------------------
;;; Abstract interface implementations (telnet backend)
;;; --------------------------------------------------------------------------

(defmethod lexter/panes:vt-pane-write-bytes ((pane telnet-pane) buffer &key end)
  "Write bytes to the telnet connection."
  (let ((client (telnet-pane-client pane)))
    (when client
      (lexter/telnet:telnet-write client buffer :end end))))

(defmethod lexter/panes:vt-pane-read-bytes ((pane telnet-pane) buffer)
  "Read available bytes from telnet. Returns count or 0.
   For CP437 encoding, translates bytes to Unicode codepoints in-place."
  (let ((client (telnet-pane-client pane)))
    (unless client
      (return-from lexter/panes:vt-pane-read-bytes 0))
    (let ((n (lexter/telnet:telnet-read client buffer)))
      ;; If using CP437, translate bytes to Unicode
      ;; Note: This expands bytes to multi-byte UTF-8, but since we're
      ;; feeding to the VT handler which expects UTF-8, we need a different approach.
      ;; For now, we'll handle CP437 at the VT handler level via encoding mode.
      n)))

(defmethod lexter/panes:vt-pane-backend-alive-p ((pane telnet-pane))
  "Return T if the telnet connection is still alive."
  (let ((client (telnet-pane-client pane)))
    (and client (lexter/telnet:telnet-connected-p client))))

(defmethod lexter/panes:vt-pane-backend-destroy ((pane telnet-pane))
  "Close the telnet connection."
  (let ((client (telnet-pane-client pane)))
    (when client
      (lexter/telnet:telnet-disconnect client))))

(defmethod lexter/panes:vt-pane-backend-resize ((pane telnet-pane) cols rows)
  "Notify the telnet server of a terminal size change via NAWS."
  (let ((client (telnet-pane-client pane)))
    (when client
      (setf (lexter/telnet::telnet-client-cols client) cols
            (lexter/telnet::telnet-client-rows client) rows)
      (lexter/telnet:telnet-send-naws client))))

(defmethod lexter/panes:vt-pane-write-string ((pane telnet-pane) string)
  "Write a string to the telnet connection."
  (let ((client (telnet-pane-client pane)))
    (when (and client (lexter/telnet:telnet-connected-p client))
      (lexter/telnet:telnet-write-string client string))))

;;; --------------------------------------------------------------------------
;;; Initialization
;;; --------------------------------------------------------------------------

(defmethod lexter/panes:pane-initialize ((pane telnet-pane) atlas)
  "Initialize telnet pane: create screen, VT handler, and connect to server."
  (when (lexter/panes:vt-pane-initialized-p pane)
    (return-from lexter/panes:pane-initialize nil))  ; already initialized
  ;; Initialize screen and VT handler (shared code)
  ;; Pass encoding and bold-as-bright from pane slots
  (lexter/panes:vt-pane-init-screen pane atlas
                                     :encoding (telnet-pane-encoding pane)
                                     :bold-as-bright (telnet-pane-bold-as-bright pane))
  ;; Create and connect telnet client
  (let ((host (telnet-pane-host pane)))
    (when host
      (let ((client (lexter/telnet:make-telnet-client
                     :host host
                     :port (telnet-pane-port pane)
                     :mode (telnet-pane-mode pane)
                     :ttype (telnet-pane-ttype pane)
                     :cols (lexter/panes:pane-width pane)
                     :rows (lexter/panes:pane-height pane))))
        (setf (telnet-pane-client pane) client)
        (lexter/telnet:telnet-connect client))))
  t)
