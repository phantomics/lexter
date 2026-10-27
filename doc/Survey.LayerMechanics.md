---
id:            LEXTER-DRAFT-layer-mechanics
title:         "Layer Mechanics: Survey"
genre:         Survey
scope:         component
project:       Lexter
component:     renderer
language:      en
status:        Draft
provenance:
  assistant:   opencode
relates-to:
  - LEXTER-DRAFT-data-structures-1e
  - LEXTER-DRAFT-data-structures-1e-critique
  - LEXTER-DRAFT-pane-profiles
  - LEXTER-DRAFT-palette-paging
  - LEXTER-DRAFT-offscreen-fbo
  - LEXTER-DRAFT-enhanced-dual-width
  - LEXTER-DRAFT-screenshot-test-rig
cites:
  - title:    "Session transcript ses_febe-LexterCritique"
    locator:  "session-ses_febe-LexterCritique.md, the closing review"
    external: true
  - title:    "Compositing Digital Images"
    locator:  "Thomas Porter and Tom Duff, Computer Graphics 18(3), SIGGRAPH 1984, pp. 253-259"
    external: true
  - title:    "sb-simd"
    locator:  "SBCL contributed module sb-simd, as installed with SBCL 2.3.4"
    external: true
open-questions:
  - LEXTER-DRAFT-layer-mechanics-O1
  - LEXTER-DRAFT-layer-mechanics-O2
  - LEXTER-DRAFT-layer-mechanics-O3
  - LEXTER-DRAFT-layer-mechanics-O4
  - LEXTER-DRAFT-layer-mechanics-O5
  - LEXTER-DRAFT-layer-mechanics-O6
  - LEXTER-DRAFT-layer-mechanics-O7
  - LEXTER-DRAFT-layer-mechanics-O8
  - LEXTER-DRAFT-layer-mechanics-O9
  - LEXTER-DRAFT-layer-mechanics-O10
  - LEXTER-DRAFT-layer-mechanics-O11
---

# Layer Mechanics: Survey

This survey explores how Lexter stores and draws the glyphs of a cell. It
asks whether the present design, in which a cell is either a simple glyph or
a sparse stack of up to three layers, should give way to a single dense
array in which every cell has room for three display glyphs and three mask
glyphs. A mask glyph changes which pixels of one display glyph are inked, by
a logical operation encoded in four bits, without adding to the cell's four
colours. The survey covers the screen model, the display grid, and the
renderer; compares the two designs; and looks at what the dense design makes
possible: mutation of the grid by assembly kernels, reuse of unused mask
fields for other effects, and a choice between one pipeline and fully
separate pipelines of different depths. It decides nothing. The present
structures are specified in
[LEXTER-DRAFT-data-structures-1e](Spec.DataStructures1e.md) and criticised in
[LEXTER-DRAFT-data-structures-1e-critique](Eval.Critique.DataStructures1e.md);
this survey asks what a second edition's cell could be, and maps the findings
of that critique and of an earlier review onto the dense design. Its main
finding is that the dense design keeps cells consistent by construction but
depends on one owner for the swatch namespace, which must come first. Scroll
bars of the kind [LEXTER-DRAFT-pane-profiles](Plan.PaneProfiles.md) leaves to
decorators are its first use case.

## Motivation

A scroll bar built from the left one-eighth block "▏" can show its thumb's
position only to the nearest cell. Cutting the block with another glyph, for
example removing its lower three-quarters with the lower three-quarters
block "▆", gives eighth-of-a-cell resolution. A column of such cells,
overprinted on a pane's edge, would make sub-cell scroll bars a common
convention, so layered cells would become the usual case rather than the
exception.

Four further wants shape the territory:

- **Arbitrary masking**, not only block elements: any glyph may cut any
  other.
- **Animation**, with many cells changing their masks on every frame. That
  rules out designs that need work per new combination of glyphs.
- **A transparent overlay**, in which Lexter draws over another
  application's scene, such as a game. In that mode a layer can no longer
  hide what is beneath it by painting the background colour, so masks must
  remove ink rather than cover it.
- **Four colours per cell.** More colours in one cell tends to illegibility.
  Depth beyond that belongs to something other than text.

## Ontology sketch

- **Display glyph.** A glyph from the atlas that is drawn. A cell has up to
  three, one per *paint layer*, painted in order, upper over lower.
- **Mask glyph.** A glyph from the atlas that is never drawn. Each paint layer
  has at most one, which combines with the display glyph to decide the
  layer's ink. A mask therefore cuts only its own layer.
- **Mask code.** Four bits per layer: the logical operation, and whether
  each of the two glyphs contributes its foreground (inked) or background
  pixels.
- **Ink slot and fill slot.** Each paint layer draws its ink in one of the
  cell's four swatch colours, and may fill its un-inked pixels with another.
  With no fill, those pixels are transparent and the layer below shows.
- **Swatch.** The cell's four colours, as now: indices into a 256-colour
  palette.

A cell therefore holds up to six glyphs and four colours. Today's
`transparent-side` becomes a combination of the mask code and the fill:
`:none` is a plain glyph filled with the background slot, `:bg` is a plain
glyph with no fill, and `:fg` is an inverted glyph with no fill. Layer 0 is
then an ordinary layer, which is all the transparent overlay needs from the
cell format.

