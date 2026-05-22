(in-package #:lexter/shaders)

;;;; GLSL 3.30 shader sources.
;;;;
;;;; UV formula note:
;;;;   PCF bitmaps are stored top-to-bottom.  glTexImage2D places the first
;;;;   uploaded row at GL texture V=0 (the bottom).  In screen space, cell
;;;;   corner (0,0) is top-left and maps to the TOP of the glyph (PCF row 0).
;;;;
;;;;   Since both the screen Y-axis and the GL texture V-axis are flipped
;;;;   relative to each other, the two flips cancel: the natural formula
;;;;   V = (atlas_row + corner.y) / atlas_rows is correct with no extra inversion.

;;; --------------------------------------------------------------------------
;;; Simple cell shaders
;;; --------------------------------------------------------------------------
;;;
;;; Per-vertex (location 0):  vec2  v_corner   unit quad corner (0..1)
;;; Per-instance (locations 1-3, divisor=1):
;;;   location 1  ivec2  i_cell     col (int16), row (int16)
;;;   location 2  uint   i_glyph    glyph index (uint16)
;;;   location 3  uint   i_swatch   swatch table index (uint16)

(defparameter +simple-vert+
"#version 330 core

layout(location = 0) in vec2  v_corner;
layout(location = 1) in ivec2 i_cell;
layout(location = 2) in uint  i_glyph;
layout(location = 3) in uint  i_swatch;

uniform ivec2 u_cell_size;    // cell dimensions in pixels
uniform ivec2 u_viewport;     // window size in pixels
uniform ivec2 u_atlas_size;   // atlas dimensions in glyphs (cols, rows)

out vec2  f_uv;
flat out uint f_swatch_idx;

void main() {
    // Extract wide flag from bit 15 of swatch
    bool wide = (i_swatch & 0x8000u) != 0u;
    float cell_mult = wide ? 2.0 : 1.0;

    int gc = int(i_glyph) % u_atlas_size.x;
    int gr = int(i_glyph) / u_atlas_size.x;
    // Wide glyphs span 2 atlas columns
    f_uv = vec2(float(gc) + v_corner.x * cell_mult, float(gr) + v_corner.y)
           / vec2(u_atlas_size);

    // Wide glyphs span 2 cell widths on screen
    vec2 px  = vec2(i_cell * u_cell_size)
             + v_corner * vec2(u_cell_size) * vec2(cell_mult, 1.0);
    vec2 ndc = px / vec2(u_viewport) * 2.0 - 1.0;
    gl_Position = vec4(ndc.x, -ndc.y, 0.0, 1.0);

    f_swatch_idx = i_swatch & 0x7FFFu;
}
")

(defparameter +simple-frag+
"#version 330 core

uniform sampler2D u_atlas;
uniform sampler1D u_swatch_table;  // RGBA8: 4 palette indices per swatch (normalized)
uniform int u_palette_slot;        // which palette slot (0-3) to use

layout(std140) uniform Palette {
    vec4 colors[1024];  // 4 palettes x 256 colors
} u_palette;

in  vec2 f_uv;
flat in uint f_swatch_idx;

out vec4 frag_color;

void main() {
    float mask = texture(u_atlas, f_uv).r;
    vec4 sw    = texelFetch(u_swatch_table, int(f_swatch_idx), 0);
    // Convert normalized 0.0-1.0 back to palette index 0-255
    // Slot 0 = bg (r), Slot 1 = fg (g)
    uint idx   = uint(mask > 0.5 ? sw.g * 255.0 + 0.5 : sw.r * 255.0 + 0.5);
    // Offset by palette slot (each palette is 256 colors)
    frag_color = u_palette.colors[u_palette_slot * 256 + int(idx)];
}
")

;;; --------------------------------------------------------------------------
;;; Layered cell shaders
;;; --------------------------------------------------------------------------
;;;
;;; Per-instance (locations 1-5, divisor=1):
;;;   location 1  ivec2  i_cell     col (int16), row (int16)
;;;   location 2  uint   i_glyph    glyph index (uint16)
;;;   location 3  uvec2  i_ink_bg   ink-idx (uint8), bg-idx (uint8) — swatch slot refs
;;;   location 4  uint   i_ts       transparent-side: 0=:bg, 1=:fg, 2=:none
;;;   location 5  uint   i_swatch   swatch table index (uint16)
;;;
;;; The cell's 4-slot colour scheme is looked up from the GPU swatch table.
;;; 3 layers map cleanly to 4 slots: layer 0 uses slots 0+1, layers 1-2
;;; each use one slot (2 and 3 respectively by convention).

(defparameter +layered-vert+
"#version 330 core

layout(location = 0) in vec2  v_corner;
layout(location = 1) in ivec2 i_cell;
layout(location = 2) in uint  i_glyph;
layout(location = 3) in uvec2 i_ink_bg;   // ink-idx, bg-idx (swatch slot refs 0-3)
layout(location = 4) in uint  i_ts;       // transparent-side
layout(location = 5) in uint  i_swatch;   // swatch table index

uniform ivec2 u_cell_size;
uniform ivec2 u_viewport;
uniform ivec2 u_atlas_size;

out  vec2  f_uv;
flat out uint  f_ink_idx;
flat out uint  f_bg_idx;
flat out uint  f_ts;
flat out uint  f_swatch_idx;

void main() {
    // Extract wide flag from bit 15 of swatch
    bool wide = (i_swatch & 0x8000u) != 0u;
    float cell_mult = wide ? 2.0 : 1.0;

    int gc = int(i_glyph) % u_atlas_size.x;
    int gr = int(i_glyph) / u_atlas_size.x;
    // Wide glyphs span 2 atlas columns
    f_uv = vec2(float(gc) + v_corner.x * cell_mult, float(gr) + v_corner.y)
           / vec2(u_atlas_size);

    // Wide glyphs span 2 cell widths on screen
    vec2 px  = vec2(i_cell * u_cell_size)
             + v_corner * vec2(u_cell_size) * vec2(cell_mult, 1.0);
    vec2 ndc = px / vec2(u_viewport) * 2.0 - 1.0;
    gl_Position = vec4(ndc.x, -ndc.y, 0.0, 1.0);

    f_ink_idx    = i_ink_bg.x;
    f_bg_idx     = i_ink_bg.y;
    f_ts         = i_ts;
    f_swatch_idx = i_swatch & 0x7FFFu;
}
")

(defparameter +layered-frag+
"#version 330 core

uniform sampler2D u_atlas;
uniform sampler1D u_swatch_table;  // RGBA8: 4 palette indices per swatch (normalized)
uniform int u_palette_slot;        // which palette slot (0-3) to use

layout(std140) uniform Palette {
    vec4 colors[1024];  // 4 palettes x 256 colors
} u_palette;

in  vec2  f_uv;
flat in uint  f_ink_idx;
flat in uint  f_bg_idx;
flat in uint  f_ts;
flat in uint  f_swatch_idx;

out vec4 frag_color;

void main() {
    float mask = texture(u_atlas, f_uv).r;
    vec4 sw    = texelFetch(u_swatch_table, int(f_swatch_idx), 0);
    // Convert normalized 0.0-1.0 back to palette index 0-255
    uint ink_pal = uint(sw[f_ink_idx] * 255.0 + 0.5);
    // Offset by palette slot (each palette is 256 colors)
    int base     = u_palette_slot * 256;
    vec4 ink     = u_palette.colors[base + int(ink_pal)];

    if (f_ts == 2u) {
        // Layer 0: fully opaque on both sides
        uint bg_pal = uint(sw[f_bg_idx] * 255.0 + 0.5);
        vec4 bg     = u_palette.colors[base + int(bg_pal)];
        frag_color  = mask > 0.5 ? ink : bg;
    } else {
        // Overlay layer: one side is transparent
        float alpha = (f_ts == 0u) ? mask          // :bg  — ink on mask=1
                                   : (1.0 - mask); // :fg  — ink on mask=0
        frag_color  = vec4(ink.rgb, alpha);
    }
}
")
