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
  - LEXTER-0013
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
  - title:    "Clipping masks and masks in image editors and vector formats"
    locator:  "Adobe Photoshop clipping masks (a layer clipped by the layer beneath it); SVG 1.1 section 14, clipping, masking and compositing; PDF 1.7 section 11.6.5, soft masks"
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
header word, which holds the cell's colours and which every format reads the
same way. Cells of the glyph formats hold up to six glyph words, each
carrying its glyph and its settings, in which layers and masks are
interleaved and each mask cuts one or more of the layers before it. A layer
inks some of its pixels and leaves the rest transparent, and what no layer
inks takes the cell's background slot. The cursor and line attributes leave
the header, the cursor for the overlay list and the lines for generated
glyphs, and the palette slot widens to eight bits. Nothing here is built.
Each part is placed in the plan's phases under Roadmap.

## Canonical Terms

Table: Terms used in this design, with their definitions.

| Term | Definition |
|---|---|
| Record | The 32 bytes, eight 32-bit words, that describe one cell |
| Format | The arrangement of a record's words, selected by the record's first byte |
| Format word | Word 0: the format in bits 0–7, the wide bits in bits 16–17, and fields the format defines |
| Header word | Word 1: the swatch index, the palette slot, and the background slot, read the same way in every format |
| Glyph format | A format whose cells hold glyph words: plain, void, inline colours, and tiles |
| Glyph word | A word holding a 24-bit glyph and a settings byte, as a layer or as a mask |
| Glyph count, type bits | In a glyph format, the number of glyph words in use and, for glyphs 1–5, whether each is a layer or a mask |
| Layer | A display glyph with a selector and an ink slot; the pixels it covers take the ink slot, and the rest are transparent |
| Mask | A mask glyph with a selector, an operation, and a reach, which cuts one or more of the layers before it |
| Reach | The number of layers a mask cuts, counting back from the layer before it |
| Slot | One of a swatch's four palette indices |
| Background slot | The slot that a cell's pixels take where no layer covers them |
| Swatch | Four palette indices, stored in the swatch store and named by a 16-bit global index |
| Palette slot | The number of one 256-colour palette in the palette store |
| Payload | The words after a cell's glyph words that its format defines, such as inline colours |
| Generated glyph | A glyph that Lexter draws itself into a reserved atlas position, such as a line or a cursor |
| Line glyph | A generated glyph holding one combination of underline, strikethrough, and overline |
| Tile | A cell-sized picture of colour values 0–15, kept in the tile texture; a tile cell draws two beneath its glyphs |
| Transparency index, colour offset | In a tile cell, the value that is transparent in both tiles, and for each tile the number of swatches by which its other values are moved |
| Overlay instance | A record with a position and flags, drawn by the overlay pass over the grid |
| Void | A cell of the void format, which references a surface and leaves its uncovered pixels undrawn |

## Thesis / Concerns

**Every word has one job.** The format word says how the cell is arranged,
the header word what colours it draws in, and each glyph word one glyph and
how it is drawn. A layer and its masks are a run of words, so they are moved,
copied, or reordered as words. **Structure replaces addresses.** A mask cuts
the layers before it, so no mask names a layer. **Every layer is alike.** A
layer only inks; the background belongs to the cell. **Zero means nothing.**
A glyph count of 0 is no glyphs, a reach field of 0 cuts only the layer
before the mask, and a record of zeros is a valid blank cell. **The grid
holds static text.** What moves or lasts a moment, such as a cursor or a link
lit by the pointer, is an overlay; what belongs to the text, such as its
underline, is in the record, as a glyph rather than as bits that only the
shader understands.

**The cell model draws; it does not remember.** It models the cells the GPU
and the CPU renderer draw, and holds only what they read. The characters a
cell shows, which selection, copying, search, and screen readers need, are
kept in a text grid of their own (LEXTER-DRAFT-cell-model-revision-O8), and
hyperlink ids, protected cells, semantic zones, and the terminal's modes are
likewise state that Lexter keeps apart from the cell model. Writers keep the
two in step; this document specifies only the side that is drawn.

The design serves these concerns:

- **Exactness.** Every pixel is a selection of one palette entry or inline
  colour, so the GPU and the CPU renderer draw the same bytes
  (LEXTER-DRAFT-cell-model-revision-D15, -D16).
- **Uniformity.** One namespace of formats, one rule for how layers and masks
  compose, layers that differ only in their settings, and settings that
  travel with their glyph, so that writers and readers handle no special
  structures.
- **Fixed offsets.** The format, the wide bits, and the header sit at fixed
  places, so a reader learns a cell's shape and colours from its first eight
  bytes.
- **Normalisation.** The cell checksum
  (LEXTER-DRAFT-cell-model-revision-D13) takes unused and reserved fields as
  zero; here they are zero by rule, and each picture has one encoding.
- **Capacity for later formats.** The format byte has room for tiles,
  surfaces, effects, and formats not yet imagined, without a new record.
