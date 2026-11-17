;;;; tests/test-tn3270.lisp — The TN3270 client's negotiation and framing.
;;;;
;;;; Loopback: a real client connects to a peer in this image on an ephemeral
;;;; port; the peer plays the server's side of a session as RFC 2355 lays it
;;;; out. No server outside the test, no GL. Tests of LEXTER-O25 and
;;;; LEXTER-O31 fail until the terminal-fixes plan repairs the client and the
;;;; screen (LEXTER-D72).

(in-package #:lexter-tests)
(in-suite tn3270)

;;; Telnet and TN3270E codes, from RFC 854, RFC 885, and RFC 2355.
(defconstant +t-iac+ 255)
(defconstant +t-sb+ 250)
(defconstant +t-se+ 240)
(defconstant +t-do+ 253)
(defconstant +t-eor+ 239)
(defconstant +tn3270e+ 40 "The TN3270E telnet option.")
(defconstant +tn3270e-connect+ 1)
(defconstant +tn3270e-device-type+ 2)
(defconstant +tn3270e-functions+ 3)
(defconstant +tn3270e-is+ 4)
(defconstant +tn3270e-request+ 7)
(defconstant +tn3270e-send+ 8)

(defmacro with-tn3270-session ((client peer) &body body)
  "Run BODY with CLIENT bound to a TN3270 client with a 24-by-80 screen,
connected over loopback to PEER, the server's end; close both afterwards."
  (let ((listener (gensym "LISTENER")) (port (gensym "PORT")))
    `(with-loopback-listener (,listener ,port)
       (let ((,client (lexter/tn3270:make-tn3270-client
                       :host "127.0.0.1" :port ,port
                       :screen (lexter/tn3270:make-tn3270-screen))))
         (unwind-protect
              (progn
                (lexter/tn3270:client-connect ,client)
                (let ((,peer (accept-peer ,listener)))
                  (unwind-protect (progn ,@body)
                    (usocket:socket-close ,peer))))
           (lexter/tn3270:client-disconnect ,client))))))

(defun tn3270e-subnegotiation (&rest body)
  "The bytes of IAC SB TN3270E BODY IAC SE, BODY being bytes and strings."
  (apply #'octets +t-iac+ +t-sb+ +tn3270e+
         (append body (list +t-iac+ +t-se+))))

(defun poll-client (client)
  "A function that polls CLIENT once without waiting."
  (lambda () (lexter/tn3270:client-poll client :timeout 0)))

(defun server-says (client peer &rest messages)
  "Send each of MESSAGES from PEER, the server, letting CLIENT answer each, and
return everything CLIENT sent in reply."
  (let ((replies (make-array 0 :element-type '(unsigned-byte 8)
                               :adjustable t :fill-pointer 0)))
    (dolist (message messages)
      (peer-send peer message)
      (loop :for b :across (exchange peer (poll-client client) :timeout 0.3)
            :do (vector-push-extend b replies)))
    (coerce replies '(vector (unsigned-byte 8)))))

;;; ------------------------------------------------------------
;;; TN3270E negotiation  (LEXTER-O25)
;;; ------------------------------------------------------------

(def-test answers-send-device-type-with-a-request ()
  "LEXTER-O25: when the server sends SEND DEVICE-TYPE, the client answers
DEVICE-TYPE REQUEST with its device type, as RFC 2355 section 7.1 requires;
only the server sends DEVICE-TYPE IS."
  (with-tn3270-session (client peer)
    (let ((replies (server-says client peer
                                (octets +t-iac+ +t-do+ +tn3270e+)
                                (tn3270e-subnegotiation +tn3270e-send+
                                                        +tn3270e-device-type+))))
      (is-true (bytes-contain-p replies +t-iac+ +t-sb+ +tn3270e+
                                +tn3270e-device-type+ +tn3270e-request+
                                (lexter/tn3270::client-device-type client)
                                +t-iac+ +t-se+)))))

(def-test requests-functions-after-device-type-is ()
  "LEXTER-O25: once the server confirms the device type with DEVICE-TYPE IS
and CONNECT, the client sends FUNCTIONS REQUEST, as RFC 2355 section 7.2
requires of the client."
  (with-tn3270-session (client peer)
    (let ((replies (server-says client peer
                                (octets +t-iac+ +t-do+ +tn3270e+)
                                (tn3270e-subnegotiation +tn3270e-send+
                                                        +tn3270e-device-type+)
                                (tn3270e-subnegotiation +tn3270e-device-type+
                                                        +tn3270e-is+
                                                        (lexter/tn3270::client-device-type client)
                                                        +tn3270e-connect+ "LU1"))))
      (is-true (bytes-contain-p replies +t-iac+ +t-sb+ +tn3270e+
                                +tn3270e-functions+ +tn3270e-request+)))))

;;; ------------------------------------------------------------
;;; The screen and record framing  (LEXTER-O31)
;;; ------------------------------------------------------------

(def-test screen-is-sized-from-its-geometry ()
  "LEXTER-O31: a screen of 27 rows of 132 columns, the IBM-3278-5's, holds a
cell for each of its 3564 buffer addresses in every per-cell array."
  (let ((screen (lexter/tn3270:make-tn3270-screen :cols 132 :rows 27)))
    (dolist (array (list (lexter/tn3270:screen-buffer screen)
                         (lexter/tn3270::screen-field-attrs screen)
                         (lexter/tn3270::screen-colors screen)
                         (lexter/tn3270::screen-highlights screen)))
      (is (= 3564 (length array))))
    (finishes (lexter/tn3270:screen-put-char screen 3000 65))))

(def-test record-keeps-an-escaped-data-byte-255 ()
  "LEXTER-O31: a data byte 255, sent doubled as FF FF, does not end the record
when the byte after it is 239; a record ends only at an unescaped IAC EOR."
  (with-tn3270-session (client peer)
    ;; Erase/Write, WCC, then the characters EBCDIC EF and C1 ('A'), all in
    ;; one record: F5 FF EF C1, with the FF doubled on the wire
    (peer-send peer #xF5 +t-iac+ +t-iac+ #xEF #xC1 +t-iac+ +t-eor+)
    (is-true (wait-for-predicate
              (lambda ()
                (lexter/tn3270:client-poll client :timeout 0)
                (= 65 (lexter/tn3270:screen-get-char
                       (lexter/tn3270::client-screen client) 1)))
              :timeout 1))))
