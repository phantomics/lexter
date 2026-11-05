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
  session:     "Cell model revision plan (2026-11-02), the dense cell model"
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

This document specifies the dense cell model of Lexter's second edition: the
32-byte record that every cell of the composed grid holds, what each of its
bits means, how a renderer turns it into pixels, and the overlay instance
built from it. It refines the layout that
[LEXTER-DRAFT-cell-field-format](Survey.CellFieldFormat.md) proposed, as
[LEXTER-DRAFT-cell-model-revision](Plan.CellModelRevision.md) left it to be
refined. A record begins with a format word, which says how its other words
are arranged and whether the cell is half of a double-width glyph, and a
header word, which every format reads the same way. Cells of the glyph
formats hold up to six glyph words, each carrying its glyph and its
settings, in which layers and masks are interleaved and each mask cuts the
layer before it. The cursor and line attributes leave the header, the cursor
for the overlay list and the lines for generated glyphs, and the palette slot
widens to eight bits. Nothing here is built. Each part is placed in the
plan's phases under Roadmap.

## Canonical Terms

Table: Terms used in this design, with their definitions.

| Term | Definition |
|---|---|
| Record | The 32 bytes, eight 32-bit words, that describe one cell |
| Format | The arrangement of a record's words, selected by the record's first byte |
| Format word | Word 0: the format in bits 0–7, the wide bits in bits 16–17, and fields the format defines |
| Header word | Word 1: the swatch index and the palette slot, read the same way in every format |
| Glyph format | A format whose cells hold glyph words: plain, void, and inline colours |
| Glyph word | A word holding a 24-bit glyph and a settings byte, as a layer or as a mask |
| Glyph count, type bits | In a glyph format, the number of glyph words in use and, for glyphs 1–5, whether each is a layer or a mask |
| Layer | A display glyph with a selector, an ink slot, a fill slot, and a fill-on bit; layers are drawn in order |
| Mask | A mask glyph with a selector and an operation, which cuts the layer before it |
| Slot | One of a swatch's four palette indices; slot 0 is the background |
| Swatch | Four palette indices, stored in the swatch store and named by a 16-bit global index |
| Palette slot | The number of one 256-colour palette in the palette store |
| Payload | The words after a cell's glyph words that its format defines, such as inline colours |
| Generated glyph | A glyph that Lexter draws itself into a reserved atlas position, such as a line or a cursor |
| Line glyph | A generated glyph holding one combination of underline, strikethrough, and overline |
| Overlay instance | A record with a position and flags, drawn by the overlay pass over the grid |
| Void | A cell of the void format, which references a surface and leaves its uncovered pixels undrawn |

## Thesis / Concerns

**Every word has one job.** The format word says how the cell is arranged,
the header word what colours it draws in, and each glyph word one glyph and
how it is drawn. A layer and its masks are a run of words, so they are moved,
copied, or reordered as words. **Structure replaces addresses.** A mask cuts
the layer before it, so no mask names a layer, and the composition is read in
one pass. **Zero means nothing.** A glyph count of 0 is no glyphs, a fill-on
bit of 0 is no fill, and a record of zeros is a valid blank cell. **The grid
holds static text.** What moves or lasts a moment, such as a cursor or a link
lit by the pointer, is an overlay; what belongs to the text, such as its
underline, is in the record, as a glyph rather than as bits that only the
shader understands.

The design serves these concerns:

- **Exactness.** Every pixel is a selection of one palette entry or inline
  colour, so the GPU and the CPU renderer draw the same bytes
  (LEXTER-DRAFT-cell-model-revision-D15, -D16).
- **Uniformity.** One namespace of formats, one rule for how layers and masks
  compose, and settings that travel with their glyph, so that writers and
  readers handle no special structures.
- **Fixed offsets.** The format, the wide bits, and the header sit at fixed
  places, so a reader learns a cell's shape from its first eight bytes.
- **Normalisation.** The cell checksum
  (LEXTER-DRAFT-cell-model-revision-D13) takes unused and reserved fields as
  zero; here they are zero by rule.
- **Capacity for later formats.** The format byte has room for tiles,
  surfaces, effects, and formats not yet imagined, without a new record.
- **Two renderers, one procedure.** The less the shader does that is not a
  lookup, the less the CPU renderer must reproduce.

## Influences

Table: Influences on this design, what each contributes, and what is not
taken from it.

