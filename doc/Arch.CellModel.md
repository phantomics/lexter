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
  - LEXTER-DRAFT-cell-model-D13
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
    locator:  "https://github.com/ryanoasis/nerd-fonts/wiki/Glyph-Sets-and-Code-Points (Pomicons at U+E000-U+E00A, progress indicators at U+EE00-U+EE0B, Material Design Icons at U+F0001-U+F1AF0)"
    external: true
  - title:    "OpenGL 3.3 core profile specification"
    locator:  "Implementation-dependent limits: MAX_TEXTURE_BUFFER_SIZE at least 65536, MAX_TEXTURE_SIZE at least 1024"
    external: true
  - title:    "OpenGL Shading Language 3.30 specification"
    locator:  "Section 8.7, texture lookup functions: implicit derivatives are undefined in non-uniform control flow; texelFetch takes no derivatives"
    external: true
---

# The Cell Model Architecture

This document specifies the dense cell record of Lexter's second edition: the
32-byte record that every cell of the composed grid holds, what each of its
bits means, how a renderer turns it into pixels, and the overlay instance
built from it. It refines the layout that
[LEXTER-DRAFT-cell-field-format](Survey.CellFieldFormat.md) proposed, as
[LEXTER-DRAFT-cell-model-revision](Plan.CellModelRevision.md) left it to be
refined. The record begins with a kind word that says what the cell is, then
a header that every kind reads the same way. Cells of the glyph kinds hold a
variable number of layers and masks, each in a word of its own that carries
its glyph and its settings, with their counts in the kind word. The cursor
and line attributes leave the header, the cursor for the overlay list and
the lines for generated glyphs, and the palette slot widens to six bits.
Nothing here is built. Each part is placed in the plan's phases under
Roadmap.

## Canonical Terms

Table: Terms used in this design, with their definitions.

| Term | Definition |
|---|---|
| Record | The 32 bytes, eight 32-bit words, that describe one cell |
| Kind word | Word 0; its first byte is the kind, and the rest is defined by the kind |
| Kind | The cell's kind, which decides what words 0 (after its first byte) and 2–7 mean |
| Header | Word 1, read the same way in every record |
| Glyph kind | A kind whose cells hold layers and masks in glyph words: plain, void, and inline colours |
| Glyph word | A word holding a 24-bit glyph and a settings byte, as a layer or as a mask |
| Layer | A display glyph with an ink slot, a fill slot, a fill-on bit, and a display selector, drawn in order |
| Mask | A mask glyph with an operation, a selector, and the index of the layer it cuts |
| Layer count, mask count | The numbers of layers and masks in a cell of a glyph kind, given in its kind word |
| Slot | One of a swatch's four palette indices; slot 0 is the background |
| Swatch | Four palette indices, stored in the swatch store and named by a 16-bit global index |
| Palette slot | The number of one 256-colour palette in the palette store |
| Payload | The words after a cell's glyph words that its kind defines, such as inline colours |
| Generated glyph | A glyph that Lexter draws itself into a reserved atlas position, such as a line or a cursor |
| Line glyph | A generated glyph holding one combination of underline, strikethrough, and overline |
| Overlay instance | A record with a position and flags, drawn by the overlay pass over the grid |
| Void | A cell of the void kind, which references a surface and leaves its uncovered pixels undrawn |

## Thesis / Concerns

**Every word has one job.** The kind word says what the cell is, the header
what colours it draws in, and each glyph word one glyph and how it is drawn.
A layer is one word, so it is moved, copied, or reordered as one word.
**Zero means nothing.** A kind of 0 with counts of 0 is a blank cell, a
fill-on bit of 0 is no fill, and a record of zeros is a valid blank cell.
**The grid holds static text.** What moves or lasts a moment, such as a
cursor or a link lit by the pointer, is an overlay; what belongs to the text,
such as its underline, is in the record, as a glyph rather than as bits that
only the shader understands.

The design serves these concerns:

- **Exactness.** Every pixel is a selection of one palette entry or inline
  colour, so the GPU and the CPU renderer draw the same bytes
  (LEXTER-DRAFT-cell-model-revision-D15, -D16).
- **Uniformity.** One namespace of kinds, one rule for where layers and
  masks are, and settings that travel with their glyph, so that writers and
  readers handle no special structures.
- **Fixed offsets.** The kind, the counts, and the header sit at fixed
  places, so a reader learns a cell's shape from its first eight bytes.
- **Normalisation.** The cell checksum
  (LEXTER-DRAFT-cell-model-revision-D13) takes unused and reserved fields as
  zero; here they are zero by rule.
- **Capacity for later kinds.** The kind byte has room for tiles, surfaces,
  effects, and kinds not yet imagined, without a new record format.
- **Two renderers, one procedure.** The less the shader does that is not a
  lookup, the less the CPU renderer must reproduce.

## Influences

Table: Influences on this design, what each contributes, and what is not
taken from it.

