(in-package #:lexter/pcf)

;;;; PCF table type constants
(defconstant +pcf-metrics+           4)
(defconstant +pcf-bitmaps+           8)
(defconstant +pcf-bdf-encodings+    32)
(defconstant +pcf-accelerators+      2)
(defconstant +pcf-bdf-accelerators+ 256)

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
  ;; Each element is cell-width*cell-height bytes for narrow glyphs,
  ;; or 2*cell-width*cell-height bytes for wide glyphs.
  ;; Row-major top-to-bottom, 0=background, 255=foreground.
  (bitmaps      #() :type simple-vector)
  ;; Hash table: codepoint (integer) -> glyph index (integer).
  (encoding     (make-hash-table) :type hash-table)
  ;; Hash table: font-internal glyph index -> t for double-wide glyphs.
  ;; NIL if font has no wide glyphs.
  (wide-glyphs  nil :type (or null hash-table)))

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

(defun read-s32 (stream msb-p)
  (let ((v (read-u32 stream msb-p)))
    (if (>= v #x80000000) (- v #x100000000) v)))

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

(defun %parse-accelerators (stream)
  "Parse a PCF accelerators table (type 2 or 256).
   Returns (values font-ascent font-descent max-width) or NIL on failure.
   The accelerator table structure (per X11/pcf.h):
     CARD8  noOverlap, constantMetrics, terminalFont, constantWidth,
            inkInside, inkMetrics, drawDirection, padding
     INT32  fontAscent
     INT32  fontDescent
     INT32  maxOverlap
     then min/max metrics bounds."
  (let* ((format (read-u32-le stream))
         (msb-p  (format-msb-p format)))
    ;; Skip 8 flag bytes (noOverlap..padding)
    (dotimes (i 8) (read-u8 stream))
    ;; Read fontAscent, fontDescent, maxOverlap
    (let ((font-ascent  (read-s32 stream msb-p))
          (font-descent (read-s32 stream msb-p))
          (_max-overlap (read-s32 stream msb-p)))
      (declare (ignore _max-overlap))
      ;; Read min bounds (6 INT16 values: lb, rb, w, asc, dsc, pad)
      (dotimes (i 6) (read-s16 stream msb-p))
      ;; Read max bounds
      (let ((_lb  (read-s16 stream msb-p))
            (_rb  (read-s16 stream msb-p))
            (max-w (read-s16 stream msb-p)))
        (declare (ignore _lb _rb))
        ;; Skip remaining max bounds fields (asc, dsc, pad)
        (dotimes (i 3) (read-s16 stream msb-p))
        (values font-ascent font-descent max-w)))))

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
         (encodings-entry (find +pcf-bdf-encodings+ toc :key #'first))
         ;; Prefer BDF_ACCELERATORS, fall back to ACCELERATORS
         (accel-entry     (or (find +pcf-bdf-accelerators+ toc :key #'first)
                              (find +pcf-accelerators+     toc :key #'first))))
    (unless (and metrics-entry bitmaps-entry encodings-entry)
      (error "PCF file is missing required tables (metrics, bitmaps, or encodings)"))
    ;; Parse metrics (gives per-glyph data and a fallback cell size from glyph 0)
    (seek-to stream (fourth metrics-entry))
    (multiple-value-bind (metrics glyph0-width glyph0-height glyph0-ascent)
        (%parse-metrics stream)
      ;; Parse accelerators for authoritative font-level dimensions
      (multiple-value-bind (accel-ascent accel-descent accel-max-w)
          (if accel-entry
              (progn (seek-to stream (fourth accel-entry))
                     (%parse-accelerators stream))
              (values nil nil nil))
        ;; Determine cell dimensions:
        ;; Height: prefer accelerators (fontAscent + fontDescent), fall back to glyph 0
        ;; Width:  prefer glyph 0's :w (advance width), fall back to accelerators max-w
        ;; Ascent: prefer accelerators fontAscent, fall back to glyph 0
        (let* ((cell-width  (or glyph0-width accel-max-w))
               (cell-height (if (and accel-ascent accel-descent)
                                (+ accel-ascent accel-descent)
                                glyph0-height))
               (ascent      (or accel-ascent glyph0-ascent)))
          (seek-to stream (fourth bitmaps-entry))
          (let ((bitmaps (%parse-bitmaps stream metrics cell-width cell-height ascent)))
            (seek-to stream (fourth encodings-entry))
            (let ((encoding (%parse-encodings stream))
                  (wide-table nil))
              ;; Detect wide glyphs: any glyph whose :w > cell-width
              (dotimes (i (length metrics))
                (let ((w (getf (aref metrics i) :w)))
                  (when (and w (> w cell-width))
                    (unless wide-table
                      (setf wide-table (make-hash-table :test 'eql)))
                    (setf (gethash i wide-table) t))))
              (make-bitmap-font
               :cell-width   cell-width
               :cell-height  cell-height
               :ascent       ascent
               :glyph-count  (length metrics)
               :bitmaps      bitmaps
               :encoding     encoding
               :wide-glyphs  wide-table))))))))

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

(defun %parse-bitmaps (stream metrics cell-width cell-height font-ascent)
  "Returns a simple-vector of pixel byte-arrays, one per glyph.
   Each glyph's raw bitmap covers its ink bounding box (per-glyph :asc + :dsc rows).
   The output pixel array is cell-width x cell-height, with the glyph's ink
   positioned within the cell using its ascent relative to FONT-ASCENT."
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
         (bitmaps     (make-array count)))
    (dotimes (i count bitmaps)
      (let* ((m (aref metrics i))
             (glyph-asc (getf m :asc))
             (glyph-dsc (getf m :dsc))
             (glyph-ink-h (max 0 (+ glyph-asc glyph-dsc)))
             ;; Row stride based on cell-width (advance width)
             (row-stride (%padded-row-stride cell-width pad-bytes))
             ;; Position ink within the cell: top row of ink = font-ascent - glyph-ascent
             (y-offset (- font-ascent glyph-asc)))
        (setf (aref bitmaps i)
              (%extract-bitmap-positioned raw (aref offsets i)
                                          cell-width cell-height
                                          glyph-ink-h y-offset
                                          row-stride msbit-p))))))

(defun %padded-row-stride (width pad-bytes)
  "Byte width of one bitmap row, padded to PAD-BYTES boundary."
  (let ((raw-bytes (ceiling width 8)))
    (* (ceiling raw-bytes pad-bytes) pad-bytes)))

(defun %extract-bitmap-positioned (raw offset cell-width cell-height
                                   ink-height y-offset row-stride msbit-p)
  "Unpack a glyph's 1-bit rows into a cell-sized pixel array.
   INK-HEIGHT is the number of rows in the raw bitmap data.
   Y-OFFSET is where the ink starts within the cell (from top).
   Output is CELL-WIDTH x CELL-HEIGHT, row-major, 0=bg 255=fg."
  (let ((pixels (make-array (* cell-width cell-height)
                            :element-type '(unsigned-byte 8)
                            :initial-element 0)))
    (dotimes (ink-row ink-height)
      (let ((dst-row (+ y-offset ink-row)))
        (when (and (>= dst-row 0) (< dst-row cell-height))
          (let ((row-base (+ offset (* ink-row row-stride))))
            (dotimes (col cell-width)
              (let* ((byte-off (+ row-base (floor col 8)))
                     (byte-val (if (< byte-off (length raw))
                                   (aref raw byte-off)
                                   0))
                     (bit-pos  (if msbit-p
                                   (- 7 (mod col 8))
                                   (mod col 8)))
                     (bit-val  (ldb (byte 1 bit-pos) byte-val)))
                (when (= bit-val 1)
                  (setf (aref pixels (+ (* dst-row cell-width) col)) 255))))))))
    pixels))

(defun %extract-bitmap (raw offset width height row-stride msbit-p)
  "Unpack a glyph's 1-bit rows into a flat (unsigned-byte 8) pixel array.
   Output is WIDTH x HEIGHT, row-major top-to-bottom, 0=bg 255=fg.
   Legacy function - used when ink height equals cell height."
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

(defun load-bdf (path &key cell-width cell-height)
  "Load a BDF bitmap font file. Returns a BITMAP-FONT struct.
   CELL-WIDTH and CELL-HEIGHT override the FONTBOUNDINGBOX dimensions.
   This is useful for fonts like zpix where the bounding box is larger
   than the actual cell size.  Glyphs with DWIDTH > cell-width are
   treated as double-wide and get 2*cell-width pixel arrays."
  (with-open-file (stream path :direction :input)
    (%parse-bdf stream :cell-width cell-width :cell-height cell-height)))

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

(defun %parse-bdf (stream &key cell-width cell-height)
  "Parse a BDF file, returning a BITMAP-FONT struct.
   CELL-WIDTH and CELL-HEIGHT, if provided, override FONTBOUNDINGBOX dimensions.
   Glyphs with DWIDTH > cell-width are treated as double-wide."
  (let ((fbb-width nil)
        (fbb-height nil)
        (ascent nil)
        (font-y-offset nil)
        (glyph-list '())
        (encoding-table (make-hash-table :test 'eql))
        (wide-table nil))  ; hash table of wide glyph indices, created on demand
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
                         (setf fbb-width w
                               fbb-height h
                               font-y-offset yoff)))
                      ((string= keyword "FONT_ASCENT")
                       (setf ascent (parse-integer rest)))
                      ((string= keyword "CHARS")
                       ;; Done with header, move to glyph parsing
                       (return)))))))
    ;; Apply overrides or fall back to FONTBOUNDINGBOX
    (let ((cw (or cell-width fbb-width))
          (ch (or cell-height fbb-height)))
      (unless (and cw ch)
        (error "BDF file missing FONTBOUNDINGBOX and no cell size overrides given"))
      (unless ascent
        ;; Compute ascent from fbb-height and font-y-offset if not explicit
        (setf ascent (+ (or fbb-height ch) (or font-y-offset 0))))
      ;; Second pass: parse each glyph
      (loop :for line = (read-line stream nil nil)
            :while line
            :do (let ((parsed (%bdf-parse-line line)))
                  (when (and parsed (string= (car parsed) "STARTCHAR"))
                    (multiple-value-bind (codepoint pixels dwidth)
                        (%parse-bdf-glyph stream cw ch ascent)
                      (when (and codepoint pixels)
                        (let* ((glyph-idx (length glyph-list))
                               (wide-p (and dwidth (> dwidth cw))))
                          (when wide-p
                            ;; Pixels already decoded at 2*cw width by
                            ;; %parse-bdf-glyph; just record in wide table
                            (unless wide-table
                              (setf wide-table (make-hash-table :test 'eql)))
                            (setf (gethash glyph-idx wide-table) t))
                          (push pixels glyph-list)
                          (setf (gethash codepoint encoding-table) glyph-idx)))))))
      ;; Build the font struct
      (let ((bitmaps (coerce (nreverse glyph-list) 'simple-vector)))
        (make-bitmap-font
         :cell-width   cw
         :cell-height  ch
         :ascent       ascent
         :glyph-count  (length bitmaps)
         :bitmaps      bitmaps
         :encoding     encoding-table
         :wide-glyphs  wide-table)))))

(defun %parse-bdf-glyph (stream cell-width cell-height font-ascent)
  "Parse a single glyph from STARTCHAR to ENDCHAR.
   Returns (values codepoint pixel-array dwidth) or (values nil nil nil) on error.
   DWIDTH is the glyph's device width in pixels (for detecting wide characters)."
  (let ((codepoint nil)
        (dwidth nil)
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
                      ((string= keyword "DWIDTH")
                       (let ((vals (%bdf-parse-integers rest)))
                         (setf dwidth (first vals))))
                      ((string= keyword "BBX")
                       (destructuring-bind (w h xoff yoff)
                           (%bdf-parse-integers rest)
                         (setf bbx-w w bbx-h h bbx-xoff xoff bbx-yoff yoff)))
                      ((string= keyword "BITMAP")
                       (return))
                      ((string= keyword "ENDCHAR")
                       ;; Empty glyph (no bitmap section)
                       (return-from %parse-bdf-glyph (values nil nil nil))))))))
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
      (return-from %parse-bdf-glyph (values nil nil nil)))
    ;; Decode the bitmap. For wide glyphs (DWIDTH > cell-width), render into
    ;; 2*cell-width so the full glyph data is preserved.
    (let* ((render-width (if (and dwidth (> dwidth cell-width))
                             (* 2 cell-width)
                             cell-width))
           (pixels (%decode-bdf-bitmap bitmap-lines
                                        bbx-w bbx-h bbx-xoff bbx-yoff
                                        render-width cell-height font-ascent)))
      (values codepoint pixels dwidth))))

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
