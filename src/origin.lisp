(in-package #:lexter/origin)

(defun define-terminal (name command &rest args
                        &key (restart-policy :transient)
                          (max-restarts 5)
                          (description nil)
                        &allow-other-keys)
  "Register a Lexter terminal as an Origin-managed process.
NAME is the Origin process name (symbol or string).
COMMAND is the shell command to run (e.g. \"/bin/bash\").
Remaining keyword arguments are passed to LEXTER/UNIX-TERM:RUN-TERMINAL.
Origin-specific keywords:
  :RESTART-POLICY  - :ALWAYS, :NEVER, or :TRANSIENT (default :TRANSIENT)
  :MAX-RESTARTS    - integer (default 5)
  :DESCRIPTION     - string (default auto-generated)
Example:
  (lexter/origin:define-terminal :bash \"/bin/bash\"
    :cols 80 :rows 24
    :font-path \"/path/to/terminus-18n.pcf\")
  (origin:start :bash)"
  (let ((stop-flag (list t))
        (lexter-args (alexandria:remove-from-plist
                      args :restart-policy :max-restarts :description)))
    (origin:define-process name
      :entry-point (lambda (&rest entry-args)
                     (setf (car stop-flag) t)
                     (apply #'lexter/unix-term:run-terminal entry-args))
      :entry-args (list* command :stop-flag stop-flag lexter-args)
      :stop-function (lambda () (setf (car stop-flag) nil))
      :restart-policy restart-policy
      :max-restarts max-restarts
      :description (or description
                       (format nil "Lexter terminal: ~A" command)))))
