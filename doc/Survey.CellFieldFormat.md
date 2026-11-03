---
id:            LEXTER-DRAFT-cell-field-format
title:         "Cell Field Format: Survey"
genre:         Survey
scope:         component
project:       Lexter
component:     renderer
language:      en
status:        Draft
provenance:
  assistant:   opencode
relates-to:
  - LEXTER-DRAFT-layer-mechanics
  - LEXTER-DRAFT-data-structures-1e
  - LEXTER-DRAFT-data-structures-1e-critique
  - LEXTER-DRAFT-mouse-reporting
  - LEXTER-0004
  - LEXTER-0007
  - LEXTER-0010
cites:
  - title:    "The OpenGL Graphics System, Version 3.3 (Core Profile)"
    locator:  "Khronos Group; implementation-dependent limits MAX_TEXTURE_SIZE (minimum 1024) and MAX_TEXTURE_BUFFER_SIZE (minimum 65536)"
    external: true
  - title:    "Kitty terminal graphics protocol"
    locator:  "Kovid Goyal; the sections on placements, z-index, and Unicode placeholders"
    external: true
  - title:    "VT220 Programmer Reference Manual"
    locator:  "Digital Equipment Corporation; Dynamically Redefinable Character Sets and the DECDLD sequence"
    external: true
open-questions:
  - LEXTER-DRAFT-cell-field-format-O1
  - LEXTER-DRAFT-cell-field-format-O2
  - LEXTER-DRAFT-cell-field-format-O3
  - LEXTER-DRAFT-cell-field-format-O4
  - LEXTER-DRAFT-cell-field-format-O5
  - LEXTER-DRAFT-cell-field-format-O6
  - LEXTER-DRAFT-cell-field-format-O7
  - LEXTER-DRAFT-cell-field-format-O8
  - LEXTER-DRAFT-cell-field-format-O9
  - LEXTER-DRAFT-cell-field-format-O10
  - LEXTER-DRAFT-cell-field-format-O11
  - LEXTER-DRAFT-cell-field-format-O12
---

# Cell Field Format: Survey

This survey sets out a proposed bit layout for the 32-byte cell record that
[LEXTER-DRAFT-layer-mechanics](Survey.LayerMechanics.md) explores. That survey
asks whether Lexter should store every cell as one fixed-size record with
three display glyphs and three mask glyphs; this one asks how the fields of
such a record would be arranged, what the space left over when masks and
layers are unused could carry, and what remains open. It covers the header,
the per-layer settings, a tail that holds either the mask glyphs or one of
several alternative payloads, references from cells to images, video, and
shader surfaces, and the data that belongs outside the record. It also
sketches a 16-colour tile mode as a possible evolution, not a settled
direction. Nothing here is decided; the survey is meant to inform a
development plan.

## Motivation

The layer-mechanics survey settled on the shape of a dense record, and the
steward leans to 32 bytes for its headroom and because one record fills one
256-bit AVX2 register. Fixing the shape leaves the arrangement open, and
the arrangement matters more than its size suggests:

- **Free space.** A cell that uses no masks, or fewer than three layers,
  leaves whole words unused. Where they sit decides whether they can carry
  anything else.
- **Kernels.** Mutation kernels work on fields at fixed offsets. Fields a
  kernel changes together should sit together, and fields it tests should be
  cheap to reach.
- **The shader.** The fragment shader branches on what kind of cell it is
  drawing. The branch should depend on one field, not on a combination of
  bits that happen to be zero.
- **Later features.** Images, video, shader regions, exact colours, and tile
  graphics all want space in the cell. A layout that leaves that space in one
  place, behind an explicit tag, admits them without a new format.

## Conventions

- The record is eight 32-bit words, 32 bytes, stored little-endian as the
  present GPU instance layout is
  ([LEXTER-DRAFT-data-structures-1e](Spec.DataStructures1e.md)). Bit 0 is the
  least significant bit of its word.
- Records are meant to start on 32-byte boundaries. SBCL does not provide
  that for arrays in its heap; the layer-mechanics survey measures where it
  places them and lists remedies.
