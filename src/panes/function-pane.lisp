;;;; Function pane: a pane rendered by a CL function.
;;;;
;;;; Use this for custom widgets, status bars, cached command output, etc.

(in-package #:pcf-gl/panes)

;;; --------------------------------------------------------------------------
;;; Function pane class
;;; --------------------------------------------------------------------------

(defclass function-pane (pane)
  ((render-fn  :initarg :render-fn
               :accessor function-pane-render-fn
               :initform nil
               :documentation "Function (pane grid) that renders pane content.")
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
   RENDER-FN is called with (pane grid) to render content.
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

(defmethod pane-flush ((pane function-pane) grid)
  "Call the render function to draw pane content."
  (let ((render-fn (function-pane-render-fn pane)))
    (when render-fn
      (funcall render-fn pane grid)))
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

(defmethod pane-resize ((pane function-pane) new-width new-height)
  "Update dimensions and mark dirty."
  (setf (pane-width pane) new-width
        (pane-height pane) new-height
        (function-pane-dirty pane) t))

;;; --------------------------------------------------------------------------
;;; Utility for render functions
;;; --------------------------------------------------------------------------

(defun write-pane-string (pane grid col row string &key (swatch 0))
  "Write STRING into the pane's grid region at relative (COL, ROW).
   COL and ROW are relative to the pane's origin.
   SWATCH is the swatch index to use."
  (let ((grid-col (+ (pane-col pane) col))
        (grid-row (+ (pane-row pane) row))
        (max-col (+ (pane-col pane) (pane-width pane))))
    (loop :for char :across string
          :for c :from grid-col :below max-col
          :do (pcf-gl/grid:set-simple-cell grid c grid-row
                                            (char-code char) swatch))))

(defun clear-pane-region (pane grid &key (glyph 32) (swatch 0))
  "Clear the entire pane region with GLYPH and SWATCH."
  (loop :for row :from (pane-row pane) :below (+ (pane-row pane) (pane-height pane))
        :do (loop :for col :from (pane-col pane) :below (+ (pane-col pane) (pane-width pane))
                  :do (pcf-gl/grid:set-simple-cell grid col row glyph swatch))))
