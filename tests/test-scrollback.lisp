;;;; tests/test-scrollback.lisp — Viewing a pane's history.
;;;;
;;;; Pure: a terminal pane with no PTY, given a screen and a packed test atlas,
;;;; fed lines through its VT handler until some scroll into its history, and
;;;; flushed into a display grid in memory; no GL. They test the pane-profiles
;;;; plan's drawing of the history (LEXTER-DRAFT-pane-profiles-D5, -D7), which
;;;; repairs LEXTER-O30.

(in-package #:lexter-tests)
(in-suite scrollback)

(defclass chrome-terminal-pane (lexter/panes:chrome-pane lexter/panes:uterm-pane) ()
  (:documentation "A terminal pane with a scroll bar, as a decorated layout has."))

(defparameter *history-codepoints* '(#x20 #x41 #x42 #x43 #x44 #x45)
  "The space, A, B, C, D, and E: the characters of the history tests.")

(defmacro with-history ((pane grid &key (class ''lexter/panes:uterm-pane)
                                        (width 10) (height 3))
                        &body body)
  "Run BODY with PANE bound to a terminal pane of HEIGHT rows, inside a
workspace and compositor, which has printed the lines A to E, so that its
screen holds C, D, and E and its history B and then A; and GRID to a display
grid the pane's size."
  `(let* ((atlas (make-test-atlas
                  :fonts (list (make-test-font :narrow *history-codepoints* :wide '()))))
          (,pane (make-instance ,class :width ,width :height ,height))
          (workspace (make-instance 'lexter/panes:workspace :panes (list ,pane)))
          (,grid (make-test-grid :cols ,width :rows ,height)))
     (lexter/panes:make-paned-compositor :workspaces (list workspace))
     (lexter/panes:vt-pane-init-screen ,pane atlas)
     (lexter/vt-handler:process-output
      (lexter/panes:vt-pane-vt-handler ,pane)
      (octets "A" 13 10 "B" 13 10 "C" 13 10 "D" 13 10 "E"))
     (flet ((letter (codepoint) (glyph atlas codepoint)))
       (declare (ignorable #'letter))
       ,@body)))

(defun view-screen (pane)
  "The screen PANE shows."
  (lexter/vt-handler:vt-handler-screen (lexter/panes:vt-pane-vt-handler pane)))

(defun scroll-to (pane offset)
  "Set PANE's view OFFSET lines back into its history."
  (lexter/model:set-scrollback-viewport (view-screen pane) offset)
  (lexter/model:mark-screen-dirty (view-screen pane)))

(defun first-column (grid)
  "The glyphs in column 0 of GRID, top to bottom."
  (loop :for row :below (lexter/grid:display-grid-rows grid)
        :collect (grid-glyph grid 0 row)))

;;; ------------------------------------------------------------
;;; The flush of a scrolled-back view  (LEXTER-O30)
;;; ------------------------------------------------------------

(def-test live-view-shows-the-screen ()
  "With the view on the live screen, the grid shows the screen's rows."
  (with-history (pane grid)
    (lexter/panes:pane-flush pane grid)
    (assert-that (first-column grid)
                 (contains (letter #x43) (letter #x44) (letter #x45)))))

(def-test scrolled-back-view-shows-history-above-the-screen ()
  "LEXTER-O30: with the view N lines back, the grid shows the last N lines of
history above the top rows of the screen (LEXTER-DRAFT-pane-profiles-D5)."
  (with-history (pane grid)
    (scroll-to pane 1)
    (lexter/panes:pane-flush pane grid)
    (assert-that (first-column grid)
                 (contains (letter #x42) (letter #x43) (letter #x44)))
    (scroll-to pane 2)
    (lexter/panes:pane-flush pane grid)
    (assert-that (first-column grid)
                 (contains (letter #x41) (letter #x42) (letter #x43)))))

(def-test returning-to-the-live-view-repaints-the-screen ()
  "LEXTER-O30: when the view returns to the live screen, every row of the
screen is drawn again."
  (with-history (pane grid)
    (scroll-to pane 2)
    (lexter/panes:pane-flush pane grid)
    (scroll-to pane 0)
    (lexter/panes:pane-flush pane grid)
    (assert-that (first-column grid)
                 (contains (letter #x43) (letter #x44) (letter #x45)))))

(def-test scrolled-back-view-draws-no-cursor ()
  "LEXTER-O30: no cursor is drawn while the view is scrolled back: the cell at
the cursor's place in the grid keeps the colours of the line it shows."
  (with-history (pane grid)
    (lexter/model:set-cursor-visible (view-screen pane) t)
    (scroll-to pane 1)
    (lexter/panes:pane-flush pane grid)
    ;; The cursor is at row 2, column 1 of the screen; at offset 1 the grid's
    ;; row 2 shows the screen's row 1, the line D, whose cell 1 is blank, in
    ;; the screen's default swatch. A cursor would exchange the cell's slots,
    ;; making it layered (LEXTER-D101).
    (is (= (lexter/model:default-swatch (view-screen pane)) (grid-swatch grid 1 2)))
    (is-false (lexter/grid:cell-layered-p grid 1 2))))

(def-test short-history-line-is-padded ()
  "LEXTER-O30: a history line narrower than the pane, left by a resize, is
drawn padded with blanks: the atlas's empty glyph, at position 0."
  (with-history (pane grid :width 10)
    (lexter/panes:pane-resize pane 12 3)
    (let ((wide (make-test-grid :cols 12 :rows 3)))
      (scroll-to pane 1)
      (lexter/panes:pane-flush pane wide)
      (is (= (letter #x42) (grid-glyph wide 0 0)))
      (is (= lexter/atlas:+empty-glyph-position+ (grid-glyph wide 11 0))))))

;;; ------------------------------------------------------------
;;; The wheel  (LEXTER-O30, LEXTER-DRAFT-pane-profiles-D7)
;;; ------------------------------------------------------------

(def-test wheel-moves-the-view-by-the-lines-setting ()
  "A wheel notch on the primary screen moves the view back by the pane's
lines-per-notch setting, within the history, and a notch the other way moves
it forward."
  (with-history (pane grid)
    (setf (lexter/panes:pane-wheel-scroll-lines pane) 1)
    (lexter/panes:pane-handle-scroll pane 0 0 0 1 nil)
    (is (= 1 (lexter/model:scrollback-viewport-offset (view-screen pane))))
    (lexter/panes:pane-handle-scroll pane 0 0 0 -1 nil)
    (is (= 0 (lexter/model:scrollback-viewport-offset (view-screen pane))))
    (setf (lexter/panes:pane-wheel-scroll-lines pane) 3)
    (lexter/panes:pane-handle-scroll pane 0 0 0 1 nil)
    (is (= 2 (lexter/model:scrollback-viewport-offset (view-screen pane))))))

(def-test wheel-asks-for-a-redraw ()
  "LEXTER-O30: moving the view marks the pane for redrawing, so that the
compositor flushes it."
  (with-history (pane grid)
    (lexter/panes:pane-flush pane grid)
    (is-false (lexter/panes:pane-dirty-p pane))
    (lexter/panes:pane-handle-scroll pane 0 0 0 1 nil)
    (is-true (lexter/panes:pane-dirty-p pane))))

;;; ------------------------------------------------------------
;;; The scroll-bar thumb  (LEXTER-O30)
;;; ------------------------------------------------------------

(def-test thumb-sits-at-the-bottom-for-the-live-view ()
  "LEXTER-O30: on the live screen the scroll-bar thumb sits at the bottom of
the bar."
  (with-history (pane grid :class 'chrome-terminal-pane :width 11)
    (multiple-value-bind (row height) (lexter/panes:scroll-bar-thumb-geometry pane)
      (is (= (- 3 height) row)))))

(def-test thumb-rises-to-the-top-for-the-oldest-history ()
  "LEXTER-O30: scrolled back to the oldest history, the thumb sits at the top
of the bar."
  (with-history (pane grid :class 'chrome-terminal-pane :width 11)
    (scroll-to pane 2)
    (is (= 0 (lexter/panes:scroll-bar-thumb-geometry pane)))))
