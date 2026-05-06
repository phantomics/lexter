;;;; Pane system package definition

(defpackage #:lexter/panes
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
   #:pane-palette
   #:pane-workspace
   #:pane-input-redirect
   #:scroll-state
   #:content-width
   #:content-height
   #:content-row
   ;; VT terminal base pane
   #:vt-pane
   #:vt-pane-screen
   #:vt-pane-vt-handler
   #:vt-pane-initialized-p
   #:vt-pane-palette-slot
   #:vt-pane-read-buffer
   #:vt-pane-write-buffer
   #:vt-pane-uc-scratch
   #:vt-pane-init-screen
   ;; VT pane abstract interface (for subclasses)
   #:vt-pane-write-bytes
   #:vt-pane-read-bytes
   #:vt-pane-backend-alive-p
   #:vt-pane-backend-destroy
   #:vt-pane-backend-resize
   #:vt-pane-write-string
   ;; VT pane shared state
   #:*cursor-blink-on*
   #:*key-sequences*
   #:%key-to-bytes
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
   ;; Chrome pane mixin (scroll bar, header, footer)
   #:chrome-pane
   #:scroll-bar-visible-p
   #:chrome-header-height
   #:chrome-footer-height
   #:chrome-header-data
   #:chrome-footer-data
   #:scroll-bar-col
   #:scroll-bar-thumb-geometry
   #:scroll-bar-hit-test
   ;; Workspace
   #:workspace
   #:workspace-name
   #:workspace-panes
   #:workspace-decorations
   #:workspace-decorator
   #:workspace-decorations-dirty
   #:workspace-focus-index
   #:focused-pane
   #:focus-next
   #:focus-prev
   #:flush-workspace
   #:mark-decorations-dirty
   ;; Grid utilities (for decoration functions)
   #:clear-grid
   ;; Compositor entry point
   #:run-paned-terminal
   #:*prefix-key*))
