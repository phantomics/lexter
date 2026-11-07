---
id:            LEXTER-0016
title:         "The Cell Model Architecture"
genre:         Architecture
scope:         project
project:       Lexter
language:      en
status:        Accepted
authors:
  - Andrew Sengul
approved-by:   Andrew Sengul
reviewed:      2026-11-06
provenance:
  assistant:   opencode
  session:     "Cell model revision plan (2026-11-02), the dense cell model"
relates-to:
  - LEXTER-DRAFT-cell-model-revision
  - LEXTER-DRAFT-cell-field-format
  - LEXTER-0013
  - LEXTER-DRAFT-data-structures-1e
  - LEXTER-0014
  - LEXTER-0004
  - LEXTER-0007
decisions:
  - LEXTER-D81
  - LEXTER-D82
  - LEXTER-D83
  - LEXTER-D84
  - LEXTER-D85
  - LEXTER-D86
  - LEXTER-D87
  - LEXTER-D88
  - LEXTER-D89
  - LEXTER-D90
  - LEXTER-D91
  - LEXTER-D92
  - LEXTER-D93
  - LEXTER-D94
  - LEXTER-D95
open-questions:
  - LEXTER-O45
  - LEXTER-O46
  - LEXTER-O47
  - LEXTER-O48
  - LEXTER-O49
  - LEXTER-O50
  - LEXTER-O51
  - LEXTER-O52
  - LEXTER-O53
  - LEXTER-O54
  - LEXTER-O55
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
  - title:    "CSS Text Decoration Module"
    locator:  "CSS Text Decoration Module Level 3, section 5.1, painting order of text decorations: underlines and overlines beneath the text, line-through over it"
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
are arranged, whether the cell is half of a double-width glyph, and whether
its text blinks, and a header word, which holds the cell's colours and which
every format reads the same way. Cells of the glyph formats hold up to six
glyph words, each carrying its glyph and its settings, in which layers and
masks are interleaved and each mask cuts one or more of the layers before it.
A layer inks some of its pixels and leaves the rest transparent, and what no
layer inks takes the cell's background slot. The cursor and line attributes
leave the header, the cursor for the overlay list and the lines for generated
glyphs, and the palette slot widens to eight bits. Nothing here is built. Each
part is placed in the plan's phases under Roadmap.

## Canonical Terms

Table: Terms used in this design, with their definitions.

| Term | Definition |
|---|---|
| Record | The 32 bytes, eight 32-bit words, that describe one cell |
| Format | The arrangement of a record's words, selected by the record's first byte |
| Format word | Word 0: the format in byte 0, the format's structure in byte 1, flags common to every format in byte 2, and the format's parameters in byte 3 |
| Drawing flags | Bits 16–18 of the format word, at the same place in every format: wide, right half, and blink |
| Header word | Word 1: the swatch index, the palette slot, and the background slot, read the same way in every format, and colour parameters the format defines |
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
| Transparency field, colour offset | In a tile cell, the field that makes one value of the top tile transparent, the first colour of a swatch; and for each tile the number of swatches by which its values are moved |
| Swatch pair, colour cycle | Swatches A–B or C–D of a tile cell, eight colour positions each; a cycle rotates some of a pair's colours, or all sixteen, on a clock |
| Blink, blink phase | A flag that makes a cell's topmost layer disappear while the window's blink phase is off, and the phase itself, a clock shared with the cursor |
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
  (LEXTER-DRAFT-cell-model-revision-D15, LEXTER-DRAFT-cell-model-revision-D16).
- **Uniformity.** One namespace of formats, one rule for how layers and masks
  compose, layers that differ only in their settings, and settings that
  travel with their glyph, so that writers and readers handle no special
  structures.
- **Fixed offsets.** The format, the drawing flags, and the header sit at
  fixed places, so a reader learns a cell's shape and colours from its first
  eight bytes.
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
| [LEXTER-DRAFT-cell-model-revision](Plan.CellModelRevision.md) | Masks with an operation and a selector (LEXTER-DRAFT-cell-model-revision-D7), halves (LEXTER-DRAFT-cell-model-revision-D8), the overlay list (LEXTER-DRAFT-cell-model-revision-D10), one composed grid (LEXTER-DRAFT-cell-model-revision-D12), integer colour stores (LEXTER-DRAFT-cell-model-revision-D14), selection without blending (LEXTER-DRAFT-cell-model-revision-D15) | The fixed layout of word 1 and the mask targets that LEXTER-DRAFT-cell-model-revision-D7 gives, with the tail type folded into unused masks |
| Clipping masks and masks (*Clipping masks and masks in image editors and vector formats*) | A mask attached by position to what it cuts, as Photoshop clips a layer by the one beneath it and SVG and PDF apply a mask to the object it is given; here the mask follows what it cuts | Masks with alpha: here a mask's pixels are inked or not |
| CSS text decoration (*CSS Text Decoration Module*) | Underlines and overlines painted beneath the text, line-through over it, which places a coloured underline beneath the text | The deprecated `blink` value, which blinks the text with its decorations; here a coloured underline beneath the text stays |
| VGA and MDA text attributes | A cell as a fixed record that the display reads directly | Underline as an attribute bit, which only the display hardware can draw |
| kitty | Underline and strikethrough drawn as generated sprites in its sprite map (*kitty decorations*) | — |
| XLFD font properties | The position and thickness of the underline and the strikeout, which BDF and PCF fonts may carry (*X Logical Font Description Conventions*) | — |
| Zero-initialised memory | Fresh and cleared memory as a valid initial value, as `calloc` and zeroed pages give | — |
| Nerd Fonts | A warning: fonts use the private-use areas of the Basic Multilingual Plane and of plane 15 (*Nerd Fonts glyph sets*), where Lexter now keys its cursor glyphs | Private-use codepoints for generated glyphs |

## Settled Decisions

### LEXTER-D81 — The format word comes first, with one job for each of its bytes

**Status:** Accepted

**Context:** The cell-field-format survey opens the record with a header and
a word of layer settings, finds a cell's arrangement from a tail type in the
settings word, and keeps the wide bits in the header. With each glyph's
settings in its own word (LEXTER-D84), a whole word is free
to say how the cell is arranged. Whether a cell is half of a double-width
glyph describes its shape, as its format does, and the wide-pair helpers,
edge repair, and resizing read it in every cell.

**Decision:** Word 0 is the format word, and each of its bytes has one job.

Table: The bytes of the format word.