## The Current System

The present design separates simple and layered cells inside one grid. The
choice is made per cell.

- **The screen model** holds flat arrays of glyphs, swatch indices,
  attributes, and wide flags (`src/model.lisp:make-screen@2d4d743`). A
  layered cell is an entry in an `equal` hash table keyed by a `(col . row)`
  cons, holding a struct and a vector of layer structs
  (`src/model.lisp:%ensure-layered@2d4d743`,
  `src/model.lisp:%get-layered@2d4d743`).
- **The display grid** repeats that pattern with its own structs, and also
  owns two render buffers sized for the worst case: 12 bytes per cell for
  simple instances and 48 for layered ones, three layers of 16
  (`src/grid.lisp:%allocate-render-buffers@2d4d743`).
- **Each frame**, `src/grid.lisp:build-render-data@2d4d743` walks every cell
  in Lisp and packs it into one of the buffers, ignoring the dirty flags, and
  compacts the layered buffer.
  `src/renderer.lisp:render-frame@2d4d743` uploads both buffers whole and
  issues one draw call for simple cells and up to three for layered cells,
  one per layer depth. Because GL 3.3 has no base-instance draw, it slides
  the vertex attribute pointers between layer draws. Layer 0 is drawn opaque
  and layers 1 and 2 are blended over it.
- **The instance format** is written out in three places that must agree:
  the packer in `build-render-data`, the attribute setup in the renderer, and
  the shader (`src/shaders.lisp:+layered-frag+@2d4d743`). The stride is
  defined twice, as `src/grid.lisp:+layered-stride+@2d4d743` and
  `src/renderer.lisp:+layered-stride+@2d4d743`.
- **Scrollback** keeps a three-element list per cell
  (`src/model.lisp:%save-to-scrollback@2d4d743`), about 56 bytes per cell in
  64-bit SBCL, and drops layers.
- **The cursor** is drawn by interning a reversed swatch into the model's
  swatch table during the flush (`src/model.lisp:flush-to-display@2d4d743`).
- **The palette slot** is one uniform for the whole frame. The compositor
  sets it from the focused pane
  (`src/panes/compositor.lisp:gui-tick@2d4d743`), so every pane is drawn with
  that pane's palette.

The data-structures critique records several of these as findings:
constants defined more than once
(LEXTER-DRAFT-data-structures-1e-critique-O18), dirty bits maintained but
never read (LEXTER-DRAFT-data-structures-1e-critique-O22), layered cells that
drift apart between the model and the grid, including under the cursor
(LEXTER-DRAFT-data-structures-1e-critique-O9), and wide characters that
never reach the GPU from a screen
(LEXTER-DRAFT-data-structures-1e-critique-O1). Its synthesis traces most of
them to copies of the same data with no single owner, and to invariants kept
by one writer and broken by the others. The earlier review cited above adds
the cost of the cons-keyed hash tables and of the list-per-cell scrollback.

## Mask Encodings

The steward's encoding gives two bits to the operation and one to each
glyph's pixel selector.

Table: The four-bit mask code.

| Bits | Field | Values |
|---|---|---|
| 0–1 | operation | 0 none, 1 union, 2 intersection, 3 exclusion |
| 2 | display selector | 0 foreground pixels of the display glyph, 1 background pixels |
| 3 | mask selector | 0 foreground pixels of the mask glyph, 1 background pixels |

Code 0 is a plain display glyph with no mask. Difference needs no code of its
own, since it is intersection with the mask's background pixels.

The encoding is complete for practical purposes. Of the sixteen logical
functions of two inputs, union with the selectors gives the four forms of
OR, intersection the four forms of AND, and exclusion gives XOR and its
negation. Operation "none" gives the display glyph plain or inverted. The
only functions missing are the mask glyph alone, which is the same as using
it as the display glyph, and the two constants, which are a full block and
an empty layer. The encoding has two redundancies: exclusion with both
selectors set equals exclusion with neither, and "none" ignores the mask
selector. The second is free for other use (see Overloading Unused Masks).

The selectors are what make the scroll bar work with Unicode as it is.
Block Elements has every lower block in eighths (U+2581 to U+2588) but only
the upper eighth and upper half; the background pixels of a lower block are
the matching upper block, and the two join without a gap, since each is the
exact complement of the other in the same font.

The alternative is a four-bit truth table, as in X11's drawing functions and
Win32's ROP2 codes: bit `i` gives the result when `i = 2·display + mask`.
Every code is then a distinct function. It has no natural "none", though:
its 0 is "clear", and reserving that as "none" leaves "plain glyph" with two
codes.

A shader evaluates either in a few integer operations:

```glsl
// d, m: true where the display or mask glyph is inked (R8 atlas, nearest)
bool dv  = d != ((code & 4u) != 0u);
bool mv  = m != ((code & 8u) != 0u);
uint op  = code & 3u;
bool ink = op == 0u ? dv : op == 1u ? (dv || mv)
         : op == 2u ? (dv && mv) : (dv != mv);
```

## The Dense Cell Array

In the dense design every cell is one fixed-size record, and the screen is a
three-dimensional array of rows by columns by record bytes. No cell has
pointers, and every cell can hold all three layers whether or not it uses
them.

A record of 32 bytes, eight 32-bit words, holds everything with room to
spare:

