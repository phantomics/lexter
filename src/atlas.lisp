(in-package #:lexter/atlas)

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
  (cols        0  :type (unsigned-byte 16))  ; atlas width in glyph columns (single-width units)
  (rows        0  :type (unsigned-byte 16))  ; atlas height in glyph rows
  ;; hash: codepoint -> atlas-position (0-based column index in the atlas grid)
  (codepoint-table (make-hash-table :test 'eql) :type hash-table)
  ;; hash: atlas-position -> t for double-wide glyphs. NIL if none.
  (wide-set    nil :type (or null hash-table))
  ;; hash: atlas-position -> pixel-array for texture rebuilds (e.g. adding cursors)
  (position-pixels (make-hash-table :test 'eql) :type hash-table))

(defun atlas-glyph-index (atlas codepoint)
  "Return the atlas glyph index for CODEPOINT, or NIL if not covered."
  (gethash codepoint (atlas-codepoint-table atlas)))

(defun atlas-glyph-wide-p (atlas glyph-index)
  "Return T if the glyph at GLYPH-INDEX is double-wide."
  (let ((ws (atlas-wide-set atlas)))
    (and ws (gethash glyph-index ws))))

;;;; Builder

(defun build-atlas (fonts)
  "Build and upload a glyph atlas from an ordered list of BITMAP-FONT structs.
   Returns an ATLAS struct with a valid GL texture.
   Double-wide glyphs occupy 2 adjacent atlas columns and are tracked in wide-set."
  (assert fonts () "At least one font required")
  (let* ((primary     (first fonts))
         (cell-w      (bitmap-font-cell-width  primary))
         (cell-h      (bitmap-font-cell-height primary)))
    ;; Validate all fonts have the same cell size
    (dolist (f (rest fonts))
      (unless (and (= (bitmap-font-cell-width  f) cell-w)
                   (= (bitmap-font-cell-height f) cell-h))
        (error "All fonts in the fallback chain must have the same cell dimensions")))
    ;; Collect glyphs: list of (codepoint pixels wide-p), first-font-wins
    (let ((codepoint-seen (make-hash-table :test 'eql))
          (glyph-entries  '()))
      (dolist (font fonts)
        (maphash (lambda (codepoint glyph-idx-in-font)
                   (unless (gethash codepoint codepoint-seen)
                     (setf (gethash codepoint codepoint-seen) t)
                     (let ((wide-p (and (bitmap-font-wide-glyphs font)
                                        (gethash glyph-idx-in-font
                                                 (bitmap-font-wide-glyphs font)))))
                       (push (list codepoint
                                   (aref (bitmap-font-bitmaps font) glyph-idx-in-font)
                                   wide-p)
                             glyph-entries))))
                 (bitmap-font-encoding font)))
      (setf glyph-entries (nreverse glyph-entries))
      ;; Choose atlas column count so the texture is roughly square and stays
      ;; within GL_MAX_TEXTURE_SIZE. A fixed small column count makes a large
      ;; font (e.g. Unifont, ~57k glyphs) produce a texture thousands of pixels
      ;; tall, exceeding the GL limit and failing tex-image-2d with INVALID_VALUE.
      ;; SLOT-COUNT counts column slots (double-wide glyphs occupy two).
      (let* ((slot-count  (loop :for e :in glyph-entries :sum (if (third e) 2 1)))
             (max-tex     (let ((m (gl:get-integer :max-texture-size)))
                            (max 1024 (if (numberp m) m (elt m 0)))))
             (max-cols    (max 2 (floor max-tex cell-w)))
             ;; cols such that cols*cell-w ~= (slots/cols)*cell-h  =>  square
             (square-cols (max 2 (ceiling (sqrt (/ (* (max 1 slot-count) (max 1 cell-h))
                                                   (max 1 cell-w))))))
             (atlas-cols  (max 2 (min max-cols (max 32 square-cols))))
             ;; (atlas-cols (min 32 (max 2 (length glyph-entries))))
             )
        ;; Pack: assign atlas column positions, skipping to next row for wide glyphs        ;; that would straddle a row boundary
        (let ((codepoint-table (make-hash-table :test 'eql))
              (wide-set nil)
              (pos-pixels (make-hash-table :test 'eql))
              (cur-col 0) (cur-row 0))
          (dolist (entry glyph-entries)
            (destructuring-bind (codepoint pixels wide-p) entry
              (when (and wide-p (> cur-col (- atlas-cols 2)))
                (setf cur-col 0)
                (incf cur-row))
              (let ((atlas-pos (+ (* cur-row atlas-cols) cur-col)))
                (setf (gethash codepoint codepoint-table) atlas-pos)
                (setf (gethash atlas-pos pos-pixels) pixels)
                (when wide-p
                  (unless wide-set
                    (setf wide-set (make-hash-table :test 'eql)))
                  (setf (gethash atlas-pos wide-set) t)))
              (incf cur-col (if wide-p 2 1))
              (when (>= cur-col atlas-cols)
                (setf cur-col 0)
                (incf cur-row))))
          ;; Compute final atlas dimensions
          (let* ((atlas-rows (1+ cur-row))
                 (tex-w      (* atlas-cols cell-w))
                 (tex-h      (* atlas-rows cell-h)))
            (when (or (> tex-w max-tex) (> tex-h max-tex))
              (error "Glyph atlas ~dx~d exceeds GL_MAX_TEXTURE_SIZE (~d). ~
                      Font has ~d glyphs (~d column slots) at ~dx~d cells -- too ~
                      large to atlas in a single texture."
                     tex-w tex-h max-tex (length glyph-entries) slot-count cell-w cell-h))
            (let ((tex-data (make-array (* tex-w tex-h)
                                        :element-type '(unsigned-byte 8)
                                        :initial-element 0)))
            ;; Blit all glyphs into texture
            (maphash (lambda (atlas-pos pixels)
                       (let* ((gc  (mod atlas-pos atlas-cols))
                              (gr  (floor atlas-pos atlas-cols))
                              (wide-p (and wide-set (gethash atlas-pos wide-set)))
                              (glyph-w (if wide-p (* 2 cell-w) cell-w)))
                         (dotimes (row cell-h)
                           (dotimes (col glyph-w)
                             (let ((src-idx (+ (* row glyph-w) col))
                                   (dst-x   (+ (* gc cell-w) col))
                                   (dst-y   (+ (* gr cell-h) row)))
                               (when (and (< src-idx (length pixels))
                                          (< dst-x tex-w) (< dst-y tex-h))
                                 (setf (aref tex-data (+ (* dst-y tex-w) dst-x))
                                       (aref pixels src-idx))))))))
                     pos-pixels)
            ;; Upload to GPU
            (let ((tex-id (first (gl:gen-textures 1))))
              (gl:bind-texture :texture-2d tex-id)
              (gl:tex-parameter :texture-2d :texture-min-filter :nearest)
              (gl:tex-parameter :texture-2d :texture-mag-filter :nearest)
              (gl:tex-parameter :texture-2d :texture-wrap-s :clamp-to-edge)
              (gl:tex-parameter :texture-2d :texture-wrap-t :clamp-to-edge)
              (cffi:with-pointer-to-vector-data (ptr tex-data)
                (gl:tex-image-2d :texture-2d 0 :r8 tex-w tex-h 0
                                 :red :unsigned-byte ptr))
              (gl:bind-texture :texture-2d 0)
              (make-atlas
               :texture-id      tex-id
               :cell-width      cell-w
               :cell-height     cell-h
               :cols            atlas-cols
               :rows            atlas-rows
                :codepoint-table codepoint-table
                :wide-set        wide-set
                :position-pixels pos-pixels)))))))))

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
  (let* ((cell-w    (atlas-cell-width  atlas))
         (cell-h    (atlas-cell-height atlas))
         (cp-table  (atlas-codepoint-table atlas))
         (wide-set  (atlas-wide-set atlas))
         (pos-pixels (atlas-position-pixels atlas))
         ;; Generate new glyphs
         (block-px     (%make-block-cursor     cell-w cell-h))
         (underline-px (%make-underline-cursor cell-w cell-h))
         (bar-px       (%make-bar-cursor       cell-w cell-h)))
    ;; Find the next available atlas column position
    (let ((max-pos 0))
      (maphash (lambda (pos _)
                 (declare (ignore _))
                 (let ((end (+ pos (if (and wide-set (gethash pos wide-set)) 2 1))))
                   (when (> end max-pos) (setf max-pos end))))
               pos-pixels)
      (let ((block-idx     max-pos)
            (underline-idx (1+ max-pos))
            (bar-idx       (+ 2 max-pos)))
        ;; Register in codepoint table and position-pixels
        (setf (gethash +cursor-block-glyph+     cp-table) block-idx
              (gethash +cursor-underline-glyph+ cp-table) underline-idx
              (gethash +cursor-bar-glyph+       cp-table) bar-idx)
        (setf (gethash block-idx     pos-pixels) block-px
              (gethash underline-idx pos-pixels) underline-px
              (gethash bar-idx       pos-pixels) bar-px)
        ;; Rebuild texture to fit new glyphs
        (%rebuild-atlas-texture atlas))))
  atlas)

(defun %rebuild-atlas-texture (atlas)
  "Rebuild the atlas GPU texture from position-pixels.
   Recalculates atlas dimensions to fit all glyphs."
  (let* ((cell-w     (atlas-cell-width atlas))
         (cell-h     (atlas-cell-height atlas))
         (wide-set   (atlas-wide-set atlas))
         (pos-pixels (atlas-position-pixels atlas))
         ;; Find max atlas position
         (max-pos 0))
    (maphash (lambda (pos _)
               (declare (ignore _))
               (let ((end (+ pos (if (and wide-set (gethash pos wide-set)) 2 1))))
                 (when (> end max-pos) (setf max-pos end))))
             pos-pixels)
    (let* ((atlas-cols  (max (atlas-cols atlas) (min 32 (max 2 max-pos))))
           (atlas-rows  (max 1 (ceiling max-pos atlas-cols)))
           (tex-w       (* atlas-cols cell-w))
           (tex-h       (* atlas-rows cell-h))
           (tex-data    (make-array (* tex-w tex-h)
                                    :element-type '(unsigned-byte 8)
                                    :initial-element 0)))
      ;; Blit all glyphs
      (maphash (lambda (atlas-pos pixels)
                 (let* ((gc  (mod atlas-pos atlas-cols))
                        (gr  (floor atlas-pos atlas-cols))
                        (wide-p (and wide-set (gethash atlas-pos wide-set)))
                        (glyph-w (if wide-p (* 2 cell-w) cell-w)))
                   (dotimes (row cell-h)
                     (dotimes (col glyph-w)
                       (let ((src-idx (+ (* row glyph-w) col))
                             (dst-x   (+ (* gc cell-w) col))
                             (dst-y   (+ (* gr cell-h) row)))
                         (when (and (< src-idx (length pixels))
                                    (< dst-x tex-w) (< dst-y tex-h))
                           (setf (aref tex-data (+ (* dst-y tex-w) dst-x))
                                 (aref pixels src-idx))))))))
               pos-pixels)
      ;; Re-upload texture
      (gl:bind-texture :texture-2d (atlas-texture-id atlas))
      (cffi:with-pointer-to-vector-data (ptr tex-data)
        (gl:tex-image-2d :texture-2d 0 :r8 tex-w tex-h 0 :red :unsigned-byte ptr))
      (gl:bind-texture :texture-2d 0)
      ;; Update atlas struct
      (setf (atlas-cols atlas) atlas-cols
            (atlas-rows atlas) atlas-rows))))
