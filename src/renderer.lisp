(in-package #:pcf-gl/renderer)

;;;; OpenGL 3.3 render state and per-frame draw loop.
;;;;
;;;; Two render paths:
;;;;   Simple  — one instanced draw call, blending off.
;;;; Layered  — up to four instanced draw calls (one per layer depth);
;;;;             layer 0 is opaque, layers 1-3 use SRC_ALPHA blending.

;;; --------------------------------------------------------------------------
;;; Constants (must match grid.lisp)
;;; --------------------------------------------------------------------------

(defconstant +layered-stride+ 14)   ; bytes per layered instance

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
  atlas
  (win-w 640 :type fixnum)
  (win-h 480 :type fixnum))

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

;;; Simple instance layout (8 bytes):
;;;   offset 0: int16  col       → i_cell.x
;;;   offset 2: int16  row       → i_cell.y
;;;   offset 4: uint16 glyph     → i_glyph
;;;   offset 6: uint8  fg        → i_colors.x
;;;   offset 7: uint8  bg        → i_colors.y
(defun %make-simple-vao (corner-vbo)
  (let ((vao (first (gl:gen-vertex-arrays 1)))
        (vbo (first (gl:gen-buffers 1))))
    (gl:bind-vertex-array vao)
    ;; Attr 0: corner (per-vertex, 2 floats, stride 8 bytes)
    (gl:bind-buffer :array-buffer corner-vbo)
    (gl:vertex-attrib-pointer 0 2 :float nil 8 0)
    (gl:enable-vertex-attrib-array 0)
    ;; Instance attributes (stride 8)
    (gl:bind-buffer :array-buffer vbo)
    (%gl:vertex-attrib-ipointer 1 2 :short          8 (cffi:make-pointer 0))  ; i_cell
    (%gl:vertex-attrib-ipointer 2 1 :unsigned-short 8 (cffi:make-pointer 4))  ; i_glyph
    (%gl:vertex-attrib-ipointer 3 2 :unsigned-byte  8 (cffi:make-pointer 6))  ; i_colors
    (gl:enable-vertex-attrib-array 1)
    (gl:enable-vertex-attrib-array 2)
    (gl:enable-vertex-attrib-array 3)
    (%gl:vertex-attrib-divisor 1 1)
    (%gl:vertex-attrib-divisor 2 1)
    (%gl:vertex-attrib-divisor 3 1)
    (gl:bind-vertex-array 0)
    (values vao vbo)))

