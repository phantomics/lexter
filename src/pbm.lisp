;;;; PBM bitmap font loader
;;;;
;;;; Loads a PBM image containing a 16x16 grid of 256 glyphs and produces
;;;; a bitmap-font struct compatible with the atlas builder.
;;;;
;;;; Requires cl-netpbm (ql:quickload :cl-netpbm).

(in-package #:lexter/pcf)

;;; --------------------------------------------------------------------------
;;; PBM font loading
;;; --------------------------------------------------------------------------

(defun load-pbm-font (pathname &key encoding-table)
  "Load a bitmap font from a PBM image file.
   
   The PBM should contain a 16x16 grid of 256 glyphs arranged in
   row-major order (glyph 0 at top-left, glyph 255 at bottom-right).
   
   ENCODING-TABLE, if provided, should be a 256-element vector mapping
   byte values (0-255) to Unicode codepoints. If NIL, creates an identity
   mapping (byte N maps to codepoint N).
   
   Returns a BITMAP-FONT struct suitable for use with build-atlas."
  (let* ((image (netpbm:read-from-file pathname))
         (height (array-dimension image 0))
         (width (array-dimension image 1))
         ;; Calculate glyph dimensions (16x16 grid)
         (glyph-w (floor width 16))
         (glyph-h (floor height 16))
         ;; Create glyph arrays
         (bitmaps (make-array 256))
         (encoding (make-hash-table :test 'eql)))
    ;; Extract each glyph
    (dotimes (glyph-idx 256)
      (let* ((grid-row (floor glyph-idx 16))
             (grid-col (mod glyph-idx 16))
             (base-y (* grid-row glyph-h))
             (base-x (* grid-col glyph-w))
             (pixels (make-array (* glyph-w glyph-h)
                                 :element-type '(unsigned-byte 8)
                                 :initial-element 0)))
        ;; Copy pixels from PBM into glyph array
        ;; PBM: 1 = black (foreground), 0 = white (background)
        ;; Our format: 255 = foreground, 0 = background
        (dotimes (row glyph-h)
          (dotimes (col glyph-w)
            (let ((pbm-y (+ base-y row))
                  (pbm-x (+ base-x col))
                  (dst-idx (+ (* row glyph-w) col)))
              (when (and (< pbm-y height) (< pbm-x width))
                ;; PBM bit array: 1 = black/foreground
                (setf (aref pixels dst-idx)
                      (if (= 1 (aref image pbm-y pbm-x)) 255 0))))))
        (setf (aref bitmaps glyph-idx) pixels)))
    ;; Build encoding table
    (if encoding-table
        ;; Use provided encoding (maps byte values to Unicode codepoints)
        (dotimes (byte-val 256)
          (let ((codepoint (aref encoding-table byte-val)))
            (when (and codepoint (> codepoint 0))
              (setf (gethash codepoint encoding) byte-val))))
        ;; Identity encoding (byte N -> codepoint N)
        (dotimes (i 256)
          (setf (gethash i encoding) i)))
    ;; Build the font struct
    (make-bitmap-font
     :cell-width glyph-w
     :cell-height glyph-h
     :ascent (- glyph-h 2)  ; Reasonable default
     :glyph-count 256
     :bitmaps bitmaps
     :encoding encoding)))

(defun load-cp437-font (pathname)
  "Load a CP437 bitmap font from a PBM file.
   
   The encoding table maps CP437 byte values to Unicode codepoints,
   allowing the font to coexist with Unicode fonts in a shared atlas.
   Box-drawing characters, accented letters, etc. will be accessible
   via their standard Unicode codepoints."
  (load-pbm-font pathname
                 :encoding-table lexter/telnet:+cp437-to-unicode+))
