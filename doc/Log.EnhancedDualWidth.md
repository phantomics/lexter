# Enhanced Dual-Width Font Support: Development Log

This document chronicles the work that let Lexter render genuinely dual-width
bitmap fonts -- fonts that mix narrow (half-width) ASCII glyphs with full-width
CJK glyphs in one file, the canonical example being GNU Unifont. It covers
three connected pieces: separating a PCF font's storage raster width from its
terminal cell width, adding wide-aware bitmap extraction to the PCF loader, and
reshaping the glyph atlas so a 57,000-glyph font does not overflow the GPU's
maximum texture size. It also folds in two small precursor fixes uncovered along
the way.

**Date:** 2026-06-06


## Problem

Lexter already had the *machinery* for double-width glyphs -- the atlas packs
wide glyphs into two columns, `atlas-glyph-wide-p` drives a double-width cursor
advance, and the BDF CJK demo (zpix) exercised the whole path. But loading
Unifont (`unifont-17.0.04.pcf`, ~57k glyphs, 8x16 narrow / 16x16 full) failed
in three distinct ways:

1. **Everything rendered double-width.** `run-paned-terminal` with Unifont drew
   every character -- Latin included -- at full width.
2. **Symbols looked subtly wider than letters.** `$ % &` appeared a touch wider
   than `M`/`a`.
3. **It eventually crashed** with `OpenGL signalled (1281 . INVALID-VALUE) from
   TEX-IMAGE-2D` when the atlas was built.

Two earlier, smaller bugs in the PCF loader were also surfaced and fixed while
investigating narrow fonts (see *Precursor fixes* below).


## Investigation

Direct inspection of the font (loading it and dumping glyph bitmaps and raw
PCF metrics) was decisive at every step.

**The two-width insight.** The PCF loader had been using a single `cell-width`
for everything, derived from glyph 0's advance. In Unifont, glyph 0 is a
full-width glyph (`w=16`), so `cell-width` became 16 -- every narrow glyph was
laid into a 16-px cell (double-width), and the wide test `:w > cell-width`
(`16 > 16`) never fired, so not even CJK was flagged wide
(`wide-glyph-count = 0`).

Dumping raw metrics for representative glyphs made the structure plain:

```
glyph0  w=16  rb-lb=16     (full-width)
M a i $ &  w=8  rb-lb=8 lb=0  (narrow ASCII)
U+4E00  w=16 rb-lb=16        (full-width CJK)
```

So there are genuinely **two widths** the loader had conflated:

- **storage width** -- the glyph bitmap raster width in the file, used for the
  row stride (16 for Unifont, 9 for a monospace font like haxor);
- **cell width** -- the terminal's narrow "half" cell (8 for Unifont, 9 for
  haxor).

They are equal for monospace fonts -- which is exactly why the conflation had
never mattered -- and differ only for dual-width fonts.

The `$%&` observation was a red herring: those glyphs have the same `w=8`
advance as the letters; their ink simply uses the full 8 px (columns 0-7) while
`M` reaches column 6. A 1-px design difference, not a spacing bug.

**The atlas overflow.** `build-atlas` hard-capped the atlas at 32 columns. With
~107k column slots (counting double-wide CJK), 32 columns forced a texture
**256 x 53,456 px** -- thousands of pixels past any GPU's `GL_MAX_TEXTURE_SIZE`,
hence the `INVALID_VALUE` from `glTexImage2D`.


## Design Decisions

### 1. Separate storage width from cell width

The PCF loader now computes both. `storage-width = (or glyph0-width
accel-max-w)` (the file's raster width, used for the row stride -- unchanged
source). `cell-width` is the narrow terminal cell, determined independently.
For monospace fonts the two are equal, so behavior is byte-for-byte identical;
they diverge only for dual-width fonts. This was the key conceptual move that
unblocked everything else.

### 2. A manual override first, auto-detection second

