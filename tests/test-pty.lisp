;;;; tests/test-pty.lisp — Terminals without a PTY, and a PTY after its child.
;;;;
;;;; The pty suite is pure: a standalone terminal made with :no-pty and never
;;;; given a window; its input is routed as the compositor routes a GLFW
;;;; callback's. The pty-slow suite forks /bin/true on a real PTY, and is
;;;; excluded by :skip-slow. The PTY tests of LEXTER-O35 fail until the
;;;; terminal-fixes plan separates the child's life from the descriptor's
;;;; (LEXTER-D74).

(in-package #:lexter-tests)

(defun make-headless-terminal ()
  "A standalone terminal with no PTY and no window, as the test rig makes."
  (lexter/unix-term:make-terminal nil :no-pty t :visible nil))

;;; ------------------------------------------------------------
;;; Input with no backend  (LEXTER-O35)
;;; ------------------------------------------------------------

(in-suite pty)

(def-test key-on-headless-terminal-is-ignored ()
  "LEXTER-O35: a key pressed on a terminal with no PTY has nowhere to go, and
is ignored without error."
  (let ((term (make-headless-terminal)))
    (finishes (lexter/panes::handle-compositor-key
               (lexter/unix-term:unix-terminal-compositor term) :a 0 :press nil))))

(def-test character-on-headless-terminal-is-ignored ()
  "LEXTER-O35: a character typed on a terminal with no PTY has nowhere to go,
and is ignored without error."
  (let ((term (make-headless-terminal)))
    (finishes (lexter/panes::handle-compositor-char
               (lexter/unix-term:unix-terminal-compositor term) 65))))

;;; ------------------------------------------------------------
;;; The descriptor and the child  (LEXTER-O35)
;;; ------------------------------------------------------------

(in-suite pty-slow)

(defmacro with-finished-child ((pty fd pid) &body body)
  "Run BODY with PTY bound to a PTY whose child, /bin/true, has exited and
whose end of file has been read, FD to its master descriptor, and PID to the
child's process id."
  (let ((buffer (gensym "BUFFER")))
    `(let* ((,pty (lexter/pty:pty-fork "/bin/true"))
            (,fd (lexter/pty:pty-master-fd ,pty))
            (,pid (lexter/pty:pty-child-pid ,pty))
            (,buffer (make-array 256 :element-type '(unsigned-byte 8))))
       (declare (ignorable ,fd ,pid))
       (wait-for-predicate (lambda () (= -1 (lexter/pty:pty-read ,pty ,buffer)))
                           :timeout 5)
       ,@body)))

(def-test closing-a-finished-pty-closes-its-descriptor ()
  "LEXTER-O35: closing a PTY whose child has exited closes its master
descriptor, though reading end of file marked the child dead (LEXTER-D74)."
  (with-finished-child (pty fd pid)
    (lexter/pty:pty-close pty)
    (signals sb-posix:syscall-error
      (sb-posix:fcntl fd sb-posix:f-getfd))))

(def-test closing-a-finished-pty-reaps-its-child ()
  "LEXTER-O35: closing a PTY whose child has exited reaps the child, so that no
zombie process is left (LEXTER-D74)."
  (with-finished-child (pty fd pid)
    (lexter/pty:pty-close pty)
    (signals sb-posix:syscall-error
      (sb-posix:waitpid pid sb-posix:wnohang))))