- Glyph fields hold atlas positions, not codepoints.
- "Slot" means a position 0–3 in a swatch; "palette slot" means one of the
  four GPU palettes ([LEXTER-0004](Log.PalettePaging.md)).

## The Record

The order puts the control data first and the optional data last: a header,
the settings of all three layers, the three display glyphs, and a tail.

Table: The 32-byte cell record, by word.

| Word | Bytes | Contents |
|---|---|---|
| 0 | 0–3 | Header |
| 1 | 4–7 | Layer settings and the tail type |
| 2 | 8–11 | Layer 0 display glyph |
| 3 | 12–15 | Layer 1 display glyph |
| 4 | 16–19 | Layer 2 display glyph |
| 5–7 | 20–31 | Tail: the three mask glyphs, or a payload |

Three properties follow from the order:

- **The control data is one 64-bit word.** The header and settings are the
  first 8 bytes, so a kernel can read or change what kind of cell this is in
  one 64-bit operation.
- **The tail is contiguous.** It lies in the upper half of a 256-bit
  register, so writing a payload is one store under a byte mask.
- **Free space grows from the end.** Layers are numbered from 0 without
  gaps, and the header holds their count. When the tail does not hold masks,
  the display words of absent layers join it: a cell with one layer has
  words 3–7 free, 20 bytes, and a cell with none has words 2–7 free, 24
  bytes.

### Word 0: the header

Table: Bits of word 0.

| Bits | Width | Field | Values |
|---|---|---|---|
| 0–15 | 16 | Swatch index | Index into the swatch store |
| 16–17 | 2 | Palette slot | 0–3 |
| 18 | 1 | Wide | 1 = the cell holds half of a double-width glyph |
| 19 | 1 | Right half | With wide set: 0 = left half, 1 = right half |
| 20–21 | 2 | Cursor | 0 none, 1 block, 2 underline, 3 bar |
| 22–23 | 2 | Layer count | 0–3 |
| 24 | 1 | Underline | |
| 25 | 1 | Strikethrough | |
| 26 | 1 | Overline | |
| 27–28 | 2 | Line colour slot | The swatch slot the three lines are drawn in |
| 29–31 | 3 | Spare | |

The swatch index takes all 16 bits because the wide flag, which once rode in
bit 15 of the swatch field, now has its own bit.

**Layers are for glyphs; attributes are bits.** The three lines are drawn
by the shader as rules of pixels, so they never use up a layer that text
needs. The cursor is two bits that the flush sets on the cursor's cell; the
shader draws the block by exchanging the ink and fill slots, and the other
two styles as rules. Nothing writes into the model to draw it.

### Word 1: layer settings

Table: Bits of word 1.

| Bits | Width | Field |
|---|---|---|
| 0–8 | 9 | Layer 0 settings |
| 9–17 | 9 | Layer 1 settings |
| 18–26 | 9 | Layer 2 settings |
| 27–29 | 3 | Tail type |
| 30–31 | 2 | Spare |

Table: The nine bits of one layer's settings, at offset 0, 9, or 18.

| Bits | Width | Field | Values |
|---|---|---|---|
| +0–1 | 2 | Ink slot | The swatch slot for inked pixels |
| +2–3 | 2 | Fill slot | The swatch slot for un-inked pixels |
| +4 | 1 | Fill on | 0 = un-inked pixels are transparent; 1 = they take the fill slot |
| +5–6 | 2 | Mask operation | 0 none, 1 union, 2 intersection, 3 exclusion |
| +7 | 1 | Display selector | 0 = the display glyph's inked pixels; 1 = its uninked pixels |
| +8 | 1 | Mask selector | 0 = the mask glyph's inked pixels; 1 = its uninked pixels |

Bits +5 to +8 are the mask code of the layer-mechanics survey: union,
intersection, and exclusion with a pixel selector for each glyph, which
together give every useful combination of two glyphs, with difference as
intersection with the mask's uninked pixels. The display selector is in use
even without a mask: it is how a glyph is drawn inverted. The mask
operation and mask selector mean something only when the tail holds masks.

