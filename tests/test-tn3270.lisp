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
cell for each of its 3564 buffer addresses in its Lexter screen and in every
per-cell array of its field state beside it (LEXTER-D128)."
  (let* ((screen (lexter/tn3270:make-tn3270-screen :cols 132 :rows 27))
         (model (lexter/tn3270:screen-model screen)))
    (is (= 3564 (* (lexter/model:screen-cols model) (lexter/model:screen-rows model))))
    (dolist (array (list (lexter/tn3270::screen-field-attrs screen)
                         (lexter/tn3270::screen-colors screen)
                         (lexter/tn3270::screen-highlights screen)))
      (is (= 3564 (length array))))
    (finishes (lexter/tn3270:screen-put-char screen 3000 65))
    (is (= 65 (lexter/tn3270:screen-get-char screen 3000)))))

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

;;; ------------------------------------------------------------
;;; The 3270 screen as a Lexter screen  (LEXTER-D128)
;;; ------------------------------------------------------------

(defun sba (address &optional (cols 80) (rows 24))
  "The bytes of SBA to ADDRESS of a screen of COLS by ROWS."
  (multiple-value-bind (b1 b2) (lexter/tn3270:encode-buffer-address address cols rows)
    (octets #x11 b1 b2)))

(defun paint (screen &rest parts)
  "Process an Erase/Write of PARTS, bytes and byte vectors of orders and EBCDIC
text, into SCREEN, as a host's record would."
  (lexter/tn3270:process-3270-stream screen (apply #'octets #xF5 #xC3 parts)))

(defun cell-style-at (screen address)
  "The style in which address ADDRESS of the 3270 SCREEN is written."
  (let ((model (lexter/tn3270:screen-model screen)))
    (lexter/model:table-style (lexter/model:screen-styles model)
                              (lexter/model:cell-style model (mod address 80) (floor address 80)))))

(def-test the-data-stream-writes-the-lexter-screen ()
  "The data stream's characters are written into the 3270 screen's Lexter
screen, which holds them once: what the 3270 screen reads at an address is
the Lexter screen's cell at its row and column (LEXTER-D128)."
  (let ((screen (lexter/tn3270:make-tn3270-screen)))
    (paint screen (sba 81) #xC1 #xC2)
    (let ((model (lexter/tn3270:screen-model screen)))
      (is (= #x41 (lexter/model:cell-content model 1 1)))
      (is (= #x42 (lexter/model:cell-content model 2 1)))
      (is (= #x42 (lexter/tn3270:screen-get-char screen 82))))))

(def-test a-field-attribute-stands-in-a-blank-cell ()
  "A field attribute's position is a blank cell, in the plain style, its
attribute kept beside the Lexter screen (LEXTER-D128)."
  (let ((screen (lexter/tn3270:make-tn3270-screen)))
    (paint screen (sba 10) #x1D #x60 #xC1)
    (is (= 32 (lexter/tn3270:screen-get-char screen 10)))
    (is (= #x60 (aref (lexter/tn3270:screen-field-attrs screen) 10)))
    (is (= #x41 (lexter/tn3270:screen-get-char screen 11)))
    (is-false (lexter/model:style-invisible (cell-style-at screen 10)))))

(def-test a-field-s-intensity-styles-its-cells ()
  "The cells of a non-display field are written invisible, so that a
password is not shown, and those of an intensified field bold; the cells of
a normal field are neither (LEXTER-D128)."
  (let ((screen (lexter/tn3270:make-tn3270-screen)))
    (paint screen (sba 0) #x1D #x4C #xC1 #xC1 (sba 10) #x1D #x48 #xC2 (sba 20) #x1D #x40 #xC3)
    (is-true (lexter/model:style-invisible (cell-style-at screen 1)))
    (is-true (lexter/model:style-invisible (cell-style-at screen 2)))
    (is-true (lexter/model:style-bold (cell-style-at screen 11)))
    (is-false (lexter/model:style-invisible (cell-style-at screen 11)))
    (is-false (lexter/model:style-bold (cell-style-at screen 21)))
    (is (= #x41 (lexter/tn3270:screen-get-char screen 1)))))

(def-test changing-a-field-attribute-restyles-its-field ()
  "A field attribute changed by Modify Field restyles the cells of its field:
a normal field made non-display hides its characters (LEXTER-D128)."
  (let ((screen (lexter/tn3270:make-tn3270-screen)))
    (paint screen (sba 0) #x1D #x40 #xC1 #xC2)
    (is-false (lexter/model:style-invisible (cell-style-at screen 1)))
    (lexter/tn3270:process-3270-stream
     screen (octets #xF1 #xC3 (sba 1) #x2C 1 #xC0 #x4C))
    (is-true (lexter/model:style-invisible (cell-style-at screen 1)))
    (is-true (lexter/model:style-invisible (cell-style-at screen 2)))))

(def-test extended-attributes-are-the-cell-s-style ()
  "A cell's extended colour and highlight are its style: the colour a palette
foreground, reverse, underscore, and blink the style's attributes."
  (let ((screen (lexter/tn3270:make-tn3270-screen)))
    (paint screen (sba 0) #x28 #x42 #xF2 #x28 #x41 #xF2 #xC1
           #x28 #x41 #xF4 #xC2 #x28 #x41 #xF1 #xC3)
    (let ((a (cell-style-at screen 0)) (b (cell-style-at screen 1)) (c (cell-style-at screen 2)))
      (is (= (lexter/model:palette-colour 9) (lexter/model:style-foreground a)))
      (is-true (lexter/model:style-reverse a))
      (is-true (lexter/model:style-underline b))
      (is-true (lexter/model:style-blink c)))))

(def-test the-3270-pane-is-built-as-a-terminal-is ()
  "The 3270 pane builds its Lexter screen into the composed grid as every
terminal pane does: a non-display field with no glyphs, reverse video through
the background slot, and the cursor's cell transformed (LEXTER-D124,
LEXTER-D128)."
  (let* ((atlas (make-test-atlas))
         (screen (lexter/tn3270:make-tn3270-screen))
         (client (lexter/tn3270:make-tn3270-client :screen screen))
         (pane (make-instance 'lexter/tn3270-pane:tn3270-pane :width 80 :height 24))
         (grid (lexter/grid:make-display-grid :cols 80 :rows 24 :atlas atlas)))
    (setf (lexter/tn3270-pane:tn3270-pane-client pane) client
          (lexter/tn3270-pane::tn3270-pane-atlas pane) atlas)
    (paint screen (sba 0) #x1D #x4C #xC1 (sba 10) #x1D #x40 #x28 #x41 #xF2 #xC2 #x13)
    (lexter/panes:pane-flush pane grid)
    (is (= 0 (getf (grid-record grid 1 0) :glyph-count)))
    (is (= (glyph atlas #x42) (grid-glyph grid 11 0)))
    (is (= 1 (getf (grid-record grid 11 0) :background-slot)))
    ;; IC put the cursor after B, at address 12
    (is (= 12 (lexter/tn3270:screen-cursor-address screen)))
    (is (= 1 (getf (grid-record grid 12 0) :background-slot)))))

(def-test read-modified-sends-what-was-typed ()
  "The fields a Read Modified reply sends are read from the Lexter screen,
where the operator's typing was written."
  (let* ((screen (lexter/tn3270:make-tn3270-screen))
         (client (lexter/tn3270:make-tn3270-client :screen screen))
         (buffer (make-array 64 :element-type '(unsigned-byte 8) :initial-element 0)))
    (paint screen (sba 0) #x1D #x40 (sba 4) #x1D #x60)
    (lexter/tn3270:screen-put-char screen 1 #x41)
    (lexter/tn3270::set-field-modified screen 0)
    (let ((end (lexter/tn3270::write-modified-fields client buffer 0)))
      ;; SBA to address 1, then the field's three cells: A and two spaces
      (is (equalp (concatenate '(vector (unsigned-byte 8)) (sba 1) (octets #xC1 #x40 #x40))
                  (subseq buffer 0 end))))))

(def-test the-3270-pane-writes-the-grid-only-through-the-model ()
  "LEXTER-D128: the 3270 pane has no path of its own to the grid: its source
calls none of the grid's writers, and the grid keeps no SET-SIMPLE-CELL."
  (let ((source (uiop:read-file-string (source-path "src/tn3270-pane/tn3270-pane.lisp"))))
    (is-false (search "lexter/grid:" source :test #'char-equal)))
  (is (null (find-symbol "SET-SIMPLE-CELL" '#:lexter/grid))))
