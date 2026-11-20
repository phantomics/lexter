(in-package #:lexter/atlas)

;;;; Glyph atlas: packs bitmaps from an ordered list of PCF fonts into a
;;;; single GL_R8 texture.  The first font in the list that covers a given
;;;; codepoint wins.  All fonts must share the same cell dimensions.
;;;; Packing needs no GL (PACK-ATLAS); UPLOAD-ATLAS makes the texture.
;;;;
;;;; Positions 0-63 are reserved for glyphs Lexter generates itself, and a
;;;; font's glyphs begin at position 64 (LEXTER-D89):
;;;;
;;;;   0      the empty glyph, every cell's blank
;;;;   1-4    cursor glyphs: full block, underline, bar, outlined block
;;;;   5      the replacement glyph: a wide glyph whose ink cannot fit one cell
;;;;   6      the "no glyph" glyph: a character no font in the chain covers
;;;;   7      reserved
;;;;   8-63   line glyphs, at 8 + 8 x style + flags; style 0 with flag 1, the
;;;;          single underline at 9, is the one generated so far
;;;;
;;;; Generated glyph K is named by the value #x110000 + K in the codepoint
;;;; table, beyond Unicode, so that no host can print one and no font can
;;;; displace one.
;;;;
;;;; Glyphs are fitted to the widths of the atlas's width policy (LEXTER-D117):
;;;; where Unicode's table gives a codepoint another width than the glyph of
;;;; the first font that covers it, the first font whose glyph has that width is
;;;; used; failing that, a narrow glyph is centred in a wide entry, and a wide
;;;; glyph whose ink fits one cell is cropped to a window centred on its ink, or
;;;; else drawn as the replacement glyph. The fitting is done when the atlas is
;;;; packed, so it is deterministic.

;;; --------------------------------------------------------------------------
;;; Generated glyphs
;;; --------------------------------------------------------------------------

(defconstant +generated-glyph-base+ #x110000
  "The name of generated glyph 0; generated glyph K is named this plus K.")
(defconstant +first-font-position+ 64
  "The first atlas position of a font's glyphs; 0-63 are generated glyphs.")

(defconstant +empty-glyph+            #x110000 "Name of the empty glyph, position 0.")
(defconstant +cursor-block-glyph+     #x110001 "Name of the full block cursor glyph, position 1.")
(defconstant +cursor-underline-glyph+ #x110002 "Name of the underline cursor glyph, position 2.")
(defconstant +cursor-bar-glyph+       #x110003 "Name of the bar (I-beam) cursor glyph, position 3.")
(defconstant +cursor-outline-glyph+   #x110004 "Name of the outlined block cursor glyph, position 4.")
(defconstant +replacement-glyph+      #x110005 "Name of the replacement glyph, position 5.")
(defconstant +no-glyph-glyph+         #x110006 "Name of the \"no glyph\" glyph, position 6.")

(defconstant +empty-glyph-position+       0 "Atlas position of the empty glyph.")
(defconstant +replacement-glyph-position+ 5 "Atlas position of the replacement glyph.")
(defconstant +no-glyph-position+          6 "Atlas position of the \"no glyph\" glyph.")

(defconstant +underline-glyph+          #x110009 "Name of the single underline, position 9.")

(defun line-glyph-position (style flags)
  "The atlas position of the line glyph of line STYLE, 0-6, and FLAGS, 1-7:
   bit 0 underline, bit 1 strikethrough, bit 2 overline (LEXTER-D89)."
  (+ 8 (* 8 style) flags))

(defstruct atlas
  "GPU glyph atlas."
  (texture-id  0  :type (unsigned-byte 32))
  (cell-width  0  :type (unsigned-byte 16))
  (cell-height 0  :type (unsigned-byte 16))
  (cols        0  :type (unsigned-byte 16))  ; atlas width in glyph columns (single-width units)
  (rows        0  :type (unsigned-byte 16))  ; atlas height in glyph rows
  ;; hash: codepoint -> atlas position of the glyph of the first font that
  ;; covers it, at its natural width; also the names of the generated glyphs
  (codepoint-table (make-hash-table :test 'eql) :type hash-table)
  ;; hash: codepoint -> atlas position of its glyph at the width the width
  ;; policy gives it, for the codepoints whose natural glyph has another width
  (fitted-table (make-hash-table :test 'eql) :type hash-table)
  ;; The width policy the glyphs were fitted to
  (width-policy lexter/width:*default-width-policy*)
  ;; hash: atlas-position -> t for double-wide glyphs. NIL if none.
  (wide-set    nil :type (or null hash-table))
  ;; hash: atlas-position -> pixel-array for texture rebuilds
  (position-pixels (make-hash-table :test 'eql) :type hash-table))

(defun atlas-glyph-wide-p (atlas glyph-index)
  "Return T if the glyph at GLYPH-INDEX is double-wide."
  (let ((ws (atlas-wide-set atlas)))
    (and ws (gethash glyph-index ws))))

(defun atlas-glyph-index (atlas codepoint &optional width)
  "Return the atlas position of CODEPOINT's glyph, or NIL if no font covers it.
   Without WIDTH, the glyph of the first font that covers CODEPOINT, at its
   natural width, as Lexter's own writers draw it by default; with WIDTH, 1 or
   2, the glyph fitted to that width, as the VT handler draws a character at
   the width the width table gives it (LEXTER-D117)."
  (let ((natural (gethash codepoint (atlas-codepoint-table atlas))))
    (if (or (null natural) (null width) (zerop width)
            (= width (if (atlas-glyph-wide-p atlas natural) 2 1)))
        natural
        (or (gethash codepoint (atlas-fitted-table atlas)) natural))))

;;; Pixels of the generated glyphs, each CELL-W by CELL-H, 0 or 255

(defun %blank-pixels (cell-w cell-h)
  (make-array (* cell-w cell-h) :element-type '(unsigned-byte 8) :initial-element 0))

(defun %make-block-cursor (cell-w cell-h)
  "Generate a solid block cursor (fully filled cell)."
  (make-array (* cell-w cell-h)
              :element-type '(unsigned-byte 8)
              :initial-element 255))

(defun %make-underline-cursor (cell-w cell-h &key (thickness 2))
  "Generate an underline cursor (bottom THICKNESS rows filled)."
  (let ((pixels (%blank-pixels cell-w cell-h)))
    (loop :for row :from (max 0 (- cell-h thickness)) :below cell-h
          :do (loop :for col :from 0 :below cell-w
                    :do (setf (aref pixels (+ (* row cell-w) col)) 255)))
    pixels))

(defun %make-bar-cursor (cell-w cell-h &key (width 2))
  "Generate a vertical bar (I-beam) cursor (left WIDTH columns filled)."
  (let ((pixels (%blank-pixels cell-w cell-h)))
    (loop :for row :from 0 :below cell-h
          :do (loop :for col :from 0 :below (min width cell-w)
                    :do (setf (aref pixels (+ (* row cell-w) col)) 255)))
    pixels))

(defun %draw-box (pixels cell-w left top right bottom)
  "Draw the outline of the box from LEFT, TOP to RIGHT, BOTTOM, inclusive."
  (loop :for col :from left :to right
        :do (setf (aref pixels (+ (* top cell-w) col)) 255
                  (aref pixels (+ (* bottom cell-w) col)) 255))
  (loop :for row :from top :to bottom
        :do (setf (aref pixels (+ (* row cell-w) left)) 255
                  (aref pixels (+ (* row cell-w) right)) 255))
  pixels)

(defun %inset-box (cell-w cell-h)
  "The bounds LEFT, TOP, RIGHT, BOTTOM of a box inset by a pixel from the cell's
   edges, or the cell's own edges when it is too small to inset."
  (if (and (>= cell-w 4) (>= cell-h 4))
      (values 1 1 (- cell-w 2) (- cell-h 2))
      (values 0 0 (1- cell-w) (1- cell-h))))

(defun %make-outline-cursor (cell-w cell-h)
  "Generate an outlined block cursor: the cell's edges, a pixel wide."
  (%draw-box (%blank-pixels cell-w cell-h) cell-w 0 0 (1- cell-w) (1- cell-h)))

(defun %make-no-glyph-glyph (cell-w cell-h)
  "Generate the \"no glyph\" glyph: an empty box inset from the cell's edges."
  (multiple-value-bind (left top right bottom) (%inset-box cell-w cell-h)
    (%draw-box (%blank-pixels cell-w cell-h) cell-w left top right bottom)))

(defun %make-replacement-glyph (cell-w cell-h)
  "Generate the replacement glyph: the inset box crossed by its diagonals, or,
   in a cell too narrow for the diagonals to show inside the box, the box
   filled, or, in a cell so small that the box is already solid, a
   checkerboard, so that it never looks like the \"no glyph\" glyph."
  (multiple-value-bind (left top right bottom) (%inset-box cell-w cell-h)
    (let ((pixels (%draw-box (%blank-pixels cell-w cell-h) cell-w left top right bottom))
          (span (max 1 (- bottom top))))
      (loop :for row :from top :to bottom
            :for col = (+ left (round (* (- right left) (- row top)) span))
            :do (setf (aref pixels (+ (* row cell-w) col)) 255
                      (aref pixels (+ (* row cell-w) (- (+ left right) col))) 255))
      (when (equalp pixels (%make-no-glyph-glyph cell-w cell-h))
        (loop :for row :from top :to bottom
              :do (loop :for col :from left :to right
                        :do (setf (aref pixels (+ (* row cell-w) col)) 255))))
      (when (equalp pixels (%make-no-glyph-glyph cell-w cell-h))
        (dotimes (row cell-h)
          (dotimes (col cell-w)
            (setf (aref pixels (+ (* row cell-w) col))
                  (if (evenp (+ row col)) 255 0)))))
      pixels)))

(defun %make-underline (cell-w cell-h ascent)
  "Generate the single underline: rows beginning just below the baseline, at
   row ASCENT, max(1, CELL-H / 16) thick, and inside the cell. The font's XLFD
   UNDERLINE_POSITION and UNDERLINE_THICKNESS are not read yet (LEXTER-D89)."
  (let* ((pixels (%blank-pixels cell-w cell-h))
         (thickness (max 1 (floor cell-h 16)))
         (top (max 0 (min ascent (- cell-h thickness)))))
    (loop :for row :from top :below (min cell-h (+ top thickness))
          :do (loop :for col :from 0 :below cell-w
                    :do (setf (aref pixels (+ (* row cell-w) col)) 255)))
    pixels))

(defun %generated-glyphs (cell-w cell-h ascent)
  "The generated glyphs, as a list of (position pixels)."
  (list (list 0 (%blank-pixels cell-w cell-h))
        (list 1 (%make-block-cursor cell-w cell-h))
        (list 2 (%make-underline-cursor cell-w cell-h))
        (list 3 (%make-bar-cursor cell-w cell-h))
        (list 4 (%make-outline-cursor cell-w cell-h))
        (list 5 (%make-replacement-glyph cell-w cell-h))
        (list 6 (%make-no-glyph-glyph cell-w cell-h))
        (list (line-glyph-position 0 1) (%make-underline cell-w cell-h ascent))))

;;;; Builder
;;;;
;;;; Packing, which assigns each glyph its atlas position and keeps its pixels,
;;;; is separate from uploading the texture, so that an atlas can be packed
;;;; with no GL context (LEXTER-DRAFT-cell-model-revision-D22). PACK-ATLAS takes
;;;; its column count from its caller; BUILD-ATLAS derives one from the GPU's
;;;; maximum texture size, packs, and uploads.

(defun %check-cell-sizes (fonts)
  "The cell width and height the font chain FONTS shares; signals an error if
   the fonts' cell sizes differ."
  (assert fonts () "At least one font required")
  (let* ((primary (first fonts))
         (cell-w  (bitmap-font-cell-width  primary))
         (cell-h  (bitmap-font-cell-height primary)))
    (dolist (f (rest fonts))
      (unless (and (= (bitmap-font-cell-width  f) cell-w)
                   (= (bitmap-font-cell-height f) cell-h))
        (error "All fonts in the fallback chain must have the same cell dimensions")))
    (values cell-w cell-h)))

(defun %font-glyph (font codepoint)
  "FONT's glyph for CODEPOINT as its pixels and its width, 1 or 2, or NIL."
  (let ((index (gethash codepoint (bitmap-font-encoding font))))
    (when index
      (values (aref (bitmap-font-bitmaps font) index)
              (if (and (bitmap-font-wide-glyphs font)
                       (gethash index (bitmap-font-wide-glyphs font)))
                  2 1)))))

(defun %pad-glyph (pixels cell-w cell-h)
  "A wide glyph holding the narrow glyph PIXELS centred, at column CELL-W / 2."
  (let ((wide (make-array (* 2 cell-w cell-h) :element-type '(unsigned-byte 8)
                                              :initial-element 0))
        (offset (floor cell-w 2)))
    (dotimes (row cell-h wide)
      (dotimes (col cell-w)
        (setf (aref wide (+ (* row 2 cell-w) offset col))
              (aref pixels (+ (* row cell-w) col)))))))

(defun %crop-glyph (pixels cell-w cell-h)
  "A narrow glyph cropped from the wide glyph PIXELS: the window of CELL-W
   columns centred on its ink, when the ink fits in it; otherwise NIL."
  (let* ((width (* 2 cell-w))
         (inked (loop :for col :below width
                      :when (loop :for row :below cell-h
                                  :thereis (plusp (aref pixels (+ (* row width) col))))
                        :collect col))
         (start (if inked
                    (let ((lo (first inked)) (hi (car (last inked))))
                      (when (<= (1+ (- hi lo)) cell-w)
                        (max 0 (min cell-w (floor (- (+ lo hi 1) cell-w) 2)))))
                    (floor cell-w 2))))
    (when start
      (let ((narrow (make-array (* cell-w cell-h) :element-type '(unsigned-byte 8))))
        (dotimes (row cell-h narrow)
          (dotimes (col cell-w)
            (setf (aref narrow (+ (* row cell-w) col))
                  (aref pixels (+ (* row width) start col)))))))))

(defun %plan-atlas (fonts width-policy)
  "Plan the font glyphs of an atlas for the font chain FONTS, fitted to
   WIDTH-POLICY. Returns, in packing order, a list of (kind codepoint pixels
   wide-p), KIND being :NATURAL for the glyph of the first font that covers the
   codepoint, :FITTED for its glyph at the width the policy gives it, or
   :REPLACEMENT for a codepoint that the replacement glyph stands for at that
   width (with no pixels); and the cell width and height."
  (multiple-value-bind (cell-w cell-h) (%check-cell-sizes fonts)
    (let ((seen (make-hash-table :test 'eql))
          (natural '())
          (fitted '()))
      (dolist (font fonts)
        (maphash (lambda (codepoint index)
                   (declare (ignore index))
                   (unless (gethash codepoint seen)
                     (setf (gethash codepoint seen) t)
                     (multiple-value-bind (pixels width) (%font-glyph font codepoint)
                       (push (list :natural codepoint pixels (= width 2)) natural)
                       (let ((wanted (lexter/width:char-width codepoint width-policy)))
                         (when (and (/= wanted 0) (/= wanted width))
                           (push (%fit-glyph fonts codepoint pixels wanted cell-w cell-h)
                                 fitted))))))
                 (bitmap-font-encoding font)))
      (values (append (nreverse natural) (nreverse fitted)) cell-w cell-h))))

(defun %fit-glyph (fonts codepoint pixels wanted cell-w cell-h)
  "The plan entry for CODEPOINT at the WANTED width, whose first glyph PIXELS
   has the other width: the first font in FONTS whose glyph has the wanted
   width, or else PIXELS padded or cropped, or else the replacement glyph."
  (dolist (font fonts)
    (multiple-value-bind (candidate width) (%font-glyph font codepoint)
      (when (and candidate (= width wanted))
        (return-from %fit-glyph (list :fitted codepoint candidate (= wanted 2))))))
  (if (= wanted 2)
      (list :fitted codepoint (%pad-glyph pixels cell-w cell-h) t)
      (let ((cropped (%crop-glyph pixels cell-w cell-h)))
        (if cropped
            (list :fitted codepoint cropped nil)
            (list :replacement codepoint nil nil)))))

(defun %slot-count (plan)
  "The number of atlas column slots the generated glyphs and the glyphs of
   PLAN take; a wide glyph takes two."
  (+ +first-font-position+
     (loop :for (kind nil nil wide-p) :in plan
           :sum (case kind (:replacement 0) (t (if wide-p 2 1))))))

(defun %max-texture-size ()
  "The GPU's maximum texture size, at least 1024. Needs a current GL context."
  (let ((m (gl:get-integer :max-texture-size)))
    (max 1024 (if (numberp m) m (elt m 0)))))

(defun atlas-columns-for (fonts max-texture-size
                          &optional (width-policy lexter/width:*default-width-policy*))
  "Choose an atlas column count for FONTS so that the texture is roughly
   square and no wider than MAX-TEXTURE-SIZE pixels. A fixed small column count
   makes a large font (e.g. Unifont, ~57k glyphs) produce a texture thousands
   of pixels tall, exceeding the GL limit."
  (multiple-value-bind (plan cell-w cell-h) (%plan-atlas fonts width-policy)
    (let* ((slot-count  (%slot-count plan))
           (max-cols    (max 2 (floor max-texture-size cell-w)))
           ;; cols such that cols*cell-w ~= (slots/cols)*cell-h  =>  square
           (square-cols (max 2 (ceiling (sqrt (/ (* (max 1 slot-count) (max 1 cell-h))
                                                 (max 1 cell-w)))))))
      (max 2 (min max-cols (max 32 square-cols))))))

(defun pack-atlas (fonts &key cols (width-policy lexter/width:*default-width-policy*))
  "Pack a glyph atlas from an ordered list of BITMAP-FONT structs, with COLS
   atlas columns, fitting glyphs to WIDTH-POLICY, without touching GL. Returns
   an ATLAS struct whose texture-id is 0; UPLOAD-ATLAS gives it a texture.
   The generated glyphs take positions 0-6 and 9, and font glyphs begin at
   position 64. Double-wide glyphs occupy 2 adjacent atlas columns, on one row, and are
   tracked in wide-set."
  (check-type cols (integer 2))
  (multiple-value-bind (plan cell-w cell-h) (%plan-atlas fonts width-policy)
    (let ((codepoint-table (make-hash-table :test 'eql))
          (fitted-table (make-hash-table :test 'eql))
          (wide-set nil)
          (pos-pixels (make-hash-table :test 'eql))
          (cur-col (mod +first-font-position+ cols))
          (cur-row (floor +first-font-position+ cols)))
      (loop :for (position pixels) :in (%generated-glyphs cell-w cell-h
                                                          (lexter/pcf:bitmap-font-ascent
                                                           (first fonts)))
            :do (setf (gethash position pos-pixels) pixels
                      (gethash (+ +generated-glyph-base+ position) codepoint-table) position))
      (dolist (entry plan)
        (destructuring-bind (kind codepoint pixels wide-p) entry
          (if (eq kind :replacement)
              (setf (gethash codepoint fitted-table) +replacement-glyph-position+)
              (progn
                (when (and wide-p (> cur-col (- cols 2)))
                  (setf cur-col 0)
                  (incf cur-row))
                (let ((atlas-pos (+ (* cur-row cols) cur-col)))
                  (setf (gethash codepoint (if (eq kind :natural) codepoint-table fitted-table))
                        atlas-pos)
                  (setf (gethash atlas-pos pos-pixels) pixels)
                  (when wide-p
                    (unless wide-set
                      (setf wide-set (make-hash-table :test 'eql)))
                    (setf (gethash atlas-pos wide-set) t)))
                (incf cur-col (if wide-p 2 1))
                (when (>= cur-col cols)
                  (setf cur-col 0)
                  (incf cur-row))))))
      (make-atlas
       :texture-id      0
       :cell-width      cell-w
       :cell-height     cell-h
       :cols            cols
       :rows            (1+ cur-row)
       :codepoint-table codepoint-table
       :fitted-table    fitted-table
       :width-policy    width-policy
       :wide-set        wide-set
       :position-pixels pos-pixels))))

(defun %atlas-texture-data (atlas)
  "Blit ATLAS's glyph pixels into a fresh R8 texture image.
   Returns the image, its width, and its height."
  (let* ((cell-w     (atlas-cell-width  atlas))
         (cell-h     (atlas-cell-height atlas))
         (atlas-cols (atlas-cols atlas))
         (wide-set   (atlas-wide-set atlas))
         (tex-w      (* atlas-cols cell-w))
         (tex-h      (* (atlas-rows atlas) cell-h))
         (tex-data   (make-array (* tex-w tex-h)
                                 :element-type '(unsigned-byte 8)
                                 :initial-element 0)))
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
             (atlas-position-pixels atlas))
    (values tex-data tex-w tex-h)))

(defun upload-atlas (atlas)
  "Upload ATLAS's glyph pixels as its GL texture, creating the texture if ATLAS
   has none yet. Needs a current GL context. Signals an error if the texture
   would exceed GL_MAX_TEXTURE_SIZE. Returns ATLAS."
  (multiple-value-bind (tex-data tex-w tex-h) (%atlas-texture-data atlas)
    (let ((max-tex (%max-texture-size)))
      (when (or (> tex-w max-tex) (> tex-h max-tex))
        (error "Glyph atlas ~dx~d exceeds GL_MAX_TEXTURE_SIZE (~d). ~
                Font has ~d glyphs at ~dx~d cells -- too large to atlas in a ~
                single texture."
               tex-w tex-h max-tex
               (hash-table-count (atlas-position-pixels atlas))
               (atlas-cell-width atlas) (atlas-cell-height atlas))))
    (if (zerop (atlas-texture-id atlas))
        (let ((tex-id (first (gl:gen-textures 1))))
          (setf (atlas-texture-id atlas) tex-id)
          (gl:bind-texture :texture-2d tex-id)
          (gl:tex-parameter :texture-2d :texture-min-filter :nearest)
          (gl:tex-parameter :texture-2d :texture-mag-filter :nearest)
          (gl:tex-parameter :texture-2d :texture-wrap-s :clamp-to-edge)
          (gl:tex-parameter :texture-2d :texture-wrap-t :clamp-to-edge))
        (gl:bind-texture :texture-2d (atlas-texture-id atlas)))
    (gl:pixel-store :unpack-alignment 1)
    (cffi:with-pointer-to-vector-data (ptr tex-data)
      (gl:tex-image-2d :texture-2d 0 :r8 tex-w tex-h 0
                       :red :unsigned-byte ptr))
    (gl:bind-texture :texture-2d 0))
  atlas)

(defun build-atlas (fonts &key cols (width-policy lexter/width:*default-width-policy*))
  "Build and upload a glyph atlas from an ordered list of BITMAP-FONT structs,
   fitting glyphs to WIDTH-POLICY. Returns an ATLAS struct with a valid GL
   texture. COLS fixes the atlas's column count; by default it is chosen from
   the GPU's maximum texture size. Needs a current GL context."
  (upload-atlas
   (pack-atlas fonts
               :cols (or cols (atlas-columns-for fonts (%max-texture-size) width-policy))
               :width-policy width-policy)))

(defun add-cursor-glyphs (atlas)
  "Return ATLAS. The cursor glyphs are generated when an atlas is packed, at
   positions 1-4 (LEXTER-D89); this function remains for its callers."
  atlas)