| Influence | Contributes | Not taken |
|---|---|---|
| [LEXTER-DRAFT-cell-field-format](Survey.CellFieldFormat.md) | A 32-byte record of control words, glyphs, and a tail; inline colours, surfaces, and tile mode | The fixed three layers and three masks, the layer count and the cursor and line bits in the header, the tail type, payloads growing backwards into absent layers, and the fill rule |
| [LEXTER-DRAFT-layer-mechanics](Survey.LayerMechanics.md) | Layers and masks in one dense record, and the mask code | — |
| [LEXTER-DRAFT-cell-model-revision](Plan.CellModelRevision.md) | Masks with an operation and a selector (LEXTER-DRAFT-cell-model-revision-D7), halves (-D8), the overlay list (-D10), one composed grid (-D12), integer colour stores (-D14), selection without blending (-D15) | The fixed layout of word 1 and the mask targets that LEXTER-DRAFT-cell-model-revision-D7 gives, with the tail type folded into unused masks |
| VGA and MDA text attributes | A cell as a fixed record that the display reads directly | Underline as an attribute bit, which only the display hardware can draw |
| kitty | Underline and strikethrough drawn as generated sprites in its sprite map (*kitty decorations*) | — |
| XLFD font properties | The position and thickness of the underline and the strikeout, which BDF and PCF fonts may carry (*X Logical Font Description Conventions*) | — |
| Zero-initialised memory | Fresh and cleared memory as a valid initial value, as `calloc` and zeroed pages give | — |
| Nerd Fonts | A warning: fonts use the private-use areas of the Basic Multilingual Plane and of plane 15 (*Nerd Fonts glyph sets*), where Lexter now keys its cursor glyphs | Private-use codepoints for generated glyphs |

## Settled Decisions

### LEXTER-DRAFT-cell-model-D1 — The format word comes first, with the format and the wide bits at fixed places

**Status:** Proposed

**Context:** The cell-field-format survey opens the record with a header and
a word of layer settings, finds a cell's arrangement from a tail type in the
settings word, and keeps the wide bits in the header. With each glyph's
settings in its own word (LEXTER-DRAFT-cell-model-D4), a whole word is free
to say how the cell is arranged. Whether a cell is half of a double-width
glyph describes its shape, as its format does, and the wide-pair helpers,
edge repair, and resizing read it in every cell.

**Decision:** Word 0 is the format word. Bits 0–7 are the format, bit 16 is
the wide bit (1 = the cell holds half of a double-width glyph), and bit 17
the right-half bit (with wide set, 0 = left half, 1 = right half). These are
at the same places in every format, and the wide bits are zero where a
format has no halves. Bits 8–15 and 18–31 are defined by the format, and are
zero where it defines nothing. Word 1 is the header word
(LEXTER-DRAFT-cell-model-D7), read the same way in every record; no format
may redefine it. The first eight bytes therefore say what a cell is, its
shape, and what colours it draws in, and a kernel reads or changes them with
one 64-bit operation.

**Alternatives:**
- The header first and the format second. Not chosen by the steward: the
  record reads more naturally as how the cell is arranged, then everything
  else, and a dump shows the format in its first byte. Neither order costs
  the GPU or SIMD anything, since a record is fetched whole.
- The wide bits in the header word. Not chosen by the steward: they describe
  the cell's shape, like its format, and moving them gives the palette slot a
  whole byte.
- The wide bits placed by each format. Rejected: the wide-pair helpers would
  first have to ask which format a cell has.
- Formats that may redefine the header word. Rejected: it is read by the row
  copies, colour animation, the cell checksum, and both renderers, which
  should not first ask what format a cell has.

### LEXTER-DRAFT-cell-model-D2 — One namespace of formats names every cell

**Status:** Proposed

**Context:** Earlier drafts had two mechanisms for special cells: a tail
type found in the bits of unused masks, and escape cells marked by an absent
layer 0. Each needed its own test, and the tail type's place depended on
four fields.

**Decision:** The format byte names every cell, in one namespace.

Table: Formats.

| Format | Name | Glyph words | After the glyph words |
|---|---|---|---|
| 0 | Plain | Words 2–7, up to six | Nothing |
| 1 | Void | Words 2–4, up to three | A reference to a surface in words 5–7; uncovered pixels are not drawn |
| 2 | Inline colours | Words 2–4, up to three | The colours of slots 0–3, three bytes each, in bytes 20–31 |
| 3 | Effect | — | Reserved for the effects of LEXTER-DRAFT-layer-mechanics-O8 |
| 4 | Tiles | — | LEXTER-DRAFT-cell-model-D11 |
| 5–255 | Reserved | — | — |

