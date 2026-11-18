;;;; Pane system package definition

(defpackage #:lexter/panes
  (:use #:cl #:lexter/gui)
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
   #:pane-handle-mouse-button
   #:pane-handle-mouse-motion
   #:pane-handle-scroll
   #:pane-process-output
   #:pane-resize
   #:pane-dirty-p
   #:pane-mark-dirty
   #:pane-destroy
   #:pane-alive-p
   #:pane-palette
   #:pane-workspace
   #:pane-input-redirect
   ;; Pane profiles
   #:define-pane-profile
   #:pane-profile
   #:profile-parent
   #:own-profile
   #:unset-setting
   #:resolve-pane-setting
   #:workspace-profile
   #:workspace-compositor
   #:compositor-profile
   #:wheel-scroll-lines
   #:snap-on-input
   #:snap-on-output
   #:pane-wheel-scroll-lines
   #:pane-snap-on-input
   #:pane-snap-on-output
   #:workspace-wheel-scroll-lines
   #:workspace-snap-on-input
   #:workspace-snap-on-output
   #:compositor-wheel-scroll-lines
   #:compositor-snap-on-input
   #:compositor-snap-on-output
   #:profile-wheel-scroll-lines
   #:profile-snap-on-input
   #:profile-snap-on-output
   #:pane-forward-key
   #:pane-forward-char
   #:pane-forward-mouse-button
   #:pane-forward-mouse-motion
   #:pane-forward-scroll
   #:*redirect-suppressed*
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
   ;; Swatches drawn at the level of the display
   #:display-swatch
   #:swatch-store-of
   ;; Compositor entry point
   #:run-paned-terminal
   #:make-paned-compositor
   #:compositor-capture
   #:compositor
   #:compositor-window
   #:compositor-renderer
   #:compositor-atlas
   #:compositor-display
   #:compositor-swatch-store
   #:compositor-cols
   #:compositor-rows
   #:compositor-cell-w
   #:compositor-cell-h
   #:compositor-pixel-scale
   #:compositor-title
   #:compositor-font-path
   #:compositor-headless
   #:compositor-reset-display
   #:*prefix-key*
   ;; GUI protocol (re-exported for convenience)
   #:gui-initialize
   #:gui-tick
   #:gui-destroy
   #:gui-window
   #:gui-alive-p
   #:run-gui-loop))
