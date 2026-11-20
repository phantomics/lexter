;;; ---------------------------------------------------------------------------
;;; The standalone Unix terminal: a compositor holding one Unix terminal pane,
;;; behind the API the test rig and the Origin integration use (LEXTER-D67).
;;; ---------------------------------------------------------------------------

(defpackage #:lexter/unix-term
  (:use #:cl #:lexter/gui)
  (:export #:run-terminal
           #:make-terminal
           #:terminal-capture
           #:terminal-compose
           #:terminal-initialize-windowless
           #:terminal-start-recording
           #:terminal-stop-recording
           #:terminal-reset
           #:terminal-config-plist
           #:unix-terminal
           #:unix-terminal-compositor
           #:unix-terminal-pane
           #:unix-terminal-window
           #:unix-terminal-renderer
           #:unix-terminal-vt-handler
           #:unix-terminal-command
           #:unix-terminal-cols
           #:unix-terminal-rows
           #:unix-terminal-pixel-scale
           #:unix-terminal-title
           #:terminal-screen
           #:terminal-pty
           ;; GUI protocol (re-exported for convenience)
           #:gui-initialize
           #:gui-tick
           #:gui-destroy
           #:gui-window
           #:gui-alive-p
           #:run-gui-loop))
