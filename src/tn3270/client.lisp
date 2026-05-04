;;;; TN3270/TN3270E client.
;;;;
;;;; Handles TCP connection, telnet negotiation, and TN3270E framing.
;;;; Uses usocket for non-blocking I/O.

(in-package #:lexter/tn3270)

;;; --------------------------------------------------------------------------
;;; Telnet constants (from tacle.tn3270/lexicon)
;;; --------------------------------------------------------------------------

(defconstant +iac+ 255 "Telnet IAC (Interpret As Command)")

;;; --------------------------------------------------------------------------
;;; Client structure
;;; --------------------------------------------------------------------------

(defstruct (tn3270-client (:conc-name client-))
  "TN3270 client state."
  ;; Connection
  (socket nil)
  (host "localhost" :type string)
  (port 3270 :type fixnum)
  ;; Negotiation state
  (negotiated nil :type boolean)
  (tn3270e nil :type boolean)  ; using TN3270E protocol?
  (device-type "IBM-3278-2" :type string)
  ;; Screen
  (screen nil :type (or null tn3270-screen))
  ;; Buffers
  (recv-buffer (make-array 8192 :element-type '(unsigned-byte 8))
               :type (simple-array (unsigned-byte 8) (*)))
  (recv-fill 0 :type fixnum)
  (send-buffer (make-array 4096 :element-type '(unsigned-byte 8))
               :type (simple-array (unsigned-byte 8) (*)))
  ;; Callbacks
  (on-screen-update nil :type (or null function))  ; called when screen changes
  (on-disconnect nil :type (or null function)))    ; called on disconnect

;;; --------------------------------------------------------------------------
;;; Connection management
;;; --------------------------------------------------------------------------

(defun client-connect (client)
  "Connect to the 3270 host. Returns T on success, NIL on failure."
  (handler-case
      (let ((sock (usocket:socket-connect (client-host client)
                                          (client-port client)
                                          :element-type '(unsigned-byte 8))))
        (setf (client-socket client) sock
              (client-negotiated client) nil
              (client-tn3270e client) nil
              (client-recv-fill client) 0)
        t)
    (error (c)
      (format *debug-io* "~&Connection failed: ~a~%" c)
      nil)))

(defun client-disconnect (client)
  "Disconnect from the host."
  (when (client-socket client)
    (ignore-errors (usocket:socket-close (client-socket client)))
    (setf (client-socket client) nil
          (client-negotiated client) nil)
    (when (client-on-disconnect client)
      (funcall (client-on-disconnect client)))))

(defun client-connected-p (client)
  "Return T if client is connected."
  (and (client-socket client) t))

;;; --------------------------------------------------------------------------
;;; Low-level I/O
;;; --------------------------------------------------------------------------

(defun client-send-bytes (client bytes &key (start 0) (end nil))
  "Send BYTES to the server."
  (when (client-socket client)
    (let* ((end (or end (length bytes)))
           (stream (usocket:socket-stream (client-socket client))))
      (write-sequence bytes stream :start start :end end)
      (force-output stream))))

(defun client-recv-available (client)
  "Read available bytes into recv-buffer. Returns number of bytes read."
  (when (client-socket client)
    (let* ((sock (client-socket client))
           (buf (client-recv-buffer client))
           (fill (client-recv-fill client))
           (stream (usocket:socket-stream sock))
           (count 0))
      ;; Read bytes one at a time while data is available
      ;; This avoids blocking on read-sequence
      (loop :while (and (listen stream)
                        (< fill (length buf)))
            :do (let ((byte (read-byte stream nil nil)))
                  (if byte
                      (progn
                        (setf (aref buf fill) byte)
                        (incf fill)
                        (incf count))
                      (return))))
      (setf (client-recv-fill client) fill)
      count)))

;;; --------------------------------------------------------------------------
;;; Telnet negotiation
;;; --------------------------------------------------------------------------

(defun send-telnet-response (client will/wont option)
  "Send a telnet WILL/WONT/DO/DONT response."
  (let ((buf (client-send-buffer client)))
    (setf (aref buf 0) +iac+
          (aref buf 1) will/wont
          (aref buf 2) option)
    (client-send-bytes client buf :end 3)))

(defun send-tn3270e-device-type (client)
  "Send TN3270E device type negotiation."
  (let* ((dtype (client-device-type client))
         (dtype-bytes (babel:string-to-octets dtype :encoding :ascii))
         (buf (client-send-buffer client))
         (pos 0))
    ;; IAC SB TN3270E DEVICE-TYPE IS <device-type> IAC SE
    (setf (aref buf pos) +iac+) (incf pos)
    (setf (aref buf pos) +sb+) (incf pos)
    (setf (aref buf pos) +telopt-tn3270e+) (incf pos)
    (setf (aref buf pos) +tn3270e-device-type+) (incf pos)
    (setf (aref buf pos) +tn3270e-is+) (incf pos)
    (loop :for b :across dtype-bytes
          :do (setf (aref buf pos) b) (incf pos))
    (setf (aref buf pos) +iac+) (incf pos)
    (setf (aref buf pos) +se+) (incf pos)
    (client-send-bytes client buf :end pos)))

(defun send-tn3270e-functions (client)
  "Send TN3270E FUNCTIONS IS (none)."
  (let ((buf (client-send-buffer client)))
    ;; IAC SB TN3270E FUNCTIONS IS IAC SE
    (setf (aref buf 0) +iac+
          (aref buf 1) +sb+
          (aref buf 2) +telopt-tn3270e+
          (aref buf 3) +tn3270e-functions+
          (aref buf 4) +tn3270e-is+
          (aref buf 5) +iac+
          (aref buf 6) +se+)
    (client-send-bytes client buf :end 7)))

(defun process-telnet-command (client buf pos end)
  "Process a telnet command at POS. Returns new position."
  (when (< (1+ pos) end)
    (let ((cmd (aref buf (1+ pos))))
      (cond
        ;; DO/DONT
        ((or (= cmd +do+) (= cmd +dont+))
         (when (< (+ pos 2) end)
           (let ((opt (aref buf (+ pos 2))))
             (cond
               ;; DO BINARY - accept
               ((and (= cmd +do+) (= opt +telopt-binary+))
                (send-telnet-response client +will+ +telopt-binary+))
               ;; DO TN3270E - accept
               ((and (= cmd +do+) (= opt +telopt-tn3270e+))
                (send-telnet-response client +will+ +telopt-tn3270e+)
                (setf (client-tn3270e client) t))
               ;; DO TTYPE - accept
               ((and (= cmd +do+) (= opt +telopt-ttype+))
                (send-telnet-response client +will+ +telopt-ttype+))
               ;; DO EOR - accept
               ((and (= cmd +do+) (= opt +telopt-eor+))
                (send-telnet-response client +will+ +telopt-eor+))
               ;; Other DO - refuse
               ((= cmd +do+)
                (send-telnet-response client +wont+ opt))
               ;; DONT TN3270E - server refused, fall back to plain TN3270
               ((and (= cmd +dont+) (= opt +telopt-tn3270e+))
                (setf (client-tn3270e client) nil))
               ;; DONT - acknowledge
               (t nil)))
           (+ pos 3)))

        ;; WILL/WONT
        ((or (= cmd +will+) (= cmd +wont+))
         (when (< (+ pos 2) end)
           (let ((opt (aref buf (+ pos 2))))
             (cond
               ;; WILL BINARY - accept
               ((and (= cmd +will+) (= opt +telopt-binary+))
                (send-telnet-response client +do+ +telopt-binary+))
               ;; WILL TN3270E - accept
               ((and (= cmd +will+) (= opt +telopt-tn3270e+))
                (send-telnet-response client +do+ +telopt-tn3270e+))
               ;; WILL EOR - accept
               ((and (= cmd +will+) (= opt +telopt-eor+))
                (send-telnet-response client +do+ +telopt-eor+))
               ;; Other WILL - refuse
               ((= cmd +will+)
                (send-telnet-response client +dont+ opt))
               ;; WONT - acknowledge
               (t nil)))
           (+ pos 3)))

        ;; Subnegotiation
        ((= cmd +sb+)
         (process-subnegotiation client buf pos end))

        ;; EOR - end of record
        ((= cmd +eor+)
         (+ pos 2))

        ;; Other - skip
        (t (+ pos 2))))))

(defun process-subnegotiation (client buf pos end)
  "Process a telnet subnegotiation starting at POS.
   Returns position after IAC SE."
  ;; Find IAC SE
  (let ((se-pos (loop :for i :from (+ pos 2) :below (1- end)
                      :when (and (= (aref buf i) +iac+)
                                 (= (aref buf (1+ i)) +se+))
                      :return i)))
    (unless se-pos
      (return-from process-subnegotiation end))  ; incomplete
    (let ((opt (aref buf (+ pos 2))))
      (cond
        ;; TN3270E subnegotiation
        ((= opt +telopt-tn3270e+)
         (when (< (+ pos 3) se-pos)
           (let ((subcmd (aref buf (+ pos 3))))
             (cond
               ;; DEVICE-TYPE SEND
               ((and (= subcmd +tn3270e-device-type+)
                     (< (+ pos 4) se-pos)
                     (= (aref buf (+ pos 4)) +tn3270e-send+))
                (send-tn3270e-device-type client))
               ;; FUNCTIONS REQUEST
               ((and (= subcmd +tn3270e-functions+)
                     (< (+ pos 4) se-pos))
                (send-tn3270e-functions client)
                (setf (client-negotiated client) t))
               ;; DEVICE-TYPE IS (server confirmation)
               ((and (= subcmd +tn3270e-device-type+)
                     (< (+ pos 4) se-pos)
                     (= (aref buf (+ pos 4)) +tn3270e-is+))
                ;; Server accepted our device type
                nil)))))
        ;; TTYPE subnegotiation
        ((= opt +telopt-ttype+)
         (when (and (< (+ pos 3) se-pos)
                    (= (aref buf (+ pos 3)) +ttype-send+))
           ;; Send terminal type
           (let ((dtype (client-device-type client))
                 (sbuf (client-send-buffer client)))
             (setf (aref sbuf 0) +iac+
                   (aref sbuf 1) +sb+
                   (aref sbuf 2) +telopt-ttype+
                   (aref sbuf 3) +ttype-is+)
             (loop :for i :from 0 :below (length dtype)
                   :do (setf (aref sbuf (+ 4 i))
                             (char-code (char dtype i))))
             (setf (aref sbuf (+ 4 (length dtype))) +iac+
                   (aref sbuf (+ 5 (length dtype))) +se+)
             (client-send-bytes client sbuf :end (+ 6 (length dtype)))
             ;; For non-TN3270E, we're negotiated after TTYPE
             (unless (client-tn3270e client)
               (setf (client-negotiated client) t)))))))
    (+ se-pos 2)))

;;; --------------------------------------------------------------------------
;;; 3270 data stream handling
;;; --------------------------------------------------------------------------

(defun extract-3270-record (client)
  "Extract a complete 3270 record from recv-buffer if available.
   Returns the record as a byte vector, or NIL if incomplete.
   Removes the record from the buffer."
  (let* ((buf (client-recv-buffer client))
         (fill (client-recv-fill client)))
    ;; Look for IAC EOR
    (loop :for i :from 0 :below (1- fill)
          :when (and (= (aref buf i) +iac+)
                     (= (aref buf (1+ i)) +eor+))
          :do (let ((record (make-array i :element-type '(unsigned-byte 8))))
                ;; Copy data (stripping doubled IACs)
                (let ((out 0))
                  (loop :for j :from 0 :below i
                        :do (let ((b (aref buf j)))
                              (setf (aref record out) b)
                              (incf out)
                              ;; Skip second IAC of doubled pair
                              (when (and (= b +iac+) (< (1+ j) i)
                                         (= (aref buf (1+ j)) +iac+))
                                (incf j))))
                  (setf record (adjust-array record out)))
                ;; Shift remaining data
                (let ((remain (- fill i 2)))
                  (when (plusp remain)
                    (replace buf buf :start1 0 :start2 (+ i 2) :end2 fill))
                  (setf (client-recv-fill client) remain))
                (return-from extract-3270-record record)))
    nil))

(defun process-tn3270e-header (data)
  "Parse TN3270E header. Returns (VALUES data-start data-type response-flag).
   TN3270E header: data-type request-flag response-flag seq-number(2)."
  (if (>= (length data) 5)
      (let ((data-type (aref data 0))
            (response-flag (aref data 2)))
        (values 5 data-type response-flag))
      (values 0 +dt-3270-data+ 0)))

(defun process-3270-record (client record)
  "Process a complete 3270 data record."
  (when (and record (plusp (length record)))
    (let* ((tn3270e (client-tn3270e client))
           (screen (client-screen client)))
      (multiple-value-bind (start data-type response-flag)
          (if tn3270e
              (process-tn3270e-header record)
              (values 0 +dt-3270-data+ 0))
        (declare (ignore response-flag))
        (when (and screen (= data-type +dt-3270-data+) (< start (length record)))
          (process-3270-stream screen record :start start)
          (when (client-on-screen-update client)
            (funcall (client-on-screen-update client))))))))

;;; --------------------------------------------------------------------------
;;; Main poll function
;;; --------------------------------------------------------------------------

(defun client-poll (client &key (timeout 0))
  "Poll for and process incoming data.
   TIMEOUT: milliseconds to wait (0 = non-blocking).
   Returns :data if data was processed, :idle otherwise, :disconnected if closed."
  (unless (client-connected-p client)
    (return-from client-poll :disconnected))
  ;; Check for readable data
  (let ((ready (usocket:wait-for-input (client-socket client)
                                        :timeout (/ timeout 1000.0)
                                        :ready-only t)))
    (unless ready
      (return-from client-poll :idle))
    ;; Read available data
    (handler-case
        (progn
          (client-recv-available client)
          (let ((buf (client-recv-buffer client))
                (processed nil))
            ;; Process telnet commands and extract 3270 records
            (loop
              (let ((fill (client-recv-fill client)))
                (when (zerop fill) (return))
                ;; Check for IAC at start
                (if (= (aref buf 0) +iac+)
                    ;; Telnet command
                    (let ((new-pos (process-telnet-command client buf 0 fill)))
                      (if (and new-pos (> new-pos 0))
                          (let ((remain (- fill new-pos)))
                            (when (plusp remain)
                              (replace buf buf :start1 0 :start2 new-pos :end2 fill))
                            (setf (client-recv-fill client) remain))
                          ;; Incomplete telnet command, wait for more data
                          (return)))
                    ;; Try to extract 3270 record
                    (let ((record (extract-3270-record client)))
                      (if record
                          (progn
                            (process-3270-record client record)
                            (setf processed t))
                          (return))))))
            (if processed :data :idle)))
      (end-of-file ()
        (client-disconnect client)
        :disconnected)
      (error (c)
        (format *debug-io* "~&Poll error: ~a~%" c)
        (client-disconnect client)
        :disconnected))))

;;; --------------------------------------------------------------------------
;;; Sending AID (attention) responses
;;; --------------------------------------------------------------------------

(defun client-send-aid (client aid-code &key (send-modified t))
  "Send an AID (attention identifier) to the host.
   AID-CODE: the AID byte (Enter, PFn, PAn, Clear, etc.)
   SEND-MODIFIED: if T, include modified fields in response."
  (unless (client-connected-p client)
    (return-from client-send-aid nil))
  (let* ((screen (client-screen client))
         (buf (client-send-buffer client))
         (pos 0)
         (tn3270e (client-tn3270e client)))
    ;; TN3270E header if needed
    (when tn3270e
      (setf (aref buf pos) +dt-3270-data+) (incf pos)  ; data-type
      (setf (aref buf pos) 0) (incf pos)               ; request-flag
      (setf (aref buf pos) 0) (incf pos)               ; response-flag
      (setf (aref buf pos) 0) (incf pos)               ; seq-number high
      (setf (aref buf pos) 0) (incf pos))              ; seq-number low
    ;; AID byte
    (setf (aref buf pos) aid-code) (incf pos)
    ;; Cursor address (always sent for most AIDs)
    (when screen
      (multiple-value-bind (b1 b2)
          (encode-buffer-address (screen-cursor-address screen)
                                 (screen-cols screen)
                                 (screen-rows screen))
        (setf (aref buf pos) b1) (incf pos)
        (setf (aref buf pos) b2) (incf pos))
      ;; Modified fields (if requested and not Clear/PA)
      (when (and send-modified
                 (/= aid-code +aid-clear+)
                 (/= aid-code +aid-pa1+)
                 (/= aid-code +aid-pa2+)
                 (/= aid-code +aid-pa3+))
        (setf pos (write-modified-fields client buf pos))))
    ;; IAC EOR
    (setf (aref buf pos) +iac+) (incf pos)
    (setf (aref buf pos) +eor+) (incf pos)
    (client-send-bytes client buf :end pos)))

(defun write-modified-fields (client buf pos)
  "Write modified field data to BUF starting at POS.
   Returns new position."
  (let* ((screen (client-screen client))
         (size (screen-size screen))
         (attrs (screen-field-attrs screen))
         (data (screen-buffer screen)))
    ;; Find all modified fields
    (loop :for fa-addr :from 0 :below size
          :when (and (plusp (aref attrs fa-addr))
                     (field-modified-p screen fa-addr))
          :do (let* ((start (mod (1+ fa-addr) size))
                     (end (or (next-field-attr screen start) fa-addr)))
                ;; SBA order
                (setf (aref buf pos) +order-sba+) (incf pos)
                (multiple-value-bind (b1 b2)
                    (encode-buffer-address start
                                           (screen-cols screen)
                                           (screen-rows screen))
                  (setf (aref buf pos) b1) (incf pos)
                  (setf (aref buf pos) b2) (incf pos))
                ;; Field data (EBCDIC encoded)
                (loop :for addr = start :then (mod (1+ addr) size)
                      :until (= addr end)
                      :for char = (aref data addr)
                      :do (let ((ebcdic (char-to-ebcdic (code-char char))))
                            (setf (aref buf pos) ebcdic)
                            (incf pos)))))
    pos))

(defun char-to-ebcdic (char)
  "Convert character to EBCDIC CP037."
  (specops/format.ebcdic:ebcdic-code-cp037 char))
