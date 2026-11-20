(in-package #:lexter/shaders)

;;;; GLSL 3.30 shader sources.
;;;;
;;;; One program draws the composed grid in one instanced call (LEXTER-D107):
;;;; each instance is one cell, its record the two uvec4 attributes of the
;;;; instance, words 0-3 and 4-7, passed to the fragment shader flat; its
;;;; place in the grid follows from its instance number. The fragment shader
;;;; follows the procedure of Drawing a Pixel in the cell-model architecture
;;;; (LEXTER-0016) for the plain format, which is the only one built: every
;;;; test is on integers, and it selects one palette entry for each pixel,
;;;; without blending (LEXTER-D110). A record of another format is drawn in
;;;; its background slot (LEXTER-D82). It is written by hand from the record's
;;;; tables and checked against records its manifests wrote (LEXTER-D130), by
;;;; the test rig's CHECK-RECORD-DRAWING.
;;;;
;;;; The atlas is read with texelFetch, at the pixel of the atlas column a
;;;; glyph word names: row 0 of the texture is the top row of the atlas's
;;;; first row of glyphs.
;;;;
;;;; Colours are read from integer texture buffers (LEXTER-D109): the swatch
;;;; store, by the header word's swatch, and the palette store, 256 entries to
;;;; a slot, by its palette slot; a slot beyond the store draws in slot 0
;;;; (LEXTER-D92).

(defparameter +cell-vert+
"#version 330 core

layout(location = 0) in vec2  v_corner;   // unit quad corner (0..1)
layout(location = 1) in uvec4 i_w0;       // record words 0-3
layout(location = 2) in uvec4 i_w1;       // record words 4-7

uniform ivec2 u_cell_size;    // cell size on screen, in pixels
uniform ivec2 u_glyph_size;   // cell size in the atlas, in pixels
uniform ivec2 u_viewport;     // window size in pixels
uniform int   u_grid_cols;    // the grid's columns

flat out uvec4 f_w0;
flat out uvec4 f_w1;
out vec2 f_local;             // the pixel's place in the cell, in atlas pixels

void main() {
    ivec2 cell = ivec2(gl_InstanceID % u_grid_cols, gl_InstanceID / u_grid_cols);
    vec2 px  = vec2(cell * u_cell_size) + v_corner * vec2(u_cell_size);
    vec2 ndc = px / vec2(u_viewport) * 2.0 - 1.0;
    gl_Position = vec4(ndc.x, -ndc.y, 0.0, 1.0);
    f_w0 = i_w0;
    f_w1 = i_w1;
    f_local = v_corner * vec2(u_glyph_size);
}
")

(defparameter +cell-frag+
"#version 330 core

uniform sampler2D      u_atlas;        // R8: 0 or 255 for each glyph pixel
uniform usamplerBuffer u_swatches;     // RGBA8UI: 4 palette indices per swatch
uniform usamplerBuffer u_palettes;     // RGBA8UI: 256 colours per palette slot
uniform ivec2 u_glyph_size;
uniform int   u_atlas_cols;
uniform int   u_palette_slots;
uniform bool  u_blink_off;             // the blink phase (LEXTER-D94)

flat in uvec4 f_w0;
flat in uvec4 f_w1;
in vec2 f_local;

out vec4 frag_color;

uint word(int n) {
    return n < 4 ? f_w0[n] : f_w1[n - 4];
}

// Glyph G at the cell's pixel X, Y: 1 where it is inked. A cell with a line
// size reads every glyph magnified two times (LEXTER-D114).
uint pixel_of(uint g, int x, int y, uint w0) {
    uint sz = (w0 >> 19) & 3u;
    int  mh = int((w0 >> 21) & 1u);
    int gx = x;
    int gy = y;
    if (sz != 0u) {
        gx = (mh * u_glyph_size.x + x) / 2;
        gy = (sz == 1u) ? y : ((int(sz) - 2) * u_glyph_size.y + y) / 2;
    }
    int col = int(g % uint(u_atlas_cols));
    int row = int(g / uint(u_atlas_cols));
    float ink = texelFetch(u_atlas, ivec2(col * u_glyph_size.x + gx,
                                          row * u_glyph_size.y + gy), 0).r;
    return ink > 0.5 ? 1u : 0u;
}

void main() {
    int x = min(int(f_local.x), u_glyph_size.x - 1);
    int y = min(int(f_local.y), u_glyph_size.y - 1);
    uint w0 = word(0);
    uint w1 = word(1);
    uint f  = w0 & 0xFFu;
    uint slot = (w1 >> 24) & 3u;                       // the background slot
    if (f == 0u) {                                     // the plain format
        uint n     = min((w0 >> 8) & 7u, 6u);
        uint types = (w0 >> 11) & 0x1Fu;               // bit i-1: glyph i is a mask
        uint cov = 0u;                                 // a bit for each layer
        uint k   = 0u;                                 // layers so far
        for (uint i = 0u; i < n; i++) {
            uint w = word(2 + int(i));
            uint p = pixel_of(w & 0xFFFFFFu, x, y, w0) ^ ((w >> 24) & 1u);
            if (i == 0u || ((types >> (i - 1u)) & 1u) == 0u) {
                cov |= p << k;
                k += 1u;
            } else {
                uint r  = min(((w >> 27) & 7u) + 1u, k);
                uint R  = ((1u << r) - 1u) << (k - r);   // the r layers before it
                uint m  = (p == 1u) ? R : 0u;
                uint op = (w >> 25) & 3u;
                uint res;
                if (op == 0u)      res = cov | m;      // union
                else if (op == 1u) res = cov & m;      // intersection
                else if (op == 2u) res = cov ^ m;      // exclusion
                else               res = m & ~cov;     // the mask less the coverage
                cov = (cov & ~R) | (res & R);
            }
        }
        if (((w0 >> 18) & 1u) == 1u && u_blink_off && k > 0u)
            cov &= ~(1u << (k - 1u));                  // the topmost layer blinks
        uint l = 0u;
        for (uint i = 0u; i < n; i++) {                // the topmost layer wins
            uint w = word(2 + int(i));
            if (i == 0u || ((types >> (i - 1u)) & 1u) == 0u) {
                if (((cov >> l) & 1u) == 1u)
                    slot = (w >> 25) & 3u;
                l += 1u;
            }
        }
    }
    uvec4 sw = texelFetch(u_swatches, int(w1 & 0xFFFFu));
    int palette_slot = int((w1 >> 16) & 0xFFu);
    if (palette_slot >= u_palette_slots)
        palette_slot = 0;
    frag_color = vec4(texelFetch(u_palettes, palette_slot * 256 + int(sw[slot]))) / 255.0;
}
")
