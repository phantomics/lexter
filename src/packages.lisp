(defpackage #:pcf-gl/pcf
  (:use #:cl)
  (:export ;; Loaders
           #:load-pcf
           #:load-bdf
           ;; Font struct (shared by PCF and BDF)
           #:bitmap-font
           #:bitmap-font-cell-width
           #:bitmap-font-cell-height
           #:bitmap-font-ascent
           #:bitmap-font-glyph-count
           #:bitmap-font-bitmaps
           #:bitmap-font-encoding
           #:glyph-index))

(defpackage #:pcf-gl/atlas
  (:use #:cl #:pcf-gl/pcf)
  (:export #:build-atlas
           #:add-cursor-glyphs
           #:atlas
           #:atlas-texture-id
           #:atlas-cell-width
           #:atlas-cell-height
           #:atlas-cols
           #:atlas-rows
           #:atlas-glyph-index
           #:+cursor-block-glyph+
           #:+cursor-underline-glyph+
           #:+cursor-bar-glyph+))

(defpackage #:pcf-gl/grid
  (:use #:cl)
  (:export ;; Grid creation and access
           #:make-display-grid
           #:display-grid
           #:display-grid-cols
           #:display-grid-rows
           #:resize-grid
           ;; Swatch API
           #:set-swatch
           #:get-swatch
           #:swatch-as-array
           ;; Simple cell API
           #:set-simple-cell
           ;; Layered cell API
           #:set-cell-swatch
           #:set-cell-layer
           #:clear-cell-layers
           #:cell-layered-p
           ;; Dirty tracking
           #:mark-row-dirty
           #:mark-all-dirty
           #:clear-dirty-flags
           #:row-dirty-p
           ;; Swatch sync tracking
           #:swatch-generation
           ;; Render data
           #:build-render-data
           ;; Constants
           #:+max-layers+
           #:+swatch-slots+
           #:+simple-stride+
           #:+layered-stride+))

(defpackage #:pcf-gl/shaders
  (:use #:cl)
  (:export #:+simple-vert+
           #:+simple-frag+
           #:+layered-vert+
           #:+layered-frag+))

(defpackage #:pcf-gl/renderer
  (:use #:cl #:pcf-gl/atlas #:pcf-gl/grid #:pcf-gl/shaders)
  (:export #:make-renderer
           #:render-state
           #:render-state-atlas
           #:render-state-win-w
           #:render-state-win-h
           #:render-state-pixel-scale
           #:set-palette
           #:render-frame
           #:update-viewport
           #:set-pixel-scale
           #:pixel-scale
           #:scaled-cell-size
           #:destroy-renderer))

;;; ---------------------------------------------------------------------------
;;; Terminal Model (Phase 2)
;;; ---------------------------------------------------------------------------

(defpackage #:pcf-gl/model
  (:use #:cl)
  (:export ;; Screen creation
           #:make-screen
           #:screen
           #:screen-cols
           #:screen-rows
           #:screen-mode
           #:screen-blank-glyph
           ;; Swatch interning
           #:intern-swatch
           #:default-swatch
           ;; Cursor
           #:cursor-col
           #:cursor-row
           #:cursor-visible-p
           #:cursor-style
           #:cursor-blink-p
           #:set-cursor-position
           #:set-cursor-style
           #:set-cursor-visible
           ;; Cell access (for application use)
           #:cell-glyph
           #:cell-swatch
           #:cell-attrs
           #:topmost-layer
           ;; Write operations
           #:write-char-at
           #:write-string-at
           #:erase-in-display
           #:erase-in-line
           #:erase-chars
            ;; Cursor-relative write (targets topmost layer)
            #:put-char
            #:delete-char
           #:insert-chars
           #:delete-chars
           ;; Line operations
           #:insert-lines
           #:delete-lines
           ;; Scrolling
           #:scroll-up
           #:scroll-down
           #:set-scrolling-region
           ;; Modes and state
           #:set-mode
           #:get-mode
           #:resize-screen
           ;; Scrollback
           #:scrollback-lines
           #:scrollback-line
           #:scrollback-viewport-offset
           #:set-scrollback-viewport
           ;; Layer management
           #:set-layer
           #:clear-overlay-layers
           ;; Display flush
           #:flush-to-display
           ;; Dirty tracking
           #:any-row-dirty-p
           ;; Attribute word bits (universal)
           #:+attr-bold+
           #:+attr-underline+
           #:+attr-blink+
           #:+attr-reverse+
           #:+attr-invisible+))

(defpackage #:pcf-gl/demo
  (:use #:cl #:pcf-gl/pcf #:pcf-gl/atlas #:pcf-gl/grid #:pcf-gl/renderer)
  (:export #:run-demo))


  ;; (:shadowing-import-from #:cl-vt #:vt-parser-params-list 
  ;;                         #:vt-parser-get-param #:vt-parser-intermediate-chars-list)

;;; ---------------------------------------------------------------------------
;;; Unix Backend (Phase 3)
;;; ---------------------------------------------------------------------------

;; (defpackage #:pcf-gl/pty
;;   (:use #:cl)
;;   (:export ;; PTY creation
;;            #:pty-open
;;            #:pty-fork
;;            #:pty-close
;;            ;; PTY I/O
;;            #:pty-read
;;            #:pty-write
;;            #:pty-write-string
;;            ;; PTY control
;;            #:pty-set-size
;;            #:pty-set-nonblocking
;;            ;; Polling
;;            #:pty-poll
;;            #:pty-check-child
;;            ;; Accessors
;;            #:pty
;;            #:pty-master-fd
;;            #:pty-slave-name
;;            #:pty-child-pid
;;            #:pty-alive-p))

;; (defpackage #:pcf-gl/vt-handler
;;   (:use #:cl #:pcf-gl/model)
;;   (:export #:make-vt-handler
;;            #:vt-handler
;;            #:vt-handler-screen
;;            #:vt-handler-atlas
;;            #:vt-handler-parser
;;            #:vt-handler-callback
;;            #:process-output
;;            ;; Debug
;;            #:*debug-vt*))

;; (defpackage #:pcf-gl/unix-term
;;   (:use #:cl #:pcf-gl/pcf #:pcf-gl/atlas #:pcf-gl/grid
;;         #:pcf-gl/renderer #:pcf-gl/model #:pcf-gl/pty #:pcf-gl/vt-handler)
;;   (:export #:run-terminal
;;            #:unix-terminal
;;            #:terminal-screen
;;            #:terminal-pty))