| Influence | Contributes | Not taken |
|---|---|---|
| [LEXTER-DRAFT-cell-field-format](Survey.CellFieldFormat.md) | A 32-byte record of control words, glyphs, and a tail; inline colours, surfaces, and tile mode | The fixed three layers and three masks, the layer count and the cursor and line bits in the header, the tail type, payloads growing backwards into absent layers, and the fill rule |
| [LEXTER-DRAFT-layer-mechanics](Survey.LayerMechanics.md) | Layers and masks in one dense record, and the mask code | — |
| [LEXTER-DRAFT-cell-model-revision](Plan.CellModelRevision.md) | Masks with targets and a selector (LEXTER-DRAFT-cell-model-revision-D7), halves (-D8), the overlay list (-D10), one composed grid (-D12), integer colour stores (-D14), selection without blending (-D15) | The fixed layout of word 1 that LEXTER-DRAFT-cell-model-revision-D7 gives, with the tail type folded into unused masks |
| VGA and MDA text attributes | A cell as a fixed record that the display reads directly | Underline as an attribute bit, which only the display hardware can draw |
| kitty | Underline and strikethrough drawn as generated sprites in its sprite map (*kitty decorations*) | — |
| XLFD font properties | The position and thickness of the underline and the strikeout, which BDF and PCF fonts may carry (*X Logical Font Description Conventions*) | — |
| Zero-initialised memory | Fresh and cleared memory as a valid initial value, as `calloc` and zeroed pages give | — |
| Nerd Fonts | A warning: fonts use the private-use areas of the Basic Multilingual Plane and of plane 15 (*Nerd Fonts glyph sets*), where Lexter now keys its cursor glyphs | Private-use codepoints for generated glyphs |

## Settled Decisions

### LEXTER-DRAFT-cell-model-D1 — Word 0 is the kind word, of which only the first byte is fixed, and word 1 is the header

**Status:** Proposed

**Context:** The cell-field-format survey opens the record with a header and
a word of layer settings, and finds a cell's kind from a tail type in the
settings word. With each glyph's settings in its own word
(LEXTER-DRAFT-cell-model-D4), the second word is free to say what the cell
is.

**Decision:** Word 0 is the kind word. Its bits 0–7 are the kind, and that
byte is the only part of the word fixed for every kind; bits 8–31 are
defined by the kind, and are zero where it defines nothing. Word 1 is the
header (LEXTER-DRAFT-cell-model-D7), and it is read the same way in every
record, whatever its kind: no kind may redefine it. The first eight bytes
therefore say what a cell is and what colours it draws in, and a kernel
reads or changes both with one 64-bit operation.

**Alternatives:**
- The header first and the kind second. Not chosen by the steward: the
  record reads more naturally as what the cell is, then everything else, and
  a dump shows the kind in its first byte. Neither order costs the GPU or
  SIMD anything, since a record is fetched whole.
- Kinds that may redefine the header. Rejected: the header is read by the
  wide-pair helpers, row copies, colour animation, the cell checksum, and
  both renderers, which should not first ask what kind a cell is.

### LEXTER-DRAFT-cell-model-D2 — One namespace of kinds names every cell

**Status:** Proposed

**Context:** Earlier drafts had two mechanisms for special cells: a tail
type found in the bits of unused masks, and escape cells marked by an absent
layer 0. Each needed its own test, and the tail type's place depended on
four fields.

**Decision:** The kind byte names every cell, in one namespace.

Table: Kinds.

| Kind | Name | Counts | Glyph words | After the glyph words |
|---|---|---|---|---|
| 0 | Plain | Yes | Words 2–7, up to six | Nothing |
| 1 | Void | Yes | Words 2–4, up to three | A reference to a surface in words 5–7; uncovered pixels are not drawn |
| 2 | Inline colours | Yes | Words 2–4, up to three | The colours of slots 0–3, three bytes each, in bytes 20–31 |
| 3 | Effect | — | — | Reserved for the effects of LEXTER-DRAFT-layer-mechanics-O8 |
| 4 | Tiles | No | — | LEXTER-DRAFT-cell-model-D11 |
| 5–255 | Reserved | — | — | — |

A renderer that meets a kind it does not know draws the cell as blank, in
slot 0 of the header's swatch. In a cell with inline colours, each slot's
colour is read from the payload, and neither the swatch store nor the
palette is consulted. The void's reference and the effect's contents are
LEXTER-DRAFT-cell-model-O9.

**Alternatives:**
- Escape cells beside tail types. Rejected: two kinds of special cell, found
  by two tests, where one byte serves.
- The tail type in the bits of unused masks, as
  LEXTER-DRAFT-cell-model-revision-D7 has it. Rejected: finding it depends on
  four fields, and it limits kinds to eight.

### LEXTER-DRAFT-cell-model-D3 — A glyph kind gives its layer and mask counts in the kind word, and they are authoritative

**Status:** Proposed

**Context:** A cell of a glyph kind holds some layers and some masks. Their
number could be found from glyphs of 0, but a zero glyph is not a neutral
mask under every operation, since intersection with the empty glyph clears a
layer, and a blank cell would then fetch glyphs only to find them empty.

