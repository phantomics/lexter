;;;; Function pane: a pane rendered by a CL function.
;;;;
;;;; Use this for custom widgets, status bars, cached command output, etc. The
;;;; pane keeps a surface of its size, which its render function writes
;;;; through the API (lexter/surface), in the pane's own coordinates, and which
;;;; its flush copies into the composed grid at the pane's place
;;;; (LEXTER-D124, LEXTER-D107).

(in-package #:lexter/panes)

;;; --------------------------------------------------------------------------
;;; Function pane class
;;; --------------------------------------------------------------------------

(defclass function-pane (pane)
  ((render-fn  :initarg :render-fn
               :accessor function-pane-render-fn
               :initform nil
               :documentation "Function (pane surface) that writes pane content to its surface.")
   (surface    :accessor function-pane-surface
               :initform nil
               :documentation "The surface the render function writes, of the pane's size.")
   (atlas      :accessor function-pane-atlas
               :initform nil
               :documentation "The atlas the pane's surface takes its glyphs from.")
   (key-handler :initarg :key-handler
                :accessor function-pane-key-handler
                :initform nil
                :documentation "Optional function (pane key scancode action mods).")
   (char-handler :initarg :char-handler
                 :accessor function-pane-char-handler
                 :initform nil
                 :documentation "Optional function (pane codepoint).")
   (state      :initarg :state
               :accessor function-pane-state
               :initform nil
               :documentation "Arbitrary state for the render function.")
   (dirty      :accessor function-pane-dirty
               :initform t
               :documentation "Set to T to request re-render."))
  (:documentation "A pane rendered by a user-supplied function."))

;;; --------------------------------------------------------------------------
;;; Constructor
;;; --------------------------------------------------------------------------

(defun make-function-pane (&key render-fn key-handler char-handler state
                                (col 0) (row 0) (width 80) (height 1)
                                (focusable nil))
  "Create a function pane.
   RENDER-FN is called with (pane surface) to write the pane's content to its
   surface, at the pane's own coordinates, from 0, 0.
   KEY-HANDLER and CHAR-HANDLER are optional input handlers.
   STATE is arbitrary data accessible via function-pane-state.
   FOCUSABLE defaults to NIL (most function panes are display-only)."
  (make-instance 'function-pane
                 :col col :row row :width width :height height
                 :render-fn render-fn
                 :key-handler key-handler
                 :char-handler char-handler
                 :state state
                 :focusable focusable))

;;; --------------------------------------------------------------------------
;;; Protocol implementations
;;; --------------------------------------------------------------------------

(defmethod pane-initialize ((pane function-pane) atlas)
  "Keep ATLAS, whose glyphs the pane's surface is written in."
  (setf (function-pane-atlas pane) atlas
        (function-pane-surface pane) nil))

(defun function-pane-ensure-surface (pane)
  "The pane's surface, made or made again at the pane's size, empty, in the
   pane's atlas."
  (let ((surface (function-pane-surface pane)))
    (cond ((null surface)
           (setf (function-pane-surface pane)
                 (lexter/grid:make-surface :cols (max 1 (pane-width pane))
                                           :rows (max 1 (pane-height pane))
                                           :atlas (function-pane-atlas pane))))
          ((or (/= (lexter/grid:display-grid-cols surface) (max 1 (pane-width pane)))
               (/= (lexter/grid:display-grid-rows surface) (max 1 (pane-height pane))))
           (lexter/grid:resize-surface surface (max 1 (pane-width pane))
                                       (max 1 (pane-height pane))))
          (t surface))))

(defmethod pane-flush ((pane function-pane) grid)
  "When the pane is dirty, call the render function to write its surface, then
   copy the surface into GRID at the pane's place."
  (when (function-pane-dirty pane)
    (let ((surface (function-pane-ensure-surface pane))
          (render-fn (function-pane-render-fn pane)))
      (when render-fn
        (funcall render-fn pane surface))
      (lexter/surface:compose-surface surface grid (pane-col pane) (pane-row pane)
                                      :cols (pane-width pane) :rows (pane-height pane))))
  ;; Clear dirty flag after render
  (setf (function-pane-dirty pane) nil))

(defmethod pane-handle-key ((pane function-pane) key scancode action mods)
  "Delegate to optional key handler."
  (let ((handler (function-pane-key-handler pane)))
    (when handler
      (funcall handler pane key scancode action mods))))

(defmethod pane-handle-char ((pane function-pane) codepoint)
  "Delegate to optional char handler."
  (let ((handler (function-pane-char-handler pane)))
    (when handler
      (funcall handler pane codepoint))))

(defmethod pane-dirty-p ((pane function-pane))
  "Return the dirty flag."
  (function-pane-dirty pane))

(defmethod pane-mark-dirty ((pane function-pane))
  "Set the dirty flag, so the render function runs at the next flush."
  (setf (function-pane-dirty pane) t))

(defmethod pane-resize ((pane function-pane) new-width new-height)
  "Update dimensions and mark dirty."
  (setf (pane-width pane) new-width
        (pane-height pane) new-height
        (function-pane-dirty pane) t))

;;; --------------------------------------------------------------------------
;;; Utility for render functions
;;; --------------------------------------------------------------------------

(defun write-pane-string (pane col row string &key (swatch 0))
  "Write STRING to the pane's surface at (COL, ROW), relative to the pane's
   origin, each character at its glyph's natural width.
   SWATCH is a global swatch index, from (DISPLAY-SWATCH PANE bg fg), since a
   function pane draws in the display's table
   (LEXTER-DRAFT-cell-model-revision-D24); by default the default colours."
  (lexter/surface:put-string (function-pane-ensure-surface pane) col row string
                             :swatch swatch))

(defun clear-pane-region (pane &key (swatch 0))
  "Make every cell of the pane's surface empty, in the background of SWATCH,
   a global swatch index as WRITE-PANE-STRING takes."
  (let ((surface (function-pane-ensure-surface pane)))
    (lexter/surface:fill-cells surface 0 0 (lexter/grid:display-grid-cols surface)
                               (lexter/grid:display-grid-rows surface) :swatch swatch)))
