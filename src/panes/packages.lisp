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
   #:pane-initialize
   #:pane-flush
   #:pane-handle-key
   #:pane-handle-char
   #:pane-process-output
   #:pane-resize
   #:pane-dirty-p
   #:pane-destroy
   #:pane-alive-p
   ;; Unix terminal pane
   #:uterm-pane
   #:uterm-pane-command
   #:uterm-pane-args
   #:uterm-pane-pty
   #:uterm-pane-screen
   #:uterm-pane-vt-handler
   #:uterm-pane-alive-p
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
