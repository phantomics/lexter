;;;; Buffer address encoding/decoding for 3270 data streams.
;;;;
;;;; 3270 uses two addressing modes:
;;;; - 12-bit: addresses 0-4095, encoded in 2 bytes using 6-bit table
;;;; - 14-bit: addresses 0-16383, encoded in 2 bytes with high bits set
;;;;
;;;; This file provides encoding/decoding for SBA (Set Buffer Address) orders.

(in-package #:lexter/tn3270)

;;; --------------------------------------------------------------------------
;;; 6-bit encoding table (used for 12-bit addresses)
;;; --------------------------------------------------------------------------

(defparameter *6bit-table*
  #(#x40 #xC1 #xC2 #xC3 #xC4 #xC5 #xC6 #xC7   ; 00-07
    #xC8 #xC9 #x4A #x4B #x4C #x4D #x4E #x4F   ; 08-15
    #x50 #xD1 #xD2 #xD3 #xD4 #xD5 #xD6 #xD7   ; 16-23
    #xD8 #xD9 #x5A #x5B #x5C #x5D #x5E #x5F   ; 24-31
    #x60 #x61 #xE2 #xE3 #xE4 #xE5 #xE6 #xE7   ; 32-39
    #xE8 #xE9 #x6A #x6B #x6C #x6D #x6E #x6F   ; 40-47
    #xF0 #xF1 #xF2 #xF3 #xF4 #xF5 #xF6 #xF7   ; 48-55
    #xF8 #xF9 #x7A #x7B #x7C #x7D #x7E #x7F)  ; 56-63
  "6-bit encoding table for 12-bit buffer addresses.")

(defparameter *6bit-decode*
  (let ((table (make-array 256 :element-type '(unsigned-byte 8) :initial-element 0)))
    (loop :for val :across *6bit-table*
          :for idx :from 0
          :do (setf (aref table val) idx))
    table)
  "Reverse lookup table: EBCDIC byte -> 6-bit value.")

;;; --------------------------------------------------------------------------
;;; Buffer address encoding
;;; --------------------------------------------------------------------------

(defun encode-buffer-address (address cols rows)
  "Encode ADDRESS as a 2-byte buffer address pair.
   Returns (VALUES high-byte low-byte).
   Uses 12-bit encoding for addresses < 4096, 14-bit otherwise."
  (declare (type fixnum address cols rows)
           (ignore cols rows))
  (if (< address 4096)
      ;; 12-bit encoding: 6 bits in each byte via lookup table
      (values (aref *6bit-table* (ldb (byte 6 6) address))
              (aref *6bit-table* (ldb (byte 6 0) address)))
      ;; 14-bit encoding: set top 2 bits of each byte
      (values (logior #x40 (ldb (byte 6 8) address))
              (logior #x40 (ldb (byte 8 0) address)))))

(defun decode-buffer-address (b1 b2)
  "Decode a 2-byte buffer address pair.
   Returns the address as an integer."
  (declare (type (unsigned-byte 8) b1 b2))
  (if (zerop (logand b1 #xC0))
      ;; 14-bit encoding: bits 0-5 of b1 are high, all 8 bits of b2 are low
      ;; Actually check: if top 2 bits of b1 are 00, it's 14-bit
      (logior (ash (logand b1 #x3F) 8) b2)
      ;; 12-bit encoding: decode via table
      (logior (ash (aref *6bit-decode* b1) 6)
              (aref *6bit-decode* b2))))
