---
id:            LEXTER-DRAFT-cell-model
title:         "The Cell Model Architecture"
genre:         Architecture
scope:         project
project:       Lexter
language:      en
status:        Draft
provenance:
  assistant:   opencode
  session:     "Cell model revision plan (2026-11-02), the dense cell format"
relates-to:
  - LEXTER-DRAFT-cell-model-revision
  - LEXTER-DRAFT-cell-field-format
  - LEXTER-DRAFT-layer-mechanics
  - LEXTER-DRAFT-data-structures-1e
  - LEXTER-DRAFT-data-structures-1e-critique
  - LEXTER-0004
  - LEXTER-0007
decisions:
  - LEXTER-DRAFT-cell-model-D1
  - LEXTER-DRAFT-cell-model-D2
  - LEXTER-DRAFT-cell-model-D3
  - LEXTER-DRAFT-cell-model-D4
  - LEXTER-DRAFT-cell-model-D5
  - LEXTER-DRAFT-cell-model-D6
  - LEXTER-DRAFT-cell-model-D7
  - LEXTER-DRAFT-cell-model-D8
  - LEXTER-DRAFT-cell-model-D9
  - LEXTER-DRAFT-cell-model-D10
  - LEXTER-DRAFT-cell-model-D11
  - LEXTER-DRAFT-cell-model-D12
open-questions:
  - LEXTER-DRAFT-cell-model-O1
  - LEXTER-DRAFT-cell-model-O2
  - LEXTER-DRAFT-cell-model-O3
  - LEXTER-DRAFT-cell-model-O4
  - LEXTER-DRAFT-cell-model-O5
  - LEXTER-DRAFT-cell-model-O6
  - LEXTER-DRAFT-cell-model-O7
  - LEXTER-DRAFT-cell-model-O8
  - LEXTER-DRAFT-cell-model-O9
cites:
  - title:    "X Logical Font Description Conventions"
    locator:  "X Consortium, XLFD version 1.5, the font properties UNDERLINE_POSITION, UNDERLINE_THICKNESS, STRIKEOUT_ASCENT, and STRIKEOUT_DESCENT"
    external: true
  - title:    "kitty decorations"
    locator:  "kitty source, kitty/decorations.c (underline and strikethrough drawn as sprites)"
    external: true
  - title:    "Nerd Fonts glyph sets"
    locator:  "https://github.com/ryanoasis/nerd-fonts/wiki/Glyph-Sets-and-Code-Points (Pomicons at U+E000-U+E00A)"
    external: true
  - title:    "OpenGL 3.3 core profile specification"
    locator:  "Implementation-dependent limits: MAX_TEXTURE_BUFFER_SIZE at least 65536, MAX_TEXTURE_SIZE at least 1024"
    external: true
---

# The Cell Model Architecture

This document specifies the dense cell record of Lexter's second edition: the
32-byte record that every cell of the composed grid holds, what each of its
bits means, how a renderer turns it into pixels, and the overlay instance
built from it. It refines the layout that
[LEXTER-DRAFT-cell-field-format](Survey.CellFieldFormat.md) proposed, as
[LEXTER-DRAFT-cell-model-revision](Plan.CellModelRevision.md) left it to be
refined. It departs from that layout in five ways: absence is marked by glyph
0 instead of a layer count; a cell whose layer 0 is absent is an escape
cell, whose other words belong to a special kind; the cursor and line
attributes leave the header, the cursor for the overlay list and the lines
for generated glyphs; the palette slot widens to six bits; and an absent
mask has target 0 instead of 3. Nothing here is built. Each part is placed
in the plan's phases under Roadmap.

## Canonical Terms

Table: Terms used in this design, with their definitions.

| Term | Definition |
|---|---|
| Record | The 32 bytes, eight 32-bit words, that describe one cell |
| Header | Word 0, read the same way in every record |
| Layer | One of three display glyphs, 0 to 2, drawn in order, each with an ink slot, a fill slot, and a display selector |
| Mask | One of three mask glyphs, each with an operation, a selector, and a target layer |
| Slot | One of a swatch's four palette indices; slot 0 is the background |
| Swatch | Four palette indices, stored in the swatch store and named by a 16-bit global index |
| Palette slot | The number of one 256-colour palette in the palette store |
| Absent | Of a layer: its glyph is 0. Of a mask: its target is 0 |
| Ordinary cell | A record whose layer 0 is present |
| Payload cell | An ordinary cell whose masks are all absent, so that its tail holds a payload named by its tail type |
| Escape cell | A record whose layer 0 is absent; its escape kind decides what its other words mean |
| Escape kind | The byte, in the top of word 2, that names an escape cell's kind |
| Tail | Words 5 to 7: the mask glyphs, or a payload |
| Generated glyph | A glyph that Lexter draws itself into a reserved atlas position, such as a line or a cursor |
| Line glyph | A generated glyph holding one combination of underline, strikethrough, and overline |
| Overlay instance | A record with a position and flags, drawn by the overlay pass over the grid |
| Void | A payload cell that references a surface, whose uncovered pixels are left undrawn |

## Thesis / Concerns