| Byte | Bits | Job |
|---|---|---|
| 0 | 0–7 | The format (LEXTER-D82) |
| 1 | 8–15 | The format's structure: in a glyph format, the glyph count and type bits (LEXTER-D83) |
| 2 | 16–23 | Drawing flags common to every format: wide (16), right half (17), and blink (18, LEXTER-D94); 19–23 reserved |
| 3 | 24–31 | The format's parameters, zero where it defines none |

Byte 0 and bits 16–18 are at the same places in every format. The wide bit
is 1 when the cell holds half of a double-width glyph, and the right-half bit,
with wide set, is 0 for the left half and 1 for the right; both are zero
where a format has no halves. Bits 19–23 are reserved: flags common to every
format are allocated from bit 19 upwards, and a format whose parameters
outgrow byte 3 may claim bits from 23 downwards, so that a reader always
finds the common flags at the bottom of byte 2. Word 1 is the header word
(LEXTER-D87): its swatch index, palette slot, and background slot are read
the same way in every record, and no format may redefine them; its last six
bits are colour parameters that the format defines.
The first eight bytes therefore say what a cell is, its shape, and what
colours it draws in, and a kernel reads or changes them with one 64-bit
operation, or one flag with a byte store.

**Alternatives:**
- The header first and the format second. Not chosen by the steward: the
  record reads more naturally as how the cell is arranged, then everything
  else, and a dump shows the format in its first byte. Neither order costs
  the GPU or SIMD anything, since a record is fetched whole.
- The wide bits in the header word. Not chosen by the steward: they describe
  the cell's shape, like its format, and the header word is left to colours.
- A subtype value in byte 1 for blinking cells. Not chosen: blink is
  independent of the format, so each subtype would need a blinking variant,
  where a flag at a fixed place serves every format.
- The wide bits placed by each format. Rejected: the wide-pair helpers would
  first have to ask which format a cell has.
- Formats that may redefine the header word's swatch, palette slot, or
  background slot. Rejected: they are read by the row copies, colour
  animation, the cell checksum, and both renderers, which should not first
  ask what format a cell has. Only the colour parameters, which the renderers
  alone read, belong to the format.

### LEXTER-D82 — One namespace of formats names every cell

**Status:** Accepted

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
| 4 | Tiles | Words 2–4, up to three | Two tiles and four swatches, beneath the glyphs (LEXTER-D91) |
| 5–255 | Reserved | — | — |

A renderer that meets a format it does not know draws the cell as blank, in
the header's background slot. Only the format word's fixed fields and the
header word's swatch, palette slot, and background slot are common to every
format, so a renderer cannot read an unknown format's glyphs;
this ends the cell-field-format survey's fallback, in which a renderer that
met an unknown tail type still drew the cell's layers. Renderers and writers
ship together, so an unknown format means a fault, not an older renderer. In
a cell with inline colours, each slot's colour is read from the payload, and
neither the swatch store nor the palette is consulted. The void's reference
and the effect's contents are LEXTER-O53.

**Alternatives:**
- Escape cells beside tail types. Rejected: two kinds of special cell, found
  by two tests, where one byte serves.
- The tail type in the bits of unused masks, as
  LEXTER-DRAFT-cell-model-revision-D7 has it. Rejected: finding it depends on
  four fields, and it limits formats to eight.
- The word "kind", or "template", for the format. Not chosen by the steward:
  "kind" is too general to be clear, and "template" suggests a generic form
  specialised for particular uses, which this is not.

### LEXTER-D83 — A glyph format gives its glyph count and type bits in the format word, and they are authoritative

**Status:** Accepted

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
| 18 | 1 | Blink | 1 = the topmost layer blinks (LEXTER-D94) |
| 19–23 | 5 | Reserved | Common flags from bit 19 upwards (LEXTER-D81) |
| 24–31 | 8 | The format's parameters | Zero, except in tiles (LEXTER-D91) |

A record of zeros is a plain cell with no glyphs and a background slot of 0:
every pixel takes slot 0 of global swatch 0 in palette slot 0
(LEXTER-D90). Global swatch 0 and palette slot 0 must
always hold valid default colours; which table owns swatch 0 is
LEXTER-DRAFT-cell-model-revision-O4.

Writers never produce a glyph count beyond the format's glyph words.
Renderers still clamp it, so that a bad record cannot read past them.

**Alternatives:**
- Separate counts of layers and masks, with masks after all the layers and
  a target in each. Rejected: it needs a target field in every mask and
  three passes to compose (LEXTER-D85).
- A stop bit above the type bits instead of a count. Rejected: finding it
  needs `findMSB`, which GLSL 3.30 lacks, or a loop.
- A count found from glyphs of 0. Rejected: a blank cell would fetch empty
  glyphs, and a mask of glyph 0 would be neutral only under union.

### LEXTER-D84 — Each glyph word holds a 24-bit glyph and its own settings byte

**Status:** Accepted

**Context:** The cell-field-format survey keeps the settings of all three
layers and masks in word 1, apart from their glyphs, so moving a layer means
moving a glyph and rewriting a field elsewhere. Atlas positions need far
fewer than 32 bits.

**Decision:** Bits 0–23 of a glyph word are an atlas position, below
16,777,216, and bits 24–31 are the settings of that layer or mask. Whether it
is a layer or a mask is given by the type bits
(LEXTER-D83), so the byte needs no flag. Bit 24 is the
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
| 27–29 | 3 | Reach | The mask cuts 1 + this many layers (LEXTER-D85) |
| 30–31 | 2 | Reserved | Zero |

Writing only a glyph, or only a setting, masks the rest of the word; the
accessors generated from LEXTER-DRAFT-cell-model-revision-D9's descriptor do
this, and writers use nothing else. The reserved bits are left for later use
(LEXTER-O49).

**Alternatives:**
- Settings in word 1, as the survey and
  LEXTER-DRAFT-cell-model-revision-D7 have them. Rejected: a layer would be
  split across two words, and the word is better spent on the cell as a
  whole.
- A flag in each byte saying layer or mask. Rejected by the steward: the type
  bits already say it, and a redundant field must itself be kept consistent.
  Records are checked by assertions in debugging builds instead.

### LEXTER-D85 — Layers and masks are interleaved, and each mask cuts the layers before it, as far as its reach

**Status:** Accepted

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

### LEXTER-D86 — The cell has one background slot, and layers have no fill

**Status:** Accepted

