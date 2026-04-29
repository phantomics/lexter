(defpackage #:pcf-gl/pcf
  (:use #:cl)
  (:export #:load-pcf
           #:pcf-font
           #:pcf-font-cell-width
           #:pcf-font-cell-height
           #:pcf-font-ascent
           #:pcf-font-glyph-count
           #:pcf-font-bitmaps
           #:pcf-font-encoding
           #:glyph-index))

(defpackage #:pcf-gl/atlas
  (:use #:cl #:pcf-gl/pcf)
  (:export #:build-atlas
           #:atlas
           #:atlas-texture-id
           #:atlas-cell-width
           #:atlas-cell-height
           #:atlas-cols
           #:atlas-rows
           #:atlas-glyph-index   ; codepoint -> glyph-idx or nil
           ))

(defpackage #:pcf-gl/grid
  (:use #:cl)
  (:export #:make-terminal-grid
           #:terminal-grid
           #:terminal-grid-cols
           #:terminal-grid-rows
           #:set-simple-cell
           #:set-cell-palette
           #:set-cell-layer
           #:clear-cell-layers
           #:cell-layered-p
           #:build-render-data))

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
           #:set-palette
           #:render-frame
           #:destroy-renderer))

(defpackage #:pcf-gl/demo
  (:use #:cl #:pcf-gl/pcf #:pcf-gl/atlas #:pcf-gl/grid #:pcf-gl/renderer)
  (:export #:run-demo))