**Zero means nothing.** A glyph of 0 is an absent layer, a target of 0 an
absent mask, a tail type of 0 an empty tail, and an escape kind of 0 a blank
cell, so a record of zeros is a valid blank cell and every field a writer
does not set reads as absent. **The grid holds static text.** What moves or
lasts a moment, such as a cursor or a link lit by the pointer, is an overlay;
what belongs to the text, such as its underline, is in the record, as a
glyph rather than as bits that only the shader understands.

The design serves these concerns:

- **Exactness.** Every pixel is a selection of one palette entry or inline
  colour, so the GPU and the CPU renderer draw the same bytes
  (LEXTER-DRAFT-cell-model-revision-D15, -D16).
- **Fixed offsets.** Every field sits at a fixed place, so kernels and the
  CPU renderer read cells without branching on their history, and word 0 can
  be read without knowing a cell's kind.
- **Normalisation.** The cell checksum
  (LEXTER-DRAFT-cell-model-revision-D13) takes absent and reserved fields as
  zero; here they are zero by rule.
- **Capacity for later kinds.** Escape kinds and tail types leave room for
  tiles, surfaces, and effects without a new record format.
- **One renderer's rules for two renderers.** The less the shader does that
  is not a lookup, the less the CPU renderer must reproduce.

## Influences

Table: Influences on this design, what each contributes, and what is not
taken from it.

| Influence | Contributes | Not taken |
|---|---|---|
| [LEXTER-DRAFT-cell-field-format](Survey.CellFieldFormat.md) | The record's order: a header, a word of settings, three display glyphs, and a tail; the tail types; tile mode | The layer count, the cursor and line bits in the header, and payloads growing backwards into absent layers |
| [LEXTER-DRAFT-layer-mechanics](Survey.LayerMechanics.md) | The dense record of three layers and three masks, and the mask code | — |
| [LEXTER-DRAFT-cell-model-revision](Plan.CellModelRevision.md) | Mask targets with a selector (LEXTER-DRAFT-cell-model-revision-D7), halves (-D8), the overlay list (-D10), one composed grid (-D12), integer colour stores (-D14), selection without blending (-D15) | Target 3 as the unused mask, which this design makes 0 |
| VGA and MDA text attributes | A cell as a fixed record that the display reads directly | Underline as an attribute bit, which only the display hardware can draw |
| kitty | Underline and strikethrough drawn as generated sprites in its sprite map (*kitty decorations*) | — |
| XLFD font properties | The position and thickness of the underline and the strikeout, which BDF and PCF fonts may carry (*X Logical Font Description Conventions*) | — |
| Zero-initialised memory | Fresh and cleared memory as a valid initial value, as `calloc` and zeroed pages give | — |
| Nerd Fonts | A warning: fonts use the private-use area, including U+E000–E00A (*Nerd Fonts glyph sets*), where Lexter now keys its cursor glyphs | Private-use codepoints for generated glyphs |

## Settled Decisions

### LEXTER-DRAFT-cell-model-D1 — A layer is absent when its glyph is 0, and the record has no layer count

**Status:** Proposed

**Context:** The cell-field-format survey gives the header a two-bit layer
count with three jobs: telling the shader which layers to skip, letting a
payload grow backwards into the display words of absent layers, and freeing
glyph 0 to be an ordinary glyph. The plan's Phase 1 reserves atlas position 0
for an empty glyph (repair of LEXTER-DRAFT-data-structures-1e-critique-O10),
so glyph 0 is no longer needed as an ordinary glyph.

**Decision:** A layer whose display glyph is 0 is absent, and the layer
count is removed. Layers need not be numbered without gaps: layer 1 may be
absent while layer 2 is present. An ordinary cell always has a layer 0; a
blank terminal cell is the space glyph from the atlas, never glyph 0. The
words of absent layers are 0, so payloads do not grow into them; escape
cells (LEXTER-DRAFT-cell-model-D3) take that role. The test of a glyph
against 0 has the same result across a cell, so the shader does not diverge.

**Alternatives:**
- Keep the count. Rejected: its two bits say what a zero test says, and
  growing payloads backwards is better served by escape cells, whose whole
  record belongs to their kind.

### LEXTER-DRAFT-cell-model-D2 — A glyph word holds a 24-bit atlas position and a reserved byte

**Status:** Proposed

**Context:** Words 2 to 7 hold atlas positions. A 32-bit position is far
more than any font needs, and the escape kind needs a place.

**Decision:** In every glyph word, bits 0–23 hold an atlas position and bits
24–31 are reserved and zero, except the top byte of word 2 in an escape cell,
which holds the escape kind (LEXTER-DRAFT-cell-model-D3). Atlas positions are
below 16,777,216.

**Alternatives:**
- Full 32-bit positions, with the escape kind elsewhere. Rejected: the kind
  would take a field from word 1 or the tail that escape kinds want, for
  positions no atlas reaches.
- 16-bit positions. Rejected: a font with full Unicode coverage, wide glyphs
  taking two positions, and generated glyphs can exceed 65,536 positions.

### LEXTER-DRAFT-cell-model-D3 — A cell whose layer 0 is absent is an escape cell, and a record of zeros is blank

**Status:** Proposed

