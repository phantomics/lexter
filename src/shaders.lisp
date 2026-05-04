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
;;;   location 3  uvec2  i_colors   fg (uint8), bg (uint8)

(defparameter +simple-vert+
"#version 330 core

layout(location = 0) in vec2  v_corner;
layout(location = 1) in ivec2 i_cell;
layout(location = 2) in uint  i_glyph;
layout(location = 3) in uvec2 i_colors;

uniform ivec2 u_cell_size;    // cell dimensions in pixels
uniform ivec2 u_viewport;     // window size in pixels
uniform ivec2 u_atlas_size;   // atlas dimensions in glyphs (cols, rows)

out vec2  f_uv;
flat out uint f_fg;
flat out uint f_bg;

void main() {
    int gc = int(i_glyph) % u_atlas_size.x;
    int gr = int(i_glyph) / u_atlas_size.x;
    f_uv = vec2(float(gc) + v_corner.x, float(gr) + v_corner.y)
           / vec2(u_atlas_size);

    vec2 px  = vec2(i_cell * u_cell_size) + v_corner * vec2(u_cell_size);
    vec2 ndc = px / vec2(u_viewport) * 2.0 - 1.0;
    gl_Position = vec4(ndc.x, -ndc.y, 0.0, 1.0);

    f_fg = i_colors.x;
    f_bg = i_colors.y;
}
")

(defparameter +simple-frag+
"#version 330 core

uniform sampler2D u_atlas;

layout(std140) uniform Palette {
    vec4 colors[256];
} u_palette;

in  vec2 f_uv;
flat in uint f_fg;
flat in uint f_bg;

out vec4 frag_color;

void main() {
    float mask  = texture(u_atlas, f_uv).r;
    frag_color  = mask > 0.5 ? u_palette.colors[f_fg]
                              : u_palette.colors[f_bg];
}
")

;;; --------------------------------------------------------------------------
;;; Layered cell shaders
;;; --------------------------------------------------------------------------
;;;
;;; Per-instance (locations 1-5, divisor=1):
;;;   location 1  ivec2  i_cell     col (int16), row (int16)
;;;   location 2  uint   i_glyph    glyph index (uint16)
;;;   location 3  uvec2  i_ink_bg   ink-idx (uint8), bg-idx (uint8)
;;;   location 4  uint   i_ts       transparent-side: 0=:bg, 1=:fg, 2=:none
;;;   location 5  uvec4  i_palette  4-slot colour scheme for this cell
;;;
;;; The cell's 4-slot colour scheme (slots 0-3 are palette indices mapping to
;;; bg, fg, primary-overlay, secondary-overlay) is carried inline in the
;;; instance record and resolved in the fragment shader via the Palette UBO.
;;; 3 layers map cleanly to 4 slots: layer 0 uses slots 0+1, layers 1-2
;;; each use one slot (2 and 3 respectively by convention).

(defparameter +layered-vert+
"#version 330 core

layout(location = 0) in vec2  v_corner;
layout(location = 1) in ivec2 i_cell;
layout(location = 2) in uint  i_glyph;
layout(location = 3) in uvec2 i_ink_bg;   // ink-idx, bg-idx
layout(location = 4) in uint  i_ts;       // transparent-side
layout(location = 5) in uvec4 i_palette;  // 4 local palette entries

uniform ivec2 u_cell_size;
uniform ivec2 u_viewport;
uniform ivec2 u_atlas_size;

out  vec2  f_uv;
flat out uint  f_ink_idx;
flat out uint  f_bg_idx;
flat out uint  f_ts;
flat out uvec4 f_palette;

void main() {
    int gc = int(i_glyph) % u_atlas_size.x;
    int gr = int(i_glyph) / u_atlas_size.x;
    f_uv = vec2(float(gc) + v_corner.x, float(gr) + v_corner.y)
           / vec2(u_atlas_size);

    vec2 px  = vec2(i_cell * u_cell_size) + v_corner * vec2(u_cell_size);
    vec2 ndc = px / vec2(u_viewport) * 2.0 - 1.0;
    gl_Position = vec4(ndc.x, -ndc.y, 0.0, 1.0);

    f_ink_idx = i_ink_bg.x;
    f_bg_idx  = i_ink_bg.y;
    f_ts      = i_ts;
    f_palette = i_palette;
}
")

(defparameter +layered-frag+
"#version 330 core

uniform sampler2D u_atlas;

layout(std140) uniform Palette {
    vec4 colors[256];
} u_palette;

in  vec2  f_uv;
flat in uint  f_ink_idx;
flat in uint  f_bg_idx;
flat in uint  f_ts;
flat in uvec4 f_palette;

out vec4 frag_color;

vec4 local_color(uint slot) {
    uint global_idx = f_palette[slot];
    return u_palette.colors[global_idx];
}

void main() {
    float mask = texture(u_atlas, f_uv).r;
    vec4  ink  = local_color(f_ink_idx);

    if (f_ts == 2u) {
        // Layer 0: fully opaque on both sides
        vec4 bg    = local_color(f_bg_idx);
        frag_color = mask > 0.5 ? ink : bg;
    } else {
        // Overlay layer: one side is transparent
        float alpha = (f_ts == 0u) ? mask          // :bg  — ink on mask=1
                                   : (1.0 - mask); // :fg  — ink on mask=0
        frag_color  = vec4(ink.rgb, alpha);
    }
}
")