**Decision:** In a glyph kind, bits 8–10 of the kind word are the layer
count, 0–4, and bits 11–13 the mask count, 0 to the glyph words left after
the layers. Bits 14–31 are reserved. The counts are authoritative: the
layers are the first glyph words and the masks the next, glyph words beyond
them are zero, and a glyph of 0 inside them is the empty glyph, which draws
nothing. Kinds that are not glyph kinds need have no counts; only the kind
byte is common to all.

A record of zeros is a plain cell with no layers and no masks: every pixel
takes slot 0 of global swatch 0 in palette slot 0
(LEXTER-DRAFT-cell-model-D10). Global swatch 0 and palette slot 0 must
always hold valid default colours; which table owns swatch 0 is
LEXTER-DRAFT-cell-model-revision-O4.

Writers never produce a layer count above 4 or counts that exceed the kind's
glyph words. Renderers still clamp the counts to those limits, so that a bad
record cannot index past the shader's coverage.

**Alternatives:**
- Two-bit counts of one more than the field. Rejected: they cannot say
  "none", so absence would return as glyph 0, a blank cell would fetch a
  layer and a mask, and a mask of glyph 0 would be neutral only under union.
- Counts found from glyphs of 0, with no count fields. Rejected for the same
  reasons, and because reading lines back would need a scan.

### LEXTER-DRAFT-cell-model-D4 — Each glyph word holds a 24-bit glyph and its own settings byte

**Status:** Proposed

**Context:** The cell-field-format survey keeps the settings of all three
layers and masks in word 1, apart from their glyphs, so moving a layer means
moving a glyph and rewriting a field elsewhere. Atlas positions need far
fewer than 32 bits.

**Decision:** Bits 0–23 of a glyph word are an atlas position, below
16,777,216, and bits 24–31 are the settings of that layer or mask. Which it
is follows from its place and the counts (LEXTER-DRAFT-cell-model-D3), so
the byte needs no flag.

Table: The settings byte of a layer.

| Bits | Width | Field | Values |
|---|---|---|---|
| 24–25 | 2 | Ink slot | The slot for covered pixels |
| 26–27 | 2 | Fill slot | The slot for uncovered pixels when the fill is on; zero when it is off |
| 28 | 1 | Fill on | 0 = uncovered pixels show what lies beneath; 1 = they take the fill slot |
| 29 | 1 | Display selector | 0 = the glyph's inked pixels cover; 1 = its uninked pixels do |
| 30–31 | 2 | Reserved | Zero |

Table: The settings byte of a mask.

| Bits | Width | Field | Values |
|---|---|---|---|
| 24–25 | 2 | Operation | 0 union, 1 intersection, 2 exclusion, 3 the mask less the coverage |
| 26 | 1 | Selector | 0 = the mask glyph's inked pixels; 1 = its uninked pixels |
| 27–28 | 2 | Target | The index of the layer it cuts, 0–3 |
| 29–31 | 3 | Reserved | Zero |

A layer is one word, so moving, swapping, inserting, or copying a layer
copies one word with its settings. Writing only a glyph, or only a setting,
masks the rest of the word; the accessors generated from
LEXTER-DRAFT-cell-model-revision-D9's descriptor do this, and writers use
nothing else. The reserved bits are left for later use
(LEXTER-DRAFT-cell-model-O5).

**Alternatives:**
- Settings in word 1, as the survey and
  LEXTER-DRAFT-cell-model-revision-D7 have them. Rejected: a layer would be
  split across two words, and word 1 is better spent on the cell as a whole.
- A flag in each byte saying layer or mask. Rejected by the steward: the
  counts already say it, and a redundant field must itself be kept
  consistent. Records are checked against their counts by assertions in
  debugging builds instead.

### LEXTER-DRAFT-cell-model-D5 — Layers and masks vary in number, with layers first and masks after

**Status:** Proposed

**Context:** A fixed three layers and three masks leaves masks unused in
most cells and cannot give a layer more than three cuts or a cell a fourth
layer. The steward asked what a variable layout costs the GPU.

**Decision:** A glyph kind's glyph words hold its layers, then its masks, in
any numbers the counts allow: one layer and five masks, four layers and two,
or none. A layer's index is its position among the layers, and a mask names
the layer it cuts by that index; masks apply in their order. A mask whose
target is not below the layer count is ignored.

The shader's loops take their bounds from the counts, which are the same for
every pixel of a cell. Most warps lie inside one cell, whose 8-by-16 pixels
fill four warps of 32, and do not diverge; a warp across a cell boundary
runs as many iterations as its longest cell, which is never more than the
fixed layout's six glyphs, and a cell of plain text reads one. Glyphs are
read with `texelFetch`, which takes no derivatives and so is defined in
divergent control flow (*OpenGL Shading Language 3.30 specification*).

**Alternatives:**
- Three layers and three masks, as LEXTER-DRAFT-cell-model-revision-D7 has
  them. Rejected: it reads every slot in every cell and fixes how glyph words
  are shared between layers and masks.
- Mask *k* bound to layer *k*, for uniform loops. Rejected: neighbouring
  cells already differ in which layers they have, so it removes little
  divergence, and it cannot draw a band inside one cell.
- Masks interleaved with layers. Rejected: nothing needs it, and it would
  make the procedure and the reading of lines scan the words.

### LEXTER-DRAFT-cell-model-D6 — A layer's fill is switched by a bit of its own