Today's `transparent-side`, in the present layered instance
(`src/shaders.lisp:+layered-frag+@2d4d743`), maps onto these settings:

Table: The present transparent-side values in the new settings.

| Present value | Display selector | Fill on | Fill slot |
|---|---|---|---|
| `:none` | 0 | 1 | The background slot |
| `:bg` | 0 | 0 | — |
| `:fg` | 1 | 0 | — |

### Words 2–4: display glyphs

Each word is the atlas position of one layer's display glyph. A word is
meaningful only for a layer below the layer count. Because absence is
recorded by the count, not by glyph 0, an absent layer's word is free to
carry data, and atlas position 0 can be reserved for an empty glyph or used
as an ordinary one as the atlas's owner decides
(LEXTER-DRAFT-data-structures-1e-critique-O10).

### Words 5–7: the tail

The tail is a tagged union. Its type is the three-bit field in word 1, so
the shader branches once, on a value that is the same across the cell.

Table: Tail types.

| Type | Name | Status in this survey |
|---|---|---|
| 0 | Masks | Proposed |
| 1 | Surface tile | Proposed |
| 2 | Inline colours | Proposed |
| 3 | Effect | Reserved; contents open |
| 4 | Tiles | A possible evolution |
| 5–7 | — | Reserved |

When the tail type is not 0, its payload may continue backward into the
display words of absent layers, as described above.

Table: Tail type 0, masks.

| Word | Contents |
|---|---|
| 5 | Layer 0 mask glyph |
| 6 | Layer 1 mask glyph |
| 7 | Layer 2 mask glyph |

Table: Tail type 1, surface tile.

| Bytes | Field |
|---|---|
| 20–21 | Surface id |
| 22–23 | Tile column within the surface |
| 24–25 | Tile row within the surface |
| 26–27 | Flags or a parameter for the surface |
| 28–31 | Spare |

Table: Tail type 2, inline colours.

| Bytes | Field |
|---|---|
| 20–22 | Colour of slot 0, RGB, one byte each |
| 23–25 | Colour of slot 1 |
| 26–28 | Colour of slot 2 |
| 29–31 | Colour of slot 3 |

Four 24-bit colours fill the tail exactly. A cell with inline colours does
not consult the swatch store or the palette, so truecolour output, which
today is mapped to 256 colours and drives growth of the swatch table
(LEXTER-DRAFT-data-structures-1e-critique-O6), could be drawn exactly. Such
a cell gives up masks.

Type 3 is held for the effects the layer-mechanics survey lists, such as
sub-cell offsets, opacity, and an alternate glyph for blinking; its
contents are LEXTER-DRAFT-layer-mechanics-O8.

### Bit budget

Table: Bits used and spare in each word.

| Word | Used | Spare |
|---|---|---|
| 0 | 29 | 3 |
| 1 | 30 | 2 |
| 2–4 | 96 | 0, but an absent layer's word is free |
| 5–7 | 96 with masks | With other payloads, as the type defines; type 1 leaves 32 bits |

## Surfaces and Tile References

A surface is something drawn into a rectangle of cells that is not built
from glyphs: a decoded sixel image, a frame of video, the output of a
shader. A table outside the grid describes each surface: its id, its size in
cells, and its texture or program.

**Every cell of a surface carries a reference** (tail type 1): the surface
id and the cell's column and row within the surface. The alternative
considered, a marker in the first cell of each row with a run length, keeps
the region's description in one cell per row, and every operation that
moves or clears cells would have to preserve it; that is the kind of
invariant the data-structures critique found broken for wide characters
(LEXTER-DRAFT-data-structures-1e-critique-O8). With a reference in every
cell:

- the shader computes the texture coordinate from the cell's own fields,
  without searching left for the start of a run;
- scrolling, scroll regions, row copies, and kernels move cells that
  describe themselves;
- writing text over part of a surface replaces those cells and leaves a
  hole, which is how sixel images behave in xterm;
