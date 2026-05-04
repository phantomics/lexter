(defpackage #:lexter/pcf
  (:use #:cl)
  (:export ;; Loaders
           #:load-pcf
           #:load-bdf
           #:load-pbm-font
           #:load-cp437-font
           ;; Font struct (shared by PCF, BDF, PBM)
           #:bitmap-font
           #:bitmap-font-cell-width
           #:bitmap-font-cell-height
           #:bitmap-font-ascent
           #:bitmap-font-glyph-count
           #:bitmap-font-bitmaps
           #:bitmap-font-encoding
           #:glyph-index))

(defpackage #:lexter/atlas
  (:use #:cl #:lexter/pcf)
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

(defpackage #:lexter/grid
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

(defpackage #:lexter/shaders
  (:use #:cl)
  (:export #:+simple-vert+
           #:+simple-frag+
           #:+layered-vert+
           #:+layered-frag+))

(defpackage #:lexter/renderer
  (:use #:cl #:lexter/atlas #:lexter/grid #:lexter/shaders)
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

(defpackage #:lexter/model
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

(defpackage #:lexter/demo
  (:use #:cl #:lexter/pcf #:lexter/atlas #:lexter/grid #:lexter/renderer)
  (:export #:run-demo))