**Status:** Proposed

**Context:** The cell-field-format survey's update on mask targets replaced
each layer's fill-on bit with a rule, a fill slot equal to the ink slot
meaning no fill, to fit word 1. The rule couples two fields: changing a
layer's ink slot alone can turn its fill off.

**Decision:** Each layer has a fill-on bit (LEXTER-DRAFT-cell-model-D4).
When it is 0 the fill slot is ignored, and writers leave it zero, so that
the same picture is always the same record. Every combination of ink slot,
fill slot, and fill means one thing, including a layer filled in its own ink
colour. The first edition's `transparent-side` of `:none`, `:bg`, and `:fg`
maps to a fill on with the background slot, a fill off, and a fill off with
the display selector at 1.

**Alternatives:**
- The fill rule. Rejected: it saved a bit that each layer's byte now has to
  spare, at the cost of fields that change each other's meaning.

### LEXTER-DRAFT-cell-model-D7 — The header holds the swatch, the palette slot, and the wide bits

**Status:** Proposed

**Context:** The cell-field-format survey's header holds the swatch index, a
two-bit palette slot, the wide bits, two cursor bits, the layer count, three
line bits, and a two-bit line colour slot. The cursor is drawn by the overlay
list (LEXTER-DRAFT-cell-model-revision-D10), the counts move to the kind word
(LEXTER-DRAFT-cell-model-D3), and lines become glyphs
(LEXTER-DRAFT-cell-model-D8).

**Decision:**

Table: Bits of word 1, the header.

| Bits | Width | Field | Values |
|---|---|---|---|
| 0–15 | 16 | Swatch index | A global index into the swatch store |
| 16–21 | 6 | Palette slot | 0–63 |
| 22 | 1 | Wide | 1 = the cell holds half of a double-width glyph |
| 23 | 1 | Right half | With wide set: 0 = left half, 1 = right half |
| 24–31 | 8 | Reserved | Zero |

**Alternatives:**
- Keep the cursor bits for the block style. Rejected: the block cursor copies
  the cell beneath it into an overlay instance
  (LEXTER-DRAFT-cell-model-D13).
- Keep the line bits, drawn by the shader as rules. Rejected for the reasons
  LEXTER-DRAFT-cell-model-D8 gives.
- An eight-bit palette slot. Not chosen: 64 palettes is far more than the
  terminals of a window need, and slots beyond them are left to tiles
  (LEXTER-DRAFT-cell-model-D11).

### LEXTER-DRAFT-cell-model-D8 — Lines are glyphs: the last mask in the text's colour, or the last layer in their own

**Status:** Proposed

**Context:** Underline, strikethrough, and overline belong to the text, not to
a moment, so they belong in the grid. As header bits they cost five bits with
their colour slot, need both renderers to draw rules from the font's
metrics, and leave no room for the further underline styles terminals now
support. Heavy use of layers is expected to be rare in text cells.

**Decision:** A line is drawn by a line glyph (LEXTER-DRAFT-cell-model-D9)
holding the cell's combination of lines, in one of two places given by the
counts:

- **In the text's colour, as the last mask.** Lines that take the colour of
  the text are a mask appended after the cell's other masks, targeting the
  text's layer. When the text's layer has its display selector at 0, the
  operation is union with the mask's inked pixels; when it is 1, the
  operation is intersection with the mask's uninked pixels, so that the line
  shows in the colour the glyph's strokes show in. The line costs a mask and
  no layer.
- **In a colour of its own, as the last layer.** An underline given a colour
  by SGR 58 is a layer appended after the cell's other layers, so that it is
  drawn over them, with the line glyph for underline alone, its ink slot
  holding the colour, and no fill. Appending it moves the masks along by one
  word; their targets do not change, since the other layers keep their
  indices. Strikethrough and overline stay in the text's colour, as the last
  mask, so a cell may use both places.
- **Reading back.** A cell's lines are read from the glyphs of its last layer
  and its last mask, wherever either falls in the range of line glyphs, with
  no scan. DECCARA, DECRARA, attribute reports, and copying with formatting
  read them this way.
- **Ephemeral lines** are not lines in this sense. A hyperlink underlined
  while the pointer is over it is an overlay instance.

Only the single underline style is defined at first. A cell whose glyph
words are all in use has no room for a line
(LEXTER-DRAFT-cell-model-O3).

**Alternatives:**
- Header bits drawn as rules, as the cell-field-format survey proposed.
  Rejected: they spend five header bits, need drawing code in both renderers,
  and have no room for styles.
- Every line as a layer. Not chosen: the common case, an underline in the
  text's colour, would spend a layer where a mask serves.

### LEXTER-DRAFT-cell-model-D9 — Generated glyphs have reserved atlas positions and names above U+10FFFF

**Status:** Proposed

**Context:** The atlas keys its generated cursor glyphs by the private-use
codepoints U+E000–E002 (`src/atlas.lisp:add-cursor-glyphs@2d4d743`). Nerd
Fonts places real glyphs there and in plane 15, so a host that prints U+E000
can reach a generated glyph, or a font's glyph can displace one. Line glyphs
need positions that a reader recognises by a range test.