- glyph layers may sit over a surface cell, since the reference is in the
  tail: subtitles over video, a caption on an image, or the cursor.

**Drawing depends on the kind of surface.** Images and video can be sampled
by the cell shader from a texture array or an image atlas, chosen by surface
id; a video player then updates only the surface's texture, and the grid is
not touched or uploaded. An arbitrary shader cannot be called from the cell
shader, since GLSL cannot dispatch to another program. Such a surface is
drawn by a separate pass into its rectangle first, and the cell pass draws
over it: cells that still reference the surface have no fill and let it show,
and cells that have been overwritten are opaque and cover it. That pass is
the separate pipeline by surface that the layer-mechanics survey describes.

**A tile reference generalises the wide flag.** The right half of a
double-width glyph is tile (1, 0) of a 2-by-1 object. The same idea would
cover DEC double-width and double-height lines, text drawn across several
cells as in kitty's text-sizing protocol, and tiles larger than two cells.
The record's wide and right-half bits cover only the 2-by-1 case; whether to
generalise them is LEXTER-DRAFT-cell-field-format-O3.

## Data Outside the Record

The tail is optional and exclusive, and everything in the record is
uploaded with every dirty row. That gives a rule: **the record holds what the
shader reads; what every cell needs regardless of kind, or what only the CPU
reads, belongs in arrays beside the grid.** kitty follows the same rule,
keeping a record of each cell's text apart from the record the GPU draws.

Table: Per-cell data and where it belongs.

| Data | Read by the shader | Place |
|---|---|---|
| Surface reference, inline colours, effects | yes | The tail |
| Line attributes, cursor | yes | The header |
| The cell's text (codepoints and combining marks) | no | A side array |
| Hyperlink id (OSC 8) | rarely, on hover | A side array; the CPU sets a header bit to show hover |
| Semantic zone (OSC 133: prompt, input, output) | no | A side array, or per row |
| Protected cell (DECSCA) | no | A spare header bit or a side array |

The text array is not optional. Atlas positions are not text: selection,
copying, and pasting, which mouse support now makes possible
([LEXTER-DRAFT-mouse-reporting](Log.MouseReporting.md)), search, screen
readers, and the test rig's planned screen dump all need the characters a
cell shows. Text cannot live in the tail, since a masked cell would lose it.

## The Swatch Store

A 16-bit swatch index addresses 65,536 swatches, 256 KB at 4 bytes each.
The present store is a one-dimensional texture of 2048 texels
(`src/renderer.lisp:%make-swatch-texture@2d4d743`), and one-dimensional
textures are limited to the implementation's maximum texture size, which
OpenGL 3.3 guarantees only as 1024. A texture buffer, sampled as a
`samplerBuffer` and core since OpenGL 3.1, is guaranteed at least 65,536
texels in OpenGL 3.3, exactly the range of a 16-bit index. The store would
move to one.

A larger address space does not settle who allocates in it. Which owner the
swatch namespace has is LEXTER-DRAFT-layer-mechanics-O5, and it remains a
prerequisite of the dense record.

## A Possible Evolution: Tile Mode

Tile mode would let a cell show a glyph whose pixels are colour indices
rather than ink, for tile graphics: tile-based games and MUDs on a BBS,
chess, cards, mahjong, a terminal tabletop with pixel figures and
landscapes. This does not entail the potential for sprite-based games,
as tiles change cell by cell; there is no smooth movement across cells.
This section records the idea as it stands; it is not a plan.

### Fields

Table: Tail type 4, tiles.

| Bytes | Field |
|---|---|
| 20–21 | Swatch A: colours 0–3 |
| 22–23 | Swatch B: colours 4–7 |
| 24–25 | Swatch C: colours 8–11 |
| 26–27 | Swatch D: colours 12–15 |
| 28–31 | Mode, bits 0–1; bits 2–31 reserved |

Table: Tile modes.

