;;;; origin-gui.lisp
;;;;
;;;; Lexter/Origin bridge: main-thread GUI dispatcher (Approach B).
;;;;
;;;; Owns GLFW initialization/termination, drives Lexter GUI objects via
;;;; the lexter/gui protocol (gui-initialize / gui-tick / gui-destroy),
;;;; and registers a cooperative executor with Origin so that cooperative
;;;; processes show up in origin:status / info / logs and are supervised
;;;; (crash detection, restart policies, backoff) like any other process.
;;;;
;;;; Usage (deployed-image model):
;;;;
;;;;   ;; Define terminals (from any thread, before or after the loop starts):
;;;;   (lexter/origin:define-terminal :bash "/bin/bash" :cols 80 :rows 24)
;;;;   (origin:start-supervisor)
;;;;
;;;;   ;; Main thread -- blocks, owns GLFW for the image's lifetime:
;;;;   (lexter/origin:run-main-loop :autostart '(:bash))
;;;;
;;;;   ;; Live coding / control via Swank on a background thread:
;;;;   ;;   (origin:status)  (origin:stop :bash)  (origin:start :bash)
;;;;   ;;   (lexter/origin:stop-main-loop)

(in-package #:lexter/origin)

;;; -----------------------------------------------------------------------
;;; State (global -- visible to all threads)
;;; -----------------------------------------------------------------------

(defvar *gui-mailbox* nil
  "The executor mailbox, created at RUN-MAIN-LOOP start.")

(defvar *gui-running* (list nil)
  "Cons cell whose CAR controls the main loop.  T = running, NIL = exit.")

(defvar *gui-objects* nil
  "Alist of (canonical-name . gui-object) for live cooperative terminals.
Only accessed from the main thread.")

(defvar *terminal-specs* (make-hash-table :test 'equal)
  "Canonical-name -> plist of constructor args for (re)building terminals.
Written by DEFINE-TERMINAL, read by the start hook on restart.")

;;; -----------------------------------------------------------------------
;;; Spec helpers
;;; -----------------------------------------------------------------------

(defun %canonical-name (name)
  "Mirror of Origin's internal canonicalization."
  (etypecase name
    (string name)
    (symbol (string-downcase (symbol-name name)))))

;;; -----------------------------------------------------------------------
;;; Executor hooks (called by Origin's cooperative machinery)
;;; -----------------------------------------------------------------------

(defun %gui-start (process)
  "Cooperative start hook: construct and initialize a Lexter terminal on
the main thread, register its liveness function on PROCESS."
  (origin:run-on-executor *gui-mailbox*
    (lambda ()
      (let* ((name (origin:process-name process))
             (spec (gethash name *terminal-specs*)))
        (unless spec
          (error 'origin:origin-error
                 :message (format nil "No terminal spec for ~S" name)))
        (let ((obj (apply #'lexter/unix-term:make-terminal
                          (getf spec :command)
                          (alexandria:remove-from-plist spec :command))))
          (lexter/gui:gui-initialize obj)
          ;; Register in the live-objects list (replace if already present).
          (let ((existing (assoc name *gui-objects* :test #'equal)))
            (if existing
                (setf (cdr existing) obj)
                (push (cons name obj) *gui-objects*)))
          ;; Set the liveness predicate Origin's supervisor will poll.
          (setf (origin:process-liveness-fn process)
                (lambda () (lexter/gui:gui-alive-p obj))))))))

(defun %gui-stop (process &key (timeout 5))
  "Cooperative stop hook: destroy the terminal's window on the main thread."
  (declare (ignore timeout))
  (origin:run-on-executor *gui-mailbox*
    (lambda ()
      (let ((cell (assoc (origin:process-name process)
                         *gui-objects* :test #'equal)))
        (when cell
          (lexter/gui:gui-destroy (cdr cell))
          (setf *gui-objects* (remove cell *gui-objects*)))))))

;;; -----------------------------------------------------------------------
;;; Tick wrapper with crash capture
;;; -----------------------------------------------------------------------

(defun %safe-tick (name obj)
  "Tick OBJ, capturing crashes into the Origin process's crash-info.
Returns T if alive, NIL if dead (clean exit or crash)."
  (handler-case
      (lexter/gui:gui-tick obj)
    (serious-condition (c)
      ;; Record crash info on the Origin process so the supervisor sees it.
      (let ((process (origin:find-process name :error-p nil)))
        (when process
          (setf (origin:process-crash-info process)
                (list :condition (princ-to-string c)
                      :type (type-of c)
                      :time (get-universal-time)))))
      nil)))

;;; -----------------------------------------------------------------------
;;; Main-thread loop
;;; -----------------------------------------------------------------------

(defun run-main-loop (&key autostart (poll-interval 0.001))
  "Block the calling thread as the cooperative GUI dispatcher.

Owns GLFW initialization/termination for the image's lifetime.
Registers the cooperative executor with Origin, drains the command
mailbox each iteration, polls GLFW events, ticks all live GUI objects,
and reaps dead ones (whose status the supervisor then picks up).

AUTOSTART is a list of process names to (ORIGIN:START ...) once the
loop is up.  POLL-INTERVAL is the sleep between iterations (default 1ms).

Call STOP-MAIN-LOOP from any thread to exit."
  (setf *gui-mailbox* (origin:make-mailbox
                        :executor-thread sb-thread:*current-thread*)
        (car *gui-running*) t
        *gui-objects* nil)
  (glfw:initialize)
  (origin:register-cooperative-executor
   :start #'%gui-start
   :stop #'%gui-stop
   :mailbox *gui-mailbox*)
  (unwind-protect
       (progn
         ;; Autostart named processes once the executor is registered.
         (dolist (name (mapcar #'%canonical-name
                               (if (listp autostart) autostart (list autostart))))
           (handler-case (origin:start name)
             (error (c)
               (format *error-output* "~&Autostart ~A failed: ~A~%" name c))))
         ;; Main loop
         (loop :while (car *gui-running*)
               :do
               ;; 1. Drain command mailbox (start/stop requests from other threads)
               (origin:execute-pending *gui-mailbox*)
               ;; 2. Poll GLFW events (one call for ALL windows)
               (glfw:poll-events)
               ;; 3. Tick each live GUI object
               (setf *gui-objects*
                     (loop :for (name . obj) :in *gui-objects*
                           :if (%safe-tick name obj)
                             :collect (cons name obj)
                           :else
                             :do (handler-case
                                     (lexter/gui:gui-destroy obj)
                                   (error () nil))))
               ;; 4. Yield
               (sleep poll-interval)))
    ;; Cleanup: destroy any survivors, unregister executor, terminate GLFW.
    (dolist (cell *gui-objects*)
      (handler-case (lexter/gui:gui-destroy (cdr cell))
        (error () nil)))
    (setf *gui-objects* nil)
    (origin:unregister-cooperative-executor)
    (setf *gui-mailbox* nil)
    (glfw:terminate)))

(defun stop-main-loop ()
  "Request the main loop to exit.  Safe to call from any thread."
  (setf (car *gui-running*) nil))

;;; -----------------------------------------------------------------------
;;; Terminal registration (Approach B -- replaces Approach A's define-terminal)
;;; -----------------------------------------------------------------------

(defun define-terminal (name command &rest args
                        &key (restart-policy :transient)
                             (max-restarts 5)
                             (description nil)
                        &allow-other-keys)
  "Register a Lexter terminal as an Origin-managed cooperative process.

NAME is the Origin process name (symbol or string).
COMMAND is the shell command to run (e.g. \"/bin/bash\").
Remaining keyword arguments are passed to MAKE-TERMINAL.

The terminal is registered but not started.  Call (ORIGIN:START name)
after RUN-MAIN-LOOP is running, or use RUN-MAIN-LOOP's :AUTOSTART.

Origin-specific keywords:
  :RESTART-POLICY  - :ALWAYS, :NEVER, or :TRANSIENT (default :TRANSIENT)
  :MAX-RESTARTS    - integer (default 5)
  :DESCRIPTION     - string (default auto-generated)

Example:
  (lexter/origin:define-terminal :bash \"/bin/bash\"
    :cols 80 :rows 24
    :font-path \"/path/to/terminus-18n.pcf\")
  (origin:start-supervisor)
  (lexter/origin:run-main-loop :autostart '(:bash))"
  (let* ((canonical (%canonical-name name))
         (lexter-args (alexandria:remove-from-plist
                       args :restart-policy :max-restarts :description)))
    ;; Store the spec so the start hook (and restarts) can rebuild from it.
    (setf (gethash canonical *terminal-specs*)
          (list* :command command lexter-args))
    ;; Register as a cooperative process (no entry-point / stop-function;
    ;; the executor hooks handle everything).
    (origin:define-process name
      :execution-mode :cooperative
      :restart-policy restart-policy
      :max-restarts max-restarts
      :description (or description
                       (format nil "Lexter terminal: ~A" command)))))