Table: A 32-byte cell record.

| Word | Contents |
|---|---|
| 0 | swatch index (15 bits); palette slot (2); wide (1); right half (1); cursor (2); layer present (3); line attributes (5); 3 spare |
| 1–2 | layer 0: display glyph, mask glyph |
| 3–4 | layer 1: display glyph, mask glyph |
| 5–6 | layer 2: display glyph, mask glyph |
| 7 | per layer, 9 bits: ink slot (2), fill slot (2), fill on (1), mask code (4); 5 spare |

A 24-byte record is possible with 24-bit glyph indices, each glyph word
carrying 8 bits of settings; it uses about 44 of its 48 setting bits and
leaves almost nothing spare. It has no room for layer-present bits, so an
absent layer would be marked by glyph 0, which needs atlas position 0
reserved for an empty glyph. That reservation is also the seed of
LEXTER-DRAFT-data-structures-1e-critique-O10, which finds position 0 a real
glyph that no screen can show. 24 bits are enough for any atlas: the largest
texture GL allows, 16384 pixels square, holds about 2.1 million 8×16 glyphs.

The steward leans to the 32-byte record, for its headroom and because one
record fills one 256-bit AVX2 register (LEXTER-DRAFT-layer-mechanics-O1).

**Layers are for glyphs; attributes are bits.** Underline, strikethrough, and
overline are rules of pixels the shader can draw from bits, and should not
use up layers that text needs: a Vietnamese letter with two stacked
diacritics already takes three. The five line-attribute bits of word 0 hold
underline, strikethrough, and overline (one bit each) and a swatch slot for
the underline colour (two bits). The cursor takes two bits as well: none,
block, underline, or bar. The flush sets them on the cursor's cell, and the
shader draws the block by swapping the ink and fill slots and the other two
as rules. That removes the reversed swatch the flush now interns on every
frame, which is the write behind
LEXTER-DRAFT-data-structures-1e-critique-O2, a source of the growth in
LEXTER-DRAFT-data-structures-1e-critique-O6, and the reason overlays vanish
under the cursor in LEXTER-DRAFT-data-structures-1e-critique-O9. It also
makes drawable the cursor styles that the screen stores but no code draws
(LEXTER-DRAFT-data-structures-1e-critique-O21). Three bits of word 0 and five
of word 7 remain for later attributes.

The record changes how the renderer works:

- **No positions are stored.** The shader computes a cell's column and row
  from its instance number and the grid width.
- **Wide glyphs become two halves.** A double-width glyph is stored in both
  of its cells, with the right-half bit set in the second. Each cell draws
  its own half, so every quad is one cell in size and continuation flags go
  away. A cell overwritten on either side then shows only its own half,
  rather than corrupting the pair's flags, which is how wide characters are
  lost today (LEXTER-DRAFT-data-structures-1e-critique-O1).
- **One draw call.** Every cell is one instance, and the fragment shader
  paints the three layers in order and writes the finished colour, so there
  are no per-layer passes, no blending between layers, and no sliding of
  attribute pointers. A layered cell is shaded once rather than up to three
  times. Settings are the same across a cell, so a cell with empty upper
  layers skips them without divergence.
- **Transparency is resolved in the shader.** The shader composites the
  layers itself and outputs premultiplied colour; only the final blend, over
  another scene, uses the GPU's blending.

```glsl
vec4 acc = vec4(0.0);                                  // premultiplied
for (int l = 0; l < 3; l++) {
    if (!present(l)) continue;                         // flat per cell
    bool ink = coverage(l);                            // display, mask, code
    vec4 c = ink ? colour(ink_slot(l))
                 : fill_on(l) ? colour(fill_slot(l)) : vec4(0.0);
    acc = c + acc * (1.0 - c.a);                       // layer l over the rest
}
frag_color = acc;
```

The worst case per pixel is six atlas reads, one swatch read, and up to four
palette reads. A 4K window at 8×16 pixels has about 64,800 cells, and the
whole frame stays well under a millisecond on integrated graphics.

The grid's array can be the upload buffer itself. Since it is row-major,
each dirty row is one contiguous byte range, uploaded with
`glBufferSubData`; the per-frame packing loop disappears, and the dirty
flags finally do the work they were written for. Rewriting the mask words of
every cell of a 4K window touches about 780 KB, and uploading the whole grid
on every frame at 60 frames a second is about 124 MB/s, which suits the
animation case.

Uploading only dirty rows makes the renderer trust a record of what it last
uploaded, and the data-structures critique shows how such records fail when
they carry no identity: a recorded generation says nothing about whose
generation it was (LEXTER-DRAFT-data-structures-1e-critique-O5), and a
workspace switch clears the grid without marking anything dirty
(LEXTER-DRAFT-data-structures-1e-critique-O14). The dense design would make
both faults worse, since a stale row would simply stay on the GPU. The
renderer therefore needs to record which grid it uploaded, by an identity or
an epoch drawn from one global counter, and to upload the whole grid when
the grid is replaced (as `terminal-reset` does), when the workspace changes,
or when the size changes.

## Comparison

Table: The current system and the dense cell array compared.