**Context:** The cell-field-format survey gives each layer a fill slot and a
fill-on bit, later replaced by a rule, so that a layer's uncovered pixels can
take a colour. A filled layer above the first paints every pixel of the cell,
its ink where it covers and its fill elsewhere, so every layer beneath it is
hidden and serves no purpose. A fill is meaningful only as the cell's
background.

**Decision:** A layer has a selector and an ink slot and no fill: the pixels
it covers take its ink slot, and the rest are transparent. The cell's
background slot, in bits 24–25 of the header word
(LEXTER-D87), is the slot of every pixel that no layer
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
  found to grow without bound (LEXTER-O24).

### LEXTER-D87 — The header word holds the swatch, an eight-bit palette slot, the background slot, and the format's colour parameters

**Status:** Accepted

**Context:** The cell-field-format survey's header holds the swatch index, a
two-bit palette slot, the wide bits, two cursor bits, the layer count, three
line bits, and a two-bit line colour slot. The cursor is drawn by the overlay
list (LEXTER-DRAFT-cell-model-revision-D10), the wide bits move to the
format word (LEXTER-D81), the glyph count replaces the layer
count (LEXTER-D83), lines become glyphs
(LEXTER-D88), and the background moves from the layers to
the cell (LEXTER-D86).

**Decision:**

Table: Bits of word 1, the header word.

| Bits | Width | Field | Values |
|---|---|---|---|
| 0–15 | 16 | Swatch index | A global index into the swatch store |
| 16–23 | 8 | Palette slot | 0–255 |
| 24–25 | 2 | Background slot | The slot of pixels that no layer covers |
| 26–31 | 6 | Colour parameters | Defined by the format, as tiles define their colour cycles (LEXTER-D95); zero where the format defines none |

Bits 0–25 mean the same in every format. Bits 26–31 hold colour behaviour that
a format defines, as byte 3 of the format word holds its other parameters;
only the renderers read them. The header word holds all of the cell's colours,
so a kernel that recolours cells touches one word. The palette slot is a whole
byte, so a writer sets it with one byte store, and every format, tiles
included, reaches every palette the same way.

**Alternatives:**
- A six-bit slot for glyphs, with a two-bit extension for tiles. Not chosen
  by the steward: the extension is a special field for one format, where a
  uniform byte serves all; that glyph cells can name more palettes than
  terminals need costs nothing.
- The background slot in the format word, beside the wide bits. Not chosen
  by the steward: it is a colour, and the colours are kept together.
- Bits 26–31 kept for parameters common to every format. Not chosen by the
  steward: it is too restrictive, since colour behaviour that one format
  has, such as cycling a tile's colours, belongs with the colours.
- Keep the cursor bits for the block style. Rejected: the block cursor is a
  transformed copy of the cell beneath it (LEXTER-D93).
- Keep the line bits, drawn by the shader as rules. Rejected for the reasons
  LEXTER-D88 gives.

### LEXTER-D88 — Lines are glyphs: a mask on the text in the text's colour, or a layer beneath the text in their own

**Status:** Accepted

**Context:** Underline, strikethrough, and overline belong to the text, not to
a moment, so they belong in the grid. As header bits they cost five bits with
their colour slot, need both renderers to draw rules from the font's
metrics, and leave no room for the further underline styles terminals now
support. Heavy use of layers is expected to be rare in text cells. CSS paints
underlines and overlines beneath the text they decorate and line-through
over it (*CSS Text Decoration Module*, painting order); ECMA-48 and the DEC
documents define the attributes but not the order they are painted in.

**Decision:** A line is drawn by a line glyph (LEXTER-D89)
holding the cell's combination of lines. In a cell that the terminal writes,
the text is the topmost layer, and lines take one of two places:

- **In the text's colour, as the cell's last mask.** Lines that take the
  colour of the text are a mask placed after the text's other masks, with a
  reach of one layer, so that it cuts the text. When the text's selector is
  0, the operation is union with the mask's inked pixels; when it is 1, the
  operation is intersection with the mask's uninked pixels, so that the line
  shows in the colour the glyph's strokes show in. The line merges with the
  glyph's pixels, so whether it lies over or under the text makes no
  difference. The line costs a mask and no layer.
- **In a colour of its own, as the layer beneath the text.** An underline
  given a colour by SGR 58 is a layer directly beneath the text's layer,
  with the line glyph for underline alone and its ink slot holding the
  colour, so that the text's descenders cross over it, as CSS paints an
  underline. Strikethrough and overline stay in the text's colour, as the
  cell's last mask, so a cell may use both places. Adding a coloured
  underline inserts a layer word before the text's layer, moving the text
  and its masks along by one word and inserting a type bit.
- **Reading back.** The lines in the text's colour are the last glyph word,
  when it is a mask holding a line glyph. The coloured underline is the layer
  directly beneath the topmost, when it holds a line glyph of a style the
  terminal writes; it is found from the type bits, so no words are scanned.
  DECCARA, DECRARA, attribute reports, and copying with formatting read
  lines this way.
- **Other arrangements** are drawn as any layer or mask is. A spelling
  checker's red wavy underline beneath the text has the shape of a coloured
  underline, so it is drawn in a line style the terminal does not write
  (LEXTER-O48), and reading back passes it over.
- **Ephemeral lines** are not lines in this sense. A hyperlink underlined
  while the pointer is over it is an overlay instance.

Only the single underline style is defined at first. A cell whose glyph
words are all in use has no room for a line (LEXTER-O47). A blinking cell's
text blinks with the lines in its colour, and its coloured underline, which
lies beneath, stays (LEXTER-D94).

**Alternatives:**
- A coloured underline as the last layer, over the text. Rejected: it was
  first chosen by default, and CSS paints underlines beneath the text. It
  would also leave the text beneath another layer, so that blink and the
  block cursor could not find it as the topmost layer.
- Header bits drawn as rules, as the cell-field-format survey proposed.
  Rejected: they spend five header bits, need drawing code in both renderers,
  and have no room for styles.
- Every line as a layer. Not chosen: the common case, an underline in the
  text's colour, would spend a layer where a mask serves.

### LEXTER-D89 — Generated glyphs have reserved atlas positions and names beyond Unicode

**Status:** Accepted

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
left for others (LEXTER-O48). A reader recovers a line
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
its own line glyphs is LEXTER-O46.

