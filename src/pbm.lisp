;;;; PBM bitmap font loader
;;;;
;;;; Loads a PBM image containing a grid of glyphs and produces
;;;; a bitmap-font struct compatible with the atlas builder.
;;;;
;;;; Requires cl-netpbm (ql:quickload :cl-netpbm).

(in-package #:lexter/pcf)

;;; --------------------------------------------------------------------------
;;; PBM font loading
;;; --------------------------------------------------------------------------

(defun load-pbm-file (path)
  "Load an uncompressed PCF bitmap font file. Returns a PCF-FONT struct."
  (if (search ".gz" path :test #'char-equal)
      (flex:with-input-from-sequence
          (stream (chipz:decompress nil 'chipz:gzip (alexandria:read-file-into-byte-vector path)))
        (netpbm:read-from-stream stream))
      (netpbm:read-from-file path)))

(defun load-pbm-font (pathname &key glyph-width glyph-height encoding-table)
  "Load a bitmap font from a PBM image file.
   
   GLYPH-WIDTH and GLYPH-HEIGHT specify the pixel dimensions of each glyph.
   The grid layout is derived from the image size divided by glyph size.
   Glyphs are extracted in row-major order (glyph 0 at top-left).
   
   ENCODING-TABLE, if provided, should be a 256-element vector mapping
   byte values (0-255) to Unicode codepoints. If NIL, creates an identity
   mapping (byte N maps to codepoint N).
   
   Returns a BITMAP-FONT struct suitable for use with build-atlas."
  (let* ((image (load-pbm-file pathname))
         ;; NOTE: cl-netpbm transposes the image. PBM header is "width height"
         ;; but netpbm returns array with dim0=width, dim1=height (non-standard).
         ;; We work with this directly: (aref image x y) where x is column, y is row.
         (img-width (array-dimension image 0))
         (img-height (array-dimension image 1))
         ;; Calculate glyph dimensions and grid layout
         (glyph-w (or glyph-width (floor img-width 16)))
         (glyph-h (or glyph-height (floor img-height 16)))
         (grid-cols (floor img-width glyph-w))
         (grid-rows (floor img-height glyph-h))
         (num-glyphs (* grid-cols grid-rows))
         ;; Create glyph arrays
         (bitmaps (make-array num-glyphs))
         (encoding (make-hash-table :test 'eql)))
    ;; Extract each glyph
    (dotimes (glyph-idx num-glyphs)
      (let* ((grid-row (floor glyph-idx grid-cols))
             (grid-col (mod glyph-idx grid-cols))
             (base-x (* grid-col glyph-w))
             (base-y (* grid-row glyph-h))
             (pixels (make-array (* glyph-w glyph-h)
                                 :element-type '(unsigned-byte 8)
                                 :initial-element 0)))
        ;; Copy pixels from PBM into glyph array
        ;; PBM: 1 = black (foreground), 0 = white (background)
        ;; Our format: 255 = foreground, 0 = background
        ;; Note: netpbm array is indexed as (aref image x y)
        (dotimes (row glyph-h)
          (dotimes (col glyph-w)
            (let ((pbm-x (+ base-x col))
                  (pbm-y (+ base-y row))
                  (dst-idx (+ (* row glyph-w) col)))
              (when (and (< pbm-x img-width) (< pbm-y img-height))
                ;; PBM bit array: 1 = black/foreground
                (setf (aref pixels dst-idx)
                      (if (= 1 (aref image pbm-x pbm-y)) 255 0))))))
        (setf (aref bitmaps glyph-idx) pixels)))
    ;; Build encoding table
    (if encoding-table
        ;; Use provided encoding (maps byte values to Unicode codepoints)
        (dotimes (byte-val (min 256 num-glyphs))
          (let ((codepoint (aref encoding-table byte-val)))
            (when (and codepoint (> codepoint 0))
              (setf (gethash codepoint encoding) byte-val))))
        ;; Identity encoding (byte N -> codepoint N)
        (dotimes (i num-glyphs)
          (setf (gethash i encoding) i)))
    ;; Build the font struct
    (make-bitmap-font
     :cell-width glyph-w
     :cell-height glyph-h
     :ascent (- glyph-h 2)  ; Reasonable default
     :glyph-count num-glyphs
     :bitmaps bitmaps
     :encoding encoding)))

(defun load-cp437-font (pathname &key (glyph-width 9) (glyph-height 16))
  "Load a CP437 bitmap font from a PBM file.
   
   GLYPH-WIDTH and GLYPH-HEIGHT specify the pixel dimensions of each glyph.
   Defaults to 9x16, the standard DOS VGA font size.
   
   The encoding table maps CP437 byte values to Unicode codepoints,
   allowing the font to coexist with Unicode fonts in a shared atlas.
   Box-drawing characters, accented letters, etc. will be accessible
   via their standard Unicode codepoints."
  (load-pbm-font pathname
                 :glyph-width glyph-width
                 :glyph-height glyph-height
                 :encoding-table lexter/telnet:+cp437-to-unicode+))