**Decision:** The atlas reserves positions 0–63 for generated glyphs, and a
font's glyphs begin at position 64.

Table: Reserved atlas positions.

| Positions | Glyphs |
|---|---|
| 0 | The empty glyph |
| 1–7 | Cursor glyphs: 1 full block, 2 underline, 3 bar, 4 outlined block; 5–7 reserved |
| 8–63 | Line glyphs: position 8 + 8 × style + flags |

The flags are bit 0 underline, bit 1 strikethrough, and bit 2 overline, and
are never 0, so positions 8, 16, and so on up to 56 are unused. Style 0 is
the single underline and is the only style defined at first; styles 1–6 are
left for others (LEXTER-DRAFT-cell-model-O4). A reader recovers a line
glyph's flags as its position minus 8, modulo 8, and its style as that
difference divided by 8. All generated glyphs are narrow; each half of a
double-width glyph carries its own.

The atlas names generated glyph *k* by the value U+110000 + *k* in its table
of codepoints. Such values are not Unicode codepoints: the decoder never
produces them and no font maps them, so no host can reach a generated glyph.

Lines are drawn from the font's XLFD properties `UNDERLINE_POSITION`,
`UNDERLINE_THICKNESS`, `STRIKEOUT_ASCENT`, and `STRIKEOUT_DESCENT` when the
font has them, and from the cell's size otherwise. Whether a font may supply
its own line glyphs is LEXTER-DRAFT-cell-model-O2.

**Alternatives:**
- Private-use codepoints. Rejected: the Basic Multilingual Plane's area holds
  Powerline's and Nerd Fonts' symbols, plane 15 holds Nerd Fonts' Material
  Design Icons, and plane 16, though seldom used, is open to any font.
- Generated glyphs after the font's, as `add-cursor-glyphs` appends them now.
  Rejected: their positions would depend on the font, and the range test
  would need the font's glyph count.

### LEXTER-DRAFT-cell-model-D10 — A pixel that nothing covers takes slot 0, except in a void

**Status:** Proposed

**Context:** Selection without blending
(LEXTER-DRAFT-cell-model-revision-D15) needs every pixel to end as one slot
or as nothing. A layer may have no fill, and a cell may have no layer that
covers a given pixel, or no layers at all.

**Decision:** A pixel that no layer covers or fills takes slot 0 of the
cell's swatch, the background. In a void, such a pixel is not drawn, so that
the surface beneath shows. The procedure is given in full under Drawing a
Pixel, and both renderers follow it.

**Alternatives:**
- Leave uncovered pixels transparent in every cell. Rejected: an ordinary
  cell would then need a filled layer to have a background at all, and the
  grid's output would depend on what was drawn before it.

### LEXTER-DRAFT-cell-model-D11 — Tiles are kind 4, with a texture of their own and palettes beyond the screens'

**Status:** Proposed

**Context:** The cell-field-format survey sketches tile mode: glyphs whose
pixels are colour indices 0–15, read through four swatches, for tile-based
games, boards, and cards. Indexed glyphs cannot share the font's atlas,
since a one-bit glyph read as indices, or an indexed glyph read as ink,
draws wrongly. A tile set may want palettes of its own.

**Decision:** A tile cell is kind 4, which has no counts.

Table: The record of a tile cell.

| Word | Contents |
|---|---|
| 0 | Bits 0–7 the kind, 4; bits 8–9 the mode; bits 10–11 the palette extension; bits 12–31 reserved |
| 1 | The header: the swatch for a glyph layer, the palette slot, and the wide bits |
| 2 | Bits 0–23: the tile of layer 0, an index into the tile texture; bits 24–31 reserved |
| 3 | Bits 0–23: layer 1, a glyph or a tile as the mode says; bits 24–31 its settings when it is a glyph |
| 4 | Reserved |
| 5 | Swatch A, colours 0–3 (bits 0–15); swatch B, colours 4–7 (bits 16–31) |
| 6 | Swatch C, colours 8–11; swatch D, colours 12–15 |
| 7 | Reserved |

Table: Tile modes.

| Mode | Layer 0 | Layer 1 |
|---|---|---|
| 0 Unified | Indices 0–15 through swatches A–D | A glyph in the header's swatch, with a layer's settings; glyph 0 draws nothing |
| 1 Split | Indices 0–7 through swatches C–D | Indices 0–7 through swatches A–B, over layer 0 |
| 2–3 | Reserved | |

- **Colours.** A pixel's index *i* selects swatch *i* div 4 and slot *i* mod
  4, in palette slot 64 × extension + the header's palette slot. Extension 0
  is the screens' own palettes; slots 64–255 are reached only by tiles, as
  far as the palette store provides them (LEXTER-DRAFT-cell-model-D12).
- **The tile texture.** Tiles are kept in a texture of their own with the
  internal format `R8UI`, one index to a texel, apart from the font's atlas.
  Tile 0 is the empty tile, which draws nothing. OpenGL 3.3 guarantees a
  two-dimensional texture of 1024 by 1024 texels, which holds 4096 tiles of
  16 by 16.
