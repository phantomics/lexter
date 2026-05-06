;;;; Chrome pane mixin: unified support for scroll bars, headers, and footers.
;;;;
;;;; This mixin provides:
;;;; - Reserved columns for scroll bars (right side)
;;;; - Reserved rows for headers (top) and footers (bottom)
;;;; - Integration with the workspace decorator for drawing all chrome
;;;; - Mouse hit-testing hooks for future interactivity
;;;;
;;;; The decorator inspects pane state (including input-redirect) to decide
;;;; what to draw. When input-redirect is active, the decorator can draw
;;;; modal dialog visuals on top of the pane content.

(in-package #:lexter/panes)

;;; --------------------------------------------------------------------------
;;; Chrome pane mixin class
;;; --------------------------------------------------------------------------

(defclass chrome-pane ()
  ((scroll-bar-visible :initarg :scroll-bar-visible
                       :accessor scroll-bar-visible-p
                       :initform t
                       :type boolean
                       :documentation "Whether the scroll bar is drawn.")
   (header-height      :initarg :header-height
                       :accessor chrome-header-height
                       :initform 0
                       :type fixnum
                       :documentation "Rows reserved for header (0 = none).")
   (footer-height      :initarg :footer-height
                       :accessor chrome-footer-height
                       :initform 0
                       :type fixnum
                       :documentation "Rows reserved for footer (0 = none).")
   (header-data        :initarg :header-data
                       :accessor chrome-header-data
                       :initform nil
                       :documentation "Arbitrary data for decorator to render in header.")
   (footer-data        :initarg :footer-data
                       :accessor chrome-footer-data
                       :initform nil
                       :documentation "Arbitrary data for decorator to render in footer.")
   (scroll-bar-dragging :accessor scroll-bar-dragging-p
                        :initform nil
                        :type boolean
                        :documentation "T when user is dragging the thumb (future)."))
  (:documentation "Mixin that adds chrome (scroll bar, header, footer) to a pane.
   The scroll bar occupies the rightmost column of the pane's allocated width.
   The header occupies the topmost rows, footer the bottommost rows.
   Content is rendered into the remaining area: (content-width) x (content-height)
   starting at grid position (pane-col, content-row).
   The actual chrome drawing is delegated to the workspace's decorator function."))

;;; --------------------------------------------------------------------------
;;; Content dimensions
;;; --------------------------------------------------------------------------

(defmethod content-width ((pane chrome-pane))
  "Return pane width minus scroll bar column when visible."
  (- (pane-width pane)
     (if (scroll-bar-visible-p pane) 1 0)))

(defmethod content-height ((pane chrome-pane))
  "Return pane height minus header and footer rows."
  (- (pane-height pane)
     (chrome-header-height pane)
     (chrome-footer-height pane)))

(defmethod content-row ((pane chrome-pane))
  "Return grid row where content starts (after header)."
  (+ (pane-row pane) (chrome-header-height pane)))

;;; --------------------------------------------------------------------------
;;; Scroll bar geometry
;;; --------------------------------------------------------------------------

(defun scroll-bar-col (pane)
  "Return the grid column where the scroll bar is drawn."
  (+ (pane-col pane) (content-width pane)))

(defun scroll-bar-thumb-geometry (pane)
  "Calculate scroll bar thumb position and size.
   Returns (values thumb-row thumb-height) relative to content-row,
   or NIL if no scroll state is available."
  (multiple-value-bind (total offset visible) (scroll-state pane)
    (when (and total visible (> total 0))
      (let* ((bar-height (content-height pane))
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

(defmethod pane-flush :around ((pane chrome-pane) grid)
  "Flush content, then invoke decorator for all active chrome elements."
  ;; Flush pane content (screen, function, etc.)
  (call-next-method)
  ;; Draw chrome via workspace decorator
  (let ((ws (pane-workspace pane)))
    (when (and ws (workspace-decorator ws))
      (let ((decorator (workspace-decorator ws)))
        ;; Header
        (when (> (chrome-header-height pane) 0)
          (funcall decorator pane grid :header
                   :col (pane-col pane)
                   :row (pane-row pane)
                   :width (pane-width pane)
                   :height (chrome-header-height pane)
                   :data (chrome-header-data pane)))
        ;; Footer
        (when (> (chrome-footer-height pane) 0)
          (funcall decorator pane grid :footer
                   :col (pane-col pane)
                   :row (+ (pane-row pane)
                           (pane-height pane)
                           (- (chrome-footer-height pane)))
                   :width (pane-width pane)
                   :height (chrome-footer-height pane)
                   :data (chrome-footer-data pane)))
        ;; Scroll bar (spans content area, not header/footer)
        (when (scroll-bar-visible-p pane)
          (multiple-value-bind (total offset visible) (scroll-state pane)
            (funcall decorator pane grid :scroll-bar
                     :col (scroll-bar-col pane)
                     :row (content-row pane)
                     :height (content-height pane)
                     :total-lines (or total 0)
                     :viewport-offset (or offset 0)
                     :visible-rows (or visible (content-height pane)))))))))

;;; --------------------------------------------------------------------------
;;; Resize handling
;;; --------------------------------------------------------------------------

(defmethod pane-resize :after ((pane chrome-pane) new-width new-height)
  "After resize, content dimensions are automatically recalculated."
  (declare (ignore new-width new-height))
  ;; content-width/height/row methods handle this dynamically; nothing to cache.
  nil)

;;; --------------------------------------------------------------------------
;;; Mouse hit-testing (future)
;;; --------------------------------------------------------------------------

(defgeneric scroll-bar-hit-test (pane grid-col grid-row)
  (:documentation "Test if a grid position hits the scroll bar.
   Returns :TRACK, :THUMB, or NIL."))

(defmethod scroll-bar-hit-test ((pane chrome-pane) grid-col grid-row)
  "Default hit-test for chrome panes."
  (unless (scroll-bar-visible-p pane)
    (return-from scroll-bar-hit-test nil))
  (let ((bar-col (scroll-bar-col pane))
        (bar-top (content-row pane))
        (bar-bottom (+ (content-row pane) (content-height pane))))
    ;; Check if in scroll bar column
    (unless (= grid-col bar-col)
      (return-from scroll-bar-hit-test nil))
    ;; Check if within vertical bounds (content area, not header/footer)
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
