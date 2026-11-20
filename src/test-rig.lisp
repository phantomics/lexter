;;;; Screenshot-based test rig for Lexter.
;;;;
;;;; Two phases:
;;;;
;;;;   Authoring (interactive, one-time): on a live recording terminal, capture
;;;;   the raw host->terminal byte stream and the rendered pixels, then write the
;;;;   bytes to a framed ".ptyb" blob and print its 64-bit pixel checksum.
;;;;
;;;;   Testing (automated, deterministic): build a single headless terminal from
;;;;   a durable config, replay each blob through it, capture pixels, and assert
;;;;   the checksum matches an inline literal. Lexter's bitmap-font + nearest
;;;;   sampling renderer is pixel-deterministic, so exact-checksum comparison is
;;;;   sound (unlike vector-font terminals, which need tolerance comparison).
;;;;
;;;; Blob format (".ptyb"):
;;;;   bytes 0-3  magic  "PTYB" (#x50 #x54 #x59 #x42)
;;;;   byte  4    version (currently 1)
;;;;   bytes 5-8  payload length, big-endian u32
;;;;   bytes 9..  payload (the raw recorded byte stream)

(defpackage #:lexter/test
  (:use #:cl #:lexter/unix-term #:lexter/vt-handler)
  (:export ;; Checksum
           #:fnv1a-64
           ;; Blob API
           #:write-blob
           #:read-blob
           #:default-blob-writer
           ;; Authoring
           #:dump-terminal
           #:print-terminal-config
           ;; Testing
           #:with-terminal-test-config
           #:test-pixels
           #:replay-blob
           #:*test-terminal*
           ;; The GPU's stores
           #:check-gpu-stores
           #:check-integer-texture-buffers
           ;; The shader against the manifests (LEXTER-D130)
           #:reference-pixel-slot
           #:check-record-drawing))

(in-package #:lexter/test)

;;; --------------------------------------------------------------------------
;;; Pixel checksum (FNV-1a, 64-bit)
;;; --------------------------------------------------------------------------

(defconstant +fnv64-offset+ 14695981039346656037)
(defconstant +fnv64-prime+  1099511628211)
(defconstant +u64-mask+     #xFFFFFFFFFFFFFFFF)

(defun fnv1a-64 (pixels)
  "Compute a deterministic 64-bit FNV-1a hash over the bytes of PIXELS, an
   (unsigned-byte 8) array of any rank (e.g. the (H W 3) result of
   TERMINAL-CAPTURE). Chosen over SXHASH for cross-implementation stability and
   over crypto hashes for speed; any pixel difference flips the result."
  (let ((hash +fnv64-offset+)
        (flat (make-array (array-total-size pixels)
                          :element-type '(unsigned-byte 8)
                          :displaced-to pixels)))
    (declare (type (unsigned-byte 64) hash))
    (loop :for b :across flat
          :do (setf hash (logand (* (logxor hash b) +fnv64-prime+) +u64-mask+)))
    hash))

;;; --------------------------------------------------------------------------
;;; Blob framing
;;; --------------------------------------------------------------------------

(defparameter +blob-magic+ #(#x50 #x54 #x59 #x42) "ASCII \"PTYB\".")
(defparameter +blob-version+ 1)

(defun %frame-blob (payload)
  "Return a fresh (unsigned-byte 8) vector: magic + version + length + PAYLOAD."
  (let* ((n   (length payload))
         (out (make-array (+ 9 n) :element-type '(unsigned-byte 8))))
    (replace out +blob-magic+)
    (setf (aref out 4) +blob-version+
          (aref out 5) (ldb (byte 8 24) n)
          (aref out 6) (ldb (byte 8 16) n)
          (aref out 7) (ldb (byte 8 8) n)
          (aref out 8) (ldb (byte 8 0) n))
    (replace out payload :start1 9)
    out))

(defun %unframe-blob (raw source)
  "Validate the framed RAW bytes and return the payload. SOURCE names the origin
   for error messages."
  (when (< (length raw) 9)
    (error "Blob ~a is truncated (~d bytes, need >= 9)." source (length raw)))
  (unless (loop :for i :below 4 :always (= (aref raw i) (aref +blob-magic+ i)))
    (error "Blob ~a has a bad magic header (expected PTYB)." source))
  (let ((version (aref raw 4)))
    (unless (= version +blob-version+)
      (error "Blob ~a has unsupported version ~d (expected ~d)."
             source version +blob-version+)))
  (let ((len (logior (ash (aref raw 5) 24) (ash (aref raw 6) 16)
                     (ash (aref raw 7) 8)  (aref raw 8))))
    (unless (= (length raw) (+ 9 len))
      (error "Blob ~a length mismatch: header says ~d payload bytes, file has ~d."
             source len (- (length raw) 9)))
    (subseq raw 9)))

(defun default-blob-writer (bytes &key name checksum)
  "Default blob handler: write a framed \"<NAME>.ptyb\" file holding BYTES.
   Returns the pathname string. CHECKSUM is accepted (and ignored) so custom
   handlers may share this signature."
  (declare (ignore checksum))
  (let ((path (format nil "~a.ptyb" name))
        (framed (%frame-blob bytes)))
    (with-open-file (s path :direction :output
                           :element-type '(unsigned-byte 8)
                           :if-exists :supersede
                           :if-does-not-exist :create)
      (write-sequence framed s))
    path))

(defun write-blob (bytes path)
  "Write BYTES as a framed .ptyb blob to PATH. Returns PATH."
  (with-open-file (s path :direction :output
                         :element-type '(unsigned-byte 8)
                         :if-exists :supersede
                         :if-does-not-exist :create)
    (write-sequence (%frame-blob bytes) s))
  path)

(defun read-blob (path)
  "Read the framed .ptyb blob at PATH and return its payload as a simple
   (unsigned-byte 8) vector. Signals an error on a bad/truncated frame."
  (with-open-file (s path :direction :input :element-type '(unsigned-byte 8))
    (let ((raw (make-array (file-length s) :element-type '(unsigned-byte 8))))
      (read-sequence raw s)
      (%unframe-blob raw path))))

;;; --------------------------------------------------------------------------
;;; Authoring
;;; --------------------------------------------------------------------------

(defun print-terminal-config (term &optional (stream *standard-output*))
  "Print TERM's durable test config as a paste-ready plist for the head of a
   WITH-TERMINAL-TEST-CONFIG form. Returns the config plist."
  (let ((cfg (terminal-config-plist term)))
    (format stream "~&~s~%" cfg)
    cfg))

(defun %pixel-dims (pixels)
  "Return (values height width channels) for an (H W C) capture array."
  (values (array-dimension pixels 0)
          (array-dimension pixels 1)
          (if (= (array-rank pixels) 3) (array-dimension pixels 2) 1)))

(defun dump-terminal (term &key name
                                (blob-handler #'default-blob-writer)
                                pixel-fn)
  "Finish a recording on TERM and emit a test fixture.

   Stops recording to obtain the raw byte stream, captures the current screen,
   computes its FNV-1a-64 pixel checksum, hands the bytes to BLOB-HANDLER (which
   defaults to writing \"<NAME>.ptyb\"), and prints \"<blob>  #x<checksum>\" so
   the line can be pasted into a TEST-PIXELS form.

   BLOB-HANDLER is called as (funcall blob-handler bytes :name NAME
   :checksum CHECKSUM) and should return an identifier (e.g. the path).

   PIXEL-FN, if supplied, is called on the raw capture for side effects such as
   writing a reference PNG:
     (funcall pixel-fn pixels :width W :height H :channels C
                              :checksum CHECKSUM :name NAME :config PLIST)
   Define it with &key &allow-other-keys so future arguments stay compatible.

   Returns (values checksum blob-id)."
  (let ((bytes (terminal-stop-recording term)))
    (unless bytes
      (error "DUMP-TERMINAL: TERM was not recording (call TERMINAL-START-RECORDING first)."))
    (let* ((pixels   (terminal-capture term))
           (checksum (fnv1a-64 pixels))
           (blob-id  (funcall blob-handler bytes :name name :checksum checksum)))
      (when pixel-fn
        (multiple-value-bind (h w c) (%pixel-dims pixels)
          (funcall pixel-fn pixels
                   :width w :height h :channels c
                   :checksum checksum :name name
                   :config (terminal-config-plist term))))
      (format t "~&~a  #x~16,'0X~%" blob-id checksum)
      (values checksum blob-id))))

;;; --------------------------------------------------------------------------
;;; Testing
;;; --------------------------------------------------------------------------

(defvar *test-terminal* nil
  "The headless replay terminal bound within WITH-TERMINAL-TEST-CONFIG.")

(defun replay-blob (term bytes)
  "Reset TERM to a blank screen, replay the raw BYTES through its VT handler,
   and return the rendered capture as an (H W 3) (unsigned-byte 8) array."
  (terminal-reset term)
  (process-output (unix-terminal-vt-handler term) bytes)
  (terminal-capture term))

(defun call-with-terminal-test-config (thunk &key font-path fonts cols rows
                                                  cell-width cell-height
                                                  pixel-scale)
  "Functional core of WITH-TERMINAL-TEST-CONFIG. Owns the GLFW lifecycle, builds
   one headless (:NO-PTY, hidden) terminal from the config, binds *TEST-TERMINAL*
   to it for the dynamic extent of THUNK, and tears everything down afterwards."
  (glfw:initialize)
  (let ((term (make-terminal nil
                             :no-pty t :visible nil
                             :font-path (or font-path "../terminus-18n.pcf")
                             :fonts fonts
                             :cols cols :rows rows
                             :pixel-scale (or pixel-scale 1))))
    (unwind-protect
         (progn
           (gui-initialize term)
           ;; The font determines cell dimensions; if the config declared them,
           ;; verify they match so a font swap can't silently shift the geometry.
           (let ((cfg (terminal-config-plist term)))
             (when (and cell-width (/= cell-width (getf cfg :cell-width)))
               (warn "Test config :CELL-WIDTH ~d disagrees with loaded font ~d."
                     cell-width (getf cfg :cell-width)))
             (when (and cell-height (/= cell-height (getf cfg :cell-height)))
               (warn "Test config :CELL-HEIGHT ~d disagrees with loaded font ~d."
                     cell-height (getf cfg :cell-height))))
           (let ((*test-terminal* term))
             (funcall thunk)))
      (gui-destroy term)
      (glfw:terminate))))

(defmacro with-terminal-test-config ((&key font-path fonts (cols 80) (rows 24)
                                           cell-width cell-height (pixel-scale 1))
                                     &body body)
  "Establish a headless replay terminal from a durable config and run BODY (a
   series of TEST-PIXELS forms) against it. The terminal is built once and
   reused across all enclosed TEST-PIXELS forms (each resets the screen first).

   Example:
     (with-terminal-test-config (:font-path \"unifont-17.0.04.pcf.gz\"
                                 :cols 80 :rows 24
                                 :cell-width 8 :cell-height 16 :pixel-scale 1)
       (test-pixels \"./1044.ptyb\" #xAABBCCDDEEFF0011)
       (test-pixels \"./1051.ptyb\" #x1122334455667788))"
  `(call-with-terminal-test-config
    (lambda () ,@body)
    :font-path ,font-path :fonts ,fonts
    :cols ,cols :rows ,rows
    :cell-width ,cell-width :cell-height ,cell-height
    :pixel-scale ,pixel-scale))

(defun test-pixels (blob-path expected &key on-mismatch)
  "Replay the .ptyb blob at BLOB-PATH through *TEST-TERMINAL* and assert its
   pixel checksum equals EXPECTED. Silent on success (returns T); signals an
   error on mismatch.

   ON-MISMATCH, if supplied, is called before the error with the actual capture
   using the same keyword signature as DUMP-TERMINAL's PIXEL-FN (e.g. to write
   an actual-<name>.png for diffing)."
  (unless *test-terminal*
    (error "TEST-PIXELS called outside WITH-TERMINAL-TEST-CONFIG."))
  (let* ((bytes  (read-blob blob-path))
         (pixels (replay-blob *test-terminal* bytes))
         (actual (fnv1a-64 pixels)))
    (unless (= actual expected)
      (when on-mismatch
        (multiple-value-bind (h w c) (%pixel-dims pixels)
          (funcall on-mismatch pixels
                   :width w :height h :channels c
                   :checksum actual :name blob-path
                   :config (terminal-config-plist *test-terminal*))))
      (error "TEST-PIXELS mismatch for ~a:~%  expected #x~16,'0X~%  actual   #x~16,'0X"
             blob-path expected actual))
    t))

;;; --------------------------------------------------------------------------
;;; The GPU's stores against their sources (LEXTER-D106)
;;; --------------------------------------------------------------------------

(defun %read-texels (buffer first count)
  "Read COUNT RGBA8UI texels from BUFFER from texel FIRST, as bytes."
  (let ((out (make-array (* count 4) :element-type '(unsigned-byte 8))))
    (gl:bind-buffer :texture-buffer buffer)
    (cffi:with-pointer-to-vector-data (ptr out)
      (%gl:get-buffer-sub-data :texture-buffer (* first 4) (* count 4) ptr))
    (gl:bind-buffer :texture-buffer 0)
    out))

(defun check-gpu-stores (&optional (term *test-terminal*))
  "Compare what TERM's renderer last uploaded with its sources: every swatch
   that a table of the compositor's store holds with the swatch store on the
   GPU, palette slot 0 with the default palette, and the slot the terminal's
   pane draws in with its active screen's palette. Run after a capture, which
   uploads; needs TERM's GL context, so it runs in the test rig's hidden
   window, not in the headless suite. Returns the number of swatches compared,
   or signals an error naming the first that differs."
  (let* ((comp (unix-terminal-compositor term))
         (rs (lexter/panes:compositor-renderer comp))
         (store (lexter/panes:compositor-swatch-store comp))
         (compared 0))
    (glfw:make-context-current (lexter/panes:compositor-window comp))
    (dotimes (r lexter/swatches:+store-ranges+)
      (let ((table (lexter/swatches:range-owner store r)))
        (when table
          (let* ((base (* r lexter/swatches:+range-size+))
                 (k (position r (lexter/swatches:swatch-table-ranges table)))
                 (used (max 0 (min lexter/swatches:+range-size+
                                   (- (lexter/swatches:swatch-table-count table)
                                      (* k lexter/swatches:+range-size+)))))
                 (gpu (%read-texels (lexter/renderer::render-state-swatch-buffer rs)
                                    base used)))
            (dotimes (i used)
              (let ((want (multiple-value-list
                           (lexter/swatches:table-swatch table (+ base i))))
                    (got (coerce (subseq gpu (* i 4) (* (1+ i) 4)) 'list)))
                (unless (equal want got)
                  (error "Swatch ~d: the table holds ~s, the GPU ~s." (+ base i) want got))
                (incf compared)))))))
    (flet ((check-palette (slot palette what)
             (let ((gpu (%read-texels (lexter/renderer::render-state-palette-buffer rs)
                                      (* slot lexter/swatches:+palette-entries+)
                                      lexter/swatches:+palette-entries+)))
               (unless (equalp gpu palette)
                 (error "Palette slot ~d differs from ~a." slot what)))))
      (check-palette 0 (lexter/swatches:make-default-palette) "the default palette")
      (let ((screen (terminal-screen term)))
        (check-palette (lexter/panes:vt-pane-drawn-palette-slot (unix-terminal-pane term))
                       (lexter/model:screen-palette screen)
                       "the terminal's palette")))
    compared))

;;; --------------------------------------------------------------------------
;;; Integer texture buffers (LEXTER-D109)
;;; --------------------------------------------------------------------------

(defparameter +tbo-check-vert+
  "#version 330 core
void main() {
    vec2 p = vec2(float(gl_VertexID & 1), float(gl_VertexID >> 1));
    gl_Position = vec4(p * 2.0 - 1.0, 0.0, 1.0);
}
")

(defparameter +tbo-check-frag+
  "#version 330 core
uniform usamplerBuffer u_store;
out vec4 frag_color;
void main() {
    uvec4 v = texelFetch(u_store, int(gl_FragCoord.x));
    frag_color = vec4(v) / 255.0;
}
")

(defun check-integer-texture-buffers (&key (texels 256))
  "Confirm that cl-opengl can create and fill a GL_RGBA8UI texture buffer, and
   that a shader reads it through usamplerBuffer with texelFetch, as the swatch
   and palette stores require (LEXTER-D109). Draws TEXELS pixels in a hidden
   window, one texel to a pixel, and compares what is read back with what was
   uploaded. Owns the GLFW lifecycle. Returns T, or signals an error naming the
   first texel that differs."
  (glfw:initialize)
  (unwind-protect
       (let ((win (glfw:create-window :title "tbo check" :width texels :height 1
                                      :visible nil
                                      :context-version-major 3
                                      :context-version-minor 3
                                      :opengl-profile :opengl-core-profile
                                      :opengl-forward-compat t))
             (data (make-array (* texels 4) :element-type '(unsigned-byte 8))))
         (dotimes (i (length data))
           (setf (aref data i) (mod (* 37 (1+ i)) 256)))
         (unwind-protect
              (let ((buf (first (gl:gen-buffers 1)))
                    (tex (first (gl:gen-textures 1)))
                    (fbo (first (gl:gen-framebuffers 1)))
                    (target (first (gl:gen-textures 1)))
                    (vao (first (gl:gen-vertex-arrays 1)))
                    (prog (lexter/renderer::%link-program +tbo-check-vert+
                                                          +tbo-check-frag+)))
                ;; The store: an ordinary buffer object seen as RGBA8UI texels
                (gl:bind-buffer :texture-buffer buf)
                (cffi:with-pointer-to-vector-data (ptr data)
                  (%gl:buffer-data :texture-buffer (length data) ptr :static-draw))
                (gl:bind-buffer :texture-buffer 0)
                (gl:active-texture :texture0)
                (gl:bind-texture :texture-buffer tex)
                (%gl:tex-buffer :texture-buffer :rgba8ui buf)
                ;; An RGBA8 target to draw into and read back
                (gl:bind-texture :texture-2d target)
                (gl:tex-image-2d :texture-2d 0 :rgba8 texels 1 0 :rgba :unsigned-byte
                                 (cffi:null-pointer))
                (gl:bind-framebuffer :framebuffer fbo)
                (gl:framebuffer-texture-2d :framebuffer :color-attachment0 :texture-2d
                                           target 0)
                (gl:viewport 0 0 texels 1)
                (gl:use-program prog)
                (gl:uniformi (gl:get-uniform-location prog "u_store") 0)
                (gl:bind-texture :texture-buffer tex)
                (gl:bind-vertex-array vao)
                (gl:disable :blend)
                (%gl:draw-arrays :triangle-strip 0 4)
                (gl:pixel-store :pack-alignment 1)
                (gl:read-buffer :color-attachment0)
                (let ((got (gl:read-pixels 0 0 texels 1 :rgba :unsigned-byte)))
                  (gl:bind-framebuffer :framebuffer 0)
                  (gl:delete-program prog)
                  (gl:delete-vertex-arrays (list vao))
                  (gl:delete-framebuffers (list fbo))
                  (gl:delete-textures (list tex target))
                  (gl:delete-buffers (list buf))
                  (dotimes (i (length data) t)
                    (unless (= (aref got i) (aref data i))
                      (error "Texel ~d, byte ~d: uploaded ~d, read back ~d."
                             (floor i 4) (mod i 4) (aref data i) (aref got i))))))
           (glfw:destroy-window win)))
    (glfw:terminate)))

;;; --------------------------------------------------------------------------
;;; The shader against the manifests (LEXTER-D130)
;;; --------------------------------------------------------------------------
;;;
;;; The renderer's fragment shader is written by hand from the architecture's
;;; tables. REFERENCE-PIXEL-SLOT follows the same procedure, Drawing a Pixel
;;; in LEXTER-0016, in Lisp, reading each record through its manifests rather
;;; than by the shader's arithmetic on its words, and CHECK-RECORD-DRAWING
;;; compares the two over every pixel of a grid of records the manifests and
;;; the API wrote. It is the seed of the CPU renderer of Phase 5 (LEXTER-D111).

(defun reference-pixel-slot (records index x y glyph-pixel &key blink-off)
  "The swatch slot that pixel X, Y of record INDEX of RECORDS takes, by the
   procedure of Drawing a Pixel for the plain format (LEXTER-0016), with
   GLYPH-PIXEL a function of an atlas position, the pixel X, Y, and the cell's
   line size and magnified half, that gives 1 where the glyph is inked at the
   pixel, magnified as LEXTER-D114 has it. A record of another format takes its
   background slot (LEXTER-D82). BLINK-OFF is the blink phase (LEXTER-D94)."
  (let ((background (lexter/manifests:read-record-common records index :background-slot)))
    (unless (eq (lexter/manifests:record-format records index) :plain)
      (return-from reference-pixel-slot background))
    (multiple-value-bind (blink line-size magnified)
        (lexter/manifests:read-record-common records index :blink :line-size :magnified-half)
      (multiple-value-bind (count types) (lexter/manifests:record-type-bits records index)
        (let ((n (min count lexter/manifests:+plain-glyph-words+))
              (coverage 0)
              (layers 0)
              (slot background))
          (flet ((layer-p (i) (or (zerop i) (not (logbitp (1- i) types))))
                 (covered (i)
                   (logxor (funcall glyph-pixel (lexter/manifests:record-glyph records index i)
                                    x y line-size magnified)
                           (lexter/manifests:record-selector records index i))))
            (dotimes (i n)
              (let ((p (covered i)))
                (if (layer-p i)
                    (setf coverage (logior coverage (ash p layers))
                          layers (1+ layers))
                    (multiple-value-bind (operation reach)
                        (lexter/manifests:record-mask records index i)
                      (let* ((r (min (1+ reach) layers))
                             (reached (ash (1- (ash 1 r)) (- layers r)))
                             (m (if (= p 1) reached 0))
                             (result (ecase operation
                                       (:union (logior coverage m))
                                       (:intersection (logand coverage m))
                                       (:exclusion (logxor coverage m))
                                       (:mask-less-coverage (logandc2 m coverage)))))
                        (setf coverage (logior (logandc2 coverage reached)
                                               (logand result reached))))))))
            (when (and (= blink 1) blink-off (plusp layers))
              (setf coverage (logandc2 coverage (ash 1 (1- layers)))))
            (let ((l 0))
              (dotimes (i n)
                (when (layer-p i)
                  (when (logbitp l coverage)
                    (setf slot (lexter/manifests:record-ink-slot records index i)))
                  (incf l))))
            slot))))))

(defun %record-drawing-grid (grid table)
  "Write GRID, whose glyphs come from its atlas, with records that exercise the
   procedure of Drawing a Pixel, their swatches interned in TABLE."
  (let ((a (lexter/swatches:intern-swatch table 0 15 9 12))
        (b (lexter/swatches:intern-swatch table 4 11 10 13))
        (records (lexter/grid:display-grid-records grid))
        (col 0))
    (flet ((next () (prog1 col (incf col)))
           (glyph (char) (lexter/surface:char-glyph grid char)))
      ;; The worked records of LEXTER-0016, and further cases
      (lexter/surface:put-char grid (next) 0 #\g :swatch a)
      (lexter/surface:put-char grid (next) 0 #\g :swatch a :ink-slot 0 :background-slot 1)
      (lexter/surface:put-char grid (next) 0 #\g :swatch a :underline t)
      (lexter/surface:put-cell grid (next) 0 `((:layer :glyph 9 :ink-slot 2)
                                               (:layer :char #\g :ink-slot 1)
                                               (:mask :glyph 10 :operation :union))
                               :swatch b)
      (lexter/surface:put-cell grid (next) 0 `((:layer :char #\| :ink-slot 1)
                                               (:mask :char #\▆ :operation :intersection)
                                               (:mask :char #\▂ :selector 1 :operation :intersection))
                               :swatch a)
      (lexter/surface:put-cell grid (next) 0 `((:layer :glyph 9 :ink-slot 2)
                                               (:layer :char #\g :ink-slot 1)
                                               (:mask :char #\▌ :operation :intersection :reach 1))
                               :swatch b)
      (lexter/surface:put-cell grid (next) 0 `((:layer :glyph 9 :ink-slot 2)
                                               (:layer :char #\g :ink-slot 1))
                               :swatch b :blink t)
      (lexter/surface:put-cell grid (next) 0 `((:layer :char #\O :ink-slot 3)
                                               (:mask :char #\X :operation :exclusion))
                               :swatch b :background-slot 2)
      (lexter/surface:put-cell grid (next) 0 `((:layer :char #\O :ink-slot 3)
                                               (:mask :char #\X :operation :mask-less-coverage))
                               :swatch b)
      (lexter/surface:put-cell grid (next) 0 `((:layer :char #\A :selector 1 :ink-slot 2)
                                               (:layer :char #\B :ink-slot 3))
                               :swatch a :background-slot 1)
      (lexter/surface:fill-cells grid (next) 0 1 1 :swatch b :background-slot 2)
      ;; A wide glyph's two halves, and a narrow glyph over it in both
      (lexter/surface:put-cell grid col 0 `((:layer :char ,(code-char #x4E00) :ink-slot 1)
                                            (:layer :char #\_ :ink-slot 2))
                               :swatch b)
      (incf col 2)
      ;; The bottom of a double-height line, the right of its two cells
      (let ((index (lexter/grid:cell-index grid (next) 0)))
        (lexter/manifests:write-plain-record records index
          :glyph-count 1 :line-size 3 :magnified-half 1 :swatch a
          :g0 (:glyph (glyph #\W) :ink-slot 1)))
      ;; A format the renderer does not draw, in its background slot
      (let ((index (lexter/grid:cell-index grid (next) 0)))
        (lexter/manifests:write-plain-record records index :swatch b :background-slot 3)
        (lexter/manifests:patch-record-common records index :format :tiles))
      ;; Row 1: palette slots: the custom palette in slot 1, and a slot beyond
      ;; the store, which draws in slot 0
      (loop :for (slot c) :in '((1 0) (1 1) (200 2) (0 3))
            :do (lexter/surface:put-char grid c 1 #\g :swatch a)
                (lexter/manifests:patch-record-common
                 records (lexter/grid:cell-index grid c 1) :palette-slot slot))
      ;; Row 2: text through the API, and a cursor's exchanged slots
      (lexter/surface:put-string grid 0 2 "Hello, record." :swatch a)
      (lexter/grid:exchange-cell-slots grid 5 2))))

(defun check-record-drawing (&key (font-path "../unifont-17.0.04.pcf.gz") (cols 16) (rows 3)
                                  (pixel-scale 1))
  "Draw a grid of records that the manifests and the API wrote with the
   renderer, in a hidden window, in both blink phases, and compare every pixel
   with what REFERENCE-PIXEL-SLOT gives through the swatch and palette stores
   (LEXTER-D130). The records cover the worked records of the cell-model
   architecture and the cases beyond them: each mask operation, a reach of two
   layers, selectors, blink, the halves of a wide glyph, a line size, a format
   the renderer does not draw, palette slots of the cell's own and beyond the
   store, and the interim cursor. Floating-point traps are masked, as llvmpipe
   needs. Owns the GLFW lifecycle. Returns the number of pixels compared, or
   signals an error naming the first that differs."
  (sb-int:with-float-traps-masked (:invalid :divide-by-zero :overflow :inexact)
    (glfw:initialize)
    (unwind-protect
         (let* ((font (lexter/pcf:load-pcf font-path))
                (cw (lexter/pcf:bitmap-font-cell-width font))
                (ch (lexter/pcf:bitmap-font-cell-height font))
                (w (* cols cw pixel-scale))
                (h (* rows ch pixel-scale))
                (win (glfw:create-window :title "record drawing check" :width w :height h
                                         :visible nil
                                         :context-version-major 3 :context-version-minor 3
                                         :opengl-profile :opengl-core-profile
                                         :opengl-forward-compat t)))
           (declare (ignore win))
           (let* ((atlas (lexter/atlas:build-atlas (list font)))
                  (grid (lexter/grid:make-display-grid :cols cols :rows rows :atlas atlas))
                  (store (lexter/swatches:make-swatch-store))
                  (table (lexter/swatches:swatch-store-display-table store))
                  (rs (lexter/renderer:make-renderer atlas w h :pixel-scale pixel-scale))
                  (custom (lexter/swatches:make-default-palette))
                  (compared 0))
             ;; Slot 1: the default palette with colours 9-15 made dark, so a
             ;; cell in it differs from the same cell in slot 0
             (loop :for i :from 9 :to 15
                   :do (lexter/manifests:write-palette-texel custom i (* 8 i) 40 (- 255 (* 8 i))))
             (lexter/renderer:set-palette rs custom 1)
             (%record-drawing-grid grid table)
             (multiple-value-bind (tex tex-w) (lexter/atlas::%atlas-texture-data atlas)
               (let* ((atlas-cols (lexter/atlas:atlas-cols atlas))
                      (records (lexter/grid:display-grid-records grid))
                      (palettes (list (cons 0 (lexter/swatches:make-default-palette))
                                      (cons 1 custom))))
                 (flet ((glyph-pixel (glyph x y line-size magnified)
                          ;; LEXTER-D114: magnified two times across, and down
                          ;; for double height
                          (let ((gx (if (zerop line-size) x (floor (+ (* magnified cw) x) 2)))
                                (gy (case line-size
                                      ((0 1) y)
                                      (t (floor (+ (* (- line-size 2) ch) y) 2)))))
                            (if (> (aref tex (+ (* (+ (* (floor glyph atlas-cols) ch) gy) tex-w)
                                                (* (mod glyph atlas-cols) cw) gx))
                                   127)
                                1 0))))
                   (lexter/renderer:enable-offscreen rs)
                   (dolist (blink-off '(nil t))
                     (lexter/renderer:render-frame rs grid store :blink-off blink-off)
                     (let ((pixels (lexter/renderer:capture-pixels rs)))
                       (dotimes (sy h)
                         (dotimes (sx w)
                           (let* ((col (floor sx (* cw pixel-scale)))
                                  (row (floor sy (* ch pixel-scale)))
                                  (x (floor (mod sx (* cw pixel-scale)) pixel-scale))
                                  (y (floor (mod sy (* ch pixel-scale)) pixel-scale))
                                  (index (lexter/grid:cell-index grid col row))
                                  (slot (reference-pixel-slot records index x y #'glyph-pixel
                                                              :blink-off blink-off))
                                  (swatch (multiple-value-list
                                           (lexter/swatches:store-swatch
                                            store (lexter/manifests:read-record-common
                                                   records index :swatch))))
                                  (palette-slot (lexter/manifests:read-record-common
                                                 records index :palette-slot))
                                  (palette (or (cdr (assoc palette-slot palettes))
                                               (cdr (assoc 0 palettes))))
                                  (want (subseq (multiple-value-list
                                                 (lexter/manifests:read-palette-texel
                                                  palette (nth slot swatch)))
                                                0 3))
                                  (got (list (aref pixels sy sx 0) (aref pixels sy sx 1)
                                             (aref pixels sy sx 2))))
                             (unless (equal want got)
                               (error "Pixel ~d,~d of cell ~d,~d (blink ~:[on~;off~]): ~
                                       the reference gives ~s in slot ~d, the GPU ~s."
                                      x y col row blink-off want slot got))
                             (incf compared))))))))
               (lexter/renderer:destroy-renderer rs)
               compared)))
      (glfw:terminate))))