- **Two renderers, one procedure.** The less the shader does that is not a
  lookup, the less the CPU renderer must reproduce.

## Influences

Table: Influences on this design, what each contributes, and what is not
taken from it.

| Influence | Contributes | Not taken |
|---|---|---|
| [LEXTER-DRAFT-cell-field-format](Survey.CellFieldFormat.md) | A 32-byte record of control words, glyphs, and a tail; inline colours, surfaces, and tile mode; keeping what only the CPU reads beside the grid | The fixed three layers and three masks, a fill for each layer, the layer count and the cursor and line bits in the header, the tail type, payloads growing backwards into absent layers, and the fill rule |
| [LEXTER-0013](Survey.LayerMechanics.md) | Layers and masks in one dense record, and the mask code | — |
| [LEXTER-DRAFT-cell-model-revision](Plan.CellModelRevision.md) | Masks with an operation and a selector (LEXTER-DRAFT-cell-model-revision-D7), halves (-D8), the overlay list (-D10), one composed grid (-D12), integer colour stores (-D14), selection without blending (-D15) | The fixed layout of word 1 and the mask targets that LEXTER-DRAFT-cell-model-revision-D7 gives, with the tail type folded into unused masks |
| Clipping masks and masks (*Clipping masks and masks in image editors and vector formats*) | A mask attached by position to what it cuts, as Photoshop clips a layer by the one beneath it and SVG and PDF apply a mask to the object it is given; here the mask follows what it cuts | Masks with alpha: here a mask's pixels are inked or not |
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
  the cell's shape, like its format, and the header word is left to colours.
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
| 3 | Effect | — | Reserved for the effects of LEXTER-O11 |
| 4 | Tiles | Words 2–4, up to three | Two tiles and four swatches, beneath the glyphs (LEXTER-DRAFT-cell-model-D11) |
| 5–255 | Reserved | — | — |

A renderer that meets a format it does not know draws the cell as blank, in
the header's background slot. Only the format word's fixed fields and the
header word are common to every format, so a renderer cannot read an unknown
format's glyphs;
this ends the cell-field-format survey's fallback, in which a renderer that
met an unknown tail type still drew the cell's layers. Renderers and writers
ship together, so an unknown format means a fault, not an older renderer. In
a cell with inline colours, each slot's colour is read from the payload, and
neither the swatch store nor the palette is consulted. The void's reference
and the effect's contents are LEXTER-DRAFT-cell-model-O9.

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
| 0–7 | 8 | Format | 0 plain, 1 void, 2 inline colours, 4 tiles |
| 8–10 | 3 | Glyph count | 0–6 in the plain format, 0–3 in the others |
| 11–15 | 5 | Type bits | For glyphs 1–5: 0 layer, 1 mask; bits past the format's glyph words are zero |
| 16 | 1 | Wide | 1 = the cell holds half of a double-width glyph |
| 17 | 1 | Right half | With wide set: 0 = left half, 1 = right half |
| 18–31 | 14 | Defined by the format | Zero, except in tiles (LEXTER-DRAFT-cell-model-D11) |

A record of zeros is a plain cell with no glyphs and a background slot of 0:
every pixel takes slot 0 of global swatch 0 in palette slot 0
(LEXTER-DRAFT-cell-model-D10). Global swatch 0 and palette slot 0 must
always hold valid default colours; which table owns swatch 0 is
LEXTER-DRAFT-cell-model-revision-O4.

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
| 27–31 | 5 | Reserved | Zero |

Table: The settings byte of a mask.

| Bits | Width | Field | Values |
|---|---|---|---|
| 24 | 1 | Selector | 0 = the mask glyph's inked pixels; 1 = its uninked pixels |
| 25–26 | 2 | Operation | 0 union, 1 intersection, 2 exclusion, 3 the mask less the coverage |
| 27–29 | 3 | Reach | The mask cuts 1 + this many layers (LEXTER-DRAFT-cell-model-D5) |
| 30–31 | 2 | Reserved | Zero |

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

### LEXTER-DRAFT-cell-model-D5 — Layers and masks are interleaved, and each mask cuts the layers before it, as far as its reach

**Status:** Proposed

**Context:** A fixed three layers and three masks leaves masks unused in
most cells and cannot give a layer more than three cuts or a cell a fourth
layer. An earlier draft of this document counted layers and masks
separately, with masks after all the layers and a target in each, which needs
a target field, three passes, and coverage held for every layer. Some
pictures want one cut through several layers, such as a bar that reveals
text and its underline up to a point within the cell. The steward asked what
a variable layout costs the GPU.

**Decision:** A glyph format's glyph words are a sequence in which each
layer is followed by the masks that cut it, in the order they apply. A mask
cuts the layers before it: the most recent, and as many more as its reach
gives, counting back. A reach field of 0 cuts the most recent layer only,
and a reach that exceeds the layers before the mask cuts them all; writers
write the smallest field that gives the cut, so that each picture has one
record. Any number of layers and masks may be used, up to the format's glyph
words: six layers, or one layer and five masks, or anything between.