| Aspect | Current system | Dense cell array |
|---|---|---|
| Model storage | Flat arrays, plus a hash table of layered cells with structs | One array of records |
| Grid storage | The same, plus render buffers reserving 60 bytes per cell | One array of records, which is also the upload buffer |
| Bytes reserved per grid cell | About 66 | 32 |
| Layers and masks per cell | 3 and 0 | 3 and 3 |
| CPU work per frame | Every cell packed in Lisp | None for unchanged rows |
| Upload | Both buffers whole, every frame | Dirty rows only |
| Draw calls | 1, plus up to 3 for layers | 1 |
| Layer compositing | GPU blending, one pass per layer | In the fragment shader |
| Format definitions | Three, kept in step by hand | One, if generated from a descriptor |
| Plain text | 12 bytes read, simple shader | 32 bytes read, empty layers skipped |
| Scrollback | A list per cell, layers lost | A record per cell, layers kept |
| Transparent overlay | Layer 0 always opaque | Fill per layer; one final blend |
| Palette slot | One per frame | Per cell, from 2 bits |
| Cursor | A reversed swatch interned into the model every frame | Two bits, drawn by the shader |
| Line attributes | Not drawn | Bits, drawn by the shader |
| Mutation by kernels | Impractical: hash tables and structs | Natural: fixed offsets |

A single descriptor, a macro such as `define-cell-layout`, could generate
the Lisp accessors, the GLSL decoding, and the vertex attribute setup from
one definition, replacing the three hand-kept copies that
LEXTER-DRAFT-data-structures-1e-critique-O18 faults.

## The Critiques and the Dense Design

Two critiques bear on this territory. The data-structures critique,
[LEXTER-DRAFT-data-structures-1e-critique](Eval.Critique.DataStructures1e.md),
tested each structure against scenarios and reproduced or traced each of its
22 findings. The earlier review in the critique session cited above read the
class and struct composition for limits on adaptability and fragile
components. They were made independently: the Eval's Method records that its
critic did not read the session transcript. They agree on the most important
point, that panes overwrite each other's swatches in the shared grid, and
otherwise complement each other: the review found ceilings and coupling that
are not yet faults, and the Eval found faults that reading the structure
alone did not show, chief among them that wide characters never reach the
GPU.

The table sorts every finding of both by what the dense design does to it.

Table: Findings of both critiques and the effect of the dense design on each.

| Finding | Source | Severity | Effect | Why |
|---|---|---|---|---|
| Wide characters never reach the GPU | LEXTER-DRAFT-data-structures-1e-critique-O1 | high | Eased | Halves remove the grid and cursor faults; the VT handler must still ask the atlas whether a glyph is wide |
| The grid's swatch generation has two meanings | LEXTER-DRAFT-data-structures-1e-critique-O2 | high | Eased | The cursor bits remove the per-frame swatch write that triggers it; the counter protocol remains |
| Host input escapes the handler's declared types | LEXTER-DRAFT-data-structures-1e-critique-O3 | high | Unaffected | The handler, not the cell format |
| Panes write their own swatch numbering into one store | LEXTER-DRAFT-data-structures-1e-critique-O4; review | high | Unaffected, now a prerequisite | Copying rows needs one swatch numbering |
| Generation records are trusted across producers | LEXTER-DRAFT-data-structures-1e-critique-O5 | high | Unaffected, a new risk | Dirty-row uploads depend on the same kind of record |
| The swatch table outgrows the grid and the GPU | LEXTER-DRAFT-data-structures-1e-critique-O6; review | high | Eased | The cursor no longer interns swatches; the 15-bit field still needs a capacity enforced at interning |
| TN3270E negotiation fails with RFC 2355 servers | LEXTER-DRAFT-data-structures-1e-critique-O7 | high | Unaffected | A protocol, not a structure |
| Moving or clearing cells leaves wide flags behind | LEXTER-DRAFT-data-structures-1e-critique-O8 | medium | Resolved | The record is the unit of every move and clear |
| Layered cells diverge between model and grid | LEXTER-DRAFT-data-structures-1e-critique-O9 | medium | Resolved | Whole records are copied; the cursor is bits |
| Glyph 0 and codepoint 32 are overloaded | LEXTER-DRAFT-data-structures-1e-critique-O10; review | medium | Eased | Layer-present bits make glyph 0 unnecessary as a sentinel; writers must still take the blank from the atlas |
| The active buffer is not always read through the handler | LEXTER-DRAFT-data-structures-1e-critique-O11 | medium | Unaffected | Ownership of buffers, not their format |
| The viewport moves the scroll bar but not the picture | LEXTER-DRAFT-data-structures-1e-critique-O12 | medium | Eased | History of records is drawn by copying rows; the inverted thumb is unaffected |
| The TN3270 screen assumes a fixed size | LEXTER-DRAFT-data-structures-1e-critique-O13 | medium | Unaffected | The 3270 pane would be rewritten to the record, but its sizing is separate |
| A workspace switch clears the grid without a repaint | LEXTER-DRAFT-data-structures-1e-critique-O14 | medium | Unaffected, a new risk | Stale rows would stay on the GPU under dirty-row uploads |
| Autowrap ignores the scrolling region | LEXTER-DRAFT-data-structures-1e-critique-O15 | medium | Unaffected | The handler |
| The telnet client mangles code 255 | LEXTER-DRAFT-data-structures-1e-critique-O16 | medium | Unaffected | A protocol |
| The headless paths dereference a missing PTY | LEXTER-DRAFT-data-structures-1e-critique-O17 | low | Unaffected | The terminal, not the cell |
| Constants and names are defined more than once | LEXTER-DRAFT-data-structures-1e-critique-O18; review | low | Resolved for the cell format | One descriptor; the duplicated default palettes remain |
| Package boundaries disagree with the code | LEXTER-DRAFT-data-structures-1e-critique-O19; review | low | Eased | The flush becomes a record copy through an exported interface, not a `::` read of the grid's arrays |
| Backends are told the pane's size | LEXTER-DRAFT-data-structures-1e-critique-O20 | low | Unaffected | The pane protocol |
| Descriptions have drifted from the model | LEXTER-DRAFT-data-structures-1e-critique-O21 | low | Eased in part | The stored cursor styles become drawable |
| The grid's dirty bits are never read | LEXTER-DRAFT-data-structures-1e-critique-O22; review | low | Resolved | They drive the uploads |
| The cursor writes into the model during the flush | Review | — | Resolved | The cursor is bits |
| Two parallel stacks, `unix-term` and the compositor | Review | — | Unaffected | Both would need the new format |
| The 3270 pane bypasses the model | Review | — | Unaffected | It must be rewritten to the record, or keep its own path |
| Global state in place of instance state | Review | — | Unaffected | `*cursor-blink-on*`, `*prefix-key*`, the window title |
| Four palette slots | Review | — | Eased | A per-cell slot lets every pane draw with its own; four remains the limit |
| Four colours per cell | Review | — | Kept by choice | Legibility; depth goes to a separate pipeline |
| `screen` drifts toward a god-struct | Review | — | Eased | Cell data becomes one array; the other slots remain |
| Scrollback stores a list per cell | Review | — | Resolved | Rows of records |
| Layered cells keyed by conses in hash tables | Review | — | Resolved | No hash tables |
| Reliance on babel's internals | Review | — | Unaffected | Encoding, not cells |
| The record's alignment in the Lisp heap | This survey | — | A new risk | See Mutation Kernels |

