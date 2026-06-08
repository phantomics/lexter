;;;; 3270 data stream parser.
;;;;
;;;; Processes 3270 command codes and orders from the host, updating the screen.
;;;; Commands: Write, Erase/Write, Erase/Write Alternate, Read Modified, etc.
;;;; Orders: SBA, SF, SFE, SA, IC, PT, RA, EUA, GE, MF

(in-package #:lexter/tn3270)

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
       (when (<= (+ pos 3) end)
         (let ((addr (decode-buffer-address (aref data (+ pos 1))
                                            (aref data (+ pos 2)))))
           (screen-set-buffer-address screen addr)))
       (+ pos 3))

      ;; SF (Start Field) - 2 bytes total
      (#x1D  ; SF order code (not in lexicon, raw value)
       (when (<= (+ pos 2) end)
         (let ((attr (aref data (+ pos 1)))
               (addr (screen-buffer-address screen)))
           (screen-put-field-attr screen addr attr)
           (screen-set-buffer-address screen (mod (1+ addr) (screen-size screen)))))
       (+ pos 2))

      ;; SFE (Start Field Extended) - variable length
      (#.+order-sfe+
       (if (<= (+ pos 2) end)
           (let* ((pair-count (aref data (+ pos 1)))
                  (len (+ 2 (* 2 pair-count))))
             (when (<= (+ pos len) end)
               ;; First pair is always field attribute
               (let ((addr (screen-buffer-address screen))
                     (attr (if (> pair-count 0)
                               (aref data (+ pos 3))  ; value of first pair
                               0)))
                 (screen-put-field-attr screen addr attr)
                 ;; Process extended attribute pairs
                 (loop :for i :from 1 :below pair-count
                       :for type = (aref data (+ pos 2 (* 2 i)))
                       :for value = (aref data (+ pos 3 (* 2 i)))
                       :do (screen-set-attribute screen type value))
                 (screen-set-buffer-address screen (mod (1+ addr) (screen-size screen)))))
             (+ pos len))
           (+ pos 2)))

      ;; SA (Set Attribute) - 3 bytes total
      (#.+order-sa+
       (when (<= (+ pos 3) end)
         (let ((type (aref data (+ pos 1)))
               (value (aref data (+ pos 2))))
           (screen-set-attribute screen type value)))
       (+ pos 3))

      ;; IC (Insert Cursor) - 1 byte
      (#.+order-ic+
       ;; Capture the current paint (buffer) position as the user cursor.
       ;; This is the only order that moves the cursor while the host paints
       ;; the screen; everything else moves the buffer address instead.
       (screen-set-cursor screen (screen-buffer-address screen))
       (+ pos 1))

      ;; PT (Program Tab) - 1 byte
      (#.+order-pt+
       ;; Skip to next unprotected field (advances the buffer address).
       (let* ((size (screen-size screen))
              (start (screen-buffer-address screen)))
         (loop :for i :from 1 :below size
               :for addr = (mod (+ start i) size)
               :for fa = (aref (screen-field-attrs screen) addr)
               :when (and (plusp fa) (not (field-protected-p fa)))
               :do (screen-set-buffer-address screen (mod (1+ addr) size))
                   (return)))
       (+ pos 1))

      ;; RA (Repeat to Address) - 4 bytes total
      (#x3C
       (when (<= (+ pos 4) end)
         (let* ((stop-addr (decode-buffer-address (aref data (+ pos 1))
                                                  (aref data (+ pos 2))))
                (char-byte (aref data (+ pos 3)))
                (char (char-code (ebcdic-to-char char-byte)))
                (start (screen-buffer-address screen))
                (size (screen-size screen)))
           ;; Repeat character from current buffer position to stop-addr.
           (loop :for addr = start :then (mod (1+ addr) size)
                 :until (= addr stop-addr)
                 :do (screen-write-cell screen addr char))
           (screen-set-buffer-address screen stop-addr)))
       (+ pos 4))

      ;; EUA (Erase Unprotected to Address) - 3 bytes total
      (#.+order-eua+
       (when (<= (+ pos 3) end)
         (let* ((stop-addr (decode-buffer-address (aref data (+ pos 1))
                                                  (aref data (+ pos 2))))
                (start (screen-buffer-address screen))
                (size (screen-size screen)))
           ;; Erase unprotected positions to stop-addr
           (loop :for addr = start :then (mod (1+ addr) size)
                 :until (= addr stop-addr)
                 :for fa-addr = (find-field-attr-before screen addr)
                 :for fa = (if fa-addr (aref (screen-field-attrs screen) fa-addr) 0)
                 :unless (and fa-addr (field-protected-p fa))
                 :do (setf (aref (screen-buffer screen) addr) 32))
           (screen-set-buffer-address screen stop-addr)))
       (+ pos 3))

      ;; GE (Graphic Escape) - 2 bytes total
      (#.+order-ge+
       (when (<= (+ pos 2) end)
         (let* ((byte (aref data (+ pos 1)))
                (char (char-code (ebcdic-to-char byte t))))  ; APL charset
           (screen-put-char-buffer screen char)))
       (+ pos 2))

      ;; MF (Modify Field) - variable length
      (#.+order-mf+
       (if (<= (+ pos 2) end)
           (let* ((pair-count (aref data (+ pos 1)))
                  (len (+ 2 (* 2 pair-count))))
             ;; Only process the pairs if they are all present in the buffer.
             (when (<= (+ pos len) end)
               ;; Find current field and modify its attributes
               (multiple-value-bind (fa-addr fa)
                   (screen-field-at screen (screen-buffer-address screen))
                 (declare (ignore fa))
                 (when fa-addr
                   (loop :for i :from 0 :below pair-count
                         :for type = (aref data (+ pos 2 (* 2 i)))
                         :for value = (aref data (+ pos 3 (* 2 i)))
                         :do (cond
                               ((= type +xa-3270+)
                                (setf (aref (screen-field-attrs screen) fa-addr) value))
                               (t (screen-set-attribute screen type value)))))))
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
  ;; The host paints starting from buffer address 0 unless an SBA order moves
  ;; it (hosts almost always lead with SBA). The buffer address is the paint
  ;; pointer and is kept distinct from the user cursor.
  (setf (screen-buffer-address screen) 0)
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
                   (let ((char (char-code (ebcdic-to-char byte ge-mode))))
                     (screen-put-char-buffer screen char)
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
          ;;
          ;; A plain Write does NOT clear the screen and, here, does NOT move
          ;; the user cursor unless the stream contains an IC order. This means
          ;; a partial refresh (e.g. a host repainting a status/clock field with
          ;; no IC) leaves the operator's cursor where it is, instead of being
          ;; dragged to the last byte painted.
          ;;
          ;; NOTE: this differs from a classic 3270, where the cursor address is
          ;; defined by IC (or defaults to 0 on Erase/Write); a real device does
          ;; not "remember" the operator cursor across a Write the way we do.
          ;; We deliberately preserve it for a better interactive experience.
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