Nothing is lost against masks with targets: a mask only ever changes the
coverage of the layers it cuts, and layers are combined in order, so every
assignment of masks to single layers is written by placing each layer's
masks after it, and the reach adds cuts through several.

Table: The operations across several layers.

| Operation | Effect on the layers it reaches |
|---|---|
| Union | Each gains the mask's pixels; the topmost of them is drawn there, as if the reach were 1 |
| Intersection | Each loses what the mask lacks, so the layers beneath, or the background, show there |
| Exclusion | Each is inverted where the mask has pixels |
| The mask less the coverage | Each covers where the mask has pixels and it did not |

The renderer holds the coverage of the layers as one bit each in a small
integer. A layer sets its bit; a mask applies its operation, bitwise, to the
bits it reaches; and the topmost layer whose bit is set gives the pixel's
slot. The loops' bounds and the branch between layer and mask are the same
for every pixel of a cell, so a warp that lies inside one cell, as most of a
cell's pixels do, does not diverge. A warp across a cell boundary runs as
many iterations as its longest cell, which is never more than six, and a cell
of plain text reads one glyph. No array is indexed by a value from the
record, so nothing need leave the GPU's registers. Glyphs are read with
`texelFetch`, which takes no derivatives and so is defined in divergent
control flow (*OpenGL Shading Language 3.30 specification*).

**Alternatives:**
- Separate counts, masks after the layers, and a target in each mask.
  Rejected: it needs three passes and spends bits of every mask on an
  address that the order gives for free.
- A single bit in each mask that cuts every layer before it. Not chosen: the
  reach covers it, by its largest value, and also cuts the top layers while
  sparing those beneath, such as a highlight under the text.
- Three layers and three masks, as LEXTER-DRAFT-cell-model-revision-D7 has
  them. Rejected: it reads every slot in every cell and fixes how glyph words
  are shared between layers and masks.
- Mask *k* bound to layer *k*, for uniform loops. Rejected: neighbouring
  cells already differ in which glyphs they have, so it removes little
  divergence, and it cannot draw a band inside one cell.

### LEXTER-DRAFT-cell-model-D6 — The cell has one background slot, and layers have no fill

**Status:** Proposed

**Context:** The cell-field-format survey gives each layer a fill slot and a
fill-on bit, later replaced by a rule, so that a layer's uncovered pixels can
take a colour. A filled layer above the first paints every pixel of the cell,
its ink where it covers and its fill elsewhere, so every layer beneath it is
hidden and serves no purpose. A fill is meaningful only as the cell's
background.

**Decision:** A layer has a selector and an ink slot and no fill: the pixels
it covers take its ink slot, and the rest are transparent. The cell's
background slot, in bits 24–25 of the header word
(LEXTER-DRAFT-cell-model-D7), is the slot of every pixel that no layer
covers. Every layer is therefore alike, and the first differs from the others
only by being drawn first.

- **Reverse video needs no swatch of its own.** SGR 7 sets the background
  slot to the foreground's slot and the text's ink slot to the background's,
  within the same swatch, so a reversed cell interns nothing new.
- **The first edition maps directly.** A layered cell's `transparent-side`
  of `:bg` is a selector of 0 and of `:fg` a selector of 1; a layer of
  `:none` above the first hid the layers beneath it, so it becomes the first
  layer, with its background as the cell's background slot.
- **A solid cell** is a cell with no layers, in its background slot.

**Alternatives:**
- A fill slot and a fill-on bit in each layer. Rejected: a fill above the
  first layer hides everything beneath it, so the fields of every layer but
  the first could only do harm.
- The fill rule, a fill slot equal to the ink slot meaning no fill. Rejected
  for the same reason, and because changing one field changed the other's
  meaning.
- The background always in slot 0. Not chosen: reverse video would then need
  a swatch with its slots exchanged, which is the interning the critique
  found to grow without bound (LEXTER-DRAFT-data-structures-1e-critique-O6).

### LEXTER-DRAFT-cell-model-D7 — The header word holds the swatch, an eight-bit palette slot, and the background slot

**Status:** Proposed

**Context:** The cell-field-format survey's header holds the swatch index, a
two-bit palette slot, the wide bits, two cursor bits, the layer count, three
line bits, and a two-bit line colour slot. The cursor is drawn by the overlay
list (LEXTER-DRAFT-cell-model-revision-D10), the wide bits move to the
format word (LEXTER-DRAFT-cell-model-D1), the glyph count replaces the layer
count (LEXTER-DRAFT-cell-model-D3), lines become glyphs
(LEXTER-DRAFT-cell-model-D8), and the background moves from the layers to
the cell (LEXTER-DRAFT-cell-model-D6).

**Decision:**

Table: Bits of word 1, the header word.

