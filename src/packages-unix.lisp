;;; ---------------------------------------------------------------------------
;;; Unix Backend (Phase 3)
;;; ---------------------------------------------------------------------------

(defpackage #:lexter/pty
  (:use #:cl)
  (:export ;; PTY creation
           #:pty-open
           #:pty-fork
           #:pty-close
           ;; PTY I/O
           #:pty-read
           #:pty-write
           #:pty-write-string
           ;; PTY control
           #:pty-set-size
           #:pty-set-nonblocking
           ;; Polling
           #:pty-poll
           #:pty-check-child
           ;; Accessors
           #:pty
           #:pty-master-fd
           #:pty-slave-name
           #:pty-child-pid
           #:pty-alive-p))

(defpackage #:lexter/vt-handler
  (:use #:cl #:lexter/model)
  (:shadowing-import-from #:cl-vt #:vt-parser-params-list 
                          #:vt-parser-get-param #:vt-parser-intermediate-chars-list)
  (:export #:make-vt-handler
           #:vt-handler
           #:vt-handler-screen
           #:vt-handler-atlas
           #:vt-handler-parser
           #:vt-handler-callback
           #:vt-handler-encoding
           #:vt-handler-bold-as-bright
           #:vt-handler-cp437-table
           #:vt-handler-in-alt-screen
           #:vt-handler-resize-all
           #:process-output
           ;; Debug
           #:*debug-vt*))

(defpackage #:lexter/unix-term
  (:use #:cl #:lexter/pcf #:lexter/atlas #:lexter/grid
        #:lexter/renderer #:lexter/model #:lexter/pty #:lexter/vt-handler
        #:lexter/gui)
  (:export #:run-terminal
           #:make-terminal
           #:unix-terminal
           #:unix-terminal-window
           #:terminal-screen
           #:terminal-pty
           ;; GUI protocol (re-exported for convenience)
           #:gui-initialize
           #:gui-tick
           #:gui-destroy
           #:gui-window
           #:gui-alive-p
           #:run-gui-loop))
