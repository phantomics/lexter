(in-package #:lexter/renderer)

;;;; OpenGL 3.3 render state and per-frame draw loop.
;;;;
;;;; Two render paths:
;;;;   Simple  — one instanced draw call, blending off.
;;;;   Layered — up to three instanced draw calls (one per layer depth);
;;;;             layer 0 is opaque, layers 1-2 use SRC_ALPHA blending.
;;;;
;;;; Colours are kept on the GPU as integers, in two texture buffers of
;;;; RGBA8UI texels read through usamplerBuffer (LEXTER-D109): the swatch
;;;; store, whose ranges the swatch tables own (LEXTER-D99), and the palette
;;;; store, 256 texels for each palette slot.

;;; --------------------------------------------------------------------------
;;; Constants
;;; --------------------------------------------------------------------------

(defconstant +default-palette-slots+ 128
  "Palette slots in the palette store unless the renderer is told otherwise
   (LEXTER-D92).")

(defconstant +default-pane-palette-slot+ 1
  "The palette slot of a pane that names none. Slot 0 holds the default
   palette and is never written after the renderer is made (LEXTER-D83).")

;;; --------------------------------------------------------------------------
;;; Render state
;;; --------------------------------------------------------------------------

(defstruct render-state
  simple-prog
  layered-prog
  corner-vbo
  simple-vao
  simple-vbo
  layered-vao
  layered-vbo
  ;; The swatch store: a buffer of RGBA8UI texels, one swatch to a texel, and
  ;; what the renderer last uploaded to each of its ranges, by table
  swatch-buffer
  swatch-texture
  (swatch-records (make-swatch-upload-records) :type swatch-upload-records)
  ;; The palette store: 256 RGBA8UI texels for each slot, and for each slot
  ;; the owner and generation of the palette last uploaded to it (LEXTER-D92)
  palette-buffer
  palette-texture
  (palette-slots +default-palette-slots+ :type fixnum)
  (palette-owners (make-array +default-palette-slots+ :initial-element nil)
                  :type simple-vector)
  (palette-gens (make-array +default-palette-slots+ :element-type 'fixnum :initial-element 0)
                :type (simple-array fixnum (*)))
  (current-palette-slot 0 :type fixnum) ; active slot for rendering
  ;; Uniform locations for u_palette_slot
  (simple-palette-slot-loc -1 :type fixnum)
  (layered-palette-slot-loc -1 :type fixnum)
  ;; --- Offscreen render target (opt-in, for post-processing + screenshots) ---
  ;; When OFFSCREEN-ENABLED, render-frame draws into OFFSCREEN-FBO (an RGBA8
  ;; color texture) instead of the default framebuffer; present-offscreen then
  ;; blits it to the window, and capture-pixels can read it back.
  (offscreen-enabled nil :type boolean)
  (offscreen-fbo nil)
  (offscreen-tex nil)
  (offscreen-w 0 :type fixnum)
  (offscreen-h 0 :type fixnum)
  atlas
  (win-w 640 :type fixnum)
  (win-h 480 :type fixnum)
  (pixel-scale 1 :type (integer 1 16)))  ; integer scale factor for HiDPI

;;; --------------------------------------------------------------------------
;;; Shader helpers
;;; --------------------------------------------------------------------------

(defun %compile-shader (type source)
  (let ((shader (gl:create-shader type)))
    (gl:shader-source shader source)
    (gl:compile-shader shader)
    (unless (gl:get-shader shader :compile-status)
      (error "Shader compile error (~a):~%~a" type (gl:get-shader-info-log shader)))
    shader))

(defun %link-program (vert-src frag-src)
  (let* ((vert (%compile-shader :vertex-shader   vert-src))
         (frag (%compile-shader :fragment-shader frag-src))
         (prog (gl:create-program)))
    (gl:attach-shader prog vert)
    (gl:attach-shader prog frag)
    (gl:link-program prog)
    (gl:delete-shader vert)
    (gl:delete-shader frag)
    (unless (gl:get-program prog :link-status)
      (error "Program link error:~%~a" (gl:get-program-info-log prog)))
    prog))

;;; --------------------------------------------------------------------------
;;; Buffer / VAO construction
;;; --------------------------------------------------------------------------

(defun %make-corner-vbo ()
  "Upload the four unit-quad corners as a static float VBO."
  (let ((vbo  (first (gl:gen-buffers 1)))
        (data (make-array 8 :element-type 'single-float
                            :initial-contents '(0.0 0.0  1.0 0.0  0.0 1.0  1.0 1.0))))
    (gl:bind-buffer :array-buffer vbo)
    (cffi:with-pointer-to-vector-data (ptr data)
      (%gl:buffer-data :array-buffer (* 8 4) ptr :static-draw))
    (gl:bind-buffer :array-buffer 0)
    vbo))

;;; Simple instance layout (12 bytes):
;;;   offset 0: int16  col         → i_cell.x
;;;   offset 2: int16  row         → i_cell.y
;;;   offset 4: uint32 glyph       → i_glyph
;;;   offset 8: uint16 swatch_idx  → i_swatch
;;;   offset 10: (pad)
(defun %make-simple-vao (corner-vbo)
  (let ((vao (first (gl:gen-vertex-arrays 1)))
        (vbo (first (gl:gen-buffers 1))))
    (gl:bind-vertex-array vao)
    ;; Attr 0: corner (per-vertex, 2 floats, stride 8 bytes)
    (gl:bind-buffer :array-buffer corner-vbo)
    (gl:vertex-attrib-pointer 0 2 :float nil 8 0)
    (gl:enable-vertex-attrib-array 0)
    ;; Instance attributes (stride +simple-stride+ = 12)
    (gl:bind-buffer :array-buffer vbo)
    (%gl:vertex-attrib-ipointer 1 2 :short          +simple-stride+ (cffi:make-pointer 0))  ; i_cell
    (%gl:vertex-attrib-ipointer 2 1 :unsigned-int   +simple-stride+ (cffi:make-pointer 4))  ; i_glyph
    (%gl:vertex-attrib-ipointer 3 1 :unsigned-short +simple-stride+ (cffi:make-pointer 8))  ; i_swatch
    (gl:enable-vertex-attrib-array 1)
    (gl:enable-vertex-attrib-array 2)
    (gl:enable-vertex-attrib-array 3)
    (%gl:vertex-attrib-divisor 1 1)
    (%gl:vertex-attrib-divisor 2 1)
    (%gl:vertex-attrib-divisor 3 1)
    (gl:bind-vertex-array 0)
    (values vao vbo)))

;;; Layered instance layout (16 bytes):
;;;   offset  0: int16  col           → i_cell.x
;;;   offset  2: int16  row           → i_cell.y
;;;   offset  4: uint32 glyph         → i_glyph
;;;   offset  8: uint8  ink-idx       → i_ink_bg.x
;;;   offset  9: uint8  bg-idx        → i_ink_bg.y
;;;   offset 10: uint8  trans-side    → i_ts
;;;   offset 11: uint8  (pad)
;;;   offset 12: uint16 swatch_idx    → i_swatch
;;;   offset 14: (pad)
(defun %make-layered-vao (corner-vbo)
  (let ((vao (first (gl:gen-vertex-arrays 1)))
        (vbo (first (gl:gen-buffers 1))))
    (gl:bind-vertex-array vao)
    ;; Attr 0: corner (per-vertex)
    (gl:bind-buffer :array-buffer corner-vbo)
    (gl:vertex-attrib-pointer 0 2 :float nil 8 0)
    (gl:enable-vertex-attrib-array 0)
    ;; Instance attributes (stride +layered-stride+ = 16) — initial pointers at offset 0
    (gl:bind-buffer :array-buffer vbo)
    (%gl:vertex-attrib-ipointer 1 2 :short          +layered-stride+ (cffi:make-pointer 0))
    (%gl:vertex-attrib-ipointer 2 1 :unsigned-int   +layered-stride+ (cffi:make-pointer 4))
    (%gl:vertex-attrib-ipointer 3 2 :unsigned-byte  +layered-stride+ (cffi:make-pointer 8))
    (%gl:vertex-attrib-ipointer 4 1 :unsigned-byte  +layered-stride+ (cffi:make-pointer 10))
    (%gl:vertex-attrib-ipointer 5 1 :unsigned-short +layered-stride+ (cffi:make-pointer 12))
    (gl:enable-vertex-attrib-array 1)
    (gl:enable-vertex-attrib-array 2)
    (gl:enable-vertex-attrib-array 3)
    (gl:enable-vertex-attrib-array 4)
    (gl:enable-vertex-attrib-array 5)
    (%gl:vertex-attrib-divisor 1 1)
    (%gl:vertex-attrib-divisor 2 1)
    (%gl:vertex-attrib-divisor 3 1)
    (%gl:vertex-attrib-divisor 4 1)
    (%gl:vertex-attrib-divisor 5 1)
    (gl:bind-vertex-array 0)
    (values vao vbo)))

;;; --------------------------------------------------------------------------
;;; Integer texture buffers
;;; --------------------------------------------------------------------------

(defun %make-texture-buffer (texels)
  "Create a buffer of TEXELS RGBA8UI texels, all zero, and a buffer texture
   that reads it. Returns (values buffer texture)."
  (let ((buffer (first (gl:gen-buffers 1)))
        (texture (first (gl:gen-textures 1)))
        (zeros (make-array (* texels 4) :element-type '(unsigned-byte 8)
                                        :initial-element 0)))
    (gl:bind-buffer :texture-buffer buffer)
    (cffi:with-pointer-to-vector-data (ptr zeros)
      (%gl:buffer-data :texture-buffer (length zeros) ptr :dynamic-draw))
    (gl:bind-buffer :texture-buffer 0)
    (gl:bind-texture :texture-buffer texture)
    (%gl:tex-buffer :texture-buffer :rgba8ui buffer)
    (gl:bind-texture :texture-buffer 0)
    (values buffer texture)))

(defun %write-texels (buffer first data start count)
  "Write COUNT texels, the bytes of DATA from byte START, to BUFFER from texel
   FIRST."
  (gl:bind-buffer :texture-buffer buffer)
  (cffi:with-pointer-to-vector-data (ptr data)
    (%gl:buffer-sub-data :texture-buffer (* first 4) (* count 4)
                         (cffi:inc-pointer ptr start)))
  (gl:bind-buffer :texture-buffer 0))

;;; --------------------------------------------------------------------------
;;; Palettes
;;; --------------------------------------------------------------------------

(defun %check-palette-slot (rs slot)
  (assert (< -1 slot (render-state-palette-slots rs)) ()
          "Palette slot ~d out of range (the store holds ~d)"
          slot (render-state-palette-slots rs)))

(defun set-palette (rs palette &optional (slot +default-pane-palette-slot+))
  "Upload PALETTE (1024 bytes: 256 x RGBA) to palette SLOT.
   This is the low-level upload; prefer upload-palette for tracked updates."
  (%check-palette-slot rs slot)
  (%write-texels (render-state-palette-buffer rs) (* slot +palette-entries+)
                 palette 0 +palette-entries+))

(defun upload-palette (rs palette generation
                       &optional (slot +default-pane-palette-slot+) (owner palette))
  "Upload PALETTE to SLOT unless the slot already holds OWNER's palette at
   GENERATION. PALETTE is 1024 bytes (256 x RGBA); GENERATION is its screen's
   palette generation; OWNER names whose palette it is, by default the palette
   array itself, so that two palettes with equal generations are told apart.
   Slot 0 holds the default palette and is never written here (LEXTER-D83).
   Returns T if upload occurred, NIL otherwise."
  (%check-palette-slot rs slot)
  (assert (plusp slot) () "Palette slot 0 holds the default palette and is not uploaded to")
  (let ((owners (render-state-palette-owners rs))
        (gens (render-state-palette-gens rs)))
    (unless (and (eq owner (aref owners slot))
                 (= generation (aref gens slot)))
      (set-palette rs palette slot)
      (setf (aref owners slot) owner
            (aref gens slot) generation)
      t)))

(defun set-active-palette-slot (rs slot)
  "Set the active palette slot for rendering. Updates uniforms in both shaders."
  (%check-palette-slot rs slot)
  (unless (= slot (render-state-current-palette-slot rs))
    (setf (render-state-current-palette-slot rs) slot)
    ;; Update uniform in simple shader
    (gl:use-program (render-state-simple-prog rs))
    (let ((loc (render-state-simple-palette-slot-loc rs)))
      (when (>= loc 0)
        (gl:uniformi loc slot)))
    ;; Update uniform in layered shader
    (gl:use-program (render-state-layered-prog rs))
    (let ((loc (render-state-layered-palette-slot-loc rs)))
      (when (>= loc 0)
        (gl:uniformi loc slot)))))

;;; --------------------------------------------------------------------------
;;; Swatches
;;; --------------------------------------------------------------------------

(defun upload-swatches (rs store)
  "Bring the GPU's copy of STORE up to date with its tables: for each range,
   the swatches its table has added since the last upload, or all of them when
   the range was last uploaded from another table or version
   (LEXTER-SWATCHES:PLAN-SWATCH-UPLOADS). Returns the number of spans
   uploaded."
  (let ((spans (plan-swatch-uploads store (render-state-swatch-records rs))))
    (loop :for (first count data start) :in spans
          :do (%write-texels (render-state-swatch-buffer rs) first data start count))
    (length spans)))

;;; --------------------------------------------------------------------------
;;; Uniform helpers
;;; --------------------------------------------------------------------------

(defun %set-uniforms (prog atlas win-w win-h pixel-scale)
  "Set shader uniforms. PIXEL-SCALE multiplies the cell size for nearest-neighbor scaling."
  (gl:use-program prog)
  ;; Scale cell size by pixel-scale for integer scaling
  (gl:uniformi (gl:get-uniform-location prog "u_cell_size")
               (* (atlas-cell-width atlas) pixel-scale)
               (* (atlas-cell-height atlas) pixel-scale))
  (gl:uniformi (gl:get-uniform-location prog "u_viewport") win-w win-h)
  (gl:uniformi (gl:get-uniform-location prog "u_atlas_size")
               (atlas-cols atlas) (atlas-rows atlas))
  ;; Texture unit bindings: atlas on unit 0, swatch store on unit 1, palette
  ;; store on unit 2
  (gl:uniformi (gl:get-uniform-location prog "u_atlas") 0)
  (gl:uniformi (gl:get-uniform-location prog "u_swatches") 1)
  (gl:uniformi (gl:get-uniform-location prog "u_palettes") 2))

;;; --------------------------------------------------------------------------
;;; Public constructor
;;; --------------------------------------------------------------------------

(defun make-renderer (atlas win-w win-h &key (pixel-scale 1)
                                             (palette-slots +default-palette-slots+))
  "Create a RENDER-STATE.  A GL 3.3 core context must already be current.
   PIXEL-SCALE is an integer multiplier for nearest-neighbor scaling (1-16).
   PALETTE-SLOTS is how many palettes the palette store holds, at most 256;
   slot 0 is given the default palette, and drawing starts in it."
  (assert (<= 1 pixel-scale 16) (pixel-scale)
          "Pixel scale must be between 1 and 16, got ~d" pixel-scale)
  (assert (<= 2 palette-slots 256) (palette-slots)
          "Palette slots must be between 2 and 256, got ~d" palette-slots)
  (let* ((sp  (%link-program +simple-vert+  +simple-frag+))
         (lp  (%link-program +layered-vert+ +layered-frag+))
         (cv  (%make-corner-vbo)))
    (multiple-value-bind (svao svbo) (%make-simple-vao  cv)
      (multiple-value-bind (lvao lvbo) (%make-layered-vao cv)
       (multiple-value-bind (sb st) (%make-texture-buffer +store-size+)
        (multiple-value-bind (pb pt) (%make-texture-buffer (* palette-slots +palette-entries+))
        (%set-uniforms sp atlas win-w win-h pixel-scale)
        (%set-uniforms lp atlas win-w win-h pixel-scale)
        ;; Cache palette slot uniform locations and set initial slot = 0
        (let ((simple-slot-loc (gl:get-uniform-location sp "u_palette_slot"))
              (layered-slot-loc (gl:get-uniform-location lp "u_palette_slot")))
          (gl:use-program sp)
          (when (>= simple-slot-loc 0)
            (gl:uniformi simple-slot-loc 0))
          (gl:use-program lp)
          (when (>= layered-slot-loc 0)
            (gl:uniformi layered-slot-loc 0))
          (gl:use-program 0)
          (let ((rs (make-render-state
                     :simple-prog  sp  :layered-prog lp
                     :corner-vbo   cv  :simple-vao   svao
                     :simple-vbo   svbo :layered-vao  lvao
                     :layered-vbo  lvbo
                     :swatch-buffer sb :swatch-texture st
                     :palette-buffer pb :palette-texture pt
                     :palette-slots palette-slots
                     :palette-owners (make-array palette-slots :initial-element nil)
                     :palette-gens (make-array palette-slots :element-type 'fixnum
                                                             :initial-element 0)
                     :simple-palette-slot-loc simple-slot-loc
                     :layered-palette-slot-loc layered-slot-loc
                     :atlas        atlas :win-w win-w :win-h win-h
                     :pixel-scale  pixel-scale)))
            (set-palette rs (make-default-palette) 0)
            rs))))))))

;;; --------------------------------------------------------------------------
;;; Offscreen render target (opt-in: post-processing + screenshots)
;;; --------------------------------------------------------------------------

(defun %ensure-offscreen (rs w h)
  "Allocate or resize the offscreen FBO + RGBA8 color texture to W x H.
   A GL context must be current. Returns the FBO id."
  (let ((tex (render-state-offscreen-tex rs))
        (fbo (render-state-offscreen-fbo rs)))
    ;; (Re)allocate the color texture when missing or size changed.
    (unless (and tex (= (render-state-offscreen-w rs) w)
                 (= (render-state-offscreen-h rs) h))
      (unless tex
        (setf tex (first (gl:gen-textures 1))
              (render-state-offscreen-tex rs) tex))
      (gl:bind-texture :texture-2d tex)
      (gl:tex-parameter :texture-2d :texture-min-filter :nearest)
      (gl:tex-parameter :texture-2d :texture-mag-filter :nearest)
      (gl:tex-parameter :texture-2d :texture-wrap-s :clamp-to-edge)
      (gl:tex-parameter :texture-2d :texture-wrap-t :clamp-to-edge)
      (gl:tex-image-2d :texture-2d 0 :rgba8 w h 0 :rgba :unsigned-byte
                       (cffi:null-pointer))
      (gl:bind-texture :texture-2d 0)
      (setf (render-state-offscreen-w rs) w
            (render-state-offscreen-h rs) h))
    ;; Create the FBO once and attach the (current) texture.
    (unless fbo
      (setf fbo (first (gl:gen-framebuffers 1))
            (render-state-offscreen-fbo rs) fbo))
    (gl:bind-framebuffer :framebuffer fbo)
    (gl:framebuffer-texture-2d :framebuffer :color-attachment0 :texture-2d tex 0)
    (let ((status (gl:check-framebuffer-status :framebuffer)))
      (unless (member status '(:framebuffer-complete :framebuffer-complete-oes))
        (gl:bind-framebuffer :framebuffer 0)
        (error "Offscreen framebuffer incomplete: ~a" status)))
    (gl:bind-framebuffer :framebuffer 0)
    fbo))

(defun enable-offscreen (rs)
  "Turn on offscreen rendering. Subsequent RENDER-FRAME calls draw into an FBO
   sized to the current window; PRESENT-OFFSCREEN blits it to the window and
   CAPTURE-PIXELS can read it back."
  (%ensure-offscreen rs (render-state-win-w rs) (render-state-win-h rs))
  (setf (render-state-offscreen-enabled rs) t))

(defun disable-offscreen (rs)
  "Turn off offscreen rendering (RENDER-FRAME draws to the window directly)."
  (setf (render-state-offscreen-enabled rs) nil))

(defun offscreen-enabled-p (rs)
  (render-state-offscreen-enabled rs))

(defun resize-offscreen (rs w h)
  "Resize the offscreen target to W x H if it exists."
  (when (render-state-offscreen-fbo rs)
    (%ensure-offscreen rs w h)))

(defun present-offscreen (rs)
  "Blit the offscreen color buffer to the default framebuffer so the window
   shows the rendered frame. No-op when offscreen rendering is disabled.
   (Phase 2 will replace this 1:1 blit with the post-processing effect chain.)"
  (when (and (render-state-offscreen-enabled rs)
             (render-state-offscreen-fbo rs))
    (let ((w (render-state-offscreen-w rs))
          (h (render-state-offscreen-h rs)))
      (gl:bind-framebuffer :read-framebuffer (render-state-offscreen-fbo rs))
      (gl:bind-framebuffer :draw-framebuffer 0)
      (%gl:blit-framebuffer 0 0 w h 0 0 w h :color-buffer-bit :nearest)
      (gl:bind-framebuffer :framebuffer 0))))

(defun capture-pixels (rs)
  "Read the offscreen color buffer back as an (H W 3) (unsigned-byte 8) array,
   row 0 = top of the image (GL's bottom-up order is flipped here). Offscreen
   rendering must be enabled and a frame must have been rendered into it."
  (unless (and (render-state-offscreen-enabled rs)
               (render-state-offscreen-fbo rs))
    (error "capture-pixels: offscreen rendering is not enabled"))
  (let* ((w (render-state-offscreen-w rs))
         (h (render-state-offscreen-h rs)))
    (gl:bind-framebuffer :read-framebuffer (render-state-offscreen-fbo rs))
    (gl:read-buffer :color-attachment0)
    ;; Tightly-packed rows: avoid the default 4-byte pack alignment skewing
    ;; rows whose byte width (w*3) is not a multiple of 4.
    (gl:pixel-store :pack-alignment 1)
    (let ((flat (gl:read-pixels 0 0 w h :rgb :unsigned-byte))
          (out  (make-array (list h w 3) :element-type '(unsigned-byte 8))))
      (gl:bind-framebuffer :read-framebuffer 0)
      ;; FLAT is bottom-up row-major (W*3 per row); flip to top-down (H W 3).
      (dotimes (row h)
        (let ((src-row (* (- h 1 row) w 3)))
          (dotimes (col w)
            (let ((src (+ src-row (* col 3))))
              (setf (aref out row col 0) (aref flat src)
                    (aref out row col 1) (aref flat (+ src 1))
                    (aref out row col 2) (aref flat (+ src 2)))))))
      out)))

;;; --------------------------------------------------------------------------
;;; Per-frame render
;;; --------------------------------------------------------------------------

(defun render-frame (rs grid store)
  "Render one frame of GRID, whose swatch indices are global indices of
   STORE.  Call after making the GL context current.
   When offscreen rendering is enabled, draws into the offscreen FBO; otherwise
   draws to the default framebuffer."
  (if (render-state-offscreen-enabled rs)
      (progn
        (%ensure-offscreen rs (render-state-win-w rs) (render-state-win-h rs))
        (gl:bind-framebuffer :framebuffer (render-state-offscreen-fbo rs))
        (gl:viewport 0 0 (render-state-offscreen-w rs) (render-state-offscreen-h rs)))
      (gl:bind-framebuffer :framebuffer 0))
  (gl:clear-color 0.0 0.0 0.0 1.0)
  (gl:clear :color-buffer-bit)
  ;; Bring the swatch store up to date with its tables
  (upload-swatches rs store)
  (multiple-value-bind (sdata sbytes ldata lc)
      (build-render-data grid)
    (declare (type fixnum sbytes))
    (let ((atlas (render-state-atlas rs))
          (sc (floor sbytes +simple-stride+)))
      ;; Bind atlas texture to unit 0
      (gl:active-texture :texture0)
      (gl:bind-texture :texture-2d (atlas-texture-id atlas))
      ;; Bind the swatch store to unit 1 and the palette store to unit 2
      (gl:active-texture :texture1)
      (gl:bind-texture :texture-buffer (render-state-swatch-texture rs))
      (gl:active-texture :texture2)
      (gl:bind-texture :texture-buffer (render-state-palette-texture rs))
      ;; ---- Simple cells ------------------------------------------------
      (when (> sc 0)
        (gl:use-program (render-state-simple-prog rs))
        (gl:disable :blend)
        (gl:bind-buffer :array-buffer (render-state-simple-vbo rs))
        (cffi:with-pointer-to-vector-data (ptr sdata)
          (%gl:buffer-data :array-buffer sbytes ptr :stream-draw))
        (gl:bind-vertex-array (render-state-simple-vao rs))
        (%gl:draw-arrays-instanced :triangle-strip 0 4 sc))
      ;; ---- Layered cells -----------------------------------------------
      (let ((total-layered (reduce #'+ lc)))
        (when (> total-layered 0)
          (gl:use-program (render-state-layered-prog rs))
          ;; Upload the full merged buffer once
          (gl:bind-buffer :array-buffer (render-state-layered-vbo rs))
          (let ((lbytes (* total-layered +layered-stride+)))
            (cffi:with-pointer-to-vector-data (ptr ldata)
              (%gl:buffer-data :array-buffer lbytes ptr :stream-draw)))
          (gl:bind-vertex-array (render-state-layered-vao rs))
          ;; Draw each layer depth in turn, updating attrib offsets.
          ;; GL 3.3 has no glDrawArraysInstancedBaseInstance, so we slide
          ;; the vertex attrib pointers to the correct byte offset instead.
          (let ((byte-off 0))
            (dotimes (ln 3)
              (let ((count (aref lc ln)))
                (when (> count 0)
                  (if (= ln 0)
                      (gl:disable :blend)
                      (progn
                        (gl:enable :blend)
                        (gl:blend-func :src-alpha :one-minus-src-alpha)))
                  ;; Slide attrib pointers to the current layer's slice
                  (%gl:vertex-attrib-ipointer
                   1 2 :short          +layered-stride+ (cffi:make-pointer (+ byte-off 0)))
                  (%gl:vertex-attrib-ipointer
                   2 1 :unsigned-int   +layered-stride+ (cffi:make-pointer (+ byte-off 4)))
                  (%gl:vertex-attrib-ipointer
                   3 2 :unsigned-byte  +layered-stride+ (cffi:make-pointer (+ byte-off 8)))
                  (%gl:vertex-attrib-ipointer
                   4 1 :unsigned-byte  +layered-stride+ (cffi:make-pointer (+ byte-off 10)))
                  (%gl:vertex-attrib-ipointer
                   5 1 :unsigned-short +layered-stride+ (cffi:make-pointer (+ byte-off 12)))
                  (%gl:draw-arrays-instanced :triangle-strip 0 4 count)
                  (incf byte-off (* count +layered-stride+)))))))))
  (gl:bind-vertex-array 0)
  (gl:use-program 0)))

;;; --------------------------------------------------------------------------
;;; Viewport and scale update
;;; --------------------------------------------------------------------------

(defun update-viewport (rs win-w win-h)
  "Update renderer viewport after a window resize. Preserves current pixel-scale."
  (setf (render-state-win-w rs) win-w
        (render-state-win-h rs) win-h)
  (gl:viewport 0 0 win-w win-h)
  ;; Keep the offscreen target matched to the window size.
  (resize-offscreen rs win-w win-h)
  (let ((atlas (render-state-atlas rs))
        (scale (render-state-pixel-scale rs)))
    (%set-uniforms (render-state-simple-prog rs)  atlas win-w win-h scale)
    (%set-uniforms (render-state-layered-prog rs) atlas win-w win-h scale)
    (gl:use-program 0)))

(defun set-pixel-scale (rs scale)
  "Change the pixel scale factor. Requires re-setting uniforms."
  (assert (<= 1 scale 16) (scale)
          "Pixel scale must be between 1 and 16, got ~d" scale)
  (setf (render-state-pixel-scale rs) scale)
  (let ((atlas (render-state-atlas rs))
        (win-w (render-state-win-w rs))
        (win-h (render-state-win-h rs)))
    (%set-uniforms (render-state-simple-prog rs)  atlas win-w win-h scale)
    (%set-uniforms (render-state-layered-prog rs) atlas win-w win-h scale)
    (gl:use-program 0)))

(defun pixel-scale (rs)
  "Return the current pixel scale factor."
  (render-state-pixel-scale rs))

(defun scaled-cell-size (rs)
  "Return the effective cell size (width . height) after scaling."
  (let ((atlas (render-state-atlas rs))
        (scale (render-state-pixel-scale rs)))
    (cons (* (atlas-cell-width atlas) scale)
          (* (atlas-cell-height atlas) scale))))

;;; --------------------------------------------------------------------------
;;; Cleanup
;;; --------------------------------------------------------------------------

(defun destroy-renderer (rs)
  (gl:delete-program (render-state-simple-prog  rs))
  (gl:delete-program (render-state-layered-prog rs))
  (gl:delete-buffers (list (render-state-corner-vbo  rs)
                           (render-state-simple-vbo  rs)
                           (render-state-layered-vbo rs)
                           (render-state-swatch-buffer rs)
                           (render-state-palette-buffer rs)))
  (gl:delete-textures (list (render-state-swatch-texture rs)
                            (render-state-palette-texture rs)))
  (gl:delete-vertex-arrays (list (render-state-simple-vao  rs)
                                 (render-state-layered-vao rs)))
  ;; Offscreen render target, if allocated.
  (when (render-state-offscreen-fbo rs)
    (gl:delete-framebuffers (list (render-state-offscreen-fbo rs)))
    (setf (render-state-offscreen-fbo rs) nil))
  (when (render-state-offscreen-tex rs)
    (gl:delete-textures (list (render-state-offscreen-tex rs)))
    (setf (render-state-offscreen-tex rs) nil)))