**Context:** Tile graphics, and kinds not yet designed, need more of the
record than a tail. Fresh and cleared memory is all zeros, and allocation,
resizing, and kernels are simpler if zeros are a valid cell.

**Decision:** A record whose word 2 has bits 0–23 equal to 0 is an escape
cell. Its escape kind is bits 24–31 of word 2. Its word 0 keeps the common
layout (LEXTER-DRAFT-cell-model-D5), so that the swatch index, the palette
slot, and the wide bits are read the same way in every record; words 1 and
3–7 belong to the kind.

Table: Escape kinds.

| Kind | Name | Draws |
|---|---|---|
| 0 | Blank | Every pixel in slot 0 of the header's swatch; words 1 and 3–7 are zero |
| 1 | Tiles | LEXTER-DRAFT-cell-model-D10 |
| 2–255 | Reserved | A renderer that meets one draws the cell as blank |

A record of zeros is therefore a blank cell drawn in slot 0 of global swatch
0 in palette slot 0. Global swatch 0 and palette slot 0 must always hold
valid default colours; which table owns swatch 0 is
LEXTER-DRAFT-cell-model-revision-O4.

**Alternatives:**
- Escape kinds that may replace word 0 as well. Rejected by the steward:
  word 0 is read by the wide-pair helpers, row copies, colour animation, the
  cell checksum, and both renderers, which should not first ask what kind a
  cell is.
- Kind 0 as an error. Rejected: zeroed memory would then be invalid, and
  every allocation would need a fill.

### LEXTER-DRAFT-cell-model-D4 — A mask is absent when its target is 0

**Status:** Proposed

**Context:** LEXTER-DRAFT-cell-model-revision-D7 gives each mask a target,
0–2 for the layer it cuts and 3 for unused. Under that encoding a zeroed
word 1 means three union masks on layer 0, each reading a mask glyph, and a
writer that forgets to set the targets of a payload cell has its payload
read as mask glyphs.

**Decision:** Target 0 means the mask is absent, and targets 1–3 cut layers
0–2. When all three targets are 0, the tail holds a payload: bits 0–2 of mask
0's field (its operation and selector) give the tail type, and the same bits
of masks 1 and 2 give six payload bits (LEXTER-DRAFT-cell-model-D9). A zeroed
word 1 is three absent masks, three layers with no fill in slot 0, and an
empty tail. This departs from LEXTER-DRAFT-cell-model-revision-D7 only in the
values of the target.

**Alternatives:**
- Target 3 as unused, as LEXTER-DRAFT-cell-model-revision-D7 has it.
  Rejected: it makes the zero value of word 1 a cell with masks, against the
  thesis that zero means nothing.

### LEXTER-DRAFT-cell-model-D5 — The header holds the swatch, the palette slot, and the wide bits

**Status:** Proposed

**Context:** The cell-field-format survey's header has 29 bits in use: the
swatch index, a two-bit palette slot, the wide bits, two cursor bits, the
layer count, three line bits, and a two-bit line colour slot. The cursor is
drawn by the overlay list (LEXTER-DRAFT-cell-model-revision-D10), the count
is replaced by glyph 0 (LEXTER-DRAFT-cell-model-D1), and lines become glyphs
(LEXTER-DRAFT-cell-model-D6).

**Decision:**

Table: Bits of word 0.

| Bits | Width | Field | Values |
|---|---|---|---|
| 0–15 | 16 | Swatch index | A global index into the swatch store |
| 16–21 | 6 | Palette slot | 0–63 |
| 22 | 1 | Wide | 1 = the cell holds half of a double-width glyph |
| 23 | 1 | Right half | With wide set: 0 = left half, 1 = right half |
| 24–31 | 8 | Reserved | Zero |

The nine bits removed and the three that were spare give the palette slot
four more bits and leave eight reserved.

**Alternatives:**
- Keep the cursor bits for the block style. Rejected: the block cursor copies
  the cell beneath it into an overlay instance
  (LEXTER-DRAFT-cell-model-D12).
- Keep the line bits, drawn by the shader as rules. Rejected for the reasons
  LEXTER-DRAFT-cell-model-D6 gives.

### LEXTER-DRAFT-cell-model-D6 — Lines are glyphs, applied as a mask in the text's colour or as a layer in their own

**Status:** Proposed

**Context:** Underline, strikethrough, and overline belong to the text, not to
a moment, so they belong in the grid. As header bits they cost five bits
with their colour slot, need the shader and the CPU renderer each to draw
rules from the font's metrics, and leave no room for the further underline
styles terminals now support. Heavy use of layers is expected to be rare in
text cells.

**Decision:** A line is drawn by a line glyph (LEXTER-DRAFT-cell-model-D7)
holding the cell's combination of lines, in one of two fixed places:

- **In the text's colour, as mask 2.** Lines that take the colour of the text
  are mask 2, targeting the text's layer, with the line glyph in word 7. When
  the text's layer is drawn with its display selector at 0, the operation is
  union with the mask's inked pixels. When the selector is 1, the text is
  drawn by its uninked pixels, and the operation is intersection with the
  mask's uninked pixels, so that the line shows in the colour the glyph's
  strokes show in. Either way the line costs a mask and no layer.