A renderer that meets a format it does not know draws the cell as blank, in
slot 0 of the header's swatch. In a cell with inline colours, each slot's
colour is read from the payload, and neither the swatch store nor the
palette is consulted. The void's reference and the effect's contents are
LEXTER-DRAFT-cell-model-O9.

**Alternatives:**
- Escape cells beside tail types. Rejected: two kinds of special cell, found
  by two tests, where one byte serves.
- The tail type in the bits of unused masks, as
  LEXTER-DRAFT-cell-model-revision-D7 has it. Rejected: finding it depends on
  four fields, and it limits formats to eight.
- The word "kind", or "template", for the format. Not chosen by the steward:
  "kind" is too general to be clear, and "template" suggests a generic form
  specialised for particular uses, which this is not.

### LEXTER-DRAFT-cell-model-D3 — A glyph format gives its glyph count and type bits in the format word, and they are authoritative

**Status:** Proposed

**Context:** A cell of a glyph format holds some glyph words, each a layer or
a mask. Their number could be found from glyphs of 0, but a zero glyph is not
a neutral mask under every operation, since intersection with the empty
glyph clears a layer, and a blank cell would then fetch glyphs only to find
them empty.

**Decision:** In a glyph format, bits 8–10 of the format word are the glyph
count, 0 to the format's glyph words, and bits 11–15 are the type bits:
bit 11 + *i* − 1 is 0 when glyph *i* is a layer and 1 when it is a mask, for
glyphs 1–5. Glyph 0 needs no bit, since a mask must follow a layer, so the
first glyph is always a layer. The count and the bits are authoritative: the
glyph words in use are the first *n*, the words and type bits beyond them are
zero, and a glyph of 0 inside them is the empty glyph, which draws nothing.
Formats that are not glyph formats need have neither.

Table: Bits of the format word in a glyph format.

| Bits | Width | Field | Values |
|---|---|---|---|
| 0–7 | 8 | Format | 0 plain, 1 void, 2 inline colours |
| 8–10 | 3 | Glyph count | 0–6 in the plain format, 0–3 in the void and inline-colour formats |
| 11–15 | 5 | Type bits | For glyphs 1–5: 0 layer, 1 mask |
| 16 | 1 | Wide | 1 = the cell holds half of a double-width glyph |
| 17 | 1 | Right half | With wide set: 0 = left half, 1 = right half |
| 18–31 | 14 | Reserved | Zero |

A record of zeros is a plain cell with no glyphs: every pixel takes slot 0
of global swatch 0 in palette slot 0 (LEXTER-DRAFT-cell-model-D10). Global
swatch 0 and palette slot 0 must always hold valid default colours; which
table owns swatch 0 is LEXTER-DRAFT-cell-model-revision-O4.

Writers never produce a glyph count beyond the format's glyph words.
Renderers still clamp it, so that a bad record cannot read past them.

**Alternatives:**
- Separate counts of layers and masks, with masks after all the layers and
  a target in each. Rejected: it needs a target field in every mask and
  three passes to compose (LEXTER-DRAFT-cell-model-D5).
- A stop bit above the type bits instead of a count. Rejected: finding it
  needs `findMSB`, which GLSL 3.30 lacks, or a loop.
- A count found from glyphs of 0. Rejected: a blank cell would fetch empty
  glyphs, and a mask of glyph 0 would be neutral only under union.

### LEXTER-DRAFT-cell-model-D4 — Each glyph word holds a 24-bit glyph and its own settings byte

**Status:** Proposed

**Context:** The cell-field-format survey keeps the settings of all three
layers and masks in word 1, apart from their glyphs, so moving a layer means
moving a glyph and rewriting a field elsewhere. Atlas positions need far
fewer than 32 bits.

**Decision:** Bits 0–23 of a glyph word are an atlas position, below
16,777,216, and bits 24–31 are the settings of that layer or mask. Whether it
is a layer or a mask is given by the type bits
(LEXTER-DRAFT-cell-model-D3), so the byte needs no flag. Bit 24 is the
selector in both, so that a renderer finds whether a glyph covers a pixel the
same way for each.

Table: The settings byte of a layer.

| Bits | Width | Field | Values |
|---|---|---|---|
| 24 | 1 | Selector | 0 = the glyph's inked pixels cover; 1 = its uninked pixels do |
| 25–26 | 2 | Ink slot | The slot for covered pixels |
| 27–28 | 2 | Fill slot | The slot for uncovered pixels when the fill is on; zero when it is off |
| 29 | 1 | Fill on | 0 = uncovered pixels show what lies beneath; 1 = they take the fill slot |
| 30–31 | 2 | Reserved | Zero |

Table: The settings byte of a mask.