**Alternatives:**
- Private-use codepoints. Rejected: the Basic Multilingual Plane's area holds
  Powerline's and Nerd Fonts' symbols, plane 15 holds Nerd Fonts' Material
  Design Icons, and plane 16, though seldom used, is open to any font.
- Generated glyphs after the font's, as `add-cursor-glyphs` appends them now.
  Rejected: their positions would depend on the font, and the range test
  would need the font's glyph count.

### LEXTER-D90 — A pixel that no layer covers takes the background slot, except in a void

**Status:** Accepted

**Context:** Selection without blending
(LEXTER-DRAFT-cell-model-revision-D15) needs every pixel to end as one slot
or as nothing. A cell may have no layer that covers a given pixel, or no
glyphs at all.

**Decision:** A pixel that no layer covers takes the cell's background slot
(LEXTER-D86). In a void, such a pixel is not drawn, so that
the surface beneath shows, and an overlay instance draws it only when its
flags say so (LEXTER-D93). The procedure is given in full
under Drawing a Pixel, and both renderers follow it.

**Alternatives:**
- Leave uncovered pixels transparent in every cell. Rejected: a cell would
  then have no background of its own, and the grid's output would depend on
  what was drawn before it.

### LEXTER-D91 — Tiles are a glyph format, with two cell-sized tiles of sixteen colours drawn with the glyphs

**Status:** Accepted

**Context:** The cell-field-format survey sketches tile mode: glyphs whose
pixels are colour indices 0–15, read through four swatches, for tile-based
games, boards, and cards. Indexed glyphs cannot share the font's atlas,
since a one-bit glyph read as indices, or an indexed glyph read as ink,
draws wrongly. A tile drawn over another needs a value that lets the one
beneath show, and two tiles in one cell may want different colours from the
same four swatches. Games want text written over their tiles, and sometimes a
piece passing in front of a label. Tile systems mirror their tiles, so that
one tile serves several orientations.

**Decision:** A tile cell is format 4, a glyph format with up to three glyph
words, drawn over two tiles.

Table: The record of a tile cell.

| Word | Contents |
|---|---|
| 0 | Format 4; bits 8–10 the glyph count, 0–3; bits 11–12 the type bits of glyphs 1–2; bits 16–18 the drawing flags, for the glyphs; bit 23 the top tile above the glyphs; bits 24–25 the top tile's transparency field; bits 28–29 the bottom tile's colour offset; bits 30–31 the top tile's colour offset; the rest reserved |
| 1 | The header word: the swatch for the glyph layers, the palette slot, and the background slot; bits 26–30 the colour cycles of swatches A–B and C–D (LEXTER-D95) |
| 2–4 | Glyph words, as in any glyph format |
| 5 | The bottom tile (bits 0–15) and the top tile (bits 16–31) |
| 6 | Swatch A, colours 0–3 (bits 0–15); swatch B, colours 4–7 (bits 16–31) |
| 7 | Swatch C, colours 8–11; swatch D, colours 12–15 |

Table: Each 16-bit tile field in word 5.

| Bits | Field |
|---|---|
| 0–13 | The tile's index in the tile texture; 0 is no tile |
| 14 | Horizontal flip |
| 15 | Vertical flip |

- **Cell-sized tiles.** A tile is the size of one cell. A larger picture is
  an array of tiles in neighbouring cells, as text is: a 16-by-16 picture is
  two tiles side by side in cells of 8 by 16, or four in cells of 8 by 8. Tile
  0 is no tile, and its flip bits are zero. The wide bits apply only to the
  glyphs, so any writing, of either width, can be drawn over tiles.
- **Flips.** Each tile field carries a horizontal and a vertical flip, so
  that a tile is drawn as itself, as either mirror image, or turned by a half
  turn: a renderer reads column *w* − 1 − *x*, or row *h* − 1 − *y*. Quarter
  turns are not offered, since cells are seldom square. A picture several
  cells wide is mirrored by writing its tiles in reverse order, each flipped.
- **Sixteen colours and offsets.** A tile's pixel holds a value *v*, 0–15,
  which the tile's colour offset, a number of whole swatches, moves to the
  colour position *c* = (*v* + 4 × offset) mod 16; *c* selects slot *c* mod 4
  of swatch *c* div 4 among A–D, in the header's palette slot.
- **Only the top tile is transparent.** The top tile's value 4 × *t*, where
  *t* is its 2-bit transparency field, is transparent: the first colour of
  swatch A, B, C, or D, before the offset moves it. The bottom tile is
  opaque; a picture that should show the cell's background beneath it uses
  the top tile alone, with tile 0 beneath. The transparent value is tested
  before the offset and any cycle, so a transparent pixel never cycles.
- **Order.** The bottom tile is drawn first, the top tile over it, and the
  glyph layers over both, with their masks. When bit 23 of the format word is
  set, the top tile is drawn over the glyph layers instead, and the bottom
  tile stays beneath them, so that a piece can pass in front of a label. Bit
  23 is the top of byte 2, which a format may claim (LEXTER-D81). A pixel
  that none of them covers takes the background slot, as in every cell
  (LEXTER-D90).
- **Colour cycling.** Each tile may cycle its colours on a clock of its own,
  by fields in the header word's colour parameters
  (LEXTER-D95).
- **A common arrangement.** Tiles made to lie on top use colours 0–7 in
  swatches A and B, with an offset of 0 and a transparency field of 2, so
  that value 8 is transparent and all eight colours can cycle; tiles made to
  lie beneath use colours 0–7 with an offset of 2, in swatches C and D, and
  keep all eight. The arcade convention, value 0 transparent, is a field of
  0.
- **Masks cut glyph layers only.** A mask's reach is clamped to the glyph
  layers before it. Masks that cut tiles are left for later
  (LEXTER-O55).
- **The tile texture.** Tiles are kept in a texture of their own with the
  internal format `R8UI`, one value to a texel, apart from the font's atlas.
  Fourteen bits address 16,384 tiles, which the flips make serve up to four
  times as many orientations. The 1024-by-1024 texture that OpenGL 3.3
  guarantees holds 8192 tiles in cells of 8 by 16, or 16,384 in cells of 8
  by 8.
- **Palettes.** A tile set that wants palettes of its own is allocated slots
  as a terminal is (LEXTER-D92).

**Alternatives:**
- Tiles as a format without glyph words, with unified and split modes, as an
  earlier draft of this document had them. Rejected: the modes divided
  sixteen colours in fixed ways that offsets and a transparent value make
  free, and they left no room for writing over the tiles.
