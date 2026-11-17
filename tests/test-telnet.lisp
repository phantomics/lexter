;;;; tests/test-telnet.lisp — What a telnet pane sends.
;;;;
;;;; Loopback: a telnet pane, initialised with a packed test atlas, connects to
;;;; a peer in this image on an ephemeral port; the peer reads what the pane
;;;; sends and plays the server's side of option negotiation. No server
;;;; outside the test, no GL. Tests of LEXTER-O34 fail until the
;;;; terminal-fixes plan repairs the client (LEXTER-D73).

(in-package #:lexter-tests)
(in-suite telnet)

(defmacro with-telnet-pane ((pane peer &key (encoding :utf8)) &body body)
  "Run BODY with PANE bound to an initialised telnet pane of ENCODING,
connected over loopback to PEER, the server's end; close both afterwards."
  (let ((listener (gensym "LISTENER")) (port (gensym "PORT")))
    `(with-loopback-listener (,listener ,port)
       (let ((,pane (lexter/telnet-pane:make-telnet-pane
                     :host "127.0.0.1" :port ,port :encoding ,encoding)))
         (unwind-protect
              (progn
                (lexter/panes:pane-initialize ,pane (make-test-atlas))
                (let ((,peer (accept-peer ,listener)))
                  (unwind-protect (progn ,@body)
                    (usocket:socket-close ,peer))))
           (lexter/panes:vt-pane-backend-destroy ,pane))))))

(defun pane-sends (pane peer string)
  "Have PANE write STRING as typed input, and return the bytes that reach PEER."
  (lexter/panes:vt-pane-write-string pane string)
  (exchange peer (constantly nil)
            :until (lambda (bytes) (plusp (length bytes)))
            :timeout 0.5))

(defun read-pane (pane)
  "A function that reads PANE's connection once, as the compositor's poll does."
  (let ((buffer (make-array 4096 :element-type '(unsigned-byte 8))))
    (lambda () (lexter/panes:vt-pane-read-bytes pane buffer))))

;;; ------------------------------------------------------------
;;; Characters on the wire  (LEXTER-O34)
;;; ------------------------------------------------------------

(def-test utf8-pane-sends-characters-encoded ()
  "LEXTER-O34: a pane whose encoding is UTF-8 sends a typed character as its
UTF-8 bytes, not masked to seven bits."
  (with-telnet-pane (pane peer :encoding :utf8)
    (assert-that (coerce (pane-sends pane peer (string (code-char #xE9))) 'list)
                 (contains #xC3 #xA9))))

(def-test cp437-pane-doubles-iac-after-encoding ()
  "LEXTER-O34: a pane whose encoding is CP437 encodes a typed character first,
and then doubles a resulting byte 255 as IAC IAC: the no-break space, CP437
255, is sent as FF FF, never as a DEL and a lone IAC."
  (with-telnet-pane (pane peer :encoding :cp437)
    (assert-that (coerce (pane-sends pane peer (string (code-char #xA0))) 'list)
                 (contains #xFF #xFF))))

;;; ------------------------------------------------------------
;;; Option state  (LEXTER-O34)
;;; ------------------------------------------------------------

(def-test option-already-on-is-not-acknowledged-again ()
  "LEXTER-O34: the client answers a server's WILL ECHO with DO ECHO once; a
second WILL ECHO, for an option already on, changes nothing and gets no reply,
as RFC 854 and the Q method of RFC 1143 require."
  (with-telnet-pane (pane peer)
    (peer-send peer 255 251 1)
    (exchange peer (read-pane pane) :timeout 0.3)
    (peer-send peer 255 251 1)
    (let ((later (exchange peer (read-pane pane) :timeout 0.3)))
      (is (= 0 (count-occurrences later 255 253 1))))))