- **In a colour of its own, as layer 2.** An underline given a colour by SGR
  58 is layer 2, with the line glyph for underline alone, its ink slot
  holding the underline's colour, and no fill. Strikethrough and overline
  stay in the text's colour, as mask 2, so a cell may use both places.
- **Cells with a payload.** A payload cell has no masks, so its lines are
  layer 2, in the text's colour or its own.
- **Reading back.** A cell's lines are read from the glyph of mask 2 when its
  target is not 0 and from the glyph of layer 2, wherever either falls in the
  range of line glyphs. DECCARA, DECRARA, attribute reports, and copying with
  formatting read them this way.
- **Ephemeral lines** are not lines in this sense. A hyperlink underlined
  while the pointer is over it is an overlay instance.

Only the single underline style is defined at first. When the place a line
needs is taken is LEXTER-DRAFT-cell-model-O3.

**Alternatives:**
- Header bits drawn as rules, as the cell-field-format survey proposed.
  Rejected: they spend five header bits, need drawing code in both renderers,
  and have no room for styles.
- Every line as a layer. Not chosen: the common case, an underline in the
  text's colour, would spend a layer where a mask serves.
- Any free mask or layer, found by searching. Rejected: reading lines back,
  and changing them in a rectangle, would scan the record instead of reading
  one place.

### LEXTER-DRAFT-cell-model-D7 — Generated glyphs have reserved atlas positions, and no codepoints

**Status:** Proposed

**Context:** The atlas keys its generated cursor glyphs by the private-use
codepoints U+E000–E002 (`src/atlas.lisp:add-cursor-glyphs@2d4d743`). Fonts
such as Nerd Fonts place real glyphs there, so a host that prints U+E000 can
reach a generated glyph, or a font's glyph can displace one. Line glyphs
need positions that a reader can recognise by a range test.

**Decision:** The atlas reserves positions 0–63 for generated glyphs, which
no codepoint maps to; a font's glyphs begin at position 64.

Table: Reserved atlas positions.

| Positions | Glyphs |
|---|---|
| 0 | The empty glyph (LEXTER-DRAFT-cell-model-D1) |
| 1–7 | Cursor glyphs: 1 full block, 2 underline, 3 bar, 4 outlined block; 5–7 reserved |
| 8–63 | Line glyphs: position 8 + 8 × style + flags |

The flags are bit 0 underline, bit 1 strikethrough, and bit 2 overline, and
are never 0, so positions 8, 16, and so on up to 56 are unused. Style 0 is
the single underline and is the only style defined at first; styles 1–6
are left for others (LEXTER-DRAFT-cell-model-O4). A reader recovers a line
glyph's flags as its position minus 8, modulo 8, and its style as that
difference divided by 8. All generated glyphs are narrow; each half of a
double-width glyph carries its own.

Lines are drawn from the font's XLFD properties `UNDERLINE_POSITION`,
`UNDERLINE_THICKNESS`, `STRIKEOUT_ASCENT`, and `STRIKEOUT_DESCENT` when
the font has them, and from the cell's size otherwise. Whether a font may
supply its own line glyphs is LEXTER-DRAFT-cell-model-O2.

**Alternatives:**
- Keep private-use codepoints. Rejected: they collide with fonts that use
  the private-use area.
- Generated glyphs after the font's, as `add-cursor-glyphs` appends them now.
  Rejected: their positions would depend on the font, and the range test
  would need the font's glyph count.

### LEXTER-DRAFT-cell-model-D8 — A pixel that nothing covers takes slot 0, except in a void

**Status:** Proposed

**Context:** Selection without blending
(LEXTER-DRAFT-cell-model-revision-D15) needs every pixel to end as one slot
or as nothing. Under the fill rule a layer may have no fill, and a cell may
have no layer that covers a given pixel.

**Decision:** A pixel that no present layer covers or fills takes slot 0 of
the cell's swatch, the background. In a void (LEXTER-DRAFT-cell-model-D9),
such a pixel is not drawn, so that the surface beneath shows. The procedure
is given in full under Drawing a Pixel, and both renderers follow it.

**Alternatives:**
- Leave uncovered pixels transparent in every cell. Rejected: an ordinary
  cell would then need a filled layer to have a background at all, and the
  grid's output would depend on what was drawn before it.

### LEXTER-DRAFT-cell-model-D9 — Payload cells have four tail types, and tiles move to escape cells

**Status:** Proposed

**Context:** LEXTER-DRAFT-cell-model-revision-O7 asks which tail types there
are. The cell-field-format survey proposed masks, surface tile, inline
colours, effect, and tiles. Masks are now the case of any target not 0
(LEXTER-DRAFT-cell-model-D4), and tiles need more of the record than a tail.

**Decision:**

Table: Tail types of a payload cell.

| Type | Name | Tail |
|---|---|---|
| 0 | Empty | Words 5–7 are zero |
| 1 | Void | A reference to a surface; uncovered pixels are not drawn |
| 2 | Inline colours | The colours of slots 0–3, three bytes each, in bytes 20–31 |
| 3 | Effect | Reserved for the effects of LEXTER-DRAFT-layer-mechanics-O8 |
| 4–7 | Reserved | A renderer that meets one draws the cell's layers as for type 0 |