- Tiles twice a cell wide, addressed with the wide bits. Rejected: a picture
  larger than two cells would need a position within it, and the wide bits
  could not then serve the glyphs drawn over the tiles.
- Sixteen-bit tile indices without flips. Not chosen by the steward: flips
  are a property of nearly every tile system, cutting the tiles a set needs,
  and fourteen bits still address what the guaranteed texture holds.
- A 4-bit transparency index, applying to both tiles. Not chosen by the
  steward: only a tile that lies over another needs transparent pixels, and
  a transparent value at the first colour of a swatch, in two bits, serves
  every arrangement this design expects.
- A transparent bit for each tile's offset, making the first colour of
  either offset transparent. Not chosen: in the common arrangement it makes
  the bottom tile lose its first colour, and a tile's transparency would
  depend on the other tile's offset.
- The header word's background slot taken for tile parameters. Rejected: a
  tile cell without a bottom tile shows its background, and the block
  cursor, reverse video, and uncovered pixels read the slot without asking
  the format (LEXTER-D87).
- Tile parameters across bits 18–25, as an earlier draft placed them. Not
  chosen: byte 3 holds them exactly, and byte 2 is left to the drawing flags
  common to every format (LEXTER-D81).
- The transparency field and offsets in the header word. Not chosen by the
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
  (LEXTER-D87), tiles reach every palette as other cells do.

### LEXTER-D92 — One allocator hands out palette slots 1–255, in a store whose size the configuration sets

**Status:** Accepted

**Context:** The first edition has four palette slots, set by hand through a
pane's `palette-slot` (`src/panes/vt-pane.lisp:vt-pane@2d4d743`), and the
renderer compares palette generations by slot, whoever produced them
(`src/renderer.lisp:render-state@2d4d743`): the pattern the critique found
for swatches (LEXTER-O23). The integer
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
  record of zeros draws in valid colours (LEXTER-D83).
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

What happens when the slots run out is LEXTER-O50.

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

### LEXTER-D93 — An overlay instance carries a full record, and the block cursor is a transformed copy of the cell beneath it

**Status:** Accepted

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
  word's background slot and the topmost layer's ink slot. The text is the
  topmost layer in the cells the terminal writes, and in the arrangements
  that lay a line beneath it (LEXTER-D88), so the exchange inverts the text
  and its background, and other layers keep their colours: a red SGR 58
  underline stays red under the cursor. A cell with no layers takes slot 1
  as its background in the copy if its own was slot 0, and slot 0 otherwise.
  The copy keeps the cell's blink flag, so text under the cursor blinks with
  its neighbours. The flush copies the record again whenever the cursor
  moves or its row changes. A cursor on a double-width glyph is two
  instances, one for each half.
- **The other styles** are instances that do not draw their background, of
  plain cells whose one glyph is a cursor glyph (LEXTER-D89)
  in the cursor's colour.

The cursor needs no mode of its own in the shader: inversion is a change to
the copied record. The steward chose the full copy, which answers
LEXTER-DRAFT-cell-model-revision-O5.

**Alternatives:**
- An inverted flag, with the pass exchanging slots as it draws. Rejected: it
  is a special case in both renderers for what a change to the record does,
  and it left the cursor's background undrawn.
- Copy only the topmost layer's glyph and settings. Rejected: the cursor would
  drop the cell's other layers, its masks, and its lines.
- Keep cursor bits in the header for the block style. Rejected: it writes an
  ephemeral state into the static grid, which
  LEXTER-DRAFT-cell-model-revision-D10 keeps apart.

### LEXTER-D94 — A blink flag hides the topmost layer while the blink phase is off

**Status:** Accepted

**Context:** The first edition stores a blink attribute (SGR 5) and draws
nothing for it (`src/model.lisp:+attr-blink+@2d4d743`). Blink is not
ephemeral in the way a cursor is: it is a property of the text, and lasts
until the text changes, so it belongs in the grid. Blanking a cell by
setting its glyph count to 0 would leave glyph words beyond the count,
which writers treat as free and debugging builds reject (LEXTER-D83), and
would lose the count to restore; rewriting blinking cells at each interval
would make every blinking row an upload. In the 3270 data stream a blinking
field has one layer, so hiding a cell's text is hiding that layer.

**Decision:** Bit 18 of the format word is the blink flag, at the same place
in every format (LEXTER-D81).

- **What blinks.** While the window's blink phase is off, a blinking cell is
  drawn without its topmost layer: the layers beneath, and the background,
  stay present. The text is the topmost layer in the cells the terminal
  writes (LEXTER-D88), so the text blinks, with the lines drawn in its
  colour; a coloured underline, beneath the text, stays. In a tile cell, the
  topmost glyph layer blinks and the tiles stay.
- **The phase.** The phase is a value the renderer gives both renderers, as
  overlays are given the time: a uniform for the shader and a parameter for
  the CPU renderer. Its interval is set by the configuration, and it shares
  the cursor's blink clock; the two can be separated later if that proves
  useful. The test rig fixes it, so a blinking cell has one checksum, and the
  checksum sees the glyphs of blinking cells whatever the phase.
- **Nothing is rewritten.** The record does not change as the cell blinks;
  no kernel passes over the grid, and no row is uploaded at a phase change.
  Redrawing only the rows that hold blinking cells is a matter for partial
  redraw, which marks them from the records as rows are uploaded.
- **Invisible text** (SGR 8) is not a flag: an invisible cell is written
  with a glyph count of 0, and its characters stay in the text grid. Blink
  has no effect on it.

**Alternatives:**
- Setting the glyph count to 0 at intervals. Rejected: it leaves glyph words
  beyond the count, loses the count to restore, and rewrites and uploads
  every blinking row at each interval.
- A blanking bit toggled in every blinking cell. Rejected: it rewrites and
  uploads the rows at each interval, where a phase given to the renderers
  changes nothing in the record.
- A subtype value in byte 1 of the format word. Rejected: blink is
  independent of the format (LEXTER-D81).
- Blink hiding every layer. Not chosen: the steward keeps the layers beneath
  the text present, as backgrounds. Text that should blink together with a
  coloured underline is a rare case, which a function that rewrites those
  cells can serve.
- Blink as an overlay. Rejected: overlays are for what moves or lasts a
  moment, and blink lasts as long as the text.

### LEXTER-D95 — A tile cell's colours cycle by swatch pair, on clocks of their own, set by the header word's colour parameters

**Status:** Accepted