| Bits | Width | Field | Values |
|---|---|---|---|
| 0–15 | 16 | Swatch index | A global index into the swatch store |
| 16–23 | 8 | Palette slot | 0–255 |
| 24–25 | 2 | Background slot | The slot of pixels that no layer covers |
| 26–31 | 6 | Reserved | Zero |

The header word holds all of the cell's colours, so a kernel that recolours
cells touches one word. The palette slot is a whole byte, so a writer sets it
with one byte store, and every format, tiles included, reaches every palette
the same way.

**Alternatives:**
- A six-bit slot for glyphs, with a two-bit extension for tiles. Not chosen
  by the steward: the extension is a special field for one format, where a
  uniform byte serves all; that glyph cells can name more palettes than
  terminals need costs nothing.
- The background slot in the format word, beside the wide bits. Not chosen
  by the steward: it is a colour, and the colours are kept together.
- Keep the cursor bits for the block style. Rejected: the block cursor is a
  transformed copy of the cell beneath it (LEXTER-DRAFT-cell-model-D13).
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
  any later layer, with a reach of one layer. When the text's selector is 0,
  the operation is union with the mask's inked pixels; when it is 1, the
  operation is intersection with the mask's uninked pixels, so that the line
  shows in the colour the glyph's strokes show in. The line costs a mask and
  no layer.
- **In a colour of its own, as the last layer.** An underline given a colour
  by SGR 58 is the last glyph word, a layer, so that it is drawn over the
  others, with the line glyph for underline alone and its ink slot holding
  the colour. Strikethrough and overline stay in the text's colour, as the
  text's last mask, so a cell may use both places.
- **Reading back.** The coloured underline is the last glyph word when it is
  a layer other than the first and holds a line glyph. The lines in the
  text's colour are the word before the second layer, or the last word when
  there is one layer, when it is a mask holding a line glyph. The second
  layer is found as the first 0 among the type bits, so no words are
  scanned. DECCARA, DECRARA, attribute reports, and copying with formatting
  read lines this way.
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

### LEXTER-DRAFT-cell-model-D9 — Generated glyphs have reserved atlas positions and names beyond Unicode

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

The atlas names generated glyph *k* by the value 0x110000 + *k* in its table
of codepoints. Such values lie beyond Unicode, whose last codepoint is
U+10FFFF: the decoder never produces them and no font maps them, so no host
can reach a generated glyph.

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

### LEXTER-DRAFT-cell-model-D10 — A pixel that no layer covers takes the background slot, except in a void

**Status:** Proposed

**Context:** Selection without blending
(LEXTER-DRAFT-cell-model-revision-D15) needs every pixel to end as one slot
or as nothing. A cell may have no layer that covers a given pixel, or no
glyphs at all.

**Decision:** A pixel that no layer covers takes the cell's background slot
(LEXTER-DRAFT-cell-model-D6). In a void, such a pixel is not drawn, so that
the surface beneath shows, and an overlay instance draws it only when its
flags say so (LEXTER-DRAFT-cell-model-D13). The procedure is given in full
under Drawing a Pixel, and both renderers follow it.

**Alternatives:**
- Leave uncovered pixels transparent in every cell. Rejected: a cell would
  then have no background of its own, and the grid's output would depend on
  what was drawn before it.

### LEXTER-DRAFT-cell-model-D11 — Tiles are a glyph format, with cell-sized tiles of sixteen colours beneath the glyphs

**Status:** Proposed

**Context:** The cell-field-format survey sketches tile mode: glyphs whose
pixels are colour indices 0–15, read through four swatches, for tile-based
games, boards, and cards. Indexed glyphs cannot share the font's atlas,
since a one-bit glyph read as indices, or an indexed glyph read as ink,
draws wrongly. A tile drawn over another needs a value that lets the one
beneath show, and two tiles in one cell may want different colours from the
same four swatches. Games want text written over their tiles.

**Decision:** A tile cell is format 4, a glyph format with up to three glyph
words, drawn over two tiles.

Table: The record of a tile cell.

| Word | Contents |
|---|---|
| 0 | Format 4; bits 8–10 the glyph count, 0–3; bits 11–12 the type bits of glyphs 1–2; bits 16–17 the wide bits, for the glyphs; bits 18–21 the transparency index; bits 22–23 the bottom tile's colour offset; bits 24–25 the top tile's colour offset; the rest reserved |
| 1 | The header word: the swatch for the glyph layers, the palette slot, and the background slot |
| 2–4 | Glyph words, as in any glyph format |
| 5 | The bottom tile (bits 0–15) and the top tile (bits 16–31), indices into the tile texture |
| 6 | Swatch A, colours 0–3 (bits 0–15); swatch B, colours 4–7 (bits 16–31) |
| 7 | Swatch C, colours 8–11; swatch D, colours 12–15 |

- **Cell-sized tiles.** A tile is the size of one cell. A larger picture is
  an array of tiles in neighbouring cells, as text is: a 16-by-16 picture is
  two tiles side by side in cells of 8 by 16, or four in cells of 8 by 8. Tile
  0 is no tile. The wide bits apply only to the glyphs, so any writing, of
  either width, can be drawn over tiles.
