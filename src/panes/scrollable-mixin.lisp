;;;; Scrollable pane mixin: adds scroll bar support to any pane type.
;;;;
;;;; This mixin provides:
;;;; - A reserved column for the scroll bar
;;;; - Integration with the workspace decorator for drawing
;;;; - Mouse hit-testing hooks for future interactivity

(in-package #:lexter/panes)

;;; --------------------------------------------------------------------------
;;; Scrollable pane mixin class
;;; --------------------------------------------------------------------------

(defclass scrollable-pane ()
  ((scroll-bar-visible :initarg :scroll-bar-visible
                       :accessor scroll-bar-visible-p
                       :initform t
                       :type boolean
                       :documentation "Whether the scroll bar is drawn.")
   (scroll-bar-dragging :accessor scroll-bar-dragging-p
                        :initform nil
                        :type boolean
                        :documentation "T when user is dragging the thumb (future)."))
  (:documentation "Mixin that adds scroll bar support to a pane.
   The scroll bar occupies the rightmost column of the pane's allocated width.
   Content is rendered into (content-width) columns, leaving room for the bar.
   The actual scroll bar drawing is delegated to the workspace's decorator function."))

;;; --------------------------------------------------------------------------
;;; Content width
;;; --------------------------------------------------------------------------

(defmethod content-width ((pane scrollable-pane))
  "Return pane width minus scroll bar column when visible."
  (- (pane-width pane)
     (if (scroll-bar-visible-p pane) 1 0)))

;;; --------------------------------------------------------------------------
;;; Scroll bar geometry
;;; --------------------------------------------------------------------------

(defun scroll-bar-col (pane)
  "Return the grid column where the scroll bar is drawn."
  (+ (pane-col pane) (content-width pane)))

(defun scroll-bar-thumb-geometry (pane)
  "Calculate scroll bar thumb position and size.
   Returns (values thumb-row thumb-height) relative to pane-row,
   or NIL if no scroll state is available."
  (multiple-value-bind (total offset visible) (scroll-state pane)
    (when (and total visible (> total 0))
      (let* ((bar-height (pane-height pane))
             ;; Thumb height proportional to visible/total, minimum 1
             (thumb-h (max 1 (round (* bar-height (/ visible (max 1 total))))))
             ;; Maximum scroll offset
             (max-offset (max 0 (- total visible)))
             ;; Thumb position: 0 when at bottom (offset=0), top when at max
             (thumb-pos (if (zerop max-offset)
                            0
                            (round (* (- bar-height thumb-h)
                                       (/ offset max-offset))))))
        (values thumb-pos thumb-h)))))

;;; --------------------------------------------------------------------------
;;; Flush integration
;;; --------------------------------------------------------------------------

(defmethod pane-flush :around ((pane scrollable-pane) grid)
  "Flush content, then invoke decorator to draw scroll bar if visible."
  ;; Flush pane content (screen, function, etc.)
  (call-next-method)
  ;; Draw scroll bar via workspace decorator
  (when (scroll-bar-visible-p pane)
    (let ((ws (pane-workspace pane)))
      (when (and ws (workspace-decorator ws))
        (multiple-value-bind (total offset visible) (scroll-state pane)
          (funcall (workspace-decorator ws)
                   pane grid :scroll-bar
                   :col (scroll-bar-col pane)
                   :row (pane-row pane)
                   :height (pane-height pane)
                   :total-lines (or total 0)
                   :viewport-offset (or offset 0)
                   :visible-rows (or visible (pane-height pane))))))))

;;; --------------------------------------------------------------------------
;;; Resize handling
;;; --------------------------------------------------------------------------

(defmethod pane-resize :after ((pane scrollable-pane) new-width new-height)
  "After resize, content-width is automatically recalculated."
  (declare (ignore new-width new-height))
  ;; content-width method handles this dynamically; nothing to cache.
  nil)

;;; --------------------------------------------------------------------------
;;; Mouse hit-testing (future)
;;; --------------------------------------------------------------------------

(defgeneric scroll-bar-hit-test (pane grid-col grid-row)
  (:documentation "Test if a grid position hits the scroll bar.
   Returns :TRACK, :THUMB, or NIL."))

(defmethod scroll-bar-hit-test ((pane scrollable-pane) grid-col grid-row)
  "Default hit-test for scrollable panes."
  (unless (scroll-bar-visible-p pane)
    (return-from scroll-bar-hit-test nil))
  (let ((bar-col (scroll-bar-col pane))
        (bar-top (pane-row pane))
        (bar-bottom (+ (pane-row pane) (pane-height pane))))
    ;; Check if in scroll bar column
    (unless (= grid-col bar-col)
      (return-from scroll-bar-hit-test nil))
    ;; Check if within vertical bounds
    (unless (and (>= grid-row bar-top) (< grid-row bar-bottom))
      (return-from scroll-bar-hit-test nil))
    ;; Determine if on thumb or track
    (multiple-value-bind (thumb-row thumb-height) (scroll-bar-thumb-geometry pane)
      (if thumb-row
          (let ((rel-row (- grid-row bar-top)))
            (if (and (>= rel-row thumb-row)
                     (< rel-row (+ thumb-row thumb-height)))
                :thumb
                :track))
          :track))))
