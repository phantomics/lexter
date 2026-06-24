;;;; Unit tests for mouse reporting (xterm modes 1000/1002/1003/1006) and the
;;;; compositor's pixel->cell / pane-content-cell routing math.
;;;;
;;;; These are pure (no GL, no display): the encoders are pure functions and the
;;;; routing helpers operate on plain structs/objects. End-to-end event-injection
;;;; testing is deferred until a synthetic-input harness exists.

(in-package #:lexter/panes)

(defvar *tests-run* 0)
(defvar *tests-failed* 0)

(defmacro check (form &optional (label ""))
  `(progn
     (incf *tests-run*)
     (handler-case
         (unless ,form
           (incf *tests-failed*)
           (format t "~&FAIL [~a]: ~s~%" ,label ',form))
       (error (e)
         (incf *tests-failed*)
         (format t "~&ERROR [~a]: ~s -> ~a~%" ,label ',form e)))))

(defun s->b (s)
  "ASCII string -> (unsigned-byte 8) vector."
  (map '(vector (unsigned-byte 8)) #'char-code s))

(defun esc (rest)
  "Build an expected byte vector: ESC followed by the ASCII chars of REST."
  (s->b (concatenate 'string (string (code-char 27)) rest)))

(defun make-test-handler (&key (tracking :normal) (encoding :sgr))
  (let ((h (lexter/vt-handler::%make-vt-handler)))
    (setf (lexter/vt-handler:vt-handler-mouse-tracking h) tracking
          (lexter/vt-handler:vt-handler-mouse-encoding h) encoding)
    h))

;;; --------------------------------------------------------------------------
;;; Pure SGR (1006) encoder
;;; --------------------------------------------------------------------------

(defun test-sgr-encoder ()
  ;; left press at origin: cb=0, 1-based coords
  (check (equalp (lexter/vt-handler:encode-mouse-sgr 0 0 0 t) (esc "[<0;1;1M")) "sgr-press-origin")
  ;; release uses lowercase m
  (check (equalp (lexter/vt-handler:encode-mouse-sgr 0 0 0 nil) (esc "[<0;1;1m")) "sgr-release")
  ;; coords are 1-based off the 0-based input
  (check (equalp (lexter/vt-handler:encode-mouse-sgr 2 9 4 t) (esc "[<2;10;5M")) "sgr-coords")
  ;; large coordinates have no cap
  (check (equalp (lexter/vt-handler:encode-mouse-sgr 0 999 0 t) (esc "[<0;1000;1M")) "sgr-no-cap"))

;;; --------------------------------------------------------------------------
;;; Pure X10 encoder
;;; --------------------------------------------------------------------------

(defun test-x10-encoder ()
  ;; CSI M (32+cb)(33+col)(33+row)
  (check (equalp (lexter/vt-handler:encode-mouse-x10 0 0 0)
                 (coerce #(27 91 77 32 33 33) '(vector (unsigned-byte 8)))) "x10-origin")
  (check (equalp (lexter/vt-handler:encode-mouse-x10 2 3 4)
                 (coerce #(27 91 77 34 36 37) '(vector (unsigned-byte 8)))) "x10-coords")
  ;; beyond the 223-cell limit the encoding cannot represent the point
  (check (null (lexter/vt-handler:encode-mouse-x10 0 300 0)) "x10-col-cap")
  (check (null (lexter/vt-handler:encode-mouse-x10 0 0 300)) "x10-row-cap"))

;;; --------------------------------------------------------------------------
;;; mouse-report-bytes gating by tracking level + encoding
;;; --------------------------------------------------------------------------

(defun test-report-gating ()
  ;; tracking off -> nothing
  (let ((h (make-test-handler :tracking nil)))
    (check (null (lexter/vt-handler:mouse-report-bytes h 0 0 0 :press nil)) "off-no-report"))
  ;; :normal reports press/release, never motion
  (let ((h (make-test-handler :tracking :normal :encoding :sgr)))
    (check (equalp (lexter/vt-handler:mouse-report-bytes h 3 4 0 :press nil)
                   (esc "[<0;4;5M")) "normal-press")
    (check (equalp (lexter/vt-handler:mouse-report-bytes h 3 4 0 :release nil)
                   (esc "[<0;4;5m")) "normal-release")
    (check (null (lexter/vt-handler:mouse-report-bytes h 3 4 0 :press nil :motion t))
           "normal-no-motion"))
  ;; modifier bits: shift=4
  (let ((h (make-test-handler :tracking :normal :encoding :sgr)))
    (check (equalp (lexter/vt-handler:mouse-report-bytes h 0 0 0 :press '(:shift))
                   (esc "[<4;1;1M")) "shift-bit")
    (check (equalp (lexter/vt-handler:mouse-report-bytes h 0 0 0 :press '(:control))
                   (esc "[<16;1;1M")) "control-bit"))
  ;; :button reports motion only while a button is held (button /= 3)
  (let ((h (make-test-handler :tracking :button :encoding :sgr)))
    (check (equalp (lexter/vt-handler:mouse-report-bytes h 0 0 0 :press nil :motion t)
                   (esc "[<32;1;1M")) "button-drag")           ; 0|32
    (check (null (lexter/vt-handler:mouse-report-bytes h 0 0 3 :press nil :motion t))
           "button-no-bare-motion"))
  ;; :any reports bare motion (button 3 | motion 32 = 35)
  (let ((h (make-test-handler :tracking :any :encoding :sgr)))
    (check (equalp (lexter/vt-handler:mouse-report-bytes h 0 0 3 :press nil :motion t)
                   (esc "[<35;1;1M")) "any-bare-motion"))
  ;; wheel up = button 64
  (let ((h (make-test-handler :tracking :normal :encoding :sgr)))
    (check (equalp (lexter/vt-handler:mouse-report-bytes h 0 0 64 :press nil)
                   (esc "[<64;1;1M")) "wheel-up"))
  ;; X10 encoding: release collapses to ambiguous button 3
  (let ((h (make-test-handler :tracking :normal :encoding :x10)))
    (check (equalp (lexter/vt-handler:mouse-report-bytes h 0 0 0 :release nil)
                   (coerce #(27 91 77 35 33 33) '(vector (unsigned-byte 8))))
           "x10-release-button3")))

;;; --------------------------------------------------------------------------
;;; GLFW->xterm button mapping
;;; --------------------------------------------------------------------------

(defun test-button-mapping ()
  (check (= (%glfw-button->xterm :left) 0) "map-left")
  (check (= (%glfw-button->xterm :right) 2) "map-right")
  (check (= (%glfw-button->xterm :3) 1) "map-middle")   ; GLFW value 2 = middle
  (check (= (%glfw-button->xterm :1) 0) "map-1")
  (check (= (%glfw-button->xterm :2) 2) "map-2")
  (check (null (%glfw-button->xterm :nonexistent)) "map-unknown"))

;;; --------------------------------------------------------------------------
;;; Compositor pixel->cell and pane-content-cell routing math
;;; --------------------------------------------------------------------------

(defun test-routing-math ()
  (let ((comp (make-compositor :cols 80 :rows 24 :cell-w 10 :cell-h 20 :pixel-scale 1)))
    (multiple-value-bind (col row) (compositor-pixel->cell comp 25.0d0 45.0d0)
      (check (and (= col 2) (= row 2)) "pixel->cell"))
    ;; clamp beyond grid
    (multiple-value-bind (col row) (compositor-pixel->cell comp 100000.0d0 100000.0d0)
      (check (and (= col 79) (= row 23)) "pixel->cell-clamp"))
    ;; pixel-scale doubles the cell size
    (let ((comp2 (make-compositor :cols 80 :rows 24 :cell-w 10 :cell-h 20 :pixel-scale 2)))
      (multiple-value-bind (col row) (compositor-pixel->cell comp2 25.0d0 45.0d0)
        (check (and (= col 1) (= row 1)) "pixel->cell-scale"))))
  ;; pane content-space translation (no chrome: content-row = pane-row)
  (let ((pane (make-instance 'pane :col 5 :row 3 :width 20 :height 10)))
    (multiple-value-bind (c r inside) (pane-content-cell pane 7 5)
      (check (and (= c 2) (= r 2) inside) "content-inside"))
    (multiple-value-bind (c r inside) (pane-content-cell pane 5 3)
      (check (and (= c 0) (= r 0) inside) "content-topleft"))
    (multiple-value-bind (c r inside) (pane-content-cell pane 4 3)
      (declare (ignore c r))
      (check (null inside) "content-left-of"))
    (multiple-value-bind (c r inside) (pane-content-cell pane 25 3)
      (declare (ignore c r))
      (check (null inside) "content-right-of"))))

;;; --------------------------------------------------------------------------
;;; Runner
;;; --------------------------------------------------------------------------

(defun run-all-tests ()
  (setf *tests-run* 0 *tests-failed* 0)
  (test-sgr-encoder)
  (test-x10-encoder)
  (test-report-gating)
  (test-button-mapping)
  (test-routing-math)
  (format t "~&~%Mouse tests: ~d run, ~d failed.~%" *tests-run* *tests-failed*)
  (when (plusp *tests-failed*)
    (error "~d mouse test(s) failed." *tests-failed*))
  t)