- **Sixteen colours, a transparency index, and offsets.** A tile's pixel
  holds a value *v*, 0–15. A value equal to the transparency index is
  transparent. Any other is moved by the tile's colour offset, a number of
  whole swatches, to *c* = (*v* + 4 × offset) mod 16, which selects slot *c*
  mod 4 of swatch *c* div 4 among A–D, in the header's palette slot. The
  transparency index is compared before the offset, so one index serves both
  tiles.
- **Order.** The bottom tile is drawn first, the top tile over it, and the
  glyph layers over both, with their masks. A pixel that none of them covers
  takes the background slot, as in every cell (LEXTER-DRAFT-cell-model-D10).
- **A common arrangement.** Tiles made to lie on top use colours 0–7 with 8
  as the transparency index and an offset of 0, in swatches A and B; tiles
  made to lie beneath use colours 0–7 with an offset of 2, in swatches C and
  D.
- **Masks cut glyph layers only.** A mask's reach is clamped to the glyph
  layers before it. Masks that cut tiles are a possibility left open: the
  format would need only to let a reach run one or two past the glyph layers,
  to the top tile and then the bottom one (LEXTER-DRAFT-cell-model-O7).
- **The tile texture.** Tiles are kept in a texture of their own with the
  internal format `R8UI`, one value to a texel, apart from the font's atlas.
  Sixteen bits address 65,536 tiles. The 1024-by-1024 texture that OpenGL 3.3
  guarantees holds 8192 tiles in cells of 8 by 16, or 16,384 in cells of 8
  by 8; on hardware with larger textures the index, not the texture, is the
  limit.
- **Palettes.** A tile set that wants palettes of its own is allocated slots
  as a terminal is (LEXTER-DRAFT-cell-model-D12).

**Alternatives:**
- Tiles as a format without glyph words, with unified and split modes, as an
  earlier draft of this document had them. Rejected: the modes divided
  sixteen colours in fixed ways that offsets and a transparency index make
  free, and they left no room for writing over the tiles.
- Tiles twice a cell wide, addressed with the wide bits. Rejected: a picture
  larger than two cells would need a position within it, and the wide bits
  could not then serve the glyphs drawn over the tiles.
- The transparency index and offsets in the header word. Not chosen by the
  steward: they say how a tile's values are read, not which colours a cell
  draws in, and the header word, common to every format, has only six bits
  spare.
- Offsets in slots, four bits each. Not chosen by the steward: offsets in
  whole swatches keep each tile's colours in whole swatches, and two bits
  each suffice to begin with.
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

### LEXTER-DRAFT-cell-model-D13 — An overlay instance carries a full record, and the block cursor is a transformed copy of the cell beneath it

**Status:** Proposed

**Context:** LEXTER-DRAFT-cell-model-revision-D10 gives each overlay instance
a glyph, up to two masks, a colour, and a position, and
LEXTER-DRAFT-cell-model-revision-O5 asks how the block cursor learns the cell
beneath it. A block cursor that reproduces the cell exactly must draw its
layers, its masks, and its half of a wide glyph, and its background as well
as its glyphs. Other overlays, such as an underline cursor, must leave the
cell beneath them showing.

**Decision:** An overlay instance is 48 bytes: a record, followed by a
position and flags.

Table: The overlay instance, by word.

| Word | Contents |
|---|---|
| 0–7 | A record, read as the grid reads one |
| 8 | Bits 0–15: x; bits 16–31: y; both signed, in cells or pixels |
| 9 | Bit 0: the unit of the position, 0 cells, 1 pixels; bit 1: draws background; bits 2–31 reserved |
| 10–11 | Reserved |

- **The pass** decodes the record with the grid's decoder and draws the
  pixels its layers cover. A pixel that no layer covers takes the background
  slot when the instance draws its background, and is discarded otherwise.
- **The block cursor** is an instance that draws its background, whose record
  is a copy of the cell beneath it with two fields exchanged: the header
  word's background slot and the first layer's ink slot. Other layers keep
  their colours, so a red SGR 58 underline stays red under the cursor. A cell
  with no layers takes slot 1 as its background in the copy if its own was
  slot 0, and slot 0 otherwise. The exchange assumes the text is the first
  layer, as it is in the cells the terminal writes; a cell arranged
  otherwise, such as one with a spelling checker's line beneath its text, is
  inverted by the same exchange, with the colours that result. The flush
  copies the record again whenever
  the cursor moves or its row changes. A cursor on a double-width glyph is
  two instances, one for each half.
- **The other styles** are instances that do not draw their background, of
  plain cells whose one glyph is a cursor glyph (LEXTER-DRAFT-cell-model-D9)
  in the cursor's colour.

The cursor needs no mode of its own in the shader: inversion is a change to
the copied record. The steward chose the full copy, which answers
LEXTER-DRAFT-cell-model-revision-O5.

