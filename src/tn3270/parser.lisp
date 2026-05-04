;;;; 3270 data stream parser.
;;;;
;;;; Processes 3270 command codes and orders from the host, updating the screen.
;;;; Commands: Write, Erase/Write, Erase/Write Alternate, Read Modified, etc.
;;;; Orders: SBA, SF, SFE, SA, IC, PT, RA, EUA, GE, MF

(in-package #:pcf-gl/tn3270)

;;; --------------------------------------------------------------------------
;;; EBCDIC conversion (via specops/format.ebcdic)
;;; --------------------------------------------------------------------------

(defun ebcdic-to-char (byte &optional ge-mode)
  "Convert EBCDIC byte to Unicode character.
   If GE-MODE is true, use CP310 (APL) character set."
  (if ge-mode
      (specops/format.ebcdic:ebcdic-code-cp310 byte)
      (specops/format.ebcdic:ebcdic-code-cp037 byte)))

;;; --------------------------------------------------------------------------
;;; Order parsing
;;; --------------------------------------------------------------------------

(defun parse-order (screen data pos end)
  "Parse a 3270 order at position POS in DATA.
   Returns new position after consuming the order.
   Modifies SCREEN as a side effect."
  (declare (type tn3270-screen screen)
           (type (simple-array (unsigned-byte 8) (*)) data)
           (type fixnum pos end))
  (when (>= pos end)
    (return-from parse-order pos))
  (let ((order (aref data pos)))
    (case order
      ;; SBA (Set Buffer Address) - 3 bytes total
      (#.+order-sba+
       (when (< (+ pos 3) end)
         (let ((addr (decode-buffer-address (aref data (+ pos 1))
                                            (aref data (+ pos 2)))))
           (screen-set-cursor screen addr)))
       (+ pos 3))

      ;; SF (Start Field) - 2 bytes total
      (#x1D  ; SF order code (not in lexicon, raw value)
       (when (< (+ pos 2) end)
         (let ((attr (aref data (+ pos 1)))
               (addr (screen-cursor-address screen)))
           (screen-put-field-attr screen addr attr)
           (screen-set-cursor screen (mod (1+ addr) (screen-size screen)))))
       (+ pos 2))

      ;; SFE (Start Field Extended) - variable length
      (#.+order-sfe+
       (if (< (+ pos 2) end)
           (let* ((pair-count (aref data (+ pos 1)))
                  (len (+ 2 (* 2 pair-count))))
             (when (< (+ pos len) end)
               ;; First pair is always field attribute
               (let ((addr (screen-cursor-address screen))
                     (attr (if (> pair-count 0)
                               (aref data (+ pos 3))  ; value of first pair
                               0)))
                 (screen-put-field-attr screen addr attr)
                 ;; Process extended attribute pairs
                 (loop :for i :from 1 :below pair-count
                       :for type = (aref data (+ pos 2 (* 2 i)))
                       :for value = (aref data (+ pos 3 (* 2 i)))
                       :do (screen-set-attribute screen type value))
                 (screen-set-cursor screen (mod (1+ addr) (screen-size screen)))))
             (+ pos len))
           (+ pos 2)))

      ;; SA (Set Attribute) - 3 bytes total
      (#.+order-sa+
       (when (< (+ pos 3) end)
         (let ((type (aref data (+ pos 1)))
               (value (aref data (+ pos 2))))
           (screen-set-attribute screen type value)))
       (+ pos 3))

      ;; IC (Insert Cursor) - 1 byte
      (#.+order-ic+
       ;; Cursor is already at current position; just mark it
       (+ pos 1))

      ;; PT (Program Tab) - 1 byte
      (#.+order-pt+
       ;; Skip to next unprotected field
       (let* ((size (screen-size screen))
              (start (screen-cursor-address screen)))
         (loop :for i :from 1 :below size
               :for addr = (mod (+ start i) size)
               :for fa = (aref (screen-field-attrs screen) addr)
               :when (and (plusp fa) (not (field-protected-p fa)))
               :do (screen-set-cursor screen (mod (1+ addr) size))
                   (return)))
       (+ pos 1))

      ;; RA (Repeat to Address) - 4 bytes total
      (#x3C
       (when (< (+ pos 4) end)
         (let* ((stop-addr (decode-buffer-address (aref data (+ pos 1))
                                                  (aref data (+ pos 2))))
                (char-byte (aref data (+ pos 3)))
                (char (char-code (ebcdic-to-char char-byte)))
                (start (screen-cursor-address screen))
                (size (screen-size screen)))
           ;; Repeat character from current position to stop-addr
           (loop :for addr = start :then (mod (1+ addr) size)
                 :until (= addr stop-addr)
                 :do (screen-put-char screen addr char))
           (screen-set-cursor screen stop-addr)))
       (+ pos 4))

      ;; EUA (Erase Unprotected to Address) - 3 bytes total
      (#.+order-eua+
       (when (< (+ pos 3) end)
         (let* ((stop-addr (decode-buffer-address (aref data (+ pos 1))
                                                  (aref data (+ pos 2))))
                (start (screen-cursor-address screen))
                (size (screen-size screen)))
           ;; Erase unprotected positions to stop-addr
           (loop :for addr = start :then (mod (1+ addr) size)
                 :until (= addr stop-addr)
                 :for fa-addr = (find-field-attr-before screen addr)
                 :for fa = (if fa-addr (aref (screen-field-attrs screen) fa-addr) 0)
                 :unless (and fa-addr (field-protected-p fa))
                 :do (setf (aref (screen-buffer screen) addr) 32))
           (screen-set-cursor screen stop-addr)))
       (+ pos 3))

      ;; GE (Graphic Escape) - 2 bytes total
      (#.+order-ge+
       (when (< (+ pos 2) end)
         (let* ((byte (aref data (+ pos 1)))
                (char (char-code (ebcdic-to-char byte t)))  ; APL charset
                (addr (screen-cursor-address screen)))
           (screen-put-char screen addr char)))
       (+ pos 2))

      ;; MF (Modify Field) - variable length
      (#.+order-mf+
       (if (< (+ pos 2) end)
           (let* ((pair-count (aref data (+ pos 1)))
                  (len (+ 2 (* 2 pair-count))))
             ;; Find current field and modify its attributes
             (multiple-value-bind (fa-addr fa)
                 (screen-field-at screen (screen-cursor-address screen))
               (declare (ignore fa))
               (when fa-addr
                 (loop :for i :from 0 :below pair-count
                       :for type = (aref data (+ pos 2 (* 2 i)))
                       :for value = (aref data (+ pos 3 (* 2 i)))
                       :do (cond
                             ((= type +xa-3270+)
                              (setf (aref (screen-field-attrs screen) fa-addr) value))
                             (t (screen-set-attribute screen type value))))))
             (+ pos len))
           (+ pos 2)))

      ;; Unknown order - skip 1 byte
      (otherwise
       (+ pos 1)))))

;;; --------------------------------------------------------------------------
;;; Command processing
;;; --------------------------------------------------------------------------

(defun process-write-command (screen data start end wcc)
  "Process a Write/Erase-Write command's WCC and data.
   WCC: Write Control Character (reset MDT, etc.)
   DATA: contains orders and text bytes from START to END."
  (declare (type tn3270-screen screen)
           (type (simple-array (unsigned-byte 8) (*)) data)
           (type fixnum start end)
           (type (unsigned-byte 8) wcc)
           (ignore wcc))  ; TODO: handle WCC bits (reset MDT, sound alarm, etc.)
  (let ((pos start)
        (ge-mode nil))
    (loop :while (< pos end)
          :do (let ((byte (aref data pos)))
                (cond
                  ;; Orders (recognized by specific byte values)
                  ((or (= byte +order-sba+)
                       (= byte #x1D)  ; SF
                       (= byte +order-sfe+)
                       (= byte +order-sa+)
                       (= byte +order-ic+)
                       (= byte +order-pt+)
                       (= byte #x3C)  ; RA
                       (= byte +order-eua+)
                       (= byte +order-ge+)
                       (= byte +order-mf+))
                   (when (= byte +order-ge+)
                     (setf ge-mode t))
                   (setf pos (parse-order screen data pos end)))
                  ;; Null bytes (often padding) - skip
                  ((zerop byte)
                   (incf pos))
                  ;; Text character
                  (t
                   (let ((char (char-code (ebcdic-to-char byte ge-mode)))
                         (addr (screen-cursor-address screen)))
                     (screen-put-char screen addr char)
                     (setf ge-mode nil))
                   (incf pos)))))))

(defun process-3270-stream (screen data &key (start 0) (end nil))
  "Process a complete 3270 data stream.
   DATA should include the command byte(s).
   Handles Write, Erase/Write, Erase/Write Alternate, etc."
  (declare (type tn3270-screen screen)
           (type (simple-array (unsigned-byte 8) (*)) data))
  (let ((end (or end (length data))))
    (when (< start end)
      (let ((cmd (aref data start)))
        (cond
          ;; Write
          ((= cmd +cmd-write+)
           (when (< (1+ start) end)
             (process-write-command screen data (+ start 2) end
                                    (aref data (1+ start)))))
          ;; Erase/Write
          ((= cmd +cmd-erase-write+)
           (screen-clear screen)
           (when (< (1+ start) end)
             (process-write-command screen data (+ start 2) end
                                    (aref data (1+ start)))))
          ;; Erase/Write Alternate (switch to alternate screen size)
          ((= cmd +cmd-erase-write-alternate+)
           (screen-clear screen)  ; TODO: actually switch to 132x43 or similar
           (when (< (1+ start) end)
             (process-write-command screen data (+ start 2) end
                                    (aref data (1+ start)))))
          ;; Erase All Unprotected
          ((= cmd +cmd-erase-all-unprotected+)
           ;; Clear all unprotected fields and reset MDTs
           (let ((size (screen-size screen)))
             (loop :for addr :from 0 :below size
                   :for fa-addr = (find-field-attr-before screen addr)
                   :for fa = (if fa-addr (aref (screen-field-attrs screen) fa-addr) 0)
                   :unless (and fa-addr (field-protected-p fa))
                   :do (setf (aref (screen-buffer screen) addr) 32))))
          ;; Read Modified - host wants our data (handled at client level)
          ((= cmd +cmd-read-modified+)
           nil)  ; Response built by client
          ;; Write Structured Field (WSF) - #xF3
          ;; Used for extended features like query/reply
          ((= cmd #xF3)
           ;; For now, silently ignore WSF commands
           ;; TODO: implement query/reply for capability negotiation
           nil)
          ;; Unknown command
          (t
           (format *debug-io* "~&Unknown 3270 command: #x~2,'0X~%" cmd)))))))
