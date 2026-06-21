(in-package #:lexter/renderer)

;;;; OpenGL 3.3 render state and per-frame draw loop.
;;;;
;;;; Two render paths:
;;;;   Simple  — one instanced draw call, blending off.
;;;;   Layered — up to three instanced draw calls (one per layer depth);
;;;;             layer 0 is opaque, layers 1-2 use SRC_ALPHA blending.

;;; --------------------------------------------------------------------------
;;; Constants (must match grid.lisp)
;;; --------------------------------------------------------------------------

(defconstant +layered-stride+ 16)   ; bytes per layered instance (must match grid.lisp)
(defconstant +max-palette-slots+ 4  "Number of palette slots in the UBO.")
(defconstant +palette-slot-size+ 4096 "Bytes per palette slot (256 x vec4).")

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
  palette-ubo
  swatch-texture          ; 1D RGBA8 texture for swatch table
  (swatch-gen 0 :type fixnum)   ; last uploaded swatch generation
  ;; Palette slot tracking: one generation counter per slot
  (palette-gens (make-array +max-palette-slots+ :element-type 'fixnum :initial-element 0)
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
;;; Palette UBO
;;; --------------------------------------------------------------------------

(defun %make-palette-ubo ()
  "Create UBO for palette storage. Holds +max-palette-slots+ palettes."
  (let ((ubo (first (gl:gen-buffers 1)))
        (total-size (* +max-palette-slots+ +palette-slot-size+)))
    (gl:bind-buffer :uniform-buffer ubo)
    (%gl:buffer-data :uniform-buffer total-size (cffi:null-pointer) :dynamic-draw)
    (gl:bind-buffer :uniform-buffer 0)
    ubo))

(defun %bind-ubo-to-prog (prog ubo)
  "Bind the 'Palette' uniform block in PROG to UBO binding point 0."
  ;; gl:get-uniform-block-index handles Lisp string -> C string conversion
  (let ((idx (gl:get-uniform-block-index prog "Palette")))
    (unless (= idx #xFFFFFFFF)
      (%gl:uniform-block-binding prog idx 0)))
  (%gl:bind-buffer-base :uniform-buffer 0 ubo))

(defun set-palette (rs palette-floats &optional (slot 0))
  "Upload PALETTE-FLOATS (1024 single-floats: 256 x RGBA) to palette SLOT.
   This is the low-level upload; prefer upload-palette for generation-tracked updates."
  (assert (< slot +max-palette-slots+) ()
          "Palette slot ~d out of range (max ~d)" slot +max-palette-slots+)
  (gl:bind-buffer :uniform-buffer (render-state-palette-ubo rs))
  (let ((offset (* slot +palette-slot-size+)))
    (cffi:with-pointer-to-vector-data (ptr palette-floats)
      (%gl:buffer-sub-data :uniform-buffer offset +palette-slot-size+ ptr)))
  (gl:bind-buffer :uniform-buffer 0))

(defun upload-palette (rs palette-floats generation &optional (slot 0))
  "Upload palette to GPU slot if generation has changed.
   PALETTE-FLOATS is a 1024-element single-float array.
   GENERATION is the screen's palette-generation counter.
   SLOT is the palette slot index (0 to +max-palette-slots+-1).
   Returns T if upload occurred, NIL otherwise."
  (assert (< slot +max-palette-slots+) ()
          "Palette slot ~d out of range (max ~d)" slot +max-palette-slots+)
  (let ((gens (render-state-palette-gens rs)))
    (when (/= generation (aref gens slot))
      (set-palette rs palette-floats slot)
      (setf (aref gens slot) generation)
      t)))

(defun set-active-palette-slot (rs slot)
  "Set the active palette slot for rendering. Updates uniforms in both shaders."
  (assert (< slot +max-palette-slots+) ()
          "Palette slot ~d out of range (max ~d)" slot +max-palette-slots+)
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
;;; Swatch Table Texture
;;; --------------------------------------------------------------------------

(defconstant +swatch-table-size+ 2048
  "Maximum number of swatches in the GPU swatch table.")

(defun %make-swatch-texture ()
  "Create a 1D RGBA8 texture for the swatch table.
   Uses normalized RGBA8 format - shaders will convert 0.0-1.0 back to 0-255."
  (let ((tex (first (gl:gen-textures 1))))
    (gl:bind-texture :texture-1d tex)
    (gl:tex-parameter :texture-1d :texture-min-filter :nearest)
    (gl:tex-parameter :texture-1d :texture-mag-filter :nearest)
    (gl:tex-parameter :texture-1d :texture-wrap-s :clamp-to-edge)
    ;; Allocate with RGBA8 format (4 bytes per texel = 4 palette indices per swatch)
    ;; Initial data is null - we'll upload when rendering
    (gl:tex-image-1d :texture-1d 0 :rgba8 +swatch-table-size+ 0
                     :rgba :unsigned-byte (cffi:null-pointer))
    (gl:bind-texture :texture-1d 0)
    tex))

(defun upload-swatch-table (rs grid)
  "Upload the grid's swatch table to the GPU if generation changed.
   Returns T if upload occurred, NIL otherwise."
  (let ((grid-gen (swatch-generation grid)))
    (when (/= grid-gen (render-state-swatch-gen rs))
      (gl:active-texture :texture1)
      (gl:bind-texture :texture-1d (render-state-swatch-texture rs))
      ;; Upload the swatch-data array directly - it's already RGBA8 layout
      ;; (4 consecutive bytes per swatch: slot0, slot1, slot2, slot3)
      (let ((data (display-grid-swatch-data grid))
            (count (display-grid-swatch-count grid)))
        (cffi:with-pointer-to-vector-data (ptr data)
          (%gl:tex-sub-image-1d :texture-1d 0 0 count
                                :rgba :unsigned-byte ptr)))
      (gl:bind-texture :texture-1d 0)
      (setf (render-state-swatch-gen rs) grid-gen)
      t)))

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
  ;; Texture unit bindings: atlas on unit 0, swatch table on unit 1
  (gl:uniformi (gl:get-uniform-location prog "u_atlas") 0)
  (gl:uniformi (gl:get-uniform-location prog "u_swatch_table") 1))

;;; --------------------------------------------------------------------------
;;; Public constructor
;;; --------------------------------------------------------------------------

(defun make-renderer (atlas win-w win-h &key (pixel-scale 1))
  "Create a RENDER-STATE.  A GL 3.3 core context must already be current.
   PIXEL-SCALE is an integer multiplier for nearest-neighbor scaling (1-16)."
  (assert (<= 1 pixel-scale 16) (pixel-scale)
          "Pixel scale must be between 1 and 16, got ~d" pixel-scale)
  (let* ((sp  (%link-program +simple-vert+  +simple-frag+))
         (lp  (%link-program +layered-vert+ +layered-frag+))
         (cv  (%make-corner-vbo))
         (pu  (%make-palette-ubo))
         (st  (%make-swatch-texture)))
    (multiple-value-bind (svao svbo) (%make-simple-vao  cv)
      (multiple-value-bind (lvao lvbo) (%make-layered-vao cv)
        (%bind-ubo-to-prog sp pu)
        (%bind-ubo-to-prog lp pu)
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
          (make-render-state :simple-prog  sp  :layered-prog lp
                             :corner-vbo   cv  :simple-vao   svao
                             :simple-vbo   svbo :layered-vao  lvao
                             :layered-vbo  lvbo :palette-ubo  pu
                             :swatch-texture st
                             :simple-palette-slot-loc simple-slot-loc
                             :layered-palette-slot-loc layered-slot-loc
                             :atlas        atlas :win-w win-w :win-h win-h
                             :pixel-scale  pixel-scale))))))

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

(defun render-frame (rs grid)
  "Render one frame.  Call after making the GL context current.
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
  ;; Upload swatch table to GPU if changed
  (upload-swatch-table rs grid)
  (multiple-value-bind (sdata sbytes ldata lc)
      (build-render-data grid)
    (declare (type fixnum sbytes))
    (let ((atlas (render-state-atlas rs))
          (sc (floor sbytes +simple-stride+)))
      ;; Bind atlas texture to unit 0
      (gl:active-texture :texture0)
      (gl:bind-texture :texture-2d (atlas-texture-id atlas))
      ;; Bind swatch table texture to unit 1
      (gl:active-texture :texture1)
      (gl:bind-texture :texture-1d (render-state-swatch-texture rs))
      ;; ---- Simple cells ------------------------------------------------
      (when (> sc 0)
        (gl:use-program (render-state-simple-prog rs))
        (%bind-ubo-to-prog (render-state-simple-prog rs)
                           (render-state-palette-ubo rs))
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
          (%bind-ubo-to-prog (render-state-layered-prog rs)
                             (render-state-palette-ubo rs))
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
                           (render-state-palette-ubo rs)))
  (gl:delete-textures (list (render-state-swatch-texture rs)))
  (gl:delete-vertex-arrays (list (render-state-simple-vao  rs)
                                 (render-state-layered-vao rs)))
  ;; Offscreen render target, if allocated.
  (when (render-state-offscreen-fbo rs)
    (gl:delete-framebuffers (list (render-state-offscreen-fbo rs)))
    (setf (render-state-offscreen-fbo rs) nil))
  (when (render-state-offscreen-tex rs)
    (gl:delete-textures (list (render-state-offscreen-tex rs)))
    (setf (render-state-offscreen-tex rs) nil)))