| Bits | Width | Field | Values |
|---|---|---|---|
| 24 | 1 | Selector | 0 = the mask glyph's inked pixels; 1 = its uninked pixels |
| 25–26 | 2 | Operation | 0 union, 1 intersection, 2 exclusion, 3 the mask less the coverage |
| 27–31 | 5 | Reserved | Zero |

Writing only a glyph, or only a setting, masks the rest of the word; the
accessors generated from LEXTER-DRAFT-cell-model-revision-D9's descriptor do
this, and writers use nothing else. The reserved bits are left for later use
(LEXTER-DRAFT-cell-model-O5).

**Alternatives:**
- Settings in word 1, as the survey and
  LEXTER-DRAFT-cell-model-revision-D7 have them. Rejected: a layer would be
  split across two words, and the word is better spent on the cell as a
  whole.
- A flag in each byte saying layer or mask. Rejected by the steward: the type
  bits already say it, and a redundant field must itself be kept consistent.
  Records are checked by assertions in debugging builds instead.

### LEXTER-DRAFT-cell-model-D5 — Layers and masks are interleaved, and each mask cuts the layer before it

**Status:** Proposed

**Context:** A fixed three layers and three masks leaves masks unused in
most cells and cannot give a layer more than three cuts or a cell a fourth
layer. An earlier draft of this document counted layers and masks
separately, with masks after all the layers and a target in each, which needs
a target field, three passes, and coverage held for every layer. The steward
asked what a variable layout costs the GPU.

**Decision:** A glyph format's glyph words are a sequence in which each
layer is followed by the masks that cut it, in the order they apply. A mask
cuts the most recent layer before it. Any number of layers and masks may be
used, up to the format's glyph words: six layers, or one layer and five
masks, or anything between.

Nothing is lost against masks with targets: a mask only ever changes the
coverage of the layer it cuts, and layers are combined in order, so every
assignment of masks to layers is written by placing each layer's masks after
it.

The renderer composes in one pass, holding only the coverage of the current
layer and its index. The loop's bound and its branch between layer and mask
are the same for every pixel of a cell, and most warps lie inside one cell,
whose 8-by-16 pixels fill four warps of 32, so they do not diverge. A warp
across a cell boundary runs as many iterations as its longest cell, which is
never more than six, and a cell of plain text reads one glyph. No array is
indexed by a value from the record, so nothing need leave the GPU's
registers. Glyphs are read with `texelFetch`, which takes no derivatives and
so is defined in divergent control flow (*OpenGL Shading Language 3.30
specification*).

**Alternatives:**
- Separate counts, masks after the layers, and a target in each mask.
  Rejected: it holds coverage for every layer, indexed by a target read from
  the record, needs three passes, and spends three bits of every mask on an
  address that the order gives for free.
- Three layers and three masks, as LEXTER-DRAFT-cell-model-revision-D7 has
  them. Rejected: it reads every slot in every cell and fixes how glyph words
  are shared between layers and masks.
- Mask *k* bound to layer *k*, for uniform loops. Rejected: neighbouring
  cells already differ in which glyphs they have, so it removes little
  divergence, and it cannot draw a band inside one cell.

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
the selector at 1.

**Alternatives:**
- The fill rule. Rejected: it saved a bit that each layer's byte now has to
  spare, at the cost of fields that change each other's meaning.

### LEXTER-DRAFT-cell-model-D7 — The header word holds the swatch and an eight-bit palette slot

**Status:** Proposed

**Context:** The cell-field-format survey's header holds the swatch index, a
two-bit palette slot, the wide bits, two cursor bits, the layer count, three
line bits, and a two-bit line colour slot. The cursor is drawn by the overlay
list (LEXTER-DRAFT-cell-model-revision-D10), the wide bits move to the
format word (LEXTER-DRAFT-cell-model-D1), the glyph count replaces the layer
count (LEXTER-DRAFT-cell-model-D3), and lines become glyphs
(LEXTER-DRAFT-cell-model-D8).

**Decision:**

Table: Bits of word 1, the header word.

| Bits | Width | Field | Values |
|---|---|---|---|
| 0–15 | 16 | Swatch index | A global index into the swatch store |
| 16–23 | 8 | Palette slot | 0–255 |
| 24–31 | 8 | Reserved | Zero |

The palette slot is a whole byte, so a kernel or a writer sets it with one
byte store, and every format, tiles included, reaches every palette the
same way.

**Alternatives:**
- A six-bit slot for glyphs, with a two-bit extension for tiles. Not chosen
  by the steward: the extension is a special field for one format, where a
  uniform byte serves all; that glyph cells can name more palettes than
  terminals need costs nothing.
