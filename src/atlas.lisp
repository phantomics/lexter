(in-package #:pcf-gl/atlas)

;;;; Glyph atlas: packs bitmaps from an ordered list of PCF fonts into a
;;;; single GL_R8 texture.  The first font in the list that covers a given
;;;; codepoint wins.  All fonts must share the same cell dimensions.
;;;;
;;;; Cursor glyphs (block, underline, bar) are generated programmatically
;;;; and appended after the font glyphs.

;;; --------------------------------------------------------------------------
;;; Cursor glyph codepoints (private use area to avoid font conflicts)
;;; --------------------------------------------------------------------------

(defconstant +cursor-block-glyph+     #xE000 "Codepoint for block cursor glyph.")
(defconstant +cursor-underline-glyph+ #xE001 "Codepoint for underline cursor glyph.")
(defconstant +cursor-bar-glyph+       #xE002 "Codepoint for bar (I-beam) cursor glyph.")

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

;;; --------------------------------------------------------------------------
;;; Cursor glyph generation
;;; --------------------------------------------------------------------------

(defun %make-block-cursor (cell-w cell-h)
  "Generate a solid block cursor (fully filled cell)."
  (make-array (* cell-w cell-h)
              :element-type '(unsigned-byte 8)
              :initial-element 255))

(defun %make-underline-cursor (cell-w cell-h &key (thickness 2))
  "Generate an underline cursor (bottom THICKNESS rows filled)."
  (let ((pixels (make-array (* cell-w cell-h)
                            :element-type '(unsigned-byte 8)
                            :initial-element 0)))
    (loop :for row :from (- cell-h thickness) :below cell-h
          :do (loop :for col :from 0 :below cell-w
                    :do (setf (aref pixels (+ (* row cell-w) col)) 255)))
    pixels))

(defun %make-bar-cursor (cell-w cell-h &key (width 2))
  "Generate a vertical bar (I-beam) cursor (left WIDTH columns filled)."
  (let ((pixels (make-array (* cell-w cell-h)
                            :element-type '(unsigned-byte 8)
                            :initial-element 0)))
    (loop :for row :from 0 :below cell-h
          :do (loop :for col :from 0 :below width
                    :do (setf (aref pixels (+ (* row cell-w) col)) 255)))
    pixels))

(defun add-cursor-glyphs (atlas)
  "Add cursor glyphs (block, underline, bar) to an existing atlas.
   Modifies the atlas in-place. Cursor glyphs are placed at the private use
   codepoints +cursor-block-glyph+, +cursor-underline-glyph+, +cursor-bar-glyph+.
   
   NOTE: This must be called AFTER build-atlas but BEFORE the atlas is used
   for rendering, as it re-uploads the texture."
  (let* ((cell-w   (atlas-cell-width  atlas))
         (cell-h   (atlas-cell-height atlas))
         (old-vec  (atlas-glyph-pixels atlas))
         (old-n    (length old-vec))
         (cp-table (atlas-codepoint-table atlas))
         ;; Generate new glyphs
         (block-px     (%make-block-cursor     cell-w cell-h))
         (underline-px (%make-underline-cursor cell-w cell-h))
         (bar-px       (%make-bar-cursor       cell-w cell-h))
         ;; New indices
         (block-idx     old-n)
         (underline-idx (1+ old-n))
         (bar-idx       (+ 2 old-n))
         (new-n         (+ old-n 3))
         ;; Extend glyph vector
         (new-vec (make-array new-n :initial-element nil)))
    ;; Copy old glyphs
    (dotimes (i old-n)
      (setf (aref new-vec i) (aref old-vec i)))
    ;; Add cursor glyphs
    (setf (aref new-vec block-idx)     block-px
          (aref new-vec underline-idx) underline-px
          (aref new-vec bar-idx)       bar-px)
    ;; Register codepoints
    (setf (gethash +cursor-block-glyph+     cp-table) block-idx
          (gethash +cursor-underline-glyph+ cp-table) underline-idx
          (gethash +cursor-bar-glyph+       cp-table) bar-idx)
    ;; Rebuild atlas layout
    (let* ((atlas-cols (min 32 new-n))
           (atlas-rows (ceiling new-n atlas-cols))
           (tex-w      (* atlas-cols cell-w))
           (tex-h      (* atlas-rows cell-h))
           (tex-data   (make-array (* tex-w tex-h)
                                   :element-type '(unsigned-byte 8)
                                   :initial-element 0)))
      ;; Copy all glyphs into texture
      (dotimes (gi new-n)
        (let* ((gc     (mod gi atlas-cols))
               (gr     (floor gi atlas-cols))
               (pixels (aref new-vec gi)))
          (dotimes (row cell-h)
            (dotimes (col cell-w)
              (let ((src-idx (+ (* row cell-w) col))
                    (dst-x   (+ (* gc cell-w) col))
                    (dst-y   (+ (* gr cell-h) row)))
                (setf (aref tex-data (+ (* dst-y tex-w) dst-x))
                      (aref pixels src-idx)))))))
      ;; Re-upload texture
      (gl:bind-texture :texture-2d (atlas-texture-id atlas))
      (cffi:with-pointer-to-vector-data (ptr tex-data)
        (gl:tex-image-2d :texture-2d 0 :r8 tex-w tex-h 0 :red :unsigned-byte ptr))
      (gl:bind-texture :texture-2d 0)
      ;; Update atlas struct
      (setf (atlas-cols atlas) atlas-cols
            (atlas-rows atlas) atlas-rows
            (atlas-glyph-pixels atlas) new-vec)
      atlas)))