**Context:** Colour cycling animates water, fire, and conveyors by rotating
colours rather than redrawing pixels, as Deluxe Paint and arcade boards did.
Rewriting cells or swatches at each step would make a kernel pass over the
model, and uploads, many times a second; the blink phase shows that a clock
given to the renderers needs neither (LEXTER-D94). Cycling
runs faster than blink, at several steps a second. Most animations cycle two
or four colours and leave the rest of a tile still, and one tile may want
two gradients cycling at different rates.

**Decision:** Cycling acts on a tile cell's colour positions, the sixteen
colours of swatches A–D, in two pairs: A–B, positions 0–7, and C–D,
positions 8–15. In a tile cell, the header word's colour parameters hold
three fields: *a*, the A–B cycle (bits 26–27); *b*, the C–D cycle (bits
28–29); and *g*, the grouping bit (bit 30). Bit 31 is reserved. A cycle
field of *f* gives *N* = 2^*f* colours.

Table: Colour cycles in a tile cell.

| *a*, *b* | *g* = 0 | *g* = 1 |
|---|---|---|
| Both 0 | No cycling | One cycle of all 16 colours, on the first clock |
| A field of 1 (*N* = 2) | The pair's first 2 colours cycle; the other 6 stay | The pair cycles as four groups of 2 |
| A field of 2 (*N* = 4) | The pair's first 4 colours cycle; the other 4 stay | The pair cycles as two groups of 4, one in each swatch |
| A field of 3 (*N* = 8) | The pair's 8 colours cycle as one group | The same |
| A field of 0, beside another | The pair stays | The pair stays |

The sixteen-colour cycle takes the encoding that would otherwise mean no
cycling with grouping on, so the fifth bit is never idle.

- **The order of steps.** A tile's pixel value is tested for transparency
  first, then moved by the tile's offset to a colour position; a position in
  a cycling group then moves forward by the step within its group. A
  transparent pixel never cycles, and the colours a tile reaches through
  its offset decide which cycle it takes part in.
- **Two clocks.** A–B cycles on the first clock and C–D on the second; the
  sixteen-colour cycle runs on the first. Each is a counter that the renderer
  advances at a rate the configuration sets, and gives both renderers, as it
  gives the blink phase; a group's step is the counter, so groups of two,
  four, eight, and sixteen stay in step with one another. The test rig fixes
  both clocks, so a cycling cell has one checksum.
- **Pairs serve layers by convention.** A top tile with an offset of 0 draws
  in A–B and a bottom tile with an offset of 2 in C–D, so each tile cycles on
  its own clock; a single tile reaching both pairs cycles two gradients at
  once.
- **Forward only.** A cycle that should run backwards is drawn by reversing
  its colours in the swatches, which is done once, not at every step.
- **Nothing is rewritten.** The record does not change as its colours cycle,
  and partial redraw finds the rows to redraw at each step from the records,
  as it does for blink.
- **Glyph formats** do not cycle yet: their cells have only four slots, so
  their cycles need a form of their own (LEXTER-O54).

**Alternatives:**
- A cycle for each tile layer, over the tile's own first colours. Not chosen
  by the steward: cycling belongs to colours, not to tiles, and by pair one
  tile can carry two gradients on two clocks.
- Groups of *N* throughout each pair, always. Not chosen by the steward:
  cycling a few colours and leaving the rest still is the commoner need, and
  the grouping bit gives groups where they are wanted.
- A sixteen-colour cycle allowed only when one tile index is 0. Rejected: a
  field whose meaning depends on the cell's content needs the tiles read
  before the bits can be, and two tiles can share one cycle of colour
  positions without conflict.
- A kernel that rotates swatch contents or cell values at each step.
  Rejected: it passes over the model and uploads many times a second, where a
  clock changes nothing in the record.
- Animating reserved swatches. Not chosen for tiles: it needs swatches that
  interning never hands out (LEXTER-DRAFT-cell-field-format-O6), and changes
  every cell that shares them.
- One clock, shared with blink. Rejected: cycling runs several times faster
  than blink, and the steward wants the pairs' cycles separable.
- The cycle fields in byte 2 of the format word. Not chosen by the steward:
  cycling is colour behaviour, which belongs in the header word
  (LEXTER-D87).
- A direction bit. Not chosen by the steward: reversing is rare, and a swatch
  change serves it.

## The Record

Table: The record, by word, for each glyph format.

| Word | Plain | Void, inline colours | Tiles |
|---|---|---|---|
| 0 | Format word: format, glyph count, type bits, drawing flags | The same | The same, with the transparency field and colour offsets in byte 3 |
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
if (word(0) >> 18) & 1 and blink_off and k > 0: // the topmost layer blinks
    cov &= ~(1 << (k - 1))
if f == TILES:
    top    = tile_index(word(5) >> 16, (word(0) >> 30) & 3,
                        4 * ((word(0) >> 24) & 3))   // its transparent value
    bottom = tile_index(word(5) & 0xFFFF, (word(0) >> 28) & 3,
                        NONE)                        // the bottom is opaque
    if (word(0) >> 23) & 1 and top is not none:  // the top tile over glyphs
        colour = palette[palette_slot * 256 + top]; done
    if cov == 0:                                 // no glyph covers
        index = (top is not none) ? top : bottom
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

tile_index(field, offset, clear):               // a palette index, or none
    t = field & 0x3FFF
    if t == 0: return none                       // no tile
    tx = (field >> 14) & 1 ? w - 1 - x : x       // horizontal flip
    ty = (field >> 15) & 1 ? h - 1 - y : y       // vertical flip
    v = tile_pixel(t, tx, ty)                    // 0-15
    if v == clear: return none                   // transparent
    c  = cycle((v + 4 * offset) mod 16)          // the colour position
    s  = c div 4                                 // swatch A, B, C, or D
    sw = (word(6 + s div 2) >> (16 * (s mod 2))) & 0xFFFF
    return swatch[sw][c mod 4]

cycle(c):                                       // LEXTER-DRAFT-cell-model-D15
    a = (word(1) >> 26) & 3; b = (word(1) >> 28) & 3; g = (word(1) >> 30) & 1
    if a == 0 and b == 0:                        // none, or all sixteen
        return g ? (c + first_step) mod 16 : c
    base = c & 8; r = c & 7                      // the pair, the place in it
    N    = 1 << (base == 0 ? a : b)
    step = base == 0 ? first_step : second_step
    if g: return base + (r & ~(N - 1)) + ((r + step) & (N - 1))  // groups
    if r < N: return base + (r + step) mod N     // the pair's first N
    return c
