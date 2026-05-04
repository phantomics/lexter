(in-package #:lexter/pcf)

;;;; PCF table type constants
(defconstant +pcf-metrics+       4)
(defconstant +pcf-bitmaps+       8)
(defconstant +pcf-bdf-encodings+ 32)

;;;; Format word bit fields
;;   bits 0-1: glyph row pad  (0->1 byte, 1->2 bytes, 2->4 bytes, 3->8 bytes)
;;   bit  2:   byte order     (0->LSB, 1->MSB)
;;   bit  3:   bit order      (0->LSBit first, 1->MSBit first)
;;   bits 4-5: scan unit      (same scale as glyph pad)
;;   bit  8:   compressed metrics flag (PCF_COMPRESSED_METRICS)

(defconstant +compressed-metrics-flag+ #x100)

;;;; Structures

(defstruct bitmap-font
  "A loaded bitmap font (from PCF or BDF)."
  (cell-width   0 :type (unsigned-byte 16))
  (cell-height  0 :type (unsigned-byte 16))
  (ascent       0 :type (unsigned-byte 16))
  (glyph-count  0 :type fixnum)
  ;; Simple-vector of (simple-array (unsigned-byte 8) (*)).
  ;; Each element is cell-width*cell-height bytes, row-major top-to-bottom,
  ;; with 0=background, 255=foreground.
  (bitmaps      #() :type simple-vector)
  ;; Hash table: codepoint (integer) -> glyph index (integer).
  (encoding     (make-hash-table) :type hash-table))

;;;; Binary reading helpers

(declaim (inline read-u8 read-u16-be read-u16-le read-u32-le read-s16-be))

(defun read-u8 (stream)
  (read-byte stream))

(defun read-u16-le (stream)
  (logior (read-byte stream)
          (ash (read-byte stream) 8)))

(defun read-u16-be (stream)
  (logior (ash (read-byte stream) 8)
          (read-byte stream)))

(defun read-u32-le (stream)
  (logior (read-byte stream)
          (ash (read-byte stream) 8)
          (ash (read-byte stream) 16)
          (ash (read-byte stream) 24)))

(defun read-u32-be (stream)
  (logior (ash (read-byte stream) 24)
          (ash (read-byte stream) 16)
          (ash (read-byte stream) 8)
          (read-byte stream)))

(defun read-u16 (stream msb-p)
  (if msb-p (read-u16-be stream) (read-u16-le stream)))

(defun read-u32 (stream msb-p)
  (if msb-p (read-u32-be stream) (read-u32-le stream)))

(defun read-s16 (stream msb-p)
  (let ((v (read-u16 stream msb-p)))
    (if (>= v #x8000) (- v #x10000) v)))

(defun format-msb-p (format)
  (logbitp 2 format))

(defun format-msbit-p (format)
  (logbitp 3 format))

(defun format-row-pad-bytes (format)
  "Number of bytes each bitmap row is padded to."
  (ash 1 (ldb (byte 2 0) format)))

(defun seek-to (stream offset)
  (file-position stream offset))

;;;; Public entry point

(defun load-pcf (path)
  "Load an uncompressed PCF bitmap font file. Returns a PCF-FONT struct."
  (with-open-file (stream path :element-type '(unsigned-byte 8))
    (%parse-pcf stream)))

;;;; Parser internals

(defun %parse-pcf (stream)
  (let ((magic (read-u32-le stream)))
    (unless (= magic #x70636601)
      (error "Not a PCF file (bad magic #x~8,'0X)" magic)))
  (let* ((table-count (read-u32-le stream))
         (toc (loop :repeat table-count
                    :collect (list (read-u32-le stream)   ; type
                                   (read-u32-le stream)   ; format
                                   (read-u32-le stream)   ; size (bytes)
                                   (read-u32-le stream)))) ; file offset
         (metrics-entry   (find +pcf-metrics+       toc :key #'first))
         (bitmaps-entry   (find +pcf-bitmaps+       toc :key #'first))
         (encodings-entry (find +pcf-bdf-encodings+ toc :key #'first)))
    (unless (and metrics-entry bitmaps-entry encodings-entry)
      (error "PCF file is missing required tables (metrics, bitmaps, or encodings)"))
    ;; Parse tables
    (seek-to stream (fourth metrics-entry))
    (multiple-value-bind (metrics cell-width cell-height ascent)
        (%parse-metrics stream)
      (seek-to stream (fourth bitmaps-entry))
      (let ((bitmaps (%parse-bitmaps stream metrics cell-width cell-height)))
        (seek-to stream (fourth encodings-entry))
        (let ((encoding (%parse-encodings stream)))
          (make-bitmap-font
           :cell-width   cell-width
           :cell-height  cell-height
           :ascent       ascent
           :glyph-count  (length metrics)
           :bitmaps      bitmaps
           :encoding     encoding))))))

(defun %parse-metrics (stream)
  "Returns (values metrics-vector cell-width cell-height ascent)."
  (let* ((format      (read-u32-le stream))
         (msb-p       (format-msb-p format))
         (compressed-p (not (zerop (logand format +compressed-metrics-flag+))))
         (count       (if compressed-p
                          (read-u16 stream msb-p)
                          (read-u32 stream msb-p)))
         (metrics     (make-array count)))
    (dotimes (i count)
      (setf (aref metrics i)
            (if compressed-p
                (list :lb  (- (read-u8 stream) 128)
                      :rb  (- (read-u8 stream) 128)
                      :w   (- (read-u8 stream) 128)
                      :asc (- (read-u8 stream) 128)
                      :dsc (- (read-u8 stream) 128))
                (prog1
                    (list :lb  (read-s16 stream msb-p)
                          :rb  (read-s16 stream msb-p)
                          :w   (read-s16 stream msb-p)
                          :asc (read-s16 stream msb-p)
                          :dsc (read-s16 stream msb-p))
                  (read-u16 stream msb-p))))) ; skip attributes word
    (let* ((m0      (aref metrics 0))
           (w       (getf m0 :w))
           (asc     (getf m0 :asc))
           (dsc     (getf m0 :dsc))
           (h       (+ asc dsc)))
      (values metrics w h asc))))

(defun %parse-bitmaps (stream metrics cell-width cell-height)
  "Returns a simple-vector of pixel byte-arrays, one per glyph."
  (let* ((format      (read-u32-le stream))
         (msb-p       (format-msb-p format))
         (msbit-p     (format-msbit-p format))
         (pad-bytes   (format-row-pad-bytes format))
         (count       (read-u32 stream msb-p))
         ;; Per-glyph byte offsets into the raw bitmap blob
         (offsets     (let ((v (make-array count :element-type '(unsigned-byte 32))))
                        (dotimes (i count v)
                          (setf (aref v i) (read-u32 stream msb-p)))))
         ;; Total bitmap sizes for each padding type (we read all 4, use ours)
         (pad-index   (ldb (byte 2 0) format))
         (total-size  (let ((sizes (make-array 4 :element-type '(unsigned-byte 32))))
                        (dotimes (i 4)
                          (setf (aref sizes i) (read-u32 stream msb-p)))
                        (aref sizes pad-index)))
         (raw         (let ((v (make-array total-size :element-type '(unsigned-byte 8))))
                        (read-sequence v stream)
                        v))
         (row-stride  (%padded-row-stride cell-width pad-bytes))
         (bitmaps     (make-array count)))
    (declare (ignore metrics))
    (dotimes (i count bitmaps)
      (setf (aref bitmaps i)
            (%extract-bitmap raw (aref offsets i)
                             cell-width cell-height row-stride msbit-p)))))

(defun %padded-row-stride (width pad-bytes)
  "Byte width of one bitmap row, padded to PAD-BYTES boundary."
  (let ((raw-bytes (ceiling width 8)))
    (* (ceiling raw-bytes pad-bytes) pad-bytes)))

(defun %extract-bitmap (raw offset width height row-stride msbit-p)
  "Unpack a glyph's 1-bit rows into a flat (unsigned-byte 8) pixel array.
   Output is WIDTH x HEIGHT, row-major top-to-bottom, 0=bg 255=fg."
  (let ((pixels (make-array (* width height) :element-type '(unsigned-byte 8)
                                             :initial-element 0)))
    (dotimes (row height)
      (let ((row-base (+ offset (* row row-stride))))
        (dotimes (col width)
          (let* ((byte-off (+ row-base (floor col 8)))
                 (byte-val (aref raw byte-off))
                 (bit-pos  (if msbit-p
                               (- 7 (mod col 8))
                               (mod col 8)))
                 (bit-val  (ldb (byte 1 bit-pos) byte-val)))
            (setf (aref pixels (+ (* row width) col))
                  (if (zerop bit-val) 0 255))))))
    pixels))

(defun %parse-encodings (stream)
  "Returns a hash table mapping codepoint -> glyph-index."
  (let* ((format  (read-u32-le stream))
         (msb-p   (format-msb-p format))
         ;; Header: 5 x INT16 (per Xlib pcf source — NOT int32)
         (min-b2  (read-s16 stream msb-p))
         (max-b2  (read-s16 stream msb-p))
         (min-b1  (read-s16 stream msb-p))
         (max-b1  (read-s16 stream msb-p))
         (_       (read-s16 stream msb-p))  ; default_char (ignored)
         (range2  (- max-b2 min-b2 -1))
         (range1  (- max-b1 min-b1 -1))
         (count   (* range2 range1))
         (table   (make-hash-table :test 'eql :size 1024)))
    (declare (ignore _))
    (dotimes (b1-off range1 table)
      (let ((b1 (+ min-b1 b1-off)))
        (dotimes (b2-off range2)
          (let* ((b2  (+ min-b2 b2-off))
                 (idx (read-u16 stream msb-p)))
            (unless (= idx #xFFFF)
              (let ((codepoint (if (zerop b1) b2 (logior (ash b1 8) b2))))
                (setf (gethash codepoint table) idx)))))))))

;;;; Public query

(defun glyph-index (font codepoint)
  "Return the glyph index for CODEPOINT in FONT, or NIL if not covered."
  (gethash codepoint (bitmap-font-encoding font)))

;;; ==========================================================================
;;; BDF Loader
;;; ==========================================================================
;;;
;;; BDF (Bitmap Distribution Format) is a plain-text font format.
;;; It's the source format that gets compiled to PCF by bdftopcf.

(defun load-bdf (path)
  "Load a BDF bitmap font file. Returns a BITMAP-FONT struct."
  (with-open-file (stream path :direction :input)
    (%parse-bdf stream)))

(defun %bdf-parse-line (line)
  "Parse a BDF line into (keyword . rest-of-line) or NIL for empty/comment."
  (let ((trimmed (string-trim '(#\Space #\Tab) line)))
    (when (and (> (length trimmed) 0)
               (char/= (char trimmed 0) #\#))  ; skip comments
      (let ((space-pos (position #\Space trimmed)))
        (if space-pos
            (cons (subseq trimmed 0 space-pos)
                  (string-trim '(#\Space #\Tab) (subseq trimmed space-pos)))
            (cons trimmed ""))))))

(defun %bdf-parse-integers (string)
  "Parse space-separated integers from STRING."
  (with-input-from-string (s string)
    (loop :for val = (read s nil nil)
          :while val
          :collect val)))

(defun %parse-bdf (stream)
  "Parse a BDF file, returning a BITMAP-FONT struct."
  (let ((cell-width nil)
        (cell-height nil)
        (ascent nil)
        (font-y-offset nil)
        (glyph-list '())
        (encoding-table (make-hash-table :test 'eql)))
    ;; First pass: read header to get FONTBOUNDINGBOX and FONT_ASCENT
    (loop :for line = (read-line stream nil nil)
          :while line
          :do (let ((parsed (%bdf-parse-line line)))
                (when parsed
                  (let ((keyword (car parsed))
                        (rest (cdr parsed)))
                    (cond
                      ((string= keyword "FONTBOUNDINGBOX")
                       (destructuring-bind (w h xoff yoff)
                           (%bdf-parse-integers rest)
                         (declare (ignore xoff))
                         (setf cell-width w
                               cell-height h
                               font-y-offset yoff)))
                      ((string= keyword "FONT_ASCENT")
                       (setf ascent (parse-integer rest)))
                      ((string= keyword "CHARS")
                       ;; Done with header, move to glyph parsing
                       (return)))))))
    ;; Validate header
    (unless (and cell-width cell-height)
      (error "BDF file missing FONTBOUNDINGBOX"))
    (unless ascent
      ;; Compute ascent from cell-height and font-y-offset if not explicit
      (setf ascent (+ cell-height (or font-y-offset 0))))
    ;; Second pass: parse each glyph
    (loop :for line = (read-line stream nil nil)
          :while line
          :do (let ((parsed (%bdf-parse-line line)))
                (when (and parsed (string= (car parsed) "STARTCHAR"))
                  (multiple-value-bind (codepoint pixels)
                      (%parse-bdf-glyph stream cell-width cell-height ascent)
                    (when (and codepoint pixels)
                      (let ((glyph-idx (length glyph-list)))
                        (push pixels glyph-list)
                        (setf (gethash codepoint encoding-table) glyph-idx)))))))
    ;; Build the font struct
    (let ((bitmaps (coerce (nreverse glyph-list) 'simple-vector)))
      (make-bitmap-font
       :cell-width   cell-width
       :cell-height  cell-height
       :ascent       ascent
       :glyph-count  (length bitmaps)
       :bitmaps      bitmaps
       :encoding     encoding-table))))

(defun %parse-bdf-glyph (stream cell-width cell-height font-ascent)
  "Parse a single glyph from STARTCHAR to ENDCHAR.
   Returns (values codepoint pixel-array) or (values nil nil) on error."
  (let ((codepoint nil)
        (bbx-w nil) (bbx-h nil) (bbx-xoff nil) (bbx-yoff nil)
        (bitmap-lines '()))
    ;; Read glyph properties until BITMAP
    (loop :for line = (read-line stream nil nil)
          :while line
          :do (let ((parsed (%bdf-parse-line line)))
                (when parsed
                  (let ((keyword (car parsed))
                        (rest (cdr parsed)))
                    (cond
                      ((string= keyword "ENCODING")
                       (setf codepoint (parse-integer rest)))
                      ((string= keyword "BBX")
                       (destructuring-bind (w h xoff yoff)
                           (%bdf-parse-integers rest)
                         (setf bbx-w w bbx-h h bbx-xoff xoff bbx-yoff yoff)))
                      ((string= keyword "BITMAP")
                       (return))
                      ((string= keyword "ENDCHAR")
                       ;; Empty glyph (no bitmap section)
                       (return-from %parse-bdf-glyph (values nil nil))))))))
    ;; Read hex bitmap lines until ENDCHAR
    (loop :for line = (read-line stream nil nil)
          :while line
          :do (let ((trimmed (string-trim '(#\Space #\Tab) line)))
                (cond
                  ((string= trimmed "ENDCHAR") (return))
                  ((> (length trimmed) 0)
                   (push trimmed bitmap-lines)))))
    (setf bitmap-lines (nreverse bitmap-lines))
    ;; Validate we have what we need
    (unless (and codepoint bbx-w bbx-h bbx-xoff bbx-yoff)
      (return-from %parse-bdf-glyph (values nil nil)))
    ;; Decode the bitmap
    (let ((pixels (%decode-bdf-bitmap bitmap-lines
                                       bbx-w bbx-h bbx-xoff bbx-yoff
                                       cell-width cell-height font-ascent)))
      (values codepoint pixels))))

(defun %hex-char-value (char)
  "Return the numeric value of a hex character, or NIL."
  (cond
    ((char<= #\0 char #\9) (- (char-code char) (char-code #\0)))
    ((char<= #\A char #\F) (+ 10 (- (char-code char) (char-code #\A))))
    ((char<= #\a char #\f) (+ 10 (- (char-code char) (char-code #\a))))
    (t nil)))

(defun %decode-bdf-bitmap (hex-lines bbx-w bbx-h bbx-xoff bbx-yoff
                                      cell-width cell-height font-ascent)
  "Decode BDF hex bitmap lines into a cell-sized pixel array.
   BBX offsets position the glyph within the cell."
  ;; Create cell-sized output, all zeros (background)
  (let* ((pixels (make-array (* cell-width cell-height)
                             :element-type '(unsigned-byte 8)
                             :initial-element 0))
         ;; Calculate where the glyph goes in the cell
         ;; X: bbx-xoff from the left edge
         ;; Y: baseline is at (font-ascent) from top; glyph bottom is at baseline + bbx-yoff
         ;;    So glyph top row is at: font-ascent - (bbx-yoff + bbx-h)
         (glyph-x bbx-xoff)
         (glyph-y (- font-ascent bbx-yoff bbx-h)))
    ;; Decode each hex line
    (loop :for hex-line :in hex-lines
          :for src-row :from 0 :below bbx-h
          :do (let ((dst-row (+ glyph-y src-row)))
                (when (and (>= dst-row 0) (< dst-row cell-height))
                  ;; Decode hex string to bits
                  (loop :for col :from 0 :below bbx-w
                        :for dst-col = (+ glyph-x col)
                        :when (and (>= dst-col 0) (< dst-col cell-width))
                        :do (let* ((hex-idx (floor col 4))
                                   (bit-in-nibble (- 3 (mod col 4)))
                                   (hex-char (if (< hex-idx (length hex-line))
                                                 (char hex-line hex-idx)
                                                 #\0))
                                   (nibble (%hex-char-value hex-char))
                                   (bit-val (if nibble
                                                (ldb (byte 1 bit-in-nibble) nibble)
                                                0)))
                              (when (= bit-val 1)
                                (setf (aref pixels (+ (* dst-row cell-width) dst-col))
                                      255)))))))
    pixels))