- **Wide tiles.** A 16-by-16 tile in cells of 8 by 16 is a double-width pair:
  both cells hold the tile, with the wide bits set, and each draws its half,
  as glyphs do (LEXTER-DRAFT-cell-model-revision-D8).
- **Two layers, no masks, no lines.** The cursor over a tile is
  LEXTER-DRAFT-cell-model-O1.

**Alternatives:**
- Indexed glyphs in the font's atlas. Rejected: the atlas would hold two
  readings of a glyph, told apart only by the cell, and its packing would
  depend on the tile set.
- Palettes for tiles only among the screens' 64. Not chosen: a tile set with
  palettes for animation or for regions would crowd out the screens.

### LEXTER-DRAFT-cell-model-D12 — Sixty-four palette slots for terminals, allocated, in a store whose size the configuration sets

**Status:** Proposed

**Context:** The first edition has four palette slots, set by hand through a
pane's `palette-slot` (`src/panes/vt-pane.lisp:vt-pane@2d4d743`), and the
renderer compares palette generations by slot, whoever produced them
(`src/renderer.lisp:render-state@2d4d743`): the pattern the critique found
for swatches (LEXTER-DRAFT-data-structures-1e-critique-O5). The integer
palette store (LEXTER-DRAFT-cell-model-revision-D14) can hold far more. A
terminal applies palette changes to its primary and alternate screens alike
(`src/vt-handler.lisp:%handler-screens@2d4d743`).

**Decision:**

- **Addressing.** The record addresses 256 palette slots: 64 through the
  header and 192 more through a tile's extension.
- **The store.** The palette store is a texture buffer of its own, with slot
  *s*'s 256 entries beginning at *s* × 256. The configuration sets how many
  slots it holds, 128 by default, which is 32,768 texels; all 256 are 65,536
  texels, the size OpenGL 3.3 guarantees. A tile that names a slot beyond the
  store draws in palette slot 0.
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
- A store always sized for 256 slots. Not chosen: the full gamut is more
  than most uses need, and the format's addressing costs nothing while the
  store's memory does.

### LEXTER-DRAFT-cell-model-D13 — An overlay instance carries a full record, and the block cursor copies the cell beneath it

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
  selects the ink slot of layer 0 takes slot 0; a cell with no layers swaps
  slots 0 and 1. The flush copies the record again whenever the cursor moves
  or its row changes. A cursor on a double-width glyph is two instances, one
  for each half.
- **The other styles** are instances of plain cells whose one layer is a
  cursor glyph (LEXTER-DRAFT-cell-model-D9) in the cursor's colour, with no
  fill.
- **The pass** decodes the record with the grid's decoder, draws covered and
  filled pixels as the grid does, and discards every other pixel.

The steward chose the full copy, which answers
LEXTER-DRAFT-cell-model-revision-O5.

**Alternatives:**
- Copy only layer 0's glyph and settings. Rejected: the cursor would drop the
  cell's other layers, its masks, and its lines.
- Keep cursor bits in the header for the block style. Rejected: it writes an
  ephemeral state into the static grid, which
  LEXTER-DRAFT-cell-model-revision-D10 keeps apart.

## The Record

Table: The record, by word, for each kind.

| Word | Glyph kinds (plain, void, inline colours) | Tiles |
|---|---|---|
| 0 | Kind, layer count, mask count | Kind, mode, palette extension |
| 1 | Header | Header |
| 2–4 | Glyph words: layers, then masks | Layer 0's tile, layer 1, reserved |
| 5–7 | More glyph words in a plain cell; the payload in a void or a cell with inline colours | Swatches A–D, reserved |

Table: Bits of word 0 in a glyph kind.

| Bits | Width | Field | Values |
|---|---|---|---|
| 0–7 | 8 | Kind | 0 plain, 1 void, 2 inline colours |
| 8–10 | 3 | Layer count | 0–4 |
| 11–13 | 3 | Mask count | 0 to the glyph words after the layers |
| 14–31 | 18 | Reserved | Zero |

Records are stored row by row in the grid's array, which is the upload
buffer. On the GPU a record is two `uvec4` attributes of an instance, read
flat.

### Invariants of a record

Writers keep these, and the cell checksum relies on them:

- Every reserved bit is zero, and every bit a kind does not define.
- In a glyph kind, the layer count is at most 4, the counts together are at
  most the kind's glyph words, and the glyph words beyond the counts are
  zero.
- A layer whose fill is off has a fill slot of zero.
- The payload holds exactly what its kind defines.
- The two halves of a double-width glyph are written and erased together,
  with the wide bit in both and the right-half bit in the second.

Debugging builds of the API and the CPU renderer assert these invariants on
the records they handle.

## Drawing a Pixel

Both renderers follow this procedure for each pixel of a cell. Every test is
on integers, and the result is one colour, or no pixel.