In a cell with inline colours, each slot's colour is read from the tail and
neither the swatch store nor the palette is consulted. The void's reference
and the effect's contents are left to the survey of surfaces and effects
(LEXTER-DRAFT-cell-model-O9). Tiles are escape kind 1
(LEXTER-DRAFT-cell-model-D10). The six payload bits are zero in every type
defined so far.

**Alternatives:**
- Tiles as a tail type, as the survey had them. Rejected: a tile cell's
  layers are read differently from an ordinary cell's, which is what escape
  cells are for, and the tail alone is too small for a tile and its four
  swatches together with a second layer.

### LEXTER-DRAFT-cell-model-D10 — Tiles are escape kind 1, with a texture of their own and 256 palettes

**Status:** Proposed

**Context:** The cell-field-format survey sketches tile mode: glyphs whose
pixels are colour indices 0–15, read through four swatches, for tile-based
games, boards, and cards. Indexed glyphs cannot share the font's atlas,
since a one-bit glyph read as indices, or an indexed glyph read as ink,
draws wrongly. A tile set may want palettes of its own.

**Decision:** A tile cell is escape kind 1.

Table: The record of a tile cell.

| Word | Contents |
|---|---|
| 0 | The common header: the swatch for the glyph layer, the palette slot, and the wide bits |
| 1 | Bits 0–23: the tile of layer 0, an index into the tile texture; bits 24–31 reserved |
| 2 | Bits 0–23 zero; bits 24–31 the escape kind, 1 |
| 3 | Bits 0–23: layer 1, an ordinary glyph or a tile as the mode says; bits 24–28 its settings as an ordinary layer's (ink, fill, display selector); bits 29–31 reserved |
| 4 | Reserved |
| 5 | Swatch A, colours 0–3 (bits 0–15); swatch B, colours 4–7 (bits 16–31) |
| 6 | Swatch C, colours 8–11; swatch D, colours 12–15 |
| 7 | Bits 0–1 the mode; bits 2–3 the palette extension; bits 4–31 reserved |

Table: Tile modes.

| Mode | Layer 0 | Layer 1 |
|---|---|---|
| 0 Unified | Indices 0–15 through swatches A–D | An ordinary glyph in the header's swatch, or absent |
| 1 Split | Indices 0–7 through swatches C–D | Indices 0–7 through swatches A–B, over layer 0 |
| 2–3 | Reserved | |

- **Colours.** A pixel's index *i* selects swatch *i* div 4 and slot *i* mod
  4, in palette slot 64 × extension + the header's palette slot. Extension 0
  is the screens' own palettes; slots 64–255 are reached only by tiles.
- **The tile texture.** Tiles are kept in a texture of their own with the
  internal format `R8UI`, one index to a texel, apart from the font's atlas.
  OpenGL 3.3 guarantees a two-dimensional texture of 1024 by 1024 texels,
  which holds 4096 tiles of 16 by 16.
- **Wide tiles.** A 16-by-16 tile in cells of 8 by 16 is a double-width pair:
  both cells hold the tile, with the wide bits set, and each draws its half,
  as glyphs do (LEXTER-DRAFT-cell-model-revision-D8).
- **Two layers.** A tile cell has at most two layers and no masks.
- **Lines and cursors.** A tile cell has no lines; the cursor over one is
  LEXTER-DRAFT-cell-model-O1.

**Alternatives:**
- Indexed glyphs in the font's atlas. Rejected: the atlas would hold two
  readings of a glyph, told apart only by the cell, and its packing would
  depend on the tile set.
- Palettes for tiles only among the screens' 64. Not chosen: a tile set with
  palettes for animation or for regions would crowd out the screens.

### LEXTER-DRAFT-cell-model-D11 — Sixty-four palette slots, allocated to terminals, with each upload recorded by owner

**Status:** Proposed

**Context:** The first edition has four palette slots, set by hand through a
pane's `palette-slot` (`src/panes/vt-pane.lisp:vt-pane@2d4d743`), and the
renderer compares palette generations by slot, whoever produced them
(`src/renderer.lisp:render-state@2d4d743`): the pattern the critique found
for swatches (LEXTER-DRAFT-data-structures-1e-critique-O5). The integer
palette store (LEXTER-DRAFT-cell-model-revision-D14) holds far more than four
palettes. A terminal applies palette changes to its primary and alternate
screens alike (`src/vt-handler.lisp:%handler-screens@2d4d743`).

**Decision:**

- **The store.** The palette store is a texture buffer of its own, with slot
  *s*'s 256 entries beginning at *s* × 256. Its 256 slots, 64 for screens and
  192 for tiles, are 65,536 texels, the size OpenGL 3.3 guarantees.
- **Slot 0** holds the default palette and is never allocated, so that a
  record of zeros draws in valid colours (LEXTER-DRAFT-cell-model-D3).
- **Allocation.** An allocator gives each terminal one of slots 1–63 when it
  is created and takes it back when the terminal goes away, alongside its
  swatch range (LEXTER-DRAFT-cell-model-revision-D4). The primary and
  alternate screens share their terminal's slot.