In the Source column, "review" is the review in the critique session, which
gave no severities.

Three observations follow. The redesign resolves or eases most of the
medium- and low-severity findings, and almost all of them are about cells:
it makes the record, rather than each function, the keeper of a cell's
invariants, which is the fix the Eval's synthesis asks for under its second
theme. It leaves untouched the Eval's first theme, copies of the same data
with no owner, and the swatch findings in particular; it raises the stakes
of those, since row copying needs one swatch numbering and dirty-row uploads
need trustworthy records. And it replaces the one part of the format the
Eval found sound: the GPU instance layout agrees byte for byte between
packer and attribute setup. The case for the dense design is therefore
capacity, speed, and maintainability, not the correctness of today's
layout.

## Mutation Kernels

A dense array of fixed-size records is what a machine-code kernel wants: cell
`i` is at byte `32·i`, every field at a fixed offset, and nothing to follow.
The steward has built tools that generate custom assembly kernels at run
time through SBCL's VOP system, and the dense grid gives them a natural
target.

Operations that fit:

- filling a region with one record, as when a pane is cleared;
- scrolling rows, which is a block move;
- recolouring a region by rewriting the swatch field of each record;
- animating masks by rewriting the mask words of many cells from a computed
  sequence;
- copying a pane's rows into the composed grid.

The 32-byte record suits SIMD exactly. One record is one 256-bit AVX2
register: a kernel loads a cell, merges new fields under a lane mask with a
blend instruction, and stores it, so updating one field of many cells is a
load, a blend, and a store per cell. A 24-byte record straddles registers.
On ARM, a 128-bit NEON register holds half a record.

Three routes are open. Custom VOPs generated at run time give the most
control. The sb-simd module, installed with this SBCL, offers SIMD
operations as Lisp functions. Typed Lisp loops over `(unsigned-byte 32)`
arrays are the portable baseline and the fallback on other platforms.

A record fills a register only if it does not straddle a 64-byte cache
line, which requires its address to be a multiple of 32. SBCL does not
promise that. Measured in SBCL 2.3.4 on x86-64, with arrays of
`(unsigned-byte 32)`:

Table: Where SBCL 2.3.4 places the data of an array, by the array's size.

| Array | Data address modulo 64 | Moved by a full collection |
|---|---|---|
| 256 bytes, 200 arrays | 0, 16, 32, and 48, 50 arrays each | yes, all |
| 61,440 bytes (an 80×24 grid of records), 200 arrays | 16 in every case, before and after three collections | yes, all |
| 514,560 bytes (a 240×67 grid, about 1080p at 8×16), 200 arrays | 16 in every case | no |

Grid-sized arrays start at a page boundary, so their data sits just after
the 16-byte array header. Records laid from the start of the data therefore
begin 16 bytes past a 32-byte boundary, and every second record crosses a
cache line, which costs every load and store that splits it. Arrays of
128 KB or more, SBCL's large-object threshold, are never moved; smaller ones
are, though they kept the same offset in these runs.

Constraints:

- **Alignment.** Three remedies are open: start the records 16 bytes into
  the array, which works with SBCL's placement as measured but relies on
  behaviour it does not document; keep the grid in foreign memory allocated
  with 32- or 64-byte alignment; or write it through `glMapBufferRange`,
  core since GL 3.0, into memory the GPU reads, whose alignment GL
  guarantees only from version 4.2, as at least 64 bytes
  (`GL_MIN_MAP_BUFFER_ALIGNMENT`). The last two also fix the address, which
  the collector would otherwise change for grids under 128 KB.
- **Pinning.** Kernels running inside Lisp are unaffected by the collector,
  and an upload already pins the array while GL reads it.
- **Dirty rows.** A kernel must mark the rows it writes as dirty, or the
  change is not uploaded.
- **Swatches.** Swatch indices still come from interning, which stays in
  Lisp; kernels copy indices but do not create them.

For an 80×24 terminal none of this matters. Kernels pay off for large grids,
for many cells changing on every frame, and for compositing many panes.

## Overloading Unused Masks

When a layer's mask code is "none", its 32-bit mask word is unused. The
redundant code noted under Mask Encodings, "none" with the mask selector
set, could tag that word as carrying something else. Candidates:

- a sub-cell pixel offset for the layer, two signed bytes, for smooth
  scrolling or motion without redrawing neighbours;
- an opacity for the layer, for fades;
- an effect number and parameter: a shimmer, a wave, a blink phase;
- a second display glyph shown on the other phase of a blink, so blinking
  needs no CPU work;
- a gradient between the ink and fill slots.

This is a tagged union in the wire format, and each effect adds a branch to
the shader. Effects driven by time also threaten the screenshot test rig
([LEXTER-DRAFT-screenshot-test-rig](Log.ScreenshotTestRig.md)), whose
checksums need identical pixels on every run, unless time reaches the shader
as a uniform the rig can fix.

## Pipeline Separation

Three arrangements are possible:

- **Unified.** One cell format, one shader, one draw call. The dense array
  alone.
- **Partially separate,** as now. Two formats share the atlas, swatch
  texture, palette buffer, and grid, and each cell chooses between them. The
  CPU merges both into every frame.
- **Fully separate.** Each pipeline owns its grid, record format, and
  shader. A surface, such as a pane or an overlay, uses one pipeline, and
  surfaces are drawn in order into their rectangles.

The partially separate design pays for two formats in every frame without
letting either be simple: one grid holds both, the hash table and packing
loop serve both, and one draw cannot cover both. A per-row choice between
formats was considered and does not help, since a vertical scroll bar puts a
layered cell in every row.

Full separation is worth more than it first appears. A *standard* pipeline,
the dense array with three layers and four colours, would serve text, which
is nearly everything. A *deep* pipeline, with more layers and wider swatches
in a larger record, would serve pixel art, sprites, and game graphics, where
more than four colours per cell is the point. Neither pays for the other,
because the depth of a cell never varies inside a surface. Because the
surfaces are separate, the pipelines can differ in more than depth: a deep
pipeline could use RGBA colours rather than a palette.

Separation by surface fits the compositor, whose panes are already
rectangles. It also bears on
LEXTER-DRAFT-data-structures-1e-critique-O4: if each pane drew
its own grid, each grid would carry its own pane's swatch table, and panes
could not overwrite each other's colours. The costs are a draw call per
surface, and that surfaces overlapping each other need the transparent
overlay's blending.

## The Model's Storage

The model could store the grid's record too:

- **Flushing becomes copying.** A pane's screen would flush into the grid by
  copying rows with `replace`, or by a kernel, through a function the grid
  exports, rather than by reading the grid's internal arrays with `::` as
  the flush does now (LEXTER-DRAFT-data-structures-1e-critique-O19). A copy
  moves whole records, so a cleared layer cannot linger in the grid, which
  is the seed of LEXTER-DRAFT-data-structures-1e-critique-O9. Copying
  requires a swatch index in a pane's screen to mean the same in the grid,
  which today it does not (LEXTER-DRAFT-data-structures-1e-critique-O4,
  LEXTER-DRAFT-layer-mechanics-O5).
- **Attributes need a home.** The SGR attributes that are drawn, underline
  and its relatives, become the record's line-attribute bits. Those that
  affect only how colours are chosen, such as bold as bright and reverse
  video, are resolved when the swatch is interned, as now; the rest could
  keep a side array.
- **Scrollback becomes rows of records.** A ring of record rows replaces the
  lists, and keeps layers. 2000 lines of 80 cells take about 5 MB, against
  about 9 MB for the lists. Lines of different widths, left by resizing,
  need a fixed maximum width or a vector per line.
- **The cursor becomes bits.** The copy into the grid would set the cursor
  field on the cursor's cell, and the shader would draw it; drawing the
  cursor would no longer write into the model (see The Dense Cell Array).
- **The model grows.** A screen of 80×24 records is 61 KB, against about
  20 KB now. That is small, but it is three times larger.

## Worked Example: A Scroll-Bar Thumb

A thumb that starts three-eighths of the way down row 2 and ends
five-eighths of the way down row 4, drawn with "▏" in one column:

Table: The cells of the thumb and their masks.

| Row | Display glyph | Mask glyph | Code | Result |
|---|---|---|---|---|
| 2 | ▏ | ▅ (lower five-eighths) | 2: intersection | The lower five-eighths of the bar |
| 3 | ▏ | none | 0 | The whole bar |
| 4 | ▏ | ▃ (lower three-eighths) | 10: intersection, mask background | The upper five-eighths of the bar |