| Mode | Layer 0 | Layer 1 | Layer 2 |
|---|---|---|---|
| 0 Unified | Indices 0–15, 4 bits per pixel, through swatches A–D | An ordinary glyph | An ordinary glyph |
| 1 Split | Indices 0–7, 3 bits per pixel, through swatches C–D | Indices 0–7 through swatches A–B, over layer 0 | An ordinary glyph |
| 2–3 | Reserved | | |

A pixel's index *i* selects swatch *i* div 4 and slot *i* mod 4, and the
palette slot in the header applies as for any cell. Ordinary glyph layers
take their colours from the header's swatch. Split mode puts a piece over a
square, a unit over terrain, or a card over the table, with layer 2 free for
a label, a highlight, or the cursor; moving a piece rewrites layer 1 in the
cells it leaves and enters. Glyphs meant for split mode use indices 0–7
only.

Sixteen colours per cell, or eight and eight in split mode, is the budget
of EGA and of the Amiga's early modes, and it is meant as a creative limit:
enough for tiles drawn with care, not enough for overworked graphics.

### Glyphs and scaling

Indexed glyphs need atlas entries of their own, holding values 0–15, since a
single-colour glyph read as indices, or an indexed glyph read as a mask,
draws wrongly; the tail type decides which reading applies. Arcade fonts
are mostly 8 by 8 pixels. Scaled by two when loaded, such a glyph becomes
16 by 16, an ordinary wide glyph in a font with 8-by-16 cells, and native
16-by-16 tile sets fit the same way unscaled. Other cell sizes do not divide
so neatly (LEXTER-DRAFT-cell-field-format-O2). Lexter's font loaders read
one bit per pixel; indexed glyphs would need a loader for indexed images or
for the tile formats of the source.

### Colour animation

Colour cycling and similar effects are left out of the record. Lexter's
colours pass through three lookups, and each is a place to animate:

Table: Where a colour animation can act.

| What changes | Scope | Work per step | Upload |
|---|---|---|---|
| Swatch indices in cells | The cells rewritten | A kernel pass adding offsets to the four 16-bit fields | Dirty rows |
| The contents of a swatch | Every cell using that swatch | A few bytes in the store | The swatch store |
| A palette entry | Everything drawn in that colour | One entry | One palette slot |

The first is the most flexible, since each cell or range can step on its own
schedule and skip what it likes, and it suits SIMD: one AVX2 addition updates
sixteen 16-bit fields, and a blend confined to bytes 20–27 touches only the
tail's swatch fields. The second is cheaper for effects shared by many
cells. Both are deterministic: step *n* always gives the same record, so the
result can be checked at chosen steps.

Swatches are interned, one entry per distinct combination of colours shared
by every cell that uses it. Changing the contents of an interned swatch would
change unrelated cells that happen to share it, so animated swatches would
have to be reserved, owned by whatever animates them and never returned by
interning (LEXTER-DRAFT-cell-field-format-O6).

### Delivery

A program on the host, such as a BBS door or a MUD, would need a way to send
tiles. The precedent is DEC's dynamically redefinable character sets: the
DECDLD sequence of the VT220 and later terminals downloads glyphs into a
soft font, in an encoding close to sixel's, and the videotex systems
(Prestel, Minitel, NAPLPS) had their own. A coloured form would be a private
sequence. Locally, tiles could be loaded from files, or written only by
code that writes the grid directly (LEXTER-DRAFT-cell-field-format-O4).

## The deeper claim

Two arrangements carry most of the design. Putting the optional data last,
behind one tag, turns unused space into capacity for later features without
a new format. Keeping the record to what the shader reads, and everything
else beside it, keeps that capacity from being spent on data that every
cell would need anyway.

## Honest Limits

- **One payload per cell.** A cell cannot mix masks on some layers with a
  payload in the other layers' mask words; a further tail type could allow
  it, but none is proposed.
- **Few spare bits.** Three in the header and two in the settings word.
  Underline styles, a hover bit, and a protected bit compete for them.
- **Masks or colours.** Inline colours, surfaces, and tiles each exclude
  masks.
- **Tiles larger than two cells** need the generalised tile position, which
  the record does not have.