- **Uploads by owner.** The renderer records, for each slot, the terminal it
  uploaded and that palette's version, and uploads a slot again when either
  differs.
- **A manual override.** A pane may name a slot, so that panes can share one
  palette; the pane that names it does not own it.

What happens when the slots run out, and who owns the tiles' slots, is
LEXTER-DRAFT-cell-model-O6.

**Alternatives:**
- Slots set by hand, as now. Rejected: with 63 slots, choosing them by hand
  invites collisions that the allocator prevents.
- A slot for each screen. Rejected: the primary and alternate screens of a
  terminal hold the same palette, so two slots would hold one palette twice.

### LEXTER-DRAFT-cell-model-D12 — An overlay instance carries a full record, and the block cursor copies the cell beneath it

**Status:** Proposed

**Context:** LEXTER-DRAFT-cell-model-revision-D10 gives each overlay instance
a glyph, up to two masks, a colour, and a position, and
LEXTER-DRAFT-cell-model-revision-O5 asks how the block cursor learns the cell
beneath it. A block cursor that reproduces the cell exactly must draw its
layers, its masks, and its half of a wide glyph.

**Decision:** An overlay instance is 48 bytes: a record, followed by a
position and flags.

Table: The overlay instance, by word.

| Word | Contents |
|---|---|
| 0–7 | A record, read as the grid reads one |
| 8 | Bits 0–15: x; bits 16–31: y; both signed, in cells or pixels |
| 9 | Bit 0: the unit of the position, 0 cells, 1 pixels; bit 1: inverted; bits 2–31 reserved |
| 10–11 | Reserved |

- **The block cursor** is an instance whose record is a copy of the cell
  beneath it, with the inverted flag set. In an inverted instance, a pixel
  that selects slot 0 takes the ink slot of layer 0 instead, and a pixel that
  selects the ink slot of layer 0 takes slot 0. The flush copies the record
  again whenever the cursor moves or its row changes. A cursor on a
  double-width glyph is two instances, one for each half.
- **The other styles** are instances whose layer 0 is a cursor glyph
  (LEXTER-DRAFT-cell-model-D7) in the cursor's colour, with no fill.
- **The pass** decodes the record with the grid's decoder, draws covered and
  filled pixels as the grid does, and discards every other pixel.

This answers LEXTER-DRAFT-cell-model-revision-O5.

**Alternatives:**
- Copy only layer 0's glyph and settings. Rejected: the cursor would drop the
  cell's other layers, its masks, and its lines.
- Keep cursor bits in the header for the block style. Rejected: it writes an
  ephemeral state into the static grid, which
  LEXTER-DRAFT-cell-model-revision-D10 keeps apart.

## The Record

Table: The record, by word.

| Word | Ordinary cell | Escape cell |
|---|---|---|
| 0 | Header | Header |
| 1 | Layer settings and mask fields | The kind's |
| 2 | Layer 0's display glyph, never 0 | Bits 0–23 zero; the escape kind |
| 3 | Layer 1's display glyph, or 0 | The kind's |
| 4 | Layer 2's display glyph, or 0 | The kind's |
| 5–7 | Mask glyphs 0–2, or a payload | The kind's |

The header and word 1 are the first eight bytes, so a kernel reads or
changes what kind of cell a record is with one 64-bit operation. Records are
stored row by row in the grid's array, which is the upload buffer.

### Word 1 in an ordinary cell

Table: Bits of word 1.

| Bits | Width | Field |
|---|---|---|
| 0–4 | 5 | Layer 0: ink slot (2), fill slot (2), display selector (1) |
| 5–9 | 5 | Layer 1, the same |
| 10–14 | 5 | Layer 2, the same |
| 15–19 | 5 | Mask 0: operation (2), selector (1), target (2) |
| 20–24 | 5 | Mask 1, the same |
| 25–29 | 5 | Mask 2, the same |
| 30–31 | 2 | Reserved |

A layer's fill slot equal to its ink slot means the layer has no fill. A
mask's target is 0 for absent and 1–3 for layers 0–2
(LEXTER-DRAFT-cell-model-D4); its operations are those of
LEXTER-DRAFT-cell-model-revision-D7.

Table: Mask operations.

| Operation | Coverage after the mask |
|---|---|
| 0 Union | Coverage or the mask's pixel |
| 1 Intersection | Coverage and the mask's pixel |
| 2 Exclusion | Coverage or the mask's pixel, but not both |
| 3 Mask less coverage | The mask's pixel and not the coverage |

The mask's pixel is its glyph's inked pixel when the selector is 0 and its
uninked pixel when the selector is 1. When all three targets are 0, bits
15–17 hold the tail type and bits 20–22 and 25–27 the six payload bits.

### Invariants of a record

Writers keep these, and the cell checksum relies on them:

- Every reserved bit is zero.
- The glyph word of an absent layer is zero, and so is the glyph word of an
  absent mask when another mask is present.
- In a payload cell, the tail holds exactly what its type defines, and the
  rest of words 5–7 is zero.
- In an escape cell, every word that the kind does not define is zero.
- The two halves of a double-width glyph are written and erased together,
  with the wide bit in both and the right-half bit in the second.