- Keep the cursor bits for the block style. Rejected: the block cursor copies
  the cell beneath it into an overlay instance
  (LEXTER-DRAFT-cell-model-D13).
- Keep the line bits, drawn by the shader as rules. Rejected for the reasons
  LEXTER-DRAFT-cell-model-D8 gives.

### LEXTER-DRAFT-cell-model-D8 — Lines are glyphs: a mask after the text in the text's colour, or the last layer in their own

**Status:** Proposed

**Context:** Underline, strikethrough, and overline belong to the text, not to
a moment, so they belong in the grid. As header bits they cost five bits with
their colour slot, need both renderers to draw rules from the font's
metrics, and leave no room for the further underline styles terminals now
support. Heavy use of layers is expected to be rare in text cells.

**Decision:** A line is drawn by a line glyph (LEXTER-DRAFT-cell-model-D9)
holding the cell's combination of lines. In a cell that the terminal writes,
the text is the first layer, and lines take one of two places:

- **In the text's colour, as the text's last mask.** Lines that take the
  colour of the text are a mask placed after the text's other masks, before
  any later layer. When the text's selector is 0, the operation is union with
  the mask's inked pixels; when it is 1, the operation is intersection with
  the mask's uninked pixels, so that the line shows in the colour the
  glyph's strokes show in. The line costs a mask and no layer.
- **In a colour of its own, as the last layer.** An underline given a colour
  by SGR 58 is the last glyph word, a layer, so that it is drawn over the
  others, with the line glyph for underline alone, its ink slot holding the
  colour, and no fill. Strikethrough and overline stay in the text's colour,
  as the text's last mask, so a cell may use both places.
- **Reading back.** The coloured underline is the last glyph word when it is
  a layer holding a line glyph. The lines in the text's colour are the word
  before the second layer, or the last word when there is one layer, when it
  is a mask holding a line glyph. The second layer is found as the first 0
  among the type bits, so no words are scanned. DECCARA, DECRARA, attribute
  reports, and copying with formatting read lines this way.
- **Other arrangements** are drawn as any layer or mask is, and are not read
  back as the text's lines. A spelling checker's red underline drawn beneath
  the text is a line layer placed before the text's layer.
- **Ephemeral lines** are not lines in this sense. A hyperlink underlined
  while the pointer is over it is an overlay instance.

Inserting a line mask before a coloured underline moves the later words
along by one and inserts a type bit. Only the single underline style is
defined at first. A cell whose glyph words are all in use has no room for a
line (LEXTER-DRAFT-cell-model-O3).

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
covers a given pixel, or no glyphs at all.

**Decision:** A pixel that no layer covers or fills takes slot 0 of the
cell's swatch, the background. In a void, such a pixel is not drawn, so that
the surface beneath shows. The procedure is given in full under Drawing a
Pixel, and both renderers follow it.

**Alternatives:**
- Leave uncovered pixels transparent in every cell. Rejected: an ordinary
  cell would then need a filled layer to have a background at all, and the
  grid's output would depend on what was drawn before it.

### LEXTER-DRAFT-cell-model-D11 — Tiles are format 4, with a texture of their own

**Status:** Proposed

**Context:** The cell-field-format survey sketches tile mode: glyphs whose
pixels are colour indices 0–15, read through four swatches, for tile-based
games, boards, and cards. Indexed glyphs cannot share the font's atlas,
since a one-bit glyph read as indices, or an indexed glyph read as ink,
draws wrongly. A tile set may want palettes of its own.

**Decision:** A tile cell is format 4, which has no glyph count or type bits.

Table: The record of a tile cell.

| Word | Contents |
|---|---|
| 0 | Bits 0–7 the format, 4; bits 8–9 the mode; bits 16–17 the wide bits; the rest reserved |
| 1 | The header word: the swatch for a glyph layer, and the palette slot |
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
  4, in the header's palette slot, as any cell's colours are found. A tile set
  that wants palettes of its own is allocated slots as a terminal is
  (LEXTER-DRAFT-cell-model-D12).
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
- A palette extension in the tile's words, reaching slots beyond the screens'
  64. Not chosen by the steward: with an eight-bit palette slot in the header
  (LEXTER-DRAFT-cell-model-D7), tiles reach every palette as other cells do.

### LEXTER-DRAFT-cell-model-D12 — One allocator hands out palette slots 1–255, in a store whose size the configuration sets

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

