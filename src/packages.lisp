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
            #:bitmap-font-wide-glyphs
            #:glyph-index)
  (:shadowing-import-from #:chipz #:gzip #:make-decompressing-stream))

(defpackage #:lexter/width
  (:use #:cl)
  (:export #:char-width
           #:unicode-width-class
           #:width-policy
           #:make-width-policy
           #:width-policy-ambiguous-width
           #:width-policy-overrides
           #:*default-width-policy*
           #:+unicode-version+))

(defpackage #:lexter/atlas
  (:use #:cl #:lexter/pcf)
  (:export #:build-atlas
           #:pack-atlas
           #:upload-atlas
           #:atlas-columns-for
           #:add-cursor-glyphs
           #:atlas
           #:atlas-texture-id
           #:atlas-cell-width
           #:atlas-cell-height
           #:atlas-cols
           #:atlas-rows
           #:atlas-glyph-index
           #:atlas-glyph-wide-p
           #:atlas-width-policy
           ;; Generated glyphs, by name and by position (LEXTER-D89)
           #:+generated-glyph-base+
           #:+first-font-position+
           #:+empty-glyph+
           #:+cursor-block-glyph+
           #:+cursor-underline-glyph+
           #:+cursor-bar-glyph+
           #:+cursor-outline-glyph+
           #:+replacement-glyph+
           #:+no-glyph-glyph+
           #:+empty-glyph-position+
           #:+replacement-glyph-position+
           #:+no-glyph-position+))

(defpackage #:lexter/grid
  (:use #:cl)
  (:export ;; Grid creation and access
           #:make-display-grid
           #:display-grid
           #:display-grid-cols
           #:display-grid-rows
           #:resize-grid
           ;; Simple cell API
           #:set-simple-cell
           ;; Layered cell API
           #:set-cell-swatch
           #:set-cell-layer
           #:clear-cell-layers
           #:cell-layered-p
           #:continuation-p
           #:exchange-cell-slots
           ;; Dirty tracking
           #:mark-row-dirty
           #:mark-all-dirty
           #:clear-dirty-flags
           #:row-dirty-p
           ;; Render data
           #:build-render-data
           ;; Constants
           #:+max-layers+
           #:+swatch-slots+
           #:+simple-stride+
           #:+layered-stride+))

(defpackage #:lexter/manifests
  (:use #:cl)
  (:import-from #:specops
                #:defmanifest #:defenum #:marshal #:unmarshal
                #:manifest-check-failed)
  (:export ;; Sizes and values
           #:+record-bytes+
           #:+plain-glyph-words+
           #:+text-cell-bytes+
           #:+texel-bytes+
           #:+continuation-marker+
           ;; Record arrays
           #:record-array
           #:make-record-array
           #:record-array-count
           #:write-plain-record
           #:patch-plain-record
           #:read-plain-record
           #:read-record-common
           #:patch-record-common
           #:record-format
           #:copy-records
           #:clear-records
           ;; Glyph words by number
           #:record-glyph
           #:record-ink-slot
           #:record-layer-p
           #:record-topmost-layer
           ;; Invariants
           #:record-invariant-violations
           #:half-pair-violations
           ;; Text cells
           #:text-array
           #:make-text-array
           #:text-array-count
           #:write-text-cell
           #:patch-text-cell
           #:read-text-cell
           #:text-cell-continuation-p
           ;; Texels
           #:write-swatch-texel
           #:read-swatch-texel
           #:write-palette-texel
           #:read-palette-texel))

(defpackage #:lexter/swatches
  (:use #:cl)
  (:import-from #:lexter/manifests
                #:write-swatch-texel #:read-swatch-texel
                #:write-palette-texel #:read-palette-texel)
  (:export ;; Constants
           #:+range-size+
           #:+store-size+
           #:+store-ranges+
           #:+first-edition-ranges+
           #:+max-table-ranges+
           #:+palette-entries+
           #:+palette-bytes+
           ;; Palettes
           #:palette
           #:make-default-palette
           ;; Stores
           #:swatch-store
           #:make-swatch-store
           #:swatch-store-display-table
           #:swatch-store-usable-ranges
           #:range-owner
           #:store-swatch
           ;; Tables
           #:swatch-table
           #:make-swatch-table
           #:swatch-table-id
           #:swatch-table-store
           #:swatch-table-count
           #:swatch-table-ranges
           #:swatch-table-version
           #:swatch-table-released
           #:swatch-table-default
           #:swatch-table-full-p
           #:intern-swatch
           #:append-swatch
           #:table-swatch
           #:bump-swatch-table-version
           #:release-swatch-table
           ;; Uploads
           #:swatch-upload-records
           #:make-swatch-upload-records
           #:plan-swatch-uploads))

(defpackage #:lexter/shaders
  (:use #:cl)
  (:export #:+simple-vert+
           #:+simple-frag+
           #:+layered-vert+
           #:+layered-frag+))

(defpackage #:lexter/renderer
  (:use #:cl #:lexter/atlas #:lexter/grid #:lexter/shaders)
  (:import-from #:lexter/swatches
                #:+store-size+ #:+palette-entries+ #:make-default-palette
                #:swatch-upload-records #:make-swatch-upload-records
                #:plan-swatch-uploads)
  (:export #:make-renderer
           #:render-state
           #:render-state-atlas
           #:render-state-win-w
           #:render-state-win-h
           #:render-state-pixel-scale
           #:set-palette
           #:upload-palette
           #:set-active-palette-slot
           #:upload-swatches
           #:render-state-palette-slots
           #:+default-palette-slots+
           #:+default-pane-palette-slot+
           #:render-frame
           #:update-viewport
           #:set-pixel-scale
           #:pixel-scale
           #:scaled-cell-size
           #:destroy-renderer
           ;; Offscreen render target (post-processing + screenshots)
           #:enable-offscreen
           #:disable-offscreen
           #:offscreen-enabled-p
           #:resize-offscreen
           #:present-offscreen
           #:capture-pixels))

;;; ---------------------------------------------------------------------------
;;; Terminal Model (Phase 2)
;;; ---------------------------------------------------------------------------

(defpackage #:lexter/model
  (:use #:cl)
  (:import-from #:lexter/manifests #:write-palette-texel #:read-palette-texel)
  ;; The layer and swatch counts have one home, the grid (LEXTER-O36)
  (:import-from #:lexter/grid #:+max-layers+ #:+swatch-slots+)
  (:import-from #:lexter/swatches
                #:palette #:make-default-palette
                #:make-swatch-store #:make-swatch-table #:swatch-table
                #:swatch-table-default #:intern-swatch)
  (:export ;; Screen creation
           #:make-screen
           #:screen
           #:screen-cols
           #:screen-rows
           #:screen-mode
           #:screen-blank-glyph
           ;; Swatch interning
           #:screen-swatches
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
           #:line-feed
           #:reverse-line-feed
           #:scroll-up
           #:scroll-down
           #:set-scrolling-region
           ;; State
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
           #:mark-screen-dirty
           ;; Palette
           #:screen-palette
           #:screen-palette-generation
           #:make-default-palette
           #:set-palette-entry
           #:set-palette-entry-rgb8
           #:get-palette-entry
           #:reset-palette
           ;; Attribute word bits (universal)
           #:+attr-bold+
           #:+attr-underline+
           #:+attr-blink+
           #:+attr-reverse+
           #:+attr-invisible+))

;;; ---------------------------------------------------------------------------
;;; GUI iteration protocol (steppable window lifecycle)
;;; ---------------------------------------------------------------------------

(defpackage #:lexter/gui
  (:use #:cl)
  (:export #:gui-initialize
           #:gui-tick
           #:gui-destroy
           #:gui-window
           #:gui-alive-p
           #:run-gui-loop))

(defpackage #:lexter/demo
  (:use #:cl #:lexter/pcf #:lexter/atlas #:lexter/grid #:lexter/renderer)
  (:import-from #:lexter/swatches
                #:make-swatch-store #:swatch-store-display-table #:intern-swatch)
  (:export #:run-demo
           #:run-cjk-demo))