**Alternatives:**
- An inverted flag, with the pass exchanging slots as it draws. Rejected: it
  is a special case in both renderers for what a change to the record does,
  and it left the cursor's background undrawn.
- Copy only the first layer's glyph and settings. Rejected: the cursor would
  drop the cell's other layers, its masks, and its lines.
- Keep cursor bits in the header for the block style. Rejected: it writes an
  ephemeral state into the static grid, which
  LEXTER-DRAFT-cell-model-revision-D10 keeps apart.

## The Record

Table: The record, by word, for each glyph format.

| Word | Plain | Void, inline colours | Tiles |
|---|---|---|---|
| 0 | Format word: format, glyph count, type bits, wide bits | The same | The same, with the transparency index and colour offsets |
| 1 | Header word: swatch, palette slot, background slot | The same | The same |
| 2–4 | Glyph words: each layer followed by its masks | Glyph words | Glyph words |
| 5–7 | More glyph words | The payload: a surface reference, or four colours | Two tiles; swatches A–D |

Records are stored row by row in the grid's array, which is the upload
buffer. On the GPU a record is two `uvec4` attributes of an instance, passed
to the fragment shader flat.

### Invariants of a record

Writers keep these, and the cell checksum relies on them:

- Every reserved bit is zero, and every bit a format does not define.
- In a glyph format, the glyph count is at most the format's glyph words, and
  the glyph words and type bits beyond it are zero.
- A mask's reach is at most the number of layers before it.
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
f  = word(0) & 0xFF
bg = (word(1) >> 24) & 3                         // the background slot
if f not in (PLAIN, VOID, INLINE, TILES): slot = bg; go to colour
n     = min((word(0) >> 8) & 7, (f == PLAIN) ? 6 : 3)
types = (word(0) >> 11) & 0x1F                   // bit i-1: glyph i is a mask
cov = 0; k = 0                                   // coverage bits; layers so far
for i in 0 .. n-1:
    p = pixel(glyph(i)) != selector(i)
    if i == 0 or not (types >> (i - 1)) & 1:     // a layer
        cov |= p << k; k += 1
    else:                                        // a mask
        r = min(reach(i) + 1, k)
        R = ((1 << r) - 1) << (k - r)            // the r layers before it
        m = p ? R : 0
        cov = (cov & ~R) | (op(i, cov, m) & R)
if cov == 0 and f == TILES:                      // no glyph covers: the tiles
    index = tile_index(word(5) >> 16, (word(0) >> 24) & 3)       // top
    if index is none:
        index = tile_index(word(5) & 0xFFFF, (word(0) >> 22) & 3) // bottom
    if index is not none:
        colour = palette[palette_slot * 256 + index]; done
slot = (f == VOID or not draws_background) ? NOTHING : bg
l = 0
for i in 0 .. n-1:                               // the topmost layer wins
    if i == 0 or not (types >> (i - 1)) & 1:
        if (cov >> l) & 1: slot = ink(i)
        l += 1
if slot == NOTHING: discard
colour:
colour = (f == INLINE) ? payload_colour(slot)
       : palette[palette_slot * 256 + swatch[swatch_index][slot]]

tile_index(t, offset):                           // a palette index, or none
    if t == 0: return none                       // no tile
    v = tile_pixel(t)                            // 0-15
    if v == (word(0) >> 18) & 15: return none    // the transparency index
    c  = (v + 4 * offset) mod 16
    s  = c div 4                                 // swatch A, B, C, or D
    sw = (word(6 + s div 2) >> (16 * (s mod 2))) & 0xFFFF
    return swatch[sw][c mod 4]