- **Addressing.** The header word's palette slot addresses 256 palettes.
- **The store.** The palette store is a texture buffer of its own, with slot
  *s*'s 256 entries beginning at *s* × 256. The configuration sets how many
  slots it holds, 128 by default, which is 32,768 texels; all 256 are 65,536
  texels, the size OpenGL 3.3 guarantees. A cell that names a slot beyond the
  store draws in palette slot 0.
- **Slot 0** holds the default palette and is never allocated, so that a
  record of zeros draws in valid colours (LEXTER-DRAFT-cell-model-D3).
- **Allocation.** One allocator hands out slots 1 upwards, to the end of the
  store, to terminals and to tile sets alike. A terminal is given one when it
  is created and gives it back when it goes away, alongside its swatch range
  (LEXTER-DRAFT-cell-model-revision-D4); its primary and alternate screens
  share it. A tile set is given as many as it loads palettes.
- **Uploads by owner.** The renderer records, for each slot, the owner it
  uploaded and that palette's version, and uploads a slot again when either
  differs.
- **A manual override.** A pane may name a slot, so that panes can share one
  palette; the pane that names it does not own it.

What happens when the slots run out is LEXTER-DRAFT-cell-model-O6.

**Alternatives:**
- Slots set by hand, as now. Rejected: with many slots, choosing them by hand
  invites collisions that the allocator prevents.
- A slot for each screen. Rejected: the primary and alternate screens of a
  terminal hold the same palette, so two slots would hold one palette twice.
- Separate ranges for terminals and tiles. Not chosen: one allocator serves
  both, and a fixed division would leave one range idle while the other
  ran out.
- A store always sized for 256 slots. Not chosen: the full gamut is more than
  most uses need, and the format's addressing costs nothing while the store's
  memory does.

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
  that selects slot 0 takes the ink slot of the first layer instead, and a
  pixel that selects that ink slot takes slot 0; a cell with no glyphs swaps
  slots 0 and 1. The flush copies the record again whenever the cursor moves
  or its row changes. A cursor on a double-width glyph is two instances, one
  for each half.
- **The other styles** are instances of plain cells whose one glyph is a
  cursor glyph (LEXTER-DRAFT-cell-model-D9) in the cursor's colour, with no
  fill.
- **The pass** decodes the record with the grid's decoder, draws covered and
  filled pixels as the grid does, and discards every other pixel.

The steward chose the full copy, which answers
LEXTER-DRAFT-cell-model-revision-O5.

**Alternatives:**
- Copy only the first layer's glyph and settings. Rejected: the cursor would
  drop the cell's other layers, its masks, and its lines.
- Keep cursor bits in the header for the block style. Rejected: it writes an
  ephemeral state into the static grid, which
  LEXTER-DRAFT-cell-model-revision-D10 keeps apart.

## The Record

Table: The record, by word, for each format.

| Word | Glyph formats (plain, void, inline colours) | Tiles |
|---|---|---|
| 0 | Format word: format, glyph count, type bits, wide bits | Format word: format, mode, wide bits |
| 1 | Header word | Header word |
| 2–4 | Glyph words: each layer followed by its masks | Layer 0's tile, layer 1, reserved |
| 5–7 | More glyph words in a plain cell; the payload in a void or a cell with inline colours | Swatches A–D, reserved |

Records are stored row by row in the grid's array, which is the upload
buffer. On the GPU a record is two `uvec4` attributes of an instance, read
flat.

### Invariants of a record

Writers keep these, and the cell checksum relies on them:

- Every reserved bit is zero, and every bit a format does not define.
- In a glyph format, the glyph count is at most the format's glyph words, and
  the glyph words and type bits beyond it are zero.
- A layer whose fill is off has a fill slot of zero.
- The payload holds exactly what its format defines.
- The two halves of a double-width glyph are written and erased together,
  with the wide bit in both and the right-half bit in the second.

Debugging builds of the API and the CPU renderer assert these invariants on
the records they handle.

## Drawing a Pixel

Both renderers follow this procedure for each pixel of a cell. Every test is
on integers, and the result is one colour, or no pixel.