The work was staged deliberately. **First**, `load-pcf` gained `:cell-width`
and `:cell-height` keyword overrides (parity with `load-bdf`), so a user could
force `(load-pcf "unifont.pcf" :cell-width 8 :cell-height 16)` and test the
rendering path before committing to any heuristic. **Then**, once that was
confirmed working in a live terminal, auto-detection was added so the override
becomes unnecessary. This kept each step independently testable and low-risk.

### 3. Auto-detect cell width from a representative ASCII glyph

This is how real terminals size a cell: from a reference glyph, not from the
font's max width. `%detect-cell-width` looks up the advance of a set of
representative narrow ASCII codepoints (`M n x m i 0 l A a`) via the encodings
table and takes the **minimum** advance among those present. Rationale:

- No ASCII letter/digit is ever double-wide, so the minimum can't be inflated
  by a full-width glyph.
- The minimum is robust against a font that happens to draw one reference glyph
  slightly wider.
- If none of the reference glyphs exist (a CJK-only font), it falls back to
  `storage-width` -- the previous behavior.

For Unifont this yields 8; for monospace fonts it yields the cell width
(identical to the old glyph-0 logic). Implementing this required parsing the
encodings table *before* computing the cell width (it was previously parsed
after the bitmaps) -- a small reorder of independent table seeks.

The override still wins when supplied, so the order is: explicit override ->
reference-glyph detection -> storage-width fallback.

### 4. Wide-aware bitmap extraction in the PCF loader

Detecting the right cell width is not enough: with `cell-width=8`, the extractor
also has to (a) read each row at the file's 16-px storage stride and (b) emit
full-width glyphs at `2*cell-width` so CJK is not truncated. The BDF path
already did this (it renders wide glyphs into `2*cell-width`); the PCF path did
not. `%parse-bitmaps` now, per glyph: takes the row stride from `storage-width`,
computes `out-width = (if (> advance cell-width) (* 2 cell-width) cell-width)`,
and extracts `out-width` columns. `%extract-bitmap-positioned`'s width parameter
was renamed `out-width` to make the output-width / row-stride distinction
explicit. The wide-glyph set (still built from `:w > cell-width`) now matches
the doubled bitmaps, and the existing atlas wide-packing consumes them
unchanged.

### 5. Reshape the atlas to a roughly-square, limit-bounded layout

The fixed 32-column atlas was replaced with a layout chosen so the texture is
roughly square and fits the GPU limit:

- `slot-count` counts column slots (a double-wide glyph occupies two);
- `square-cols = ceil(sqrt(slot-count * cell-h / cell-w))`, floored at 32 so
  small fonts behave as before, and capped at `floor(GL_MAX_TEXTURE_SIZE /
  cell-w)`;
- a fast, descriptive error fires if even a square layout would exceed the
  limit, replacing the cryptic GL error.

For Unifont this produces **3704 x 3696 px**, comfortably within the 4096
minimum that GL 3.3 guarantees. Monospace fonts keep ~32 columns, so their
atlas is unchanged.

A performance question was raised and settled here: does a non-power-of-two
column count cost more to index? No. The `atlas-pos -> (col, row)` decode is in
the **vertex shader** (`int gc = i_glyph % u_atlas_size.x; ...`), `u_atlas_size`
is a **uniform**, so the GLSL compiler could not strength-reduce `% 32` to a
mask even at 32 columns -- a general integer division was already being used.
The decode is GPU-side and per-vertex (a few thousand divisions per frame),
not on any CPU hot path, so 32 vs 463 columns is immaterial. (If it ever
mattered, the fix would be to bake the column count as a shader `#define`
constant, not to keep a power-of-two atlas.)


## Implementation

### `src/pcf.lisp`

- `load-pcf` gained `&key cell-width cell-height`, threaded into `%parse-pcf`
  (both the plain and `.gz` paths).
- `%parse-pcf` now parses the encodings table up front, computes
  `storage-width` and `cell-width` (override -> `%detect-cell-width` ->
  `storage-width`) separately, and passes both to `%parse-bitmaps`.
