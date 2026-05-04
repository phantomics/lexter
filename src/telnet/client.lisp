;;;; Telnet client library
;;;;
;;;; Handles TCP connection, telnet option negotiation (ECHO, SGA, TTYPE, NAWS, BINARY),
;;;; and IAC sequence processing. Supports both telnet mode and raw TCP mode.

(in-package #:lexter/telnet)

;;; --------------------------------------------------------------------------
;;; Telnet protocol constants
;;; --------------------------------------------------------------------------

;; IAC (Interpret As Command) and command bytes
(defconstant +iac+  255)   ; Interpret As Command
(defconstant +dont+ 254)   ; Don't do option
(defconstant +do+   253)   ; Do option
(defconstant +wont+ 252)   ; Won't do option
(defconstant +will+ 251)   ; Will do option
(defconstant +sb+   250)   ; Subnegotiation Begin
(defconstant +ga+   249)   ; Go Ahead
(defconstant +el+   248)   ; Erase Line
(defconstant +ec+   247)   ; Erase Character
(defconstant +ayt+  246)   ; Are You There
(defconstant +ao+   245)   ; Abort Output
(defconstant +ip+   244)   ; Interrupt Process
(defconstant +brk+  243)   ; Break
(defconstant +dm+   242)   ; Data Mark
(defconstant +nop+  241)   ; No Operation
(defconstant +se+   240)   ; Subnegotiation End

;; Option codes
(defconstant +opt-binary+   0)   ; Binary Transmission
(defconstant +opt-echo+     1)   ; Echo
(defconstant +opt-sga+      3)   ; Suppress Go Ahead
(defconstant +opt-ttype+   24)   ; Terminal Type
(defconstant +opt-naws+    31)   ; Negotiate About Window Size

;; TTYPE subnegotiation
(defconstant +ttype-is+     0)   ; Terminal type IS
(defconstant +ttype-send+   1)   ; SEND terminal type

;;; --------------------------------------------------------------------------
;;; Telnet client struct
;;; --------------------------------------------------------------------------

(defstruct telnet-client
  "A telnet client connection."
  (host        nil :type (or null string))
  (port        23  :type (unsigned-byte 16))
  (socket      nil :type (or null usocket:stream-usocket))
  (stream      nil :type (or null stream))
  ;; Mode: :telnet (negotiate options, strip IAC) or :raw (pass through everything)
  (mode        :telnet :type keyword)
  ;; Terminal type to report (e.g., "ANSI", "VT100", "XTERM")
  (ttype       "ANSI" :type string)
  ;; Current terminal dimensions (for NAWS)
  (cols        80 :type (unsigned-byte 16))
  (rows        24 :type (unsigned-byte 16))
  ;; Receive buffer
  (recv-buffer (make-array 4096 :element-type '(unsigned-byte 8))
               :type (simple-array (unsigned-byte 8) (*)))
  (recv-fill   0 :type fixnum)
  ;; IAC state machine: :normal, :saw-iac, :saw-will/wont/do/dont, :in-sb, :sb-data
  (iac-state   :normal :type keyword)
  (iac-command 0 :type (unsigned-byte 8))
  ;; Subnegotiation buffer
  (sb-buffer   (make-array 256 :element-type '(unsigned-byte 8))
               :type (simple-array (unsigned-byte 8) (*)))
  (sb-fill     0 :type fixnum)
  (sb-option   0 :type (unsigned-byte 8))
  ;; Negotiated state (which options are active)
  (local-echo  nil :type boolean)   ; We are echoing locally (server requested WILL ECHO, we said DO)
  (binary-mode nil :type boolean))  ; Binary transmission mode active

;;; --------------------------------------------------------------------------
;;; Connection management
;;; --------------------------------------------------------------------------

(defun telnet-connect (client)
  "Connect to the telnet server. Returns T on success, NIL on failure."
  (handler-case
      (let* ((socket (usocket:socket-connect (telnet-client-host client)
                                              (telnet-client-port client)
                                              :element-type '(unsigned-byte 8)))
             (stream (usocket:socket-stream socket)))
        (setf (telnet-client-socket client) socket
              (telnet-client-stream client) stream
              (telnet-client-recv-fill client) 0
              (telnet-client-iac-state client) :normal
              (telnet-client-sb-fill client) 0
              (telnet-client-local-echo client) nil
              (telnet-client-binary-mode client) nil)
        t)
    (error (e)
      (declare (ignore e))
      nil)))

(defun telnet-disconnect (client)
  "Disconnect from the telnet server."
  (when (telnet-client-socket client)
    (ignore-errors
      (usocket:socket-close (telnet-client-socket client)))
    (setf (telnet-client-socket client) nil
          (telnet-client-stream client) nil)))

(defun telnet-connected-p (client)
  "Return T if the client is connected."
  (and (telnet-client-socket client)
       (telnet-client-stream client)
       (open-stream-p (telnet-client-stream client))))

;;; --------------------------------------------------------------------------
;;; Low-level I/O
;;; --------------------------------------------------------------------------

(defun %send-bytes (client &rest bytes)
  "Send raw bytes to the server."
  (let ((stream (telnet-client-stream client)))
    (dolist (b bytes)
      (write-byte b stream))
    (force-output stream)))

(defun %send-iac (client command &optional option)
  "Send an IAC command sequence."
  (if option
      (%send-bytes client +iac+ command option)
      (%send-bytes client +iac+ command)))

;;; --------------------------------------------------------------------------
;;; Telnet option negotiation
;;; --------------------------------------------------------------------------

(defun %handle-will (client option)
  "Handle WILL option from server."
  (case option
    ;; ECHO: Server will echo, we say DO (and note we should not local-echo)
    (#.+opt-echo+
     (%send-iac client +do+ option)
     (setf (telnet-client-local-echo client) nil))
    ;; SGA: Server will suppress go-ahead, we say DO
    (#.+opt-sga+
     (%send-iac client +do+ option))
    ;; BINARY: Server will send binary, we say DO
    (#.+opt-binary+
     (%send-iac client +do+ option)
     (setf (telnet-client-binary-mode client) t))
    ;; Unknown option: refuse
    (otherwise
     (%send-iac client +dont+ option))))

(defun %handle-wont (client option)
  "Handle WONT option from server."
  (declare (ignore client option))
  ;; Server won't do something, that's fine
  nil)

(defun %handle-do (client option)
  "Handle DO option from server (server asks us to enable something)."
  (case option
    ;; TTYPE: Server wants to know our terminal type
    (#.+opt-ttype+
     (%send-iac client +will+ option))
    ;; NAWS: Server wants window size
    (#.+opt-naws+
     (%send-iac client +will+ option)
     ;; Immediately send our window size
     (telnet-send-naws client))
    ;; BINARY: Server wants us to send binary
    (#.+opt-binary+
     (%send-iac client +will+ option))
    ;; SGA: Server wants us to suppress go-ahead
    (#.+opt-sga+
     (%send-iac client +will+ option))
    ;; ECHO: Server wants us to echo (unusual, but possible)
    (#.+opt-echo+
     (%send-iac client +will+ option)
     (setf (telnet-client-local-echo client) t))
    ;; Unknown: refuse
    (otherwise
     (%send-iac client +wont+ option))))

(defun %handle-dont (client option)
  "Handle DONT option from server."
  ;; Just acknowledge we won't do it
  (%send-iac client +wont+ option))

(defun %handle-subnegotiation (client option data length)
  "Handle completed subnegotiation."
  (case option
    ;; TTYPE: Server is requesting terminal type
    (#.+opt-ttype+
     (when (and (> length 0) (= (aref data 0) +ttype-send+))
       ;; Send: IAC SB TTYPE IS <type> IAC SE
       (let* ((ttype (telnet-client-ttype client))
              (stream (telnet-client-stream client)))
         (write-byte +iac+ stream)
         (write-byte +sb+ stream)
         (write-byte +opt-ttype+ stream)
         (write-byte +ttype-is+ stream)
         (loop for c across ttype
               do (write-byte (char-code c) stream))
         (write-byte +iac+ stream)
         (write-byte +se+ stream)
         (force-output stream))))
    (otherwise nil)))

;;; --------------------------------------------------------------------------
;;; Send NAWS (window size)
;;; --------------------------------------------------------------------------

(defun telnet-send-naws (client)
  "Send the current window size via NAWS subnegotiation."
  (when (telnet-connected-p client)
    (let ((stream (telnet-client-stream client))
          (cols (telnet-client-cols client))
          (rows (telnet-client-rows client)))
      ;; IAC SB NAWS <cols-hi> <cols-lo> <rows-hi> <rows-lo> IAC SE
      ;; Note: if any byte is 255, it must be doubled (IAC IAC)
      (write-byte +iac+ stream)
      (write-byte +sb+ stream)
      (write-byte +opt-naws+ stream)
      ;; Cols high byte
      (let ((ch (ash cols -8)))
        (write-byte ch stream)
        (when (= ch 255) (write-byte 255 stream)))
      ;; Cols low byte
      (let ((cl (logand cols #xFF)))
        (write-byte cl stream)
        (when (= cl 255) (write-byte 255 stream)))
      ;; Rows high byte
      (let ((rh (ash rows -8)))
        (write-byte rh stream)
        (when (= rh 255) (write-byte 255 stream)))
      ;; Rows low byte
      (let ((rl (logand rows #xFF)))
        (write-byte rl stream)
        (when (= rl 255) (write-byte 255 stream)))
      (write-byte +iac+ stream)
      (write-byte +se+ stream)
      (force-output stream))))

;;; --------------------------------------------------------------------------
;;; IAC state machine
;;; --------------------------------------------------------------------------

(defun %process-telnet-byte (client byte output-buffer output-fill)
  "Process a single byte through the telnet state machine.
   Returns the new output-fill position."
  (let ((state (telnet-client-iac-state client)))
    (case state
      (:normal
       (if (= byte +iac+)
           (setf (telnet-client-iac-state client) :saw-iac)
           ;; Regular data byte
           (progn
             (setf (aref output-buffer output-fill) byte)
             (incf output-fill))))

      (:saw-iac
       (case byte
         ;; Doubled IAC = literal 255
         (#.+iac+
          (setf (aref output-buffer output-fill) 255)
          (incf output-fill)
          (setf (telnet-client-iac-state client) :normal))
         ;; Negotiation commands
         (#.+will+
          (setf (telnet-client-iac-command client) +will+
                (telnet-client-iac-state client) :saw-command))
         (#.+wont+
          (setf (telnet-client-iac-command client) +wont+
                (telnet-client-iac-state client) :saw-command))
         (#.+do+
          (setf (telnet-client-iac-command client) +do+
                (telnet-client-iac-state client) :saw-command))
         (#.+dont+
          (setf (telnet-client-iac-command client) +dont+
                (telnet-client-iac-state client) :saw-command))
         ;; Subnegotiation begin
         (#.+sb+
          (setf (telnet-client-sb-fill client) 0
                (telnet-client-iac-state client) :saw-sb))
         ;; Other IAC commands (NOP, GA, etc) - ignore
         (otherwise
          (setf (telnet-client-iac-state client) :normal))))

      (:saw-command
       ;; This byte is the option number
       (let ((cmd (telnet-client-iac-command client)))
         (case cmd
           (#.+will+ (%handle-will client byte))
           (#.+wont+ (%handle-wont client byte))
           (#.+do+   (%handle-do client byte))
           (#.+dont+ (%handle-dont client byte))))
       (setf (telnet-client-iac-state client) :normal))

      (:saw-sb
       ;; First byte after SB is the option
       (setf (telnet-client-sb-option client) byte
             (telnet-client-iac-state client) :in-sb))

      (:in-sb
       (if (= byte +iac+)
           (setf (telnet-client-iac-state client) :sb-iac)
           ;; Subnegotiation data byte
           (let ((fill (telnet-client-sb-fill client)))
             (when (< fill (length (telnet-client-sb-buffer client)))
               (setf (aref (telnet-client-sb-buffer client) fill) byte)
               (incf (telnet-client-sb-fill client))))))

      (:sb-iac
       (case byte
         ;; IAC IAC in subnegotiation = literal 255
         (#.+iac+
          (let ((fill (telnet-client-sb-fill client)))
            (when (< fill (length (telnet-client-sb-buffer client)))
              (setf (aref (telnet-client-sb-buffer client) fill) 255)
              (incf (telnet-client-sb-fill client))))
          (setf (telnet-client-iac-state client) :in-sb))
         ;; SE ends subnegotiation
         (#.+se+
          (%handle-subnegotiation client
                                   (telnet-client-sb-option client)
                                   (telnet-client-sb-buffer client)
                                   (telnet-client-sb-fill client))
          (setf (telnet-client-iac-state client) :normal))
         ;; Unexpected - treat as end of SB
         (otherwise
          (setf (telnet-client-iac-state client) :normal))))))
  output-fill)

;;; --------------------------------------------------------------------------
;;; High-level read/write
;;; --------------------------------------------------------------------------

(defun telnet-read (client output-buffer)
  "Read available data from the telnet connection into OUTPUT-BUFFER.
   In :telnet mode, strips IAC sequences and handles negotiation.
   In :raw mode, passes all bytes through unchanged.
   Returns the number of data bytes placed in OUTPUT-BUFFER, or 0 if none available."
  (unless (telnet-connected-p client)
    (return-from telnet-read 0))
  (let ((stream (telnet-client-stream client)))
    ;; Check if data is available (non-blocking)
    (handler-case
        (progn
          ;; Use listen to check for available data
          (unless (listen stream)
            (return-from telnet-read 0))
          ;; Read available bytes into internal buffer
          (let* ((buf (telnet-client-recv-buffer client))
                 (n (read-sequence buf stream)))
            (when (zerop n)
              (return-from telnet-read 0))
            ;; Process bytes
            (if (eq (telnet-client-mode client) :raw)
                ;; Raw mode: copy directly
                (progn
                  (replace output-buffer buf :end2 n)
                  n)
                ;; Telnet mode: process through state machine
                (let ((output-fill 0))
                  (loop for i from 0 below n
                        do (setf output-fill
                                 (%process-telnet-byte client (aref buf i)
                                                        output-buffer output-fill)))
                  output-fill))))
      (error ()
        0))))

(defun telnet-write (client buffer &key (start 0) end)
  "Write bytes to the telnet connection.
   In :telnet mode, escapes any IAC (255) bytes by doubling them.
   In :raw mode, sends bytes unchanged."
  (unless (telnet-connected-p client)
    (return-from telnet-write nil))
  (let ((stream (telnet-client-stream client))
        (end (or end (length buffer))))
    (if (eq (telnet-client-mode client) :raw)
        ;; Raw mode: write directly
        (write-sequence buffer stream :start start :end end)
        ;; Telnet mode: escape IAC bytes
        (loop for i from start below end
              for byte = (aref buffer i)
              do (write-byte byte stream)
                 (when (= byte 255)
                   (write-byte 255 stream))))  ; Double the IAC
    (force-output stream)
    t))

(defun telnet-write-string (client string)
  "Write a string to the telnet connection as ASCII bytes."
  (unless (telnet-connected-p client)
    (return-from telnet-write-string nil))
  (let ((stream (telnet-client-stream client)))
    (loop for c across string
          for code = (char-code c)
          do (write-byte (logand code #x7F) stream)  ; ASCII only
             (when (and (eq (telnet-client-mode client) :telnet)
                        (= code 255))
               (write-byte 255 stream)))
    (force-output stream)
    t))
