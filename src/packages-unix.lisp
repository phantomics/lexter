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
           #:vt-handler-recording
           #:process-output
           ;; Raw-input recording (test rig)
           #:start-recording
           #:stop-recording
           #:recording-active-p
           ;; Mouse reporting (xterm modes 1000/1002/1003/1006)
           #:vt-handler-mouse-tracking
           #:vt-handler-mouse-encoding
           #:mouse-report-bytes
           #:encode-mouse-sgr
           #:encode-mouse-x10
           ;; Debug
           #:*debug-vt*))
