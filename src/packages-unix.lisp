
  ;; (:shadowing-import-from #:cl-vt #:vt-parser-params-list 
  ;;                         #:vt-parser-get-param #:vt-parser-intermediate-chars-list)

;;; ---------------------------------------------------------------------------
;;; Unix Backend (Phase 3)
;;; ---------------------------------------------------------------------------

(defpackage #:pcf-gl/pty
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

(defpackage #:pcf-gl/vt-handler
  (:use #:cl #:pcf-gl/model)
  (:shadowing-import-from #:cl-vt #:vt-parser-params-list 
                          #:vt-parser-get-param #:vt-parser-intermediate-chars-list)
  (:export #:make-vt-handler
           #:vt-handler
           #:vt-handler-screen
           #:vt-handler-atlas
           #:vt-handler-parser
           #:vt-handler-callback
           #:process-output
           ;; Debug
           #:*debug-vt*))

(defpackage #:pcf-gl/unix-term
  (:use #:cl #:pcf-gl/pcf #:pcf-gl/atlas #:pcf-gl/grid
        #:pcf-gl/renderer #:pcf-gl/model #:pcf-gl/pty #:pcf-gl/vt-handler)
  (:export #:run-terminal
           #:unix-terminal
           #:terminal-screen
           #:terminal-pty))
