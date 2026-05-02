;;;; Pane system package definition

(defpackage #:pcf-gl/panes
  (:use #:cl)
  (:export
   ;; Protocol - base class
   #:pane
   #:pane-col
   #:pane-row
   #:pane-width
   #:pane-height
   #:pane-focusable
   ;; Protocol - generic functions
   #:pane-flush
   #:pane-handle-key
   #:pane-handle-char
   #:pane-process-output
   #:pane-resize
   #:pane-dirty-p
   #:pane-destroy
   ;; Terminal pane
   #:terminal-pane
   #:terminal-pane-pty
   #:terminal-pane-screen
   #:terminal-pane-vt-handler
   #:make-terminal-pane
   ;; Function pane
   #:function-pane
   #:function-pane-render-fn
   #:function-pane-state
   #:function-pane-dirty
   #:make-function-pane
   ;; Workspace
   #:workspace
   #:workspace-name
   #:workspace-panes
   #:workspace-decorations
   #:workspace-focus-index
   #:focused-pane
   #:focus-next
   #:focus-prev
   #:flush-workspace
   ;; Compositor entry point
   #:run-paned-terminal
   #:*prefix-key*))