## Drawing a Pixel

Both renderers follow this procedure for each pixel of a cell. Every test is
on integers, and the result is one colour, or no pixel.

```
// word(n) is word n of the record; glyph(l) is word(2 + l) & 0xFFFFFF,
// the display glyph of layer l; mask_glyph(m) is word(5 + m) & 0xFFFFFF
if glyph(0) == 0:                               // escape cell
    draw by kind (word(2) >> 24); unknown kinds draw as kind 0
    return
slot = BACKGROUND (slot 0), or NOTHING if the cell is a void
for l in 0, 1, 2:
    if glyph(l) == 0: continue                  // absent layer
    cov = display_pixel(l) != display_selector(l)
    for m in 0, 1, 2:
        if target(m) == l + 1:
            cov = apply(op(m), cov, mask_pixel(m) != mask_selector(m))
    if cov:                        slot = ink(l)
    else if fill(l) != ink(l):     slot = fill(l)
if slot == NOTHING: discard
colour = inline colours ? tail_colour(slot)
       : palette[palette_slot * 256 + swatch[swatch_index][slot]]
```

Description: The procedure first tests whether the cell is an escape cell
and, if so, draws it by its kind. Otherwise it starts from the background
slot, or from nothing in a void, and visits the three layers in order,
skipping absent ones. For each layer it finds whether the layer's display
glyph covers the pixel, applies each mask that targets the layer in mask
order, and then sets the slot to the layer's ink slot if the pixel is
covered, or to its fill slot if the layer has a fill. A later layer
therefore overrides an earlier one. Finally it discards the pixel if no slot
was chosen in a void, and otherwise looks the slot up in the inline colours
or in the swatch and palette.

The right half of a double-width glyph samples the second of the glyph's two
atlas columns. The colour is written as bytes, divided by 255 on the GPU,
without blending (LEXTER-DRAFT-cell-model-revision-D15).

## Palettes and Swatches

- **The swatch store** is a texture buffer of 65,536 swatches, `RGBA8UI`,
  each holding four palette indices; slot 0 is the background by convention,
  and slot 1 the foreground, as the first edition reads them
  (`src/shaders.lisp:+simple-frag+@2d4d743`).
- **The palette store** is a texture buffer of 256 palettes of 256 colours,
  `RGBA8UI` (LEXTER-DRAFT-cell-model-D11).
- **Palette slots.** An ordinary or payload cell draws in the header's
  palette slot, 0–63; a tile reaches slots 64–255 through its extension
  (LEXTER-DRAFT-cell-model-D10).
- **What the checksum hashes.** The cell checksum hashes the contents of
  every palette slot that a cell, including a tile's extension, selects
  (LEXTER-DRAFT-cell-model-revision-D13).

## Lines and Cursors

Table: How a cell's lines are placed.

| Lines | Place | Glyph |
|---|---|---|
| Any combination in the text's colour | Mask 2 on the text's layer | The combination's line glyph |
| An underline with an SGR 58 colour | Layer 2, no fill, ink slot holding the colour | The underline alone |
| Strikethrough or overline beside a coloured underline | Mask 2 | Their combination, without the underline |
| Any lines in a payload cell | Layer 2 | The combination's line glyph |

Table: Where each cursor and pointer effect is drawn.

| Effect | Drawn by |
|---|---|
| Block cursor | An inverted overlay instance copying the cell (LEXTER-DRAFT-cell-model-D12) |
| Underline and bar cursors | An overlay instance with a cursor glyph |
| A hyperlink lit by the pointer | An overlay instance with an underline glyph |

## Open Questions

### LEXTER-DRAFT-cell-model-O1 — How is the cursor drawn over an escape cell?

Inverting slots means nothing for a tile, whose layer 0 has no ink slot. The
cursor could be the outlined block glyph over such a cell, or each escape
kind could define how it is inverted. Blank escape cells can invert slot 0
and slot 1.

### LEXTER-DRAFT-cell-model-O2 — May a font supply its own line glyphs?

Generated lines follow the font's XLFD properties where it has them. A font
may also draw its own underline as a combining mark, such as U+0332, but such
marks are drawn as marks, not as rules across the cell. Whether a
configuration can choose a font's glyphs for some lines is open; the default
is to generate them.

### LEXTER-DRAFT-cell-model-O3 — What happens when the place a line needs is taken?

A cell whose mask 2 is in use by something other than lines, or whose layer
2 is taken, has no room for its lines. The line could take precedence and
move the other content, or be dropped. Such cells are expected to be rare.

### LEXTER-DRAFT-cell-model-O4 — Which further underline styles are defined, and how do their patterns meet?

Double, curly, dotted, and dashed underlines (SGR 4:2–4:5, and 21) fit
styles 1–6. A curly or dashed pattern must line up from cell to cell, so its
period must divide the cell's width, or each boundary shows a seam. How the
generator chooses a period for each cell width is open.

### LEXTER-DRAFT-cell-model-O5 — What do the reserved bits hold?

