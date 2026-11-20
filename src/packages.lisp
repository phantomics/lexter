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
           #:+no-glyph-position+
           #:+underline-glyph+
           #:line-glyph-position))

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
           #:record-selector
           #:record-mask
           #:record-type-bits
           #:record-layer-p
           #:record-topmost-layer
           ;; Invariants
           #:record-invariant-violations
           #:half-pair-violations
           #:*check-records*
           #:check-record
           ;; Text cells
           #:text-array
           #:make-text-array
           #:text-array-count
           #:write-text-cell
           #:patch-text-cell
           #:read-text-cell
           #:text-cell-continuation-p
           #:copy-text-cells
           #:clear-text-cells
           ;; Terminal rows
           #:make-terminal-row-array
           #:write-terminal-row
           #:patch-terminal-row
           #:read-terminal-row
           ;; Texels
           #:write-swatch-texel
           #:read-swatch-texel
           #:write-palette-texel
           #:read-palette-texel))

(defpackage #:lexter/grid
  (:use #:cl)
  (:import-from #:lexter/manifests
                #:record-array #:make-record-array #:+plain-glyph-words+
                #:write-plain-record #:patch-plain-record #:read-plain-record
                #:read-record-common #:patch-record-common #:record-format
                #:copy-records #:clear-records
                #:record-glyph #:record-ink-slot #:record-selector #:record-mask
                #:record-type-bits #:record-layer-p #:record-topmost-layer
                #:text-array #:make-text-array)
  (:export ;; Grid creation and access
           #:make-display-grid
           #:display-grid
           #:display-grid-cols
           #:display-grid-rows
           #:display-grid-records
           #:display-grid-atlas
           #:display-grid-palette-slot
           #:cell-index
           #:resize-grid
           ;; Surfaces
           #:surface
           #:surface-p
           #:make-surface
           #:resize-surface
           #:surface-text
           ;; Records
           #:write-text-record
           #:clear-cell
           #:cell-glyph
           #:cell-swatch
           #:continuation-p
           #:wide-left-p
           #:exchange-cell-slots
           ;; Change stamps (LEXTER-D113)
           #:next-change-stamp
           #:row-stamp
           #:touch-row
           #:touch-all-rows
           ;; Uploads and clocks (LEXTER-D113)
           #:record-upload-state
           #:make-record-upload-state
           #:plan-record-uploads
           #:display-grid-clock-masks
           #:+clock-blink+))

(defpackage #:lexter/surface
  (:use #:cl)
  (:import-from #:lexter/manifests
                #:+continuation-marker+ #:*check-records* #:check-record
                #:write-plain-record #:patch-plain-record #:read-record-common
                #:patch-record-common #:copy-records
                #:record-glyph #:record-ink-slot #:record-selector
                #:write-text-cell #:read-text-cell)
  (:import-from #:lexter/grid
                #:display-grid-cols #:display-grid-rows #:display-grid-records
                #:display-grid-atlas #:display-grid-palette-slot
                #:surface-p #:surface-text #:cell-index #:touch-row
                #:continuation-p #:wide-left-p)
  (:export #:char-glyph
           #:put-char
           #:put-string
           #:put-glyph
           #:put-cell
           #:fill-cells
           #:clear-cells
           #:surface-char
           #:surface-string
           #:compose-surface))

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
           #:plan-swatch-uploads
           ;; Palette slots (LEXTER-D92)
           #:+default-palette-slots+
           #:palette-slots
           #:make-palette-slots
           #:palette-slot-count
           #:allocate-palette-slot
           #:release-palette-slot
           #:palette-slot-owner))

(defpackage #:lexter/shaders
  (:use #:cl)
  (:export #:+cell-vert+
           #:+cell-frag+))

(defpackage #:lexter/renderer
  (:use #:cl #:lexter/atlas #:lexter/grid #:lexter/shaders)
  (:import-from #:lexter/swatches
                #:+store-size+ #:+palette-entries+ #:make-default-palette
                #:swatch-upload-records #:make-swatch-upload-records
                #:plan-swatch-uploads #:+default-palette-slots+)
  (:export #:make-renderer
           #:render-state
           #:render-state-atlas
           #:render-state-win-w
           #:render-state-win-h
           #:render-state-pixel-scale
           #:set-palette
           #:upload-palette
           #:upload-swatches
           #:render-state-palette-slots
           #:+default-palette-slots+
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
  (:import-from #:lexter/manifests
                #:write-palette-texel #:read-palette-texel
                #:+continuation-marker+
                #:text-array #:make-text-array #:text-array-count
                #:write-text-cell #:patch-text-cell #:read-text-cell
                #:text-cell-continuation-p #:copy-text-cells #:clear-text-cells
                #:make-terminal-row-array
                #:write-terminal-row #:patch-terminal-row #:read-terminal-row)
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
           ;; Colours
           #:colour
           #:+default-colour+
           #:palette-colour
           #:rgb-colour
           #:colour-palette-index
           #:colour-rgb
           #:rgb-to-256
           ;; Styles
           #:style
           #:make-style
           #:copy-style
           #:style-foreground
           #:style-background
           #:style-underline-colour
           #:style-bold
           #:style-underline
           #:style-line-style
           #:style-strikethrough
           #:style-overline
           #:style-reverse
           #:style-blink
           #:style-invisible
           #:+max-styles+
           #:style-table
           #:make-style-table
           #:style-table-count
           #:intern-style
           #:table-style
           #:erased-style
           #:style-table-bold-as-bright
           #:style-swatch
           #:screen-styles
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
           ;; Cell access
           #:cell-content
           #:cell-style
           #:cell-wide-p
           #:cell-continuation-p
           #:cell-codepoints
           #:set-cell-style
           ;; Terminal rows
           #:row-soft-wrap-p
           #:set-row-soft-wrap
           #:row-prompt-kind
           #:row-line-size
           ;; Write operations
           #:write-char-at
           #:write-string-at
           #:join-character
           #:erase-in-display
           #:erase-in-line
           #:erase-chars
           ;; Cursor-relative write
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
           #:history-row
           #:history-row-text
           #:history-row-codepoints
           #:history-row-soft-wrap-p
           #:scrollback-viewport-offset
           #:set-scrollback-viewport
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
           #:reset-palette))

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
  (:use #:cl #:lexter/pcf #:lexter/atlas #:lexter/grid #:lexter/renderer #:lexter/surface)
  (:import-from #:lexter/swatches
                #:make-swatch-store #:swatch-store-display-table #:intern-swatch)
  (:export #:run-demo
           #:run-cjk-demo))