```
// word(n) is word n of the record; for a glyph word w,
// glyph(w) is word(w) & 0xFFFFFF and its settings are word(w) >> 24
k = word(0) & 0xFF
if k == TILES: draw by the tile procedure (LEXTER-DRAFT-cell-model-D11)
if k not in (PLAIN, VOID, INLINE): slot = 0; go to colour
G = (k == PLAIN) ? 6 : 3                        // the kind's glyph words
L = min((word(0) >> 8) & 7, 4, G)
M = min((word(0) >> 11) & 7, G - L)
for l in 0 .. L-1:                              // layers' coverage
    cov[l] = pixel(glyph(2 + l)) != display_selector(2 + l)
for m in 0 .. M-1:                              // masks, in order
    w = 2 + L + m
    t = target(w)
    if t < L:
        cov[t] = apply(op(w), cov[t], pixel(glyph(w)) != selector(w))
slot = (k == VOID) ? NOTHING : 0
for l in 0 .. L-1:                              // later layers win
    if cov[l]:                slot = ink(2 + l)
    else if fill_on(2 + l):   slot = fill(2 + l)
if slot == NOTHING: discard
colour:
colour = (k == INLINE) ? payload_colour(slot)
       : palette[palette_slot * 256 + swatch[swatch_index][slot]]
```

Description: The procedure reads the kind from the first byte. Tiles have a
procedure of their own, and an unknown kind is drawn in the background slot.
For a glyph kind it reads the layer and mask counts, clamped to the kind's
glyph words. It first finds, for each layer, whether the layer's glyph
covers the pixel under its display selector; then applies each mask, in
order, to the coverage of the layer it targets; then visits the layers in
order, setting the slot to a layer's ink slot where it covers the pixel, or
to its fill slot where it does not and its fill is on, so that a later layer
overrides an earlier one. A pixel that no layer sets keeps the background
slot, or in a void is discarded. The slot is then looked up in the inline
colours or in the swatch and the palette.

The coverage of the layers can be held as four bits of an integer. The right
half of a double-width glyph samples the second of the glyph's two atlas
columns. The colour is written as bytes, divided by 255 on the GPU, without
blending (LEXTER-DRAFT-cell-model-revision-D15).

## Palettes and Swatches

- **The swatch store** is a texture buffer of 65,536 swatches, `RGBA8UI`,
  each holding four palette indices; slot 0 is the background by convention,
  and slot 1 the foreground, as the first edition reads them
  (`src/shaders.lisp:+simple-frag+@2d4d743`).
- **The palette store** is a texture buffer of 256-colour palettes,
  `RGBA8UI`, sized by the configuration (LEXTER-DRAFT-cell-model-D12).
- **Palette slots.** A cell of a glyph kind draws in the header's palette
  slot, 0–63; a tile reaches slots 64–255 through its extension
  (LEXTER-DRAFT-cell-model-D11).
- **What the checksum hashes.** The cell checksum hashes the contents of
  every palette slot that a cell, including a tile's extension, selects
  (LEXTER-DRAFT-cell-model-revision-D13).

## Lines and Cursors

Table: How a cell's lines are placed.

| Lines | Place | Glyph |
|---|---|---|
| Any combination in the text's colour | The last mask, on the text's layer | The combination's line glyph |
| An underline with an SGR 58 colour | The last layer, no fill, ink slot holding the colour | The underline alone |
| Strikethrough or overline beside a coloured underline | The last mask | Their combination, without the underline |

Table: Where each cursor and pointer effect is drawn.

| Effect | Drawn by |
|---|---|
| Block cursor | An inverted overlay instance copying the cell (LEXTER-DRAFT-cell-model-D13) |
| Underline and bar cursors | An overlay instance with a cursor glyph |
| A hyperlink lit by the pointer | An overlay instance with an underline glyph |

## Open Questions

### LEXTER-DRAFT-cell-model-O1 — How is the cursor drawn over a tile, or a kind without layers?

Exchanging slots means nothing for a tile, whose layer 0 has no ink slot.
The cursor could be the outlined block glyph over such a cell, or each kind
could define how it is inverted.

### LEXTER-DRAFT-cell-model-O2 — May a font supply its own line glyphs?

Generated lines follow the font's XLFD properties where it has them. A font
may also draw its own underline as a combining mark, such as U+0332, but such
marks are drawn as marks, not as rules across the cell. Whether a
configuration can choose a font's glyphs for some lines is open; the default
is to generate them.

### LEXTER-DRAFT-cell-model-O3 — What happens when a cell has no glyph word left for a line?

A plain cell whose six glyph words are in use, or a void or inline-colour
cell whose three are, cannot take a line. The line could take precedence and
displace the last mask or layer, or be dropped. Such cells are expected to be
rare.

### LEXTER-DRAFT-cell-model-O4 — Which further underline styles are defined, and how do their patterns meet?

Double, curly, dotted, and dashed underlines (SGR 4:2–4:5, and 21) fit
styles 1–6. A curly or dashed pattern must line up from cell to cell, so its
period must divide the cell's width, or each boundary shows a seam. How the
generator chooses a period for each cell width is open.

### LEXTER-DRAFT-cell-model-O5 — What do the reserved bits hold?

The header has eight reserved bits, a glyph kind's kind word eighteen, a
layer's settings byte two, and a mask's three. The candidates are effects
for each layer, which need no payload and so could stand beside masks, and
the protected-cell bit of DECSCA (LEXTER-DRAFT-cell-field-format-O7), which
only the CPU reads and so could also live beside the grid. The bits stay
reserved until a use is chosen.