The header has eight and word 1 two. The top byte of each glyph word is
reserved too: words 2–4 in every ordinary cell, and words 5–7 when the tail
holds masks. The one remaining candidate from the cell-field-format
survey is the protected-cell bit of DECSCA
(LEXTER-DRAFT-cell-field-format-O7), which only the CPU reads and so could
also live beside the grid.

### LEXTER-DRAFT-cell-model-O6 — What happens when palette slots run out, and who owns the tiles' slots?

A 64th terminal finds no free slot among 1–63; it could share the default
palette, or a slot already in use. Slots 64–255 belong to tile sets, which
need an owner and a lifetime of their own.

### LEXTER-DRAFT-cell-model-O7 — Is index 0 of a tile transparent, and which cell sizes do tiles support?

These are LEXTER-DRAFT-cell-field-format-O1 and -O2, carried here unchanged
for tile cells: the arcade convention of a transparent colour 0, and how
tiles fit cells other than 8 by 16.

### LEXTER-DRAFT-cell-model-O8 — How does a mask apply to a wide display glyph?

It is LEXTER-DRAFT-cell-model-revision-O6. Line glyphs are narrow and are
applied to each half's cell as they are, so whichever rule is chosen must
let a narrow mask apply to one half.

### LEXTER-DRAFT-cell-model-O9 — What do the void and effect tail types carry?

The cell-field-format survey's surface tile, a surface id and a column and
row within the surface, is the candidate for the void; the effect's contents
are LEXTER-DRAFT-layer-mechanics-O8. Both are left to the survey of surfaces
and effects that LEXTER-DRAFT-cell-model-revision-D12 calls for.

## Roadmap

1. **With the plan's Phase 1.** The atlas reserves positions 0–63, and the
   cursor glyphs move from private-use codepoints to positions 1–4
   (LEXTER-DRAFT-cell-model-D7).
2. **With the plan's Phase 2.** The palette store is sized for 256 slots
   (LEXTER-DRAFT-cell-model-D11), with the integer stores of
   LEXTER-DRAFT-cell-model-revision-D14.
3. **With the plan's Phase 3.** The record as specified here: the header,
   word 1 with absent masks at target 0, glyph words of 24 bits, absence by
   glyph 0, escape kind 0, payload tail type 0, lines as glyphs with the
   single underline, the procedure of Drawing a Pixel in the shader, and
   palette slots allocated to terminals. The descriptor of
   LEXTER-DRAFT-cell-model-revision-D9 is written from these tables.
4. **With the plan's Phase 4.** The overlay instance and the block cursor's
   copy (LEXTER-DRAFT-cell-model-D12), after
   LEXTER-DRAFT-cell-model-O1 is settled.
5. **With the plan's Phase 5.** The CPU renderer follows the same procedure.
6. **Later.** Inline colours; tiles, after LEXTER-DRAFT-cell-model-O6 and -O7;
   the void and effects, after the survey of surfaces; further underline
   styles, after LEXTER-DRAFT-cell-model-O4.
7. **The second edition specified.** Spec.DataStructures2e takes its record
   from this document.

## Appendices

### Worked records

Table: A record of zeros.

| Field | Value | Meaning |
|---|---|---|
| Word 2 | 0 | An escape cell of kind 0 |
| Word 0 | 0 | Swatch 0, palette slot 0, not wide |
| Result | — | A blank cell in the default background |

Table: The letter g, underlined in the text's colour.

| Field | Value |
|---|---|
| Word 0 | The pane's swatch *s* (slot 0 background, slot 1 foreground) and palette slot *p* |
| Word 1, layer 0 | Ink slot 1, fill slot 0, selector 0 |
| Word 1, masks 0 and 1 | Target 0 (absent) |
| Word 1, mask 2 | Union, selector 0, target 1 (layer 0) |
| Word 2 | The atlas position of g |
| Words 3–6 | 0 |
| Word 7 | 9, the line glyph for underline (8 + 0 + 1) |

Table: The letter g with an SGR 58 red underline and a strikethrough.

| Field | Value |
|---|---|
| Word 0 | A swatch whose slot 2 holds red |
| Word 1, layer 0 | Ink slot 1, fill slot 0, selector 0 |
| Word 1, layer 2 | Ink slot 2, fill slot 2 (no fill), selector 0 |
| Word 1, mask 2 | Union, selector 0, target 1 |
| Word 2 | The atlas position of g |
| Word 4 | 9, the underline |
| Word 7 | 10, the strikethrough (8 + 0 + 2) |

Table: A block cursor over the underlined g.

| Field | Value |
|---|---|
| Words 0–7 | A copy of the underlined g's record |
| Word 8 | The cell's column and row |
| Word 9 | Unit 0 (cells), inverted |
| Result | The background drawn in slot 1's colour, and the g and its underline in slot 0's |

Table: The left half of a 16-by-16 tile in cells of 8 by 16.

| Field | Value |
|---|---|
| Word 0 | Swatch for the glyph layer, palette slot *p*, wide 1, right half 0 |
| Word 1 | The tile's index in the tile texture |
| Word 2 | Kind 1 in bits 24–31 |
| Word 3 | 0, no second layer |
| Words 5–6 | Swatches A–D |
| Word 7 | Mode 0, extension 1: palettes from slot 64 + *p* |