```

Description: The procedure reads the format from the first byte and the
background slot from the header word; an unknown format is drawn in the
background slot. For a glyph format it reads the glyph count, clamped to the
format's glyph words, and the type bits, and keeps one coverage bit for each
layer. A glyph that is a layer sets its bit to whether its glyph covers the
pixel under its selector. A glyph that is a mask finds whether its own glyph
covers the pixel, and combines that, by its operation, with the bits of the
layers it reaches: the most recent layer and as many before it as its reach
gives. If the cell blinks and the blink phase is off, the topmost layer's bit
is then cleared, so that the layers beneath, or the background, show. In a
tile cell, each tile's value is read at the pixel, mirrored as its flips say;
unless it is the top tile's transparent value, it is moved by the tile's
colour offset to a colour position, which the cycles of its swatch pair may
move on, and which selects a slot of one of swatches A–D. A top tile raised
above the glyphs takes the pixel first; otherwise a pixel that no glyph layer
covers is given to the top tile, or, where it is absent or transparent, to the
bottom tile. Otherwise a second loop visits the layers in order and takes the
ink slot of the topmost layer whose bit is set. A pixel that nothing covers
keeps the background slot, or, in a void or an overlay instance that does not
draw its background, is discarded. The slot is then looked up in the inline
colours or in the swatch and the palette. In the grid, `draws_background` is
always true; `blink_off` is the blink phase, and `first_step` and
`second_step` the two cycle clocks, which both renderers are given
(LEXTER-D94, LEXTER-D95); *w* and *h* are
the cell's size, and *x* and *y* the pixel's place in it.

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
  (LEXTER-D86) chooses which is drawn as the background.
- **The palette store** is a texture buffer of 256-colour palettes,
  `RGBA8UI`, sized by the configuration (LEXTER-D92).
- **Palette slots.** Every cell draws in the header word's palette slot,
  0–255.
- **What the checksum hashes.** The cell checksum hashes the contents of
  every palette slot that a cell selects
  (LEXTER-DRAFT-cell-model-revision-D13).

## Lines and Cursors

Table: How a cell's lines are placed, when the terminal writes them.

| Lines | Place | Glyph |
|---|---|---|
| Any combination in the text's colour | The cell's last glyph word, a mask on the text, reaching one layer | The combination's line glyph |
| An underline with an SGR 58 colour | The layer directly beneath the text, whose ink slot holds the colour | The underline alone |
| Strikethrough or overline beside a coloured underline | The cell's last glyph word, a mask on the text | Their combination, without the underline |

Table: Where each cursor and pointer effect is drawn.

| Effect | Drawn by |
|---|---|
| Block cursor | An overlay instance that draws its background, copying the cell with its background slot and topmost layer's ink slot exchanged (LEXTER-D93) |
| Underline and bar cursors | An overlay instance with a cursor glyph, not drawing its background |
| A hyperlink lit by the pointer | An overlay instance with an underline glyph, not drawing its background |

## Open Questions

### LEXTER-O45 — How is the block cursor drawn over a tile cell?

Exchanging the background slot with the topmost layer's ink slot inverts a
tile cell's glyphs and its background, but not its tiles, whose colours come
from swatches A–D. The cursor could be the outlined block glyph over such a
cell, or the tile format could define how its copy is transformed, such as by
exchanging swatches or offsets, or by a bit that inverts each tile's colours.
The steward notes that inverted colours suit abstract designs, such as
gradients, and spoil naturalistic ones, such as grass and flowers, whose
palettes are not meant to be rearranged; so the choice may belong to the tile
set rather than to the format.

### LEXTER-O46 — May a font supply its own line glyphs?

Generated lines follow the font's XLFD properties where it has them. A font
may also draw its own underline as a combining mark, such as U+0332, but such
marks are drawn as marks, not as rules across the cell. Whether a
configuration can choose a font's glyphs for some lines is open; the default
is to generate them.

### LEXTER-O47 — What happens when a cell has no glyph word left for a line?

A plain cell whose six glyph words are in use, or a void or inline-colour
cell whose three are, cannot take a line. The line could take precedence and
displace another glyph, or be dropped. Such cells are expected to be rare.

### LEXTER-O48 — Which further underline styles are defined, and how do their patterns meet?

Double, curly, dotted, and dashed underlines (SGR 4:2–4:5, and 21) fit
styles 1–6. A curly or dashed pattern must line up from cell to cell, so its
period must divide the cell's width, or each boundary shows a seam. How the
generator chooses a period for each cell width is open, and so is which
style a spelling checker's mark takes: one the terminal never writes, so that
reading lines back passes it over (LEXTER-D88).

### LEXTER-O49 — What do the reserved bits hold?

The header word's colour parameters are six bits that the plain, void, and
inline-colour formats leave reserved, of which tiles use five for their
cycles; the format word has thirteen reserved bits in those three formats,
five common flags in byte 2 and all of byte 3, and six in tiles, bits 19–22
and 26–27;
a layer's settings byte has five; and a mask's two. The candidates are
effects for each layer, which need no payload and so could stand beside
masks. The bits stay reserved until a use is chosen; state that only the CPU
reads, such as the protected-cell bit of DECSCA
(LEXTER-DRAFT-cell-field-format-O7), belongs beside the cell model rather
than in it.

### LEXTER-O50 — What happens when palette slots run out?

When the store's slots are all allocated, a new terminal could share the
default palette or a slot already in use, and a tile set could be refused or
given fewer palettes than it asks for. Whether the store can grow while
running, up to the 256 slots the record addresses, is open too.

### LEXTER-O51 — How are tile sets fitted to the cell size?

LEXTER-D91 answers LEXTER-DRAFT-cell-field-format-O1 with a transparent value
for the top tile, and much of LEXTER-DRAFT-cell-field-format-O2 with tiles
the size of a cell. What remains of LEXTER-DRAFT-cell-field-format-O2 is how
a tile set drawn at another size is fitted: sliced into cells, scaled by an
integer, bordered, or refused. A loader that imports a tile set with another
transparent value renumbers its colours, so that the value falls on the
first colour of a swatch. Whether masks may cut tiles was asked here first,
and is now LEXTER-O55.

### LEXTER-O52 — How does a mask apply to a wide display glyph?

It is LEXTER-DRAFT-cell-model-revision-O6. Line glyphs are narrow and are
applied to each half's cell as they are, so whichever rule is chosen must
let a narrow mask apply to one half.

### LEXTER-O53 — What do the void and effect formats carry?

The cell-field-format survey's surface tile, a surface id and a column and
row within the surface, is the candidate for the void's payload, and it may
need fewer than three words, which would leave the void more glyph words.
The effect's contents are LEXTER-O11. Both are left to
the survey of surfaces and effects that LEXTER-DRAFT-cell-model-revision-D12
calls for.

### LEXTER-O54 — How would a glyph cell cycle its colours?

Tiles cycle up to eight colours (LEXTER-D95), but a glyph
cell has only the four slots of its swatch, so its cycles need a form of their
own: the topmost layer's ink slot and the background slot could each step
through two or four slots on the two clocks, giving pulsing or rainbow text
without rewriting the cells. Whether glyph formats cycle, and how their
colour parameters lay this out, is open.

### LEXTER-O55 — May masks cut a cell's tiles?

Masks now cut only glyph layers (LEXTER-D91). A mask that cuts the top tile
would let the bottom tile show through it where the mask says, so that both
tiles could cycle eight full colours with no value spent on transparency. The
design this would need:

- **A mask before any glyph layer.** The tile format would give glyph 0 a
  type bit, so that a cell can begin with a mask; tiles use only two of
  byte 1's five type bits, so there is room for a third.
- **Reach into the tiles.** A mask whose reach runs one past the glyph layers
  before it would cut the top tile, and two past, the bottom tile as well.
  The mask byte's three-bit reach already allows it.
- **Coverage bits for the tiles.** A tile covers a pixel where its value is
  not transparent, and the two tiles take coverage bits beneath the glyph
  layers', which masks cut as they cut layers; the cost is a few bitwise
  operations for each pixel.

It is left for a step after the first tiles, in the plan's Later Formats.

## Roadmap

1. **With the plan's Phase 1.** The atlas reserves positions 0–63 and names
   generated glyphs from 0x110000, and the cursor glyphs move from
   private-use codepoints to positions 1–4 (LEXTER-D89).
2. **With the plan's Phase 2.** The palette store, sized by the
   configuration (LEXTER-D92), with the integer stores of
   LEXTER-DRAFT-cell-model-revision-D14.
3. **With the plan's Phase 3.** The record as specified here: the format
   word with its drawing flags, the header word with its background slot,
   glyph words with their settings, the plain format with its glyph count and
   type bits, masks with their reach, lines as glyphs with the single
   underline, blinking text and the blink phase, the procedure of Drawing a
   Pixel in the shader, and palette slots allocated to terminals.
   The descriptor of LEXTER-DRAFT-cell-model-revision-D9 is written from
   these tables.
4. **With the plan's Phase 4.** The overlay instance and the block cursor's
   transformed copy (LEXTER-D93).
5. **With the plan's Phase 5.** The CPU renderer follows the same procedure.
6. **Later.** The inline-colour format; tiles and their texture, after
   LEXTER-O45 and LEXTER-O50, and the fitting of tile sets of
   LEXTER-O51; the void and effects, after the survey of
   surfaces; further underline styles, after LEXTER-O48.
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
| 0 | Plain, glyph count 3, type bits 00010 (glyph 1 a layer, glyph 2 a mask) |
| 1 | A swatch whose slot 2 holds red, palette slot *p*, background slot 0 |
| 2 | 9, the underline; ink slot 2 |
| 3 | The atlas position of g; ink slot 1 |
| 4 | 10, the strikethrough (8 + 0 + 2); selector 0, union |
| Result | The red underline beneath the g, with the g's descender crossing it, and the strikethrough in the g's colour |

Table: A spelling checker's red underline beneath the letter g.

| Word | Value |
|---|---|
| 0 | Plain, glyph count 2, type bits 00000 (both layers) |
| 1 | A swatch whose slot 2 holds red, palette slot *p*, background slot 0 |
| 2 | The line glyph of the spelling checker's style, which the terminal never writes (LEXTER-O48); ink slot 2 |
| 3 | The atlas position of g; ink slot 1 |
| Result | The g drawn over the line; not read back as an SGR underline, by its style |

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
| 2 | 9, the underline; ink slot 2 |
| 3 | The atlas position of g; ink slot 1 |
| 4 | ▌, the left half; selector 0, intersection, reach field 1 (two layers) |
| Result | The g and its underline in the left half; the background in the right |

Table: The letter g, blinking, with an SGR 58 red underline.

| Word | Value |
|---|---|
| 0 | Plain, glyph count 2, type bits 00000 (both layers), blink 1 |
| 1 | A swatch whose slot 2 holds red, palette slot *p*, background slot 0 |
| 2 | 9, the underline; ink slot 2 |
| 3 | The atlas position of g; ink slot 1 |
| Result | In the on phase, the g over its red underline; in the off phase, the underline alone on the background |

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
| 0 | Tiles, glyph count 1; transparency field 2 (value 8); bottom offset 2, top offset 0 |
| 1 | Swatch *s* for the label, a palette slot allocated to the tile set, background slot 0 |
| 2 | The atlas position of the label's letter; ink slot 1 |
| 5 | The square's tile (bits 0–15), drawn in colours 0–7; the piece's tile (bits 16–31), in colours 0–7 with 8 where the square shows through |
| 6 | Swatches A and B, the piece's eight colours |
| 7 | Swatches C and D, the square's eight colours, reached through the offset of 2 |
| Result | The square, the piece over it, and the letter over both |

Table: Shore water, mirrored, with its waves cycling beneath a boat that
passes in front of a label.

| Word | Value |
|---|---|
| 0 | Tiles, glyph count 1; top tile above the glyphs; transparency field 2 (value 8); bottom offset 2, top offset 0 |
| 1 | Swatch *s* for the label, the tile set's palette slot, background slot 0; *a* = 0, *b* = 2 (the first four colours of C–D cycle), *g* = 0 |
| 2 | The atlas position of the label's letter; ink slot 1 |
| 5 | The shore's water tile with its horizontal flip set, so that the same tile serves the opposite shore (bits 0–15); the boat's tile (bits 16–31) |
| 6 | Swatches A and B, the boat's colours |
| 7 | Swatch C, four shades of water that rotate on the second clock; swatch D, the shore's fixed colours |
| Result | The water's colours rotating through swatch C at each step of the second clock, the shore steady, the label over the water, and the boat in front of the label |