### LEXTER-DRAFT-cell-model-O6 — What happens when palette slots run out, and who owns the tiles' slots?

A 64th terminal finds no free slot among 1–63; it could share the default
palette, or a slot already in use. Slots 64–255 belong to tile sets, which
need an owner and a lifetime of their own.

### LEXTER-DRAFT-cell-model-O7 — Is colour 0 of a tile transparent, and which cell sizes do tiles support?

These are LEXTER-DRAFT-cell-field-format-O1 and -O2, carried here unchanged
for tile cells: the arcade convention of a transparent colour 0, and how
tiles fit cells other than 8 by 16.

### LEXTER-DRAFT-cell-model-O8 — How does a mask apply to a wide display glyph?

It is LEXTER-DRAFT-cell-model-revision-O6. Line glyphs are narrow and are
applied to each half's cell as they are, so whichever rule is chosen must
let a narrow mask apply to one half.

### LEXTER-DRAFT-cell-model-O9 — What do the void and effect kinds carry?

The cell-field-format survey's surface tile, a surface id and a column and
row within the surface, is the candidate for the void's payload, and it may
need fewer than three words, which would leave the void more glyph words.
The effect's contents are LEXTER-DRAFT-layer-mechanics-O8. Both are left to
the survey of surfaces and effects that LEXTER-DRAFT-cell-model-revision-D12
calls for.

## Roadmap

1. **With the plan's Phase 1.** The atlas reserves positions 0–63 and names
   generated glyphs above U+10FFFF, and the cursor glyphs move from
   private-use codepoints to positions 1–4 (LEXTER-DRAFT-cell-model-D9).
2. **With the plan's Phase 2.** The palette store, sized by the
   configuration (LEXTER-DRAFT-cell-model-D12), with the integer stores of
   LEXTER-DRAFT-cell-model-revision-D14.
3. **With the plan's Phase 3.** The record as specified here: the kind word,
   the header, glyph words with their settings, the plain kind with its
   counts, lines as glyphs with the single underline, the procedure of
   Drawing a Pixel in the shader, and palette slots allocated to terminals.
   The descriptor of LEXTER-DRAFT-cell-model-revision-D9 is written from
   these tables.
4. **With the plan's Phase 4.** The overlay instance and the block cursor's
   copy (LEXTER-DRAFT-cell-model-D13).
5. **With the plan's Phase 5.** The CPU renderer follows the same procedure.
6. **Later.** The inline-colour kind; tiles, after LEXTER-DRAFT-cell-model-O1,
   -O6, and -O7; the void and effects, after the survey of surfaces; further
   underline styles, after LEXTER-DRAFT-cell-model-O4.
7. **The second edition specified.** Spec.DataStructures2e takes its record
   from this document.

## Appendices

### Worked records

Table: A record of zeros.

| Field | Value | Meaning |
|---|---|---|
| Word 0 | 0 | A plain cell with no layers and no masks |
| Word 1 | 0 | Swatch 0, palette slot 0, not wide |
| Result | — | Every pixel in slot 0: a blank cell in the default background |

Table: The letter g, underlined in the text's colour.

| Word | Value |
|---|---|
| 0 | Kind 0, one layer, one mask |
| 1 | The pane's swatch *s* (slot 0 background, slot 1 foreground) and palette slot *p* |
| 2 | The atlas position of g; ink slot 1, fill off, display selector 0 |
| 3 | 9, the underline (8 + 0 + 1); union, selector 0, target 0 |
| 4–7 | 0 |

Table: The letter g with an SGR 58 red underline and a strikethrough.

| Word | Value |
|---|---|
| 0 | Kind 0, two layers, one mask |
| 1 | A swatch whose slot 2 holds red |
| 2 | The atlas position of g; ink slot 1, fill off |
| 3 | 9, the underline; ink slot 2, fill off |
| 4 | 10, the strikethrough (8 + 0 + 2); union, selector 0, target 0 |
| 5–7 | 0 |

Table: A scroll bar's thumb as a band from two-eighths to six-eighths down
one cell.

| Word | Value |
|---|---|
| 0 | Kind 0, one layer, two masks |
| 2 | ▏, the bar; ink slot 1, fill off |
| 3 | ▆, the lower six-eighths; intersection, selector 0, target 0 |
| 4 | ▂, the lower two-eighths; intersection, selector 1, target 0 |

Table: A block cursor over the underlined g.

| Word | Value |
|---|---|
| 0–7 | A copy of the underlined g's record |
| 8 | The cell's column and row |
| 9 | Unit 0 (cells), inverted |
| Result | The background drawn in slot 1's colour, and the g and its underline in slot 0's |

Table: The left half of a 16-by-16 tile in cells of 8 by 16.

| Word | Value |
|---|---|
| 0 | Kind 4, mode 0, palette extension 1: palettes from slot 64 + *p* |
| 1 | Swatch for the glyph layer, palette slot *p*, wide 1, right half 0 |
| 2 | The tile's index in the tile texture |
| 3 | 0, no glyph over the tile |
| 5–6 | Swatches A–D |