- **Swatch ownership is unsolved.** The 16-bit store and reserved swatches
  both depend on it.
- **Surfaces outside the checksum.** Video and time-driven shaders cannot be
  tested by exact checksums; the steward expects them to have a pipeline and
  tests of their own (LEXTER-DRAFT-cell-field-format-O5).
- **Unbuilt.** Nothing here has been implemented or measured beyond the
  alignment figures of the layer-mechanics survey.

## Relationship to Other Work

Within Lexter:

- [LEXTER-DRAFT-layer-mechanics](Survey.LayerMechanics.md) argues for the
  dense record and the mask code; this survey proposes the record's layout.
  Its earlier field table, with the layers' glyphs interleaved, is
  superseded by the order given here.
- [LEXTER-DRAFT-data-structures-1e](Spec.DataStructures1e.md) specifies the
  present instance layouts this record would replace, and
  [LEXTER-DRAFT-data-structures-1e-critique](Eval.Critique.DataStructures1e.md)
  records the faults several of its properties address.
- [LEXTER-0007](Log.EnhancedDualWidth.md) defines wide glyphs, which the
  record stores as halves and which tile references would generalise.
- [LEXTER-0004](Log.PalettePaging.md) defines the four palette slots that the
  header's palette slot selects.
- [LEXTER-0010](Log.ScreenshotTestRig.md) checks output by checksum, which
  glyph cells and kernel-driven animation preserve and surfaces do not.
- [LEXTER-DRAFT-mouse-reporting](Log.MouseReporting.md) makes selection
  possible, which needs the text array.

Outside it:

- **kitty's graphics protocol**, cited above, places images with a z-index
  above or below text, and its Unicode placeholders carry an image id in a
  cell's foreground colour and the cell's row and column in combining
  marks: references from every cell, in the character stream.
- **Sixel in xterm, foot, mlterm, and WezTerm** anchors decoded images at
  cells; text written over them replaces them. **notcurses** keeps a state
  for each cell under a bitmap. **Terminology** shows images and plays video
  in the terminal. **iTerm2** has inline images of its own.
- **Hyperlinks (OSC 8)** are stored as a per-cell id in VTE, kitty, WezTerm,
  and foot; **semantic prompts (OSC 133)** per cell in WezTerm and per line
  in kitty.
- **DECDLD**, cited above, and the videotex character sets of Prestel,
  Minitel, and NAPLPS let a host define glyphs; **RIPscrip** brought vector
  graphics to BBSes.
- **Dwarf Fortress, libtcod, Brogue, and Cogmind** draw games on a text grid
  with replaceable tile sets.
- **Colour cycling** in Deluxe Paint and Mark Ferrari's scenes, and palette
  animation on the NES and arcade boards, animate colour without redrawing
  pixels, as swatch iteration would.

## Open Questions

### LEXTER-DRAFT-cell-field-format-O1 — Is index 0 transparent in tile mode?

The arcade convention makes colour 0 of a tile transparent. Tying it to the
layer's fill bit would make index 0 transparent when the fill is off and the
fill colour when it is on. The steward is considering it.

### LEXTER-DRAFT-cell-field-format-O2 — Which scales and cell sizes does tile mode support?

Scaling 8-by-8 glyphs by two fits a wide pair of 8-by-16 cells exactly. Other
cell sizes need a border or a different integer scale, and some have none
that fits. Whether tile mode is tied to particular cell sizes, and which
scales the loader offers, is open.

### LEXTER-DRAFT-cell-field-format-O3 — Should the wide bits become a tile position?

Images, big text, double-height lines, and tiles larger than two cells all
need a cell to know its column and row within a larger object. The surface
reference has them; glyph cells have only the right-half bit. Generalising
it would cost bits the header does not have, or a tail type.

### LEXTER-DRAFT-cell-field-format-O4 — How do tiles reach Lexter?

A coloured, DECDLD-like private sequence; files loaded locally; or only code
that writes the grid directly.

### LEXTER-DRAFT-cell-field-format-O5 — How are surfaces tested?