```
// word(n) is word n of the record; for glyph i, w(i) is word(2 + i),
// glyph(i) is w(i) & 0xFFFFFF, and its settings are w(i) >> 24
f = word(0) & 0xFF
if f == TILES: draw by the tile procedure (LEXTER-DRAFT-cell-model-D11)
if f not in (PLAIN, VOID, INLINE): slot = 0; go to colour
n = min((word(0) >> 8) & 7, (f == PLAIN) ? 6 : 3)
types = (word(0) >> 11) & 0x1F                  // bit i-1: glyph i is a mask
slot = (f == VOID) ? NOTHING : 0
for i in 0 .. n-1:
    p = pixel(glyph(i)) != selector(i)
    if i > 0 and (types >> (i - 1)) & 1:        // a mask cuts the layer
        cov = apply(op(i), cov, p)
    else:                                       // a layer begins
        if i > 0: commit(layer, cov)
        layer = i; cov = p
if n > 0: commit(layer, cov)
if slot == NOTHING: discard
colour:
colour = (f == INLINE) ? payload_colour(slot)
       : palette[palette_slot * 256 + swatch[swatch_index][slot]]

commit(l, c):                                   // later layers win
    if c:                 slot = ink(l)
    else if fill_on(l):   slot = fill(l)
```

Description: The procedure reads the format from the first byte. Tiles have
a procedure of their own, and an unknown format is drawn in the background
slot. For a glyph format it reads the glyph count, clamped to the format's
glyph words, and the type bits. It visits the glyphs in order. A glyph that
is a layer finishes the layer before it, if any, and becomes the current
layer, whose coverage is whether its glyph covers the pixel under its
selector. A glyph that is a mask combines its own coverage with the current
layer's by its operation. Finishing a layer sets the slot to its ink slot
where it covers the pixel, or to its fill slot where it does not and its fill
is on, so that a later layer overrides an earlier one. A pixel that no layer
sets keeps the background slot, or in a void is discarded. The slot is then
looked up in the inline colours or in the swatch and the palette.

Table: Mask operations.

| Operation | Coverage after the mask |
|---|---|
| 0 Union | Coverage or the mask's pixel |
| 1 Intersection | Coverage and the mask's pixel |
| 2 Exclusion | Coverage or the mask's pixel, but not both |
| 3 Mask less coverage | The mask's pixel and not the coverage |

The right half of a double-width glyph samples the second of the glyph's two
atlas columns. The colour is written as bytes, divided by 255 on the GPU,
without blending (LEXTER-DRAFT-cell-model-revision-D15).

## Palettes and Swatches

- **The swatch store** is a texture buffer of 65,536 swatches, `RGBA8UI`,
  each holding four palette indices; slot 0 is the background by convention,
  and slot 1 the foreground, as the first edition reads them
  (`src/shaders.lisp:+simple-frag+@2d4d743`).
- **The palette store** is a texture buffer of 256-colour palettes,
  `RGBA8UI`, sized by the configuration (LEXTER-DRAFT-cell-model-D12).
- **Palette slots.** Every cell draws in the header word's palette slot,
  0–255.
- **What the checksum hashes.** The cell checksum hashes the contents of
  every palette slot that a cell selects
  (LEXTER-DRAFT-cell-model-revision-D13).

## Lines and Cursors

Table: How a cell's lines are placed, when the terminal writes them.

| Lines | Place | Glyph |
|---|---|---|
| Any combination in the text's colour | The text's last mask, before any later layer | The combination's line glyph |
| An underline with an SGR 58 colour | The last glyph word, a layer, no fill, ink slot holding the colour | The underline alone |
| Strikethrough or overline beside a coloured underline | The text's last mask | Their combination, without the underline |

Table: Where each cursor and pointer effect is drawn.

| Effect | Drawn by |
|---|---|
| Block cursor | An inverted overlay instance copying the cell (LEXTER-DRAFT-cell-model-D13) |
| Underline and bar cursors | An overlay instance with a cursor glyph |
| A hyperlink lit by the pointer | An overlay instance with an underline glyph |

## Open Questions

### LEXTER-DRAFT-cell-model-O1 — How is the cursor drawn over a tile, or a format without layers?

Exchanging slots means nothing for a tile, whose layer 0 has no ink slot.
The cursor could be the outlined block glyph over such a cell, or each format
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
displace another glyph, or be dropped. Such cells are expected to be rare.

### LEXTER-DRAFT-cell-model-O4 — Which further underline styles are defined, and how do their patterns meet?

Double, curly, dotted, and dashed underlines (SGR 4:2–4:5, and 21) fit
styles 1–6. A curly or dashed pattern must line up from cell to cell, so its
period must divide the cell's width, or each boundary shows a seam. How the
generator chooses a period for each cell width is open.

### LEXTER-DRAFT-cell-model-O5 — What do the reserved bits hold?

The header word has eight reserved bits, a glyph format's format word
fourteen, a layer's settings byte two, and a mask's five. The candidates are
effects for each layer, which need no payload and so could stand beside
masks, and the protected-cell bit of DECSCA
(LEXTER-DRAFT-cell-field-format-O7), which only the CPU reads and so could
also live beside the grid. The bits stay reserved until a use is chosen.