;;; Layered instance layout (14 bytes):
;;;   offset  0: int16  col           → i_cell.x
;;;   offset  2: int16  row           → i_cell.y
;;;   offset  4: uint16 glyph         → i_glyph
;;;   offset  6: uint8  ink-idx       → i_ink_bg.x
;;;   offset  7: uint8  bg-idx        → i_ink_bg.y
;;;   offset  8: uint8  trans-side    → i_ts
;;;   offset  9: uint8  (pad)
;;;   offset 10: uint8  palette[0]    → i_palette.x
;;;   offset 11: uint8  palette[1]    → i_palette.y
;;;   offset 12: uint8  palette[2]    → i_palette.z
;;;   offset 13: uint8  palette[3]    → i_palette.w
(defun %make-layered-vao (corner-vbo)
  (let ((vao (first (gl:gen-vertex-arrays 1)))
        (vbo (first (gl:gen-buffers 1))))
    (gl:bind-vertex-array vao)
    ;; Attr 0: corner (per-vertex)
    (gl:bind-buffer :array-buffer corner-vbo)
    (gl:vertex-attrib-pointer 0 2 :float nil 8 0)
    (gl:enable-vertex-attrib-array 0)
    ;; Instance attributes (stride 14) — initial pointers at offset 0
    (gl:bind-buffer :array-buffer vbo)
    (%gl:vertex-attrib-ipointer 1 2 :short          14 (cffi:make-pointer 0))
    (%gl:vertex-attrib-ipointer 2 1 :unsigned-short 14 (cffi:make-pointer 4))
    (%gl:vertex-attrib-ipointer 3 2 :unsigned-byte  14 (cffi:make-pointer 6))
    (%gl:vertex-attrib-ipointer 4 1 :unsigned-byte  14 (cffi:make-pointer 8))
    (%gl:vertex-attrib-ipointer 5 4 :unsigned-byte  14 (cffi:make-pointer 10))
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
  (let ((ubo (first (gl:gen-buffers 1))))
    (gl:bind-buffer :uniform-buffer ubo)
    (%gl:buffer-data :uniform-buffer 4096 (cffi:null-pointer) :dynamic-draw)
    (gl:bind-buffer :uniform-buffer 0)
    ubo))

(defun %bind-ubo-to-prog (prog ubo)
  "Bind the 'Palette' uniform block in PROG to UBO binding point 0."
  ;; gl:get-uniform-block-index handles Lisp string -> C string conversion
  (let ((idx (gl:get-uniform-block-index prog "Palette")))
    (unless (= idx #xFFFFFFFF)
      (%gl:uniform-block-binding prog idx 0)))
  (%gl:bind-buffer-base :uniform-buffer 0 ubo))

(defun set-palette (rs palette-floats)
  "Upload PALETTE-FLOATS (1024 single-floats: 256 x RGBA) to the palette UBO."
  (gl:bind-buffer :uniform-buffer (render-state-palette-ubo rs))
  (cffi:with-pointer-to-vector-data (ptr palette-floats)
    (%gl:buffer-sub-data :uniform-buffer 0 4096 ptr))
  (gl:bind-buffer :uniform-buffer 0))

;;; --------------------------------------------------------------------------
;;; Uniform helpers
;;; --------------------------------------------------------------------------

(defun %set-uniforms (prog atlas win-w win-h)
  (gl:use-program prog)
  (gl:uniformi (gl:get-uniform-location prog "u_cell_size")
               (atlas-cell-width atlas) (atlas-cell-height atlas))
  (gl:uniformi (gl:get-uniform-location prog "u_viewport") win-w win-h)
  (gl:uniformi (gl:get-uniform-location prog "u_atlas_size")
               (atlas-cols atlas) (atlas-rows atlas))
  (gl:uniformi (gl:get-uniform-location prog "u_atlas") 0))

;;; --------------------------------------------------------------------------
;;; Public constructor
;;; --------------------------------------------------------------------------

(defun make-renderer (atlas win-w win-h)
  "Create a RENDER-STATE.  A GL 3.3 core context must already be current."
  (let* ((sp  (%link-program +simple-vert+  +simple-frag+))
         (lp  (%link-program +layered-vert+ +layered-frag+))
         (cv  (%make-corner-vbo))
         (pu  (%make-palette-ubo)))
    (multiple-value-bind (svao svbo) (%make-simple-vao  cv)
      (multiple-value-bind (lvao lvbo) (%make-layered-vao cv)
        (%bind-ubo-to-prog sp pu)
        (%bind-ubo-to-prog lp pu)
        (%set-uniforms sp atlas win-w win-h)
        (%set-uniforms lp atlas win-w win-h)
        (gl:use-program 0)
        (make-render-state :simple-prog  sp  :layered-prog lp
                           :corner-vbo   cv  :simple-vao   svao
                           :simple-vbo   svbo :layered-vao  lvao
                           :layered-vbo  lvbo :palette-ubo  pu
                           :atlas        atlas :win-w win-w :win-h win-h)))))

;;; --------------------------------------------------------------------------
;;; Per-frame render
;;; --------------------------------------------------------------------------

(defun render-frame (rs grid)
  "Render one frame.  Call after making the GL context current."
  (gl:clear-color 0.0 0.0 0.0 1.0)
  (gl:clear :color-buffer-bit)
  (multiple-value-bind (sdata sc ldata lc)
      (build-render-data grid)
    (let ((atlas (render-state-atlas rs)))
      ;; Bind atlas texture to unit 0
      (gl:active-texture :texture0)
      (gl:bind-texture :texture-2d (atlas-texture-id atlas))
      ;; ---- Simple cells ------------------------------------------------
      (when (> sc 0)
        (gl:use-program (render-state-simple-prog rs))
        (%bind-ubo-to-prog (render-state-simple-prog rs)
                           (render-state-palette-ubo rs))
        (gl:disable :blend)
        (gl:bind-buffer :array-buffer (render-state-simple-vbo rs))
        (cffi:with-pointer-to-vector-data (ptr sdata)
          (%gl:buffer-data :array-buffer (length sdata) ptr :stream-draw))
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
          (cffi:with-pointer-to-vector-data (ptr ldata)
            (%gl:buffer-data :array-buffer (length ldata) ptr :stream-draw))
          (gl:bind-vertex-array (render-state-layered-vao rs))
          ;; Draw each layer depth in turn, updating attrib offsets.
          ;; GL 3.3 has no glDrawArraysInstancedBaseInstance, so we slide
          ;; the vertex attrib pointers to the correct byte offset instead.
          (let ((byte-off 0))
            (dotimes (ln 4)
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
                   2 1 :unsigned-short +layered-stride+ (cffi:make-pointer (+ byte-off 4)))
                  (%gl:vertex-attrib-ipointer
                   3 2 :unsigned-byte  +layered-stride+ (cffi:make-pointer (+ byte-off 6)))
                  (%gl:vertex-attrib-ipointer
                   4 1 :unsigned-byte  +layered-stride+ (cffi:make-pointer (+ byte-off 8)))
                  (%gl:vertex-attrib-ipointer
                   5 4 :unsigned-byte  +layered-stride+ (cffi:make-pointer (+ byte-off 10)))
                  (%gl:draw-arrays-instanced :triangle-strip 0 4 count)
                  (incf byte-off (* count +layered-stride+)))))))))
  (gl:bind-vertex-array 0)
  (gl:use-program 0)))

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
  (gl:delete-vertex-arrays (list (render-state-simple-vao  rs)
                                 (render-state-layered-vao rs))))