Glyph cells are checked by checksum. Video and time-driven shaders are not
reproducible in the same way; the steward expects a separate pipeline with
separate tests, whose form is open.

### LEXTER-DRAFT-cell-field-format-O6 — Should swatches be divided into interned and reserved?

Animating a swatch's contents needs swatches that interning never hands out.
The division belongs to whoever owns the swatch namespace
(LEXTER-DRAFT-layer-mechanics-O5).

### LEXTER-DRAFT-cell-field-format-O7 — What do the spare bits hold?

Three header bits and two settings bits remain. Candidates are underline
styles (curly, dotted, double), a hover bit for hyperlinks, and the
protected-cell bit.

### LEXTER-DRAFT-cell-field-format-O8 — What does the text array hold?

Codepoints, combining marks, and grapheme clusters need a form: a fixed
number of codepoints per cell with an overflow pool, as notcurses does, or
something else. It must stay consistent with the record under every
operation, or it repeats the critique's finding that invariants are kept by
one writer and broken by others.

### LEXTER-DRAFT-cell-field-format-O9 — Does tile mode belong in the standard record?

It fits in the tail, and so needs no pipeline of its own. A separate tile
pipeline could offer more colours or larger tiles at the cost of another
record format.

### LEXTER-DRAFT-cell-field-format-O10 — How is a surface's geometry kept consistent with its cells?

The surface table holds each surface's rectangle; its cells hold references.
When cells are overwritten, scrolled, or copied, the two can disagree. Which
of them is authoritative, and when a surface with no remaining cells is
freed, is open.

## Update 2026-10-27 — Mask Targets

This installment records a possibility, not a revision: the body above is
unchanged, and nothing here is authoritative.

### The limit it addresses

In the layout above, mask *k* belongs to layer *k*, so a layer takes at most
one mask. A thumb that starts and ends inside one cell needs the bar and two
bounds on the same layer, which one mask cannot give; the layer-mechanics
survey left this as LEXTER-DRAFT-layer-mechanics-O3, and its worked example
fell back on a minimum thumb length of one cell. The number of masks need not
change to lift the limit, only their assignment.

### Masks with targets

Each of the three masks gains a target: the layer it cuts. Its control field
is four bits.

Table: A mask's control field.

| Bits | Width | Field | Values |
|---|---|---|---|
| 0–1 | 2 | Operation | 0 union, 1 intersection, 2 difference, 3 exclusion |
| 2–3 | 2 | Target | 0, 1, 2 = the layer it cuts; 3 = the mask is unused |

Masks apply to their target in index order, after the display selector, so
that the writer chooses the order by which masks it uses. Moving "unused"
into the target lets the operation field hold four operations with no "none".
Two or three masks may share a target, and the shader's work does not grow:

```glsl
bool cov = display_pixel(l) != display_selector(l);
for (int m = 0; m < 3; m++)                    // flat per cell
    if (mask_target(m) == uint(l))
        cov = apply(mask_op(m), cov, mask_pixel(m));
```

A cell still makes at most three mask reads per pixel, and the targets are
the same across a cell, so the loop does not diverge.

Table: A band from two-eighths to six-eighths down, inside one cell.

| Step | Glyph | Operation | Coverage after the step |
|---|---|---|---|
| Display glyph of layer *L* | ▏ | — | The whole bar |
| Mask 0, target *L* | ▆ (lower six-eighths) | Intersection | The bar from 2/8 down to the bottom |
| Mask 1, target *L* | ▂ (lower two-eighths) | Difference | The bar from 2/8 to 6/8 |

Mask 2 stays free for another layer. The minimum thumb length becomes a
choice of usability rather than a limit of the format.

### Fitting word 1: the fill rule

Three masks of four bits, three layers of six, and the tail type come to 33
bits. One rule recovers three: **a fill slot equal to the ink slot means no
fill**, which retires each layer's fill-on bit. Nothing is lost. A layer
whose ink and fill slots are the same draws every pixel in one colour, a
solid cell, which can always be drawn with two different slots instead: a
space glyph whose fill is that slot, or a full block whose ink is. The rule
compares slots, not colours, so two slots that hold the same colour are
unaffected.