- `%detect-cell-width` + `+cell-width-reference-codepoints+` implement the
  reference-ASCII-glyph heuristic.
- `%parse-bitmaps` is wide-aware: storage-width row stride, per-glyph
  `out-width`, double-wide extraction.
- `%extract-bitmap-positioned`'s width parameter renamed to `out-width`.

### `src/atlas.lisp`

- `build-atlas` replaces the fixed 32-column cap with the square,
  limit-bounded `atlas-cols` computation, plus a descriptive over-limit error.

### No changes elsewhere

The atlas wide-glyph packing, the double-width cursor advance, the vertex
shader's UV decode, and the screen/VT pipeline were all already in place from
the CJK BDF demo and needed no modification.


## Precursor fixes (uncovered while testing narrow fonts)

These two PCF-loader bugs predate the dual-width work but were found and fixed
on the way, and the dual-width rendering depends on them being correct:

- **Vertical over-read.** `%parse-bitmaps` computed a glyph's row count as
  `(+ (abs asc) (abs dsc))`. For glyphs sitting above the baseline (negative
  descent: `~`, backtick, `-`) this overcounted and pulled rows from the *next*
  glyph into the bottom of the current one -- visible as a stacked second glyph
  on high-sitting characters (and harmlessly clipped on low ones). Fixed to the
  signed `(max 0 (+ asc dsc))`.
- **Cursor glyph keyword.** The 3270 pane looked up the block cursor with the
  keyword `:cursor-block` instead of the codepoint constant
  `+cursor-block-glyph+`, so the lookup returned NIL and no cursor drew. (Listed
  here for completeness; fixed in the 3270 work.)


## Verification

All checks are headless (font loading, metric/bitmap inspection, and atlas
dimension arithmetic); live on-screen confirmation was the user's, who
confirmed Unifont now renders correctly in `run-paned-terminal`.

- **Auto-detect:** `(load-pcf "unifont-17.0.04.pcf")` with no override yields
  `cell-width=8`, 49,804 wide glyphs; `M` renders at width 8 (single), `U+4E00`
  is wide -- identical to passing `:cell-width 8`.
- **Override:** `:cell-width 8` gives the same result.
- **No monospace regression:** haxor auto-detects `cell-width=9`, 0 wide glyphs
  -- unchanged from before.
- **Atlas sizing:** old layout `256 x 53,456` (over limit) vs new `3704 x 3696`
  (fits 4096/8192/16384).
- Clean compile/load of `lexter`, `lexter/unix`, `lexter/panes`.


## Files

| File | Action | Description |
|------|--------|-------------|
| `src/pcf.lisp` | Modified | storage-width/cell-width split; `load-pcf` overrides; `%detect-cell-width` + reference codepoints; wide-aware `%parse-bitmaps`; `%extract-bitmap-positioned` param rename |
| `src/atlas.lisp` | Modified | square, `GL_MAX_TEXTURE_SIZE`-bounded atlas layout; over-limit error |


## Outstanding Work

- **On-demand / paged glyph atlasing.** Atlasing all of Unifont builds a
  ~13.7 MB R8 texture (3704 x 3696) on every run. It works, but a font large
  enough to exceed `GL_MAX_TEXTURE_SIZE` even when square would now raise a
  clear error rather than render. The general solution is to atlas glyphs on
  demand (only those actually used) or to page the atlas across multiple
  textures -- the right next step if large fonts or low startup cost become a
  priority.
- **Proportional / non-dual-width fonts.** The cell-width heuristic assumes a
  terminal font (monospace or strictly dual-width), where ASCII shares one
  advance. A genuinely proportional bitmap font is out of scope and would need
  a different model.
- **Shader-constant atlas columns.** If the per-vertex atlas decode ever shows
  up in a profile, baking the column count as a shader `#define` (recompiling
  the shader per atlas) would let the GLSL compiler strength-reduce the
  division. Not currently worth it.