### LEXTER-DRAFT-cell-model-O6 — What happens when palette slots run out?

When the store's slots are all allocated, a new terminal could share the
default palette or a slot already in use, and a tile set could be refused or
given fewer palettes than it asks for. Whether the store can grow while
running, up to the 256 slots the record addresses, is open too.

### LEXTER-DRAFT-cell-model-O7 — Is colour 0 of a tile transparent, and which cell sizes do tiles support?

These are LEXTER-DRAFT-cell-field-format-O1 and -O2, carried here unchanged
for tile cells: the arcade convention of a transparent colour 0, and how
tiles fit cells other than 8 by 16.

### LEXTER-DRAFT-cell-model-O8 — How does a mask apply to a wide display glyph?

It is LEXTER-DRAFT-cell-model-revision-O6. Line glyphs are narrow and are
applied to each half's cell as they are, so whichever rule is chosen must
let a narrow mask apply to one half.

### LEXTER-DRAFT-cell-model-O9 — What do the void and effect formats carry?

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
3. **With the plan's Phase 3.** The record as specified here: the format
   word, the header word, glyph words with their settings, the plain format
   with its glyph count and type bits, lines as glyphs with the single
   underline, the procedure of Drawing a Pixel in the shader, and palette
   slots allocated to terminals. The descriptor of
   LEXTER-DRAFT-cell-model-revision-D9 is written from these tables.
4. **With the plan's Phase 4.** The overlay instance and the block cursor's
   copy (LEXTER-DRAFT-cell-model-D13).
5. **With the plan's Phase 5.** The CPU renderer follows the same procedure.
6. **Later.** The inline-colour format; tiles, after
   LEXTER-DRAFT-cell-model-O1, -O6, and -O7; the void and effects, after the
   survey of surfaces; further underline styles, after
   LEXTER-DRAFT-cell-model-O4.
7. **The second edition specified.** Spec.DataStructures2e takes its record
   from this document.

## Appendices

### Worked records

In these records, swatch *s* has the background in slot 0 and the foreground
in slot 1, and *p* is the terminal's palette slot. Glyph words not listed are
zero. Type bits are written with glyph 5 first and glyph 1 last.

Table: A record of zeros.

| Word | Value | Meaning |
|---|---|---|
| 0 | 0 | The plain format, no glyphs, not wide |
| 1 | 0 | Swatch 0, palette slot 0 |
| Result | — | Every pixel in slot 0: a blank cell in the default background |

Table: The letter g, underlined in the text's colour.

| Word | Value |
|---|---|
| 0 | Plain, glyph count 2, type bits 00001 (glyph 1 a mask) |
| 1 | Swatch *s*, palette slot *p* |
| 2 | The atlas position of g; selector 0, ink slot 1, fill off |
| 3 | 9, the underline (8 + 0 + 1); selector 0, union |

Table: The letter g with an SGR 58 red underline and a strikethrough.

| Word | Value |
|---|---|
| 0 | Plain, glyph count 3, type bits 00001 (glyph 1 a mask, glyph 2 a layer) |
| 1 | A swatch whose slot 2 holds red, palette slot *p* |
| 2 | The atlas position of g; ink slot 1, fill off |
| 3 | 10, the strikethrough (8 + 0 + 2); selector 0, union |
| 4 | 9, the underline; ink slot 2, fill off |

Table: A spelling checker's red underline beneath the letter g.

| Word | Value |
|---|---|
| 0 | Plain, glyph count 2, type bits 00000 (both layers) |
| 1 | A swatch whose slot 2 holds red, palette slot *p* |
| 2 | 9, the underline; ink slot 2, fill off |
| 3 | The atlas position of g; ink slot 1, fill off |
| Result | The g drawn over the line; not read back as an SGR underline |

Table: A scroll bar's thumb as a band from two-eighths to six-eighths down
one cell.

| Word | Value |
|---|---|
| 0 | Plain, glyph count 3, type bits 00011 (glyphs 1 and 2 masks) |
| 2 | ▏, the bar; ink slot 1, fill off |
| 3 | ▆, the lower six-eighths; selector 0, intersection |
| 4 | ▂, the lower two-eighths; selector 1, intersection |

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
| 0 | Tiles, mode 0, wide 1, right half 0 |
| 1 | Swatch for the glyph layer, and a palette slot allocated to the tile set |
| 2 | The tile's index in the tile texture |
| 3 | 0, no glyph over the tile |
| 5–6 | Swatches A–D |