Table: Word 1 with mask targets.

| Bits | Width | Field |
|---|---|---|
| 0–4 | 5 | Layer 0: ink slot (2), fill slot (2; equal to the ink slot = no fill), display selector (1) |
| 5–9 | 5 | Layer 1, the same |
| 10–14 | 5 | Layer 2, the same |
| 15–18 | 4 | Mask 0: operation (2), target (2) |
| 19–22 | 4 | Mask 1, the same |
| 23–26 | 4 | Mask 2, the same |
| 27–29 | 3 | Tail type |
| 30–31 | 2 | Spare |

The header keeps its three spare bits, and the tail keeps its layout: words
5–7 hold mask glyphs 0–2, whatever their targets.

Table: The present transparent-side values under the fill rule.

| Present value | Display selector | Fill slot |
|---|---|---|
| `:none` | 0 | The background slot, which differs from the ink slot |
| `:bg` | 0 | Equal to the ink slot (no fill) |
| `:fg` | 1 | Equal to the ink slot (no fill) |

A present layer whose ink and background slots happen to be equal under
`:none` would have to be rewritten with two different slots.

### What this format gives up

Without a pixel selector for each mask, two operations are lost: union with
the mask's uninked pixels, and exclusion with them. The first is how a layer
would add an upper block to its glyph. Drawing that block on another layer in
the same colour gives the same picture, but costs a layer, and layers are
what the record is shortest of. The format is recorded as a possibility for
that reason.

### An alternative that keeps them

Each mask keeps a selector bit, so its field is five bits, and the tail type
moves into the masks' own bits when no mask is used. A cell already holds
masks or a payload, never both, so the tail type is needed only when all
three targets are 3.

Table: A mask's control field in the alternative.

| Bits | Width | Field | Values |
|---|---|---|---|
| 0–1 | 2 | Operation | 0 union, 1 intersection, 2 exclusion, 3 reserved |
| 2 | 1 | Mask selector | 0 = the mask glyph's inked pixels; 1 = its uninked pixels |
| 3–4 | 2 | Target | 0, 1, 2 = the layer it cuts; 3 = the mask is unused |

Table: Word 1 in the alternative.

| Bits | Width | Field |
|---|---|---|
| 0–14 | 15 | Layers 0–2, five bits each, with the fill rule |
| 15–19 | 5 | Mask 0 |
| 20–24 | 5 | Mask 1 |
| 25–29 | 5 | Mask 2 |
| 30–31 | 2 | Spare |

When all three targets are 3, mask 0's operation and selector bits hold the
tail type, and those of masks 1 and 2 hold six bits for the payload, such as
tile mode's mode field. When any target is 0–2, the tail holds mask glyphs.

The operations with the selector give union, intersection, and exclusion
against either the mask's inked or its uninked pixels, six functions, with
difference as intersection with the uninked pixels, as in the original mask
code of the layer-mechanics survey. Operation 3 is free; one candidate is the
mask's pixels less the running coverage, which no other value expresses. The
costs are a conditional decode, since the tail type is found inside the
masks' bits, and that a cell's kind depends on four fields rather than one.

A third encoding packs operation and target into one four-bit code: "unused"
plus three targets times five operations, sixteen values. It keeps union with
the uninked pixels, but decoding divides by five, and a kernel could not
change a target or an operation alone.

This installment adds two open questions.

### LEXTER-DRAFT-cell-field-format-O11 — Should masks have targets, and in which encoding?

The format with four operations, or the alternative with a selector for each
mask and the tail type folded into unused masks. The steward's concern with
the first is that the two operations it drops can be recovered only by
spending a layer.

### LEXTER-DRAFT-cell-field-format-O12 — How does a mask apply to a wide display glyph?

A mask on one half of a double-width glyph could be a narrow glyph applied to
that half, or the matching half of a wide mask glyph. The rule is needed by
either encoding.
