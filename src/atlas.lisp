(in-package #:pcf-gl/atlas)

;;;; Glyph atlas: packs bitmaps from an ordered list of PCF fonts into a
;;;; single GL_R8 texture.  The first font in the list that covers a given
;;;; codepoint wins.  All fonts must share the same cell dimensions.

(defstruct atlas
  "GPU glyph atlas."
  (texture-id  0  :type (unsigned-byte 32))
  (cell-width  0  :type (unsigned-byte 16))
  (cell-height 0  :type (unsigned-byte 16))
  (cols        0  :type (unsigned-byte 16))  ; atlas width in glyphs
  (rows        0  :type (unsigned-byte 16))  ; atlas height in glyphs
  ;; hash: codepoint -> glyph-index in atlas (0-based)
  (codepoint-table (make-hash-table :test 'eql) :type hash-table)
  ;; vector: glyph-index -> pixel data (for debugging / inspection)
  ;; Not retained after GPU upload in production, kept here for PoC.
  (glyph-pixels #() :type simple-vector))

(defun atlas-glyph-index (atlas codepoint)
  "Return the atlas glyph index for CODEPOINT, or NIL if not covered."
  (gethash codepoint (atlas-codepoint-table atlas)))

;;;; Builder

(defun build-atlas (fonts)
  "Build and upload a glyph atlas from an ordered list of PCF-FONT structs.
   Returns an ATLAS struct with a valid GL texture."
  (assert fonts () "At least one font required")
  (let* ((primary     (first fonts))
         (cell-w      (pcf-font-cell-width  primary))
         (cell-h      (pcf-font-cell-height primary)))
    ;; Validate all fonts have the same cell size
    (dolist (f (rest fonts))
      (unless (and (= (pcf-font-cell-width  f) cell-w)
                   (= (pcf-font-cell-height f) cell-h))
        (error "All fonts in the fallback chain must have the same cell dimensions")))
    ;; Assign a glyph index to each unique codepoint, first-font-wins
    (let* ((codepoint-table (make-hash-table :test 'eql))
           (glyph-list      '()))        ; list of pixel arrays in order
      (dolist (font fonts)
        (maphash (lambda (codepoint glyph-idx-in-font)
                   (unless (gethash codepoint codepoint-table)
                     (let ((atlas-idx (length glyph-list)))
                       (setf (gethash codepoint codepoint-table) atlas-idx)
                       (push (aref (pcf-font-bitmaps font) glyph-idx-in-font)
                             glyph-list))))
                 (pcf-font-encoding font)))
      (let* ((glyph-vec   (coerce (nreverse glyph-list) 'simple-vector))
             (num-glyphs  (length glyph-vec))
             ;; Choose atlas column count: ~32 glyphs wide is a good default
             (atlas-cols  (min 32 num-glyphs))
             (atlas-rows  (ceiling num-glyphs atlas-cols))
             (tex-w       (* atlas-cols cell-w))
             (tex-h       (* atlas-rows cell-h))
             (tex-data    (make-array (* tex-w tex-h)
                                     :element-type '(unsigned-byte 8)
                                     :initial-element 0)))
        ;; Copy each glyph into the right position in the flat texture array.
        ;; PCF bitmaps are top-to-bottom; glTexImage2D treats row 0 as the
        ;; BOTTOM of the texture.  We store rows in natural (top-to-bottom)
        ;; order and compensate in the vertex shader UV formula.
        (dotimes (gi num-glyphs)
          (let* ((gc      (mod gi atlas-cols))
                 (gr      (floor gi atlas-cols))
                 (pixels  (aref glyph-vec gi)))
            (dotimes (row cell-h)
              (dotimes (col cell-w)
                (let ((src-idx (+ (* row cell-w) col))
                      (dst-x   (+ (* gc cell-w) col))
                      (dst-y   (+ (* gr cell-h) row)))
                  (setf (aref tex-data (+ (* dst-y tex-w) dst-x))
                        (aref pixels src-idx)))))))
        ;; Upload to GPU
        (let ((tex-id (first (gl:gen-textures 1))))
          (gl:bind-texture :texture-2d tex-id)
          (gl:tex-parameter :texture-2d :texture-min-filter :nearest)
          (gl:tex-parameter :texture-2d :texture-mag-filter :nearest)
          (gl:tex-parameter :texture-2d :texture-wrap-s :clamp-to-edge)
          (gl:tex-parameter :texture-2d :texture-wrap-t :clamp-to-edge)
          (cffi:with-pointer-to-vector-data (ptr tex-data)
            (gl:tex-image-2d :texture-2d 0 :r8 tex-w tex-h 0 :red :unsigned-byte ptr))
          (gl:bind-texture :texture-2d 0)
          (make-atlas
           :texture-id      tex-id
           :cell-width      cell-w
           :cell-height     cell-h
           :cols            atlas-cols
           :rows            atlas-rows
           :codepoint-table codepoint-table
           :glyph-pixels    glyph-vec))))))