```

Description: The procedure reads the format from the first byte and the
background slot from the header word; an unknown format is drawn in the
background slot. For a glyph format it reads the glyph count, clamped to the
format's glyph words, and the type bits, and keeps one coverage bit for each
layer. A glyph that is a layer sets its bit to whether its glyph covers the
pixel under its selector. A glyph that is a mask finds whether its own glyph
covers the pixel, and combines that, by its operation, with the bits of the
layers it reaches: the most recent layer and as many before it as its reach
gives. In a tile cell, a pixel that no glyph layer covers is then given to
the top tile, or, where the top tile is absent or transparent, to the bottom
tile: the tile's value, unless it is the transparency index, is moved by the
tile's colour offset and selects a slot of one of swatches A–D. Otherwise a
second loop visits the layers in order and takes the ink slot of the topmost
layer whose bit is set. A pixel that nothing covers keeps the background
slot, or, in a void or an overlay instance that does not draw its
background, is discarded. The slot is then looked up in the inline colours
or in the swatch and the palette. In the grid, `draws_background` is always
true.

Table: Mask operations, applied to the bits the mask reaches.

| Operation | Coverage after the mask |
|---|---|
| 0 Union | Coverage or the mask's pixel |
| 1 Intersection | Coverage and the mask's pixel |
| 2 Exclusion | Coverage or the mask's pixel, but not both |
| 3 Mask less coverage | The mask's pixel and not the coverage |

The right half of a double-width glyph samples the second of the glyph's two
atlas columns; tiles are cell-sized and have no halves. The colour is written
as bytes, divided by 255 on the GPU, without blending
(LEXTER-DRAFT-cell-model-revision-D15).

## Palettes and Swatches

- **The swatch store** is a texture buffer of 65,536 swatches, `RGBA8UI`,
  each holding four palette indices. By convention slot 0 holds the
  background colour and slot 1 the foreground, as the first edition reads
  them (`src/shaders.lisp:+simple-frag+@2d4d743`); the background slot
  (LEXTER-DRAFT-cell-model-D6) chooses which is drawn as the background.
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
| Any combination in the text's colour | The text's last mask, before any later layer, reaching one layer | The combination's line glyph |
| An underline with an SGR 58 colour | The last glyph word, a layer whose ink slot holds the colour | The underline alone |
| Strikethrough or overline beside a coloured underline | The text's last mask | Their combination, without the underline |

Table: Where each cursor and pointer effect is drawn.

| Effect | Drawn by |
|---|---|
| Block cursor | An overlay instance that draws its background, copying the cell with its background slot and first ink slot exchanged (LEXTER-DRAFT-cell-model-D13) |
| Underline and bar cursors | An overlay instance with a cursor glyph, not drawing its background |
| A hyperlink lit by the pointer | An overlay instance with an underline glyph, not drawing its background |

## Open Questions

### LEXTER-DRAFT-cell-model-O1 — How is the block cursor drawn over a tile cell?

Exchanging the background slot with the first layer's ink slot inverts a tile
cell's glyphs and its background, but not its tiles, whose colours come from
swatches A–D. The cursor could be the outlined block glyph over such a cell,
or the tile format could define how its copy is transformed, such as by
exchanging swatches or offsets.

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

The header word has six reserved bits; the format word fourteen in the
plain, void, and inline-colour formats and six in tiles; a layer's settings
byte five; and a mask's two. The candidates are
effects for each layer, which need no payload and so could stand beside
masks. The bits stay reserved until a use is chosen; state that only the CPU
reads, such as the protected-cell bit of DECSCA
(LEXTER-DRAFT-cell-field-format-O7), belongs beside the cell model rather
than in it.

### LEXTER-DRAFT-cell-model-O6 — What happens when palette slots run out?

When the store's slots are all allocated, a new terminal could share the
default palette or a slot already in use, and a tile set could be refused or
given fewer palettes than it asks for. Whether the store can grow while
running, up to the 256 slots the record addresses, is open too.

### LEXTER-DRAFT-cell-model-O7 — How are tile sets fitted to the cell size, and may masks cut tiles?

LEXTER-DRAFT-cell-model-D11 answers LEXTER-DRAFT-cell-field-format-O1 with a
transparency index in each tile cell, and much of -O2 with tiles the size of
a cell. What remains of -O2 is how a tile set drawn at another size is
fitted: sliced into cells, scaled by an integer, bordered, or refused. Masks
that cut tiles are also open: a mask's reach could run one past the glyph
layers to cut the top tile, or two to cut the bottom tile as well, which
needs no new field, only a wider clamp and a coverage bit for each tile.

### LEXTER-DRAFT-cell-model-O8 — How does a mask apply to a wide display glyph?

It is LEXTER-DRAFT-cell-model-revision-O6. Line glyphs are narrow and are
applied to each half's cell as they are, so whichever rule is chosen must
let a narrow mask apply to one half.

### LEXTER-DRAFT-cell-model-O9 — What do the void and effect formats carry?

The cell-field-format survey's surface tile, a surface id and a column and
row within the surface, is the candidate for the void's payload, and it may
need fewer than three words, which would leave the void more glyph words.
The effect's contents are LEXTER-O11. Both are left to
the survey of surfaces and effects that LEXTER-DRAFT-cell-model-revision-D12
calls for.

## Roadmap

1. **With the plan's Phase 1.** The atlas reserves positions 0–63 and names
   generated glyphs from 0x110000, and the cursor glyphs move from
   private-use codepoints to positions 1–4 (LEXTER-DRAFT-cell-model-D9).
2. **With the plan's Phase 2.** The palette store, sized by the
   configuration (LEXTER-DRAFT-cell-model-D12), with the integer stores of
   LEXTER-DRAFT-cell-model-revision-D14.
3. **With the plan's Phase 3.** The record as specified here: the format
   word, the header word with its background slot, glyph words with their
   settings, the plain format with its glyph count and type bits, masks with
   their reach, lines as glyphs with the single underline, the procedure of
   Drawing a Pixel in the shader, and palette slots allocated to terminals.
   The descriptor of LEXTER-DRAFT-cell-model-revision-D9 is written from
   these tables.
4. **With the plan's Phase 4.** The overlay instance and the block cursor's
   transformed copy (LEXTER-DRAFT-cell-model-D13).
5. **With the plan's Phase 5.** The CPU renderer follows the same procedure.
6. **Later.** The inline-colour format; tiles and their texture, after
   LEXTER-DRAFT-cell-model-O1 and -O6, and the fitting of tile sets of
   LEXTER-DRAFT-cell-model-O7; the void and effects, after the survey of
   surfaces; further underline styles, after LEXTER-DRAFT-cell-model-O4.
7. **The second edition specified.** Spec.DataStructures2e takes its record
   from this document.

## Appendices

### Worked records

In these records, swatch *s* has the background colour in slot 0 and the
foreground in slot 1, and *p* is the terminal's palette slot. Glyph words not
listed are zero, as are reach fields not given. Type bits are written with
glyph 5 first and glyph 1 last.

Table: A record of zeros.

| Word | Value | Meaning |
|---|---|---|
| 0 | 0 | The plain format, no glyphs, not wide |
| 1 | 0 | Swatch 0, palette slot 0, background slot 0 |
| Result | — | Every pixel in slot 0: a blank cell in the default background |

Table: The letter g, underlined in the text's colour.

| Word | Value |
|---|---|
| 0 | Plain, glyph count 2, type bits 00001 (glyph 1 a mask) |
| 1 | Swatch *s*, palette slot *p*, background slot 0 |
| 2 | The atlas position of g; selector 0, ink slot 1 |
| 3 | 9, the underline (8 + 0 + 1); selector 0, union, reach field 0 |

Table: The letter g in reverse video.

| Word | Value |
|---|---|
| 0 | Plain, glyph count 1 |
| 1 | Swatch *s*, palette slot *p*, background slot 1 |
| 2 | The atlas position of g; selector 0, ink slot 0 |
| Result | The foreground colour behind a g in the background colour, from the same swatch |

Table: The letter g with an SGR 58 red underline and a strikethrough.

| Word | Value |
|---|---|
| 0 | Plain, glyph count 3, type bits 00001 (glyph 1 a mask, glyph 2 a layer) |
| 1 | A swatch whose slot 2 holds red, palette slot *p*, background slot 0 |
| 2 | The atlas position of g; ink slot 1 |
| 3 | 10, the strikethrough (8 + 0 + 2); selector 0, union |
| 4 | 9, the underline; ink slot 2 |

Table: A spelling checker's red underline beneath the letter g.

| Word | Value |
|---|---|
| 0 | Plain, glyph count 2, type bits 00000 (both layers) |
| 1 | A swatch whose slot 2 holds red, palette slot *p*, background slot 0 |
| 2 | 9, the underline; ink slot 2 |
| 3 | The atlas position of g; ink slot 1 |
| Result | The g drawn over the line; not read back as an SGR underline |

Table: A scroll bar's thumb as a band from two-eighths to six-eighths down
one cell.

| Word | Value |
|---|---|
| 0 | Plain, glyph count 3, type bits 00011 (glyphs 1 and 2 masks) |
| 2 | ▏, the bar; ink slot 1 |
| 3 | ▆, the lower six-eighths; selector 0, intersection |
| 4 | ▂, the lower two-eighths; selector 1, intersection |

Table: The underlined g with a coloured underline, revealed up to the middle
of the cell by one mask.

| Word | Value |
|---|---|
| 0 | Plain, glyph count 3, type bits 00010 (glyph 2 a mask) |
| 1 | A swatch whose slot 2 holds red, palette slot *p*, background slot 0 |
| 2 | The atlas position of g; ink slot 1 |
| 3 | 9, the underline; ink slot 2 |
| 4 | ▌, the left half; selector 0, intersection, reach field 1 (two layers) |
| Result | The g and its underline in the left half; the background in the right |

Table: A block cursor over the underlined g.

| Word | Value |
|---|---|
| 0 | As in the underlined g |
| 1 | Swatch *s*, palette slot *p*, background slot 1 (exchanged) |
| 2 | The atlas position of g; selector 0, ink slot 0 (exchanged) |
| 3 | As in the underlined g |
| 8 | The cell's column and row |
| 9 | Unit 0 (cells), draws background |
| Result | The foreground colour behind the g and its underline, drawn in the background colour |

Table: A chess piece on a board square, with a half-width label, in one tile
cell.

| Word | Value |
|---|---|
| 0 | Tiles, glyph count 1; transparency index 8; bottom offset 2, top offset 0 |
| 1 | Swatch *s* for the label, a palette slot allocated to the tile set, background slot 0 |
| 2 | The atlas position of the label's letter; ink slot 1 |
| 5 | The square's tile (bits 0–15), drawn in colours 0–7; the piece's tile (bits 16–31), in colours 0–7 with 8 where the square shows through |
| 6 | Swatches A and B, the piece's eight colours |
| 7 | Swatches C and D, the square's eight colours, reached through the offset of 2 |
| Result | The square, the piece over it, and the letter over both |