A thumb that starts and ends inside one cell needs three shapes at once: the
bar, the upper bound, and the lower bound. With one mask per layer that is
possible only for a full-width bar: "▆" with an exclusion mask of "▂" gives
a band from two-eighths to six-eighths down. A thin bar needs a second mask,
or a band glyph generated into the atlas.

Such thumbs are the ordinary case, not a corner. With the default 2000 lines
of scrollback and 24 visible rows, a thumb in proportion is
24 × 24 / 2024 ≈ 0.28 of a cell, about four pixels of a 16-pixel cell.
Graphical toolkits give the thumb a minimum length for the same reason, so
that it stays visible and can be grabbed. A minimum of one cell keeps every
thumb within two cells, each end of which needs only one mask; the thumb's
position stays exact to an eighth while its length is rounded up. The
minimum is a rule for whoever draws the scroll bar, not a property of the
record.

The thumb's position needs care too. Today's
`src/panes/chrome-mixin.lisp:scroll-bar-thumb-geometry@2d4d743` places the
live screen, a viewport offset of 0, at the top of the bar, the opposite of
its own comment and of every scroll bar's convention
(LEXTER-DRAFT-data-structures-1e-critique-O12). A sub-cell thumb would make
that inversion more visible, not less.

Eighths are exact only where the cell height is a multiple of eight. In the
18-pixel cells of Terminus, the font's block elements are rounded, though a
block and its complement still join.

## The deeper claim

The territory points to one rule: a cell format should be uniform within a
surface and separate across surfaces. Inside a surface, one dense record
makes the grid an array that kernels, uploads, and the shader treat alike,
and makes the record the keeper of every cell's invariants. Across
surfaces, separate pipelines let depth and colour vary where the content
needs them, without making every cell pay for the deepest case.

The rule has a precondition that the record cannot meet: each namespace a
record points into, swatches above all, needs one owner, and each record of
"what changed" needs an identity. Both critiques put swatch ownership first,
and the dense design leans on it harder than today's format does, so it
comes before the dense design rather than after it.

## Honest Limits

- **A fixed ceiling.** Three layers and one mask per layer, permanently for
  the standard pipeline; raising it means a new record size.
- **The thin single-cell band.** A sub-cell band of a thin glyph needs two
  masks or a generated glyph (LEXTER-DRAFT-layer-mechanics-O3).
- **A rewrite.** The model's storage, the grid, `flush-to-display`, the
  renderer, both shaders, and the 3270 pane, which writes to the grid
  directly, would all change.
- **Plain text pays.** A cell with one glyph reads 32 bytes instead of 12.
- **The swatch problem is a prerequisite, not a consequence.** A new format
  does not give panes one swatch numbering
  (LEXTER-DRAFT-data-structures-1e-critique-O4) or make the change records
  trustworthy (LEXTER-DRAFT-data-structures-1e-critique-O2,
  LEXTER-DRAFT-data-structures-1e-critique-O5), and row copying and
  dirty-row uploads depend on both.
- **The present layout is sound.** The GPU instance layout is the one part
  of the format the data-structures critique found correct; replacing it is
  justified by capacity, speed, and maintainability, not by a fault in it.
- **Alignment is not guaranteed.** SBCL places a grid-sized array's data 16
  bytes past a 64-byte boundary, so 32-byte records need an offset that
  relies on undocumented behaviour, or memory outside the Lisp heap.
- **Kernels are platform-specific.** AVX2 kernels need an x86-64 machine
  with AVX2 and a portable fallback, and generated code is harder to
  maintain than Lisp.
- **Time-driven effects** break checksum testing unless time is fixed by the
  test rig.
- **Glyph rounding.** Masks cannot make eighths exact where the font's cell
  height does not divide by eight.

## Relationship to Other Work

Within Lexter:

- [LEXTER-DRAFT-data-structures-1e](Spec.DataStructures1e.md) specifies the
  present cell, grid, and instance formats that this survey would replace.
- [LEXTER-DRAFT-data-structures-1e-critique](Eval.Critique.DataStructures1e.md)
  finds the faults several of the dense design's properties address (see The
  Critiques and the Dense Design), and its synthesis asks for a survey of how
  terminals own colour and glyph data across panes and the GPU. This survey
  covers how glyphs are stored and drawn; how other terminals own colour data
  across panes and the GPU remains unsurveyed.
- [LEXTER-DRAFT-pane-profiles](Plan.PaneProfiles.md) leaves scroll bars to
  decorators, which would write masked cells.
- [LEXTER-DRAFT-palette-paging](Log.PalettePaging.md) introduced the four
  palette slots; a per-cell slot would let every pane use its own.
- [LEXTER-DRAFT-offscreen-fbo](Log.OffscreenFBO.md) provides the offscreen
  target that a transparent overlay and the test rig both draw into.
- [LEXTER-DRAFT-enhanced-dual-width](Log.EnhancedDualWidth.md) defines wide
  glyphs, which the dense record would store as halves.
- [LEXTER-DRAFT-screenshot-test-rig](Log.ScreenshotTestRig.md) checks
  output by checksum, which masks keep deterministic and time-driven effects
  could break.

Outside it:

- **VGA text mode** is the ancestor of the dense design: two bytes per cell,
  a code and an attribute, in one array that the hardware reads directly.
- **Porter and Duff's compositing operators**, cited above, include "in",
  "out", and "xor", which are intersection, difference, and exclusion
  applied to coverage.
- **The Amiga blitter** combined up to three sources by an eight-bit
  minterm, a truth table; X11's drawing functions and Win32's ROP2 codes
  are four-bit truth tables over two.
- **Stencil buffers and SVG or CSS masks** remove coverage from a drawing by
  another shape, as mask glyphs do within a cell.
- **Notcurses** keeps a fixed-size cell and stores long grapheme clusters in
  a side pool, an escape hatch from a dense format.
- **kitty** keeps separate per-cell records for the CPU and the GPU.

## Open Questions

### LEXTER-DRAFT-layer-mechanics-O1 — A 32-byte or a 24-byte record?

The 32-byte record has spare bits and matches a 256-bit register; the
24-byte record saves a quarter of the memory and bandwidth but has almost no
room for growth, and none for the cursor and line-attribute bits. The
steward leans to 32 bytes. What stays open is whether the spare bits are
enough, and how the record is aligned (LEXTER-DRAFT-layer-mechanics-O7).

### LEXTER-DRAFT-layer-mechanics-O2 — The operation and selector code, or a truth table?

The steward's encoding has a natural "none" and a spare code for effects;
the truth table makes every code a distinct function.

### LEXTER-DRAFT-layer-mechanics-O3 — One mask per layer, or two?

One mask fits the record and covers most of the scroll bar. A thin band
inside one cell needs a second mask, which would cost 12 more bytes per
cell, or a generated glyph.

### LEXTER-DRAFT-layer-mechanics-O4 — Should the model store the grid's record?

Sharing the format makes the flush a copy and scrollback compact, and makes
the model three times larger. The model's attributes would need a place.

### LEXTER-DRAFT-layer-mechanics-O5 — Who owns the swatch namespace?

That panes need one swatch numbering is settled by both critiques
(LEXTER-DRAFT-data-structures-1e-critique-O4); the question is the owner. A
swatch table owned by the compositor and shared by every writer; a base
offset per pane into a partitioned table; or a grid per pane, which fits
separate pipelines by surface. The choice also decides how capacity is
enforced (LEXTER-DRAFT-data-structures-1e-critique-O6) and how change records
carry an identity (LEXTER-DRAFT-data-structures-1e-critique-O5). It is a
prerequisite of row copying, and of the dense design generally.

### LEXTER-DRAFT-layer-mechanics-O6 — One pipeline, or separate pipelines by surface?

Separate pipelines allow a deep pipeline for graphics without burdening
text. What a deep record would hold (layer count, colours per cell, palette
or RGBA) is open, as is whether the compositor's panes are the right unit of
surface.

### LEXTER-DRAFT-layer-mechanics-O7 — Which route for kernels, and where does the grid live?

Custom VOPs, sb-simd, or typed Lisp first; and the Lisp heap, foreign
memory, or mapped GPU memory for the array. Alignment now weighs on the
second choice: in the Lisp heap, records need an offset of 16 bytes that
depends on how SBCL places large arrays, and grids under 128 KB move during
collection; foreign memory and mapped buffers give a fixed, chosen alignment.

### LEXTER-DRAFT-layer-mechanics-O8 — What may an unused mask word carry?

The candidates are offsets, opacity, effects, blink glyphs, and gradients.
How effects are selected, and how they stay deterministic under test, is
open.

### LEXTER-DRAFT-layer-mechanics-O9 — Should each cell carry a palette slot?

Two bits per cell would let every pane draw with its own palette, rather
than all of them with the focused pane's.

### LEXTER-DRAFT-layer-mechanics-O10 — How are generated shapes added to the atlas?

Bands, wipes, and other shapes a font lacks would be added at run time. The
atlas currently re-uploads the whole texture to add glyphs
(`src/atlas.lisp:add-cursor-glyphs@2d4d743`), and would need reserved space
and single-glyph uploads.

### LEXTER-DRAFT-layer-mechanics-O11 — Repair the first edition in place, or move to the second?

The critique's findings fall into three groups. Some are needed whichever
course is taken: the swatch protocol
(LEXTER-DRAFT-data-structures-1e-critique-O2, -O4, -O5, -O6), host input
(LEXTER-DRAFT-data-structures-1e-critique-O3), the protocols and terminal
paths (LEXTER-DRAFT-data-structures-1e-critique-O7, -O11, -O13 to -O17,
-O20), the thumb's inversion (LEXTER-DRAFT-data-structures-1e-critique-O12),
and the VT handler's part of LEXTER-DRAFT-data-structures-1e-critique-O1,
which leaves every CJK character wrong today and probably cannot wait. Some
would be wasted work if the dense design follows: the per-function repairs
of LEXTER-DRAFT-data-structures-1e-critique-O8 and -O9, the duplicated
stride of LEXTER-DRAFT-data-structures-1e-critique-O18, the dirty bits of
LEXTER-DRAFT-data-structures-1e-critique-O22, and the grid's half of
LEXTER-DRAFT-data-structures-1e-critique-O1. The rest are small either way.
The question is whether to repair the second group in place, as a stopgap,
or to leave it for the second edition.
