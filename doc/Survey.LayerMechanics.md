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
  - LEXTER-DRAFT-cell-field-format
  - LEXTER-DRAFT-data-structures-1e
  - LEXTER-DRAFT-data-structures-1e-critique
  - LEXTER-DRAFT-pane-profiles
  - LEXTER-0004
  - LEXTER-0008
  - LEXTER-0007
  - LEXTER-0010
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
  - title:    "EGL_EXT_buffer_age and GLX_EXT_buffer_age"
    locator:  "Khronos EGL and OpenGL extension registries"
    external: true
  - title:    "EGL_KHR_swap_buffers_with_damage"
    locator:  "Khronos EGL extension registry"
    external: true
  - title:    "Perform partial rendering when possible"
    locator:  "Alacritty issue 5843, github.com/alacritty/alacritty"
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
  - LEXTER-DRAFT-layer-mechanics-O12
  - LEXTER-DRAFT-layer-mechanics-O13
  - LEXTER-DRAFT-layer-mechanics-O14
  - LEXTER-DRAFT-layer-mechanics-O15
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
separate pipelines of different depths. Later sections take up who owns the
swatches, how cursors and other moving glyphs are drawn, partial redraw, and
a development sequence. The survey decides nothing itself; where the steward
has chosen a direction it says so, and the development plan that follows will
record the decision. The present structures are specified in
[LEXTER-DRAFT-data-structures-1e](Spec.DataStructures1e.md) and criticised in
[LEXTER-DRAFT-data-structures-1e-critique](Eval.Critique.DataStructures1e.md);
this survey asks what a second edition's cell could be, and maps the findings
of that critique and of an earlier review onto the dense design. Its main
finding is that the dense design keeps cells consistent by construction but
depends on settled ownership of the swatches, which must come first. Scroll
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
only functions missing are the mask glyph alone plain or inverted, which
is the same as using it as the display glyph, and the two constants, which
are a full block and an empty layer. The encoding has two redundancies:
exclusion with both selectors set equals exclusion with neither, and "none"
ignores the mask selector. The second is free for other use (see Overloading
Unused Masks).

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

The layout of [LEXTER-DRAFT-cell-field-format](Survey.CellFieldFormat.md)
supersedes this table: it gives the swatch index 16 bits, puts the settings
of all three layers in one word, and places the three display glyphs ahead
of a tail that holds the masks or another payload. The table is kept here for
the argument about size that follows.

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
use up layers that text needs. Text can need them: a letter with two
diacritics that arrive as separate combining marks takes three layers if
each mark has a layer of its own, or two if one mark is a union mask on the
letter's layer, though most text arrives precomposed (ệ is U+1EC7) and needs
one. The five line-attribute bits of word 0 hold underline, strikethrough,
and overline (one bit each) and a swatch slot for the underline colour (two
bits). An earlier draft gave the cursor two bits as well, set by the flush on
the cursor's cell; the steward has since chosen to draw cursors from an
overlay list (see Cursors and the Overlay List), which leaves those bits free
unless the block style keeps them (LEXTER-DRAFT-layer-mechanics-O15). Either
way, the flush stops interning a reversed swatch and writing it into the grid
on every frame, which is the write behind
LEXTER-DRAFT-data-structures-1e-critique-O2, a source of the growth in
LEXTER-DRAFT-data-structures-1e-critique-O6, and the reason overlays vanish
under the cursor in LEXTER-DRAFT-data-structures-1e-critique-O9, and the
cursor styles that the screen stores but no code draws become drawable
(LEXTER-DRAFT-data-structures-1e-critique-O21).

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
  layers skips them without divergence, apart from the case of neighboring
  cells with different layer counts; these may share a GPU warp and retain
  divergence.
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
whole frame should stay well under a millisecond on integrated graphics, an
estimate not yet measured.

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
| Palette slot | One per frame | Per pane, from a uniform, or per cell, from 2 bits (see Swatch Ownership) |
| Cursor | A reversed swatch interned into the model every frame | An instance in the overlay list, drawn over the grid |
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
critic did not read the session transcript save for exposure to the 40-line
header containing the initial prompt and model reasoning and fragments of
Plan.PaneProfiles.md that touched on the swatch finding. They agree on the
most important point, that panes overwrite each other's swatches in the shared
grid, which the review calls "the single most fragile thing in the codebase"
and the first thing to fix. Otherwise they complement each other: the review
found ceilings and coupling that it did not show to be faults, and the Eval
found faults that reading the structure alone did not show, chief among them
that wide characters never reach the GPU.

The table sorts every finding of both by what the dense design does to it.

Table: Findings of both critiques and the effect of the dense design on each.

| Finding | Source | Severity | Effect | Why |
|---|---|---|---|---|
| Wide characters never reach the GPU | LEXTER-DRAFT-data-structures-1e-critique-O1 | high | Eased | Halves remove the grid and cursor faults; the VT handler must still ask the atlas whether a glyph is wide, and whatever writes a wide glyph must write both halves |
| The grid's swatch generation has two meanings | LEXTER-DRAFT-data-structures-1e-critique-O2 | high | Eased | A cursor that writes no swatches removes the trigger; the cause, a counter with two meanings, goes only with per-screen swatch ranges (see Swatch Ownership) |
| Host input escapes the handler's declared types | LEXTER-DRAFT-data-structures-1e-critique-O3 | high | Unaffected | The handler, not the cell format |
| Panes write their own swatch numbering into one store | LEXTER-DRAFT-data-structures-1e-critique-O4; review | high | Unaffected, now a prerequisite | Copied rows need swatch indices that mean the same wherever they go; per-screen ranges provide that (see Swatch Ownership). The review also names the 3270 pane's global swatch allocator |
| Generation records are trusted across producers | LEXTER-DRAFT-data-structures-1e-critique-O5 | high | Unaffected, a new risk | Dirty-row uploads depend on the same kind of record; per-screen ranges record each table's identity |
| The swatch table outgrows the grid and the GPU | LEXTER-DRAFT-data-structures-1e-critique-O6; review | high | Eased | The cursor no longer interns swatches; capacity must still be enforced at interning, per table under per-screen ranges. The review saw the overflow only at the grid |
| TN3270E negotiation fails with RFC 2355 servers | LEXTER-DRAFT-data-structures-1e-critique-O7 | high | Unaffected | A protocol, not a structure |
| Moving or clearing cells leaves wide flags behind | LEXTER-DRAFT-data-structures-1e-critique-O8 | medium | Resolved | The record is the unit of every move and clear |
| Layered cells diverge between model and grid | LEXTER-DRAFT-data-structures-1e-critique-O9 | medium | Resolved | Whole records are copied; the cursor is drawn over the grid, not into it |
| Glyph 0 and codepoint 32 are overloaded | LEXTER-DRAFT-data-structures-1e-critique-O10; review | medium | Eased | Layer-present bits make glyph 0 unnecessary as a sentinel; writers must still take the blank from the atlas. The review names only the codepoint half |
| The active buffer is not always read through the handler | LEXTER-DRAFT-data-structures-1e-critique-O11 | medium | Unaffected | Ownership of buffers, not their format |
| The viewport moves the scroll bar but not the picture | LEXTER-DRAFT-data-structures-1e-critique-O12 | medium | Eased | History of records is drawn by copying rows; the inverted thumb is unaffected |
| The TN3270 screen assumes a fixed size | LEXTER-DRAFT-data-structures-1e-critique-O13 | medium | Unaffected | The 3270 pane would be rewritten to the record, but its sizing is separate |
| A workspace switch clears the grid without a repaint | LEXTER-DRAFT-data-structures-1e-critique-O14 | medium | Unaffected, a new risk | Stale rows would stay on the GPU under dirty-row uploads |
| Autowrap ignores the scrolling region | LEXTER-DRAFT-data-structures-1e-critique-O15 | medium | Unaffected | The handler |
| The telnet client mangles code 255 | LEXTER-DRAFT-data-structures-1e-critique-O16 | low | Unaffected | A protocol |
| The headless paths dereference a missing PTY | LEXTER-DRAFT-data-structures-1e-critique-O17 | low | Unaffected | The terminal, not the cell |
| Constants and names are defined more than once | LEXTER-DRAFT-data-structures-1e-critique-O18; review | low | Resolved for the cell format | One descriptor; the duplicated default palettes remain |
| Package boundaries disagree with the code | LEXTER-DRAFT-data-structures-1e-critique-O19; review | low | Eased | The flush becomes a record copy through an exported interface, not a `::` read of the grid's arrays. The review names only that one `::` read |
| Backends are told the pane's size | LEXTER-DRAFT-data-structures-1e-critique-O20 | low | Unaffected | The pane protocol |
| Descriptions have drifted from the model | LEXTER-DRAFT-data-structures-1e-critique-O21 | low | Eased in part | The stored cursor styles become drawable |
| The grid's dirty bits are never read | LEXTER-DRAFT-data-structures-1e-critique-O22; review | low | Resolved | They drive the uploads |
| The cursor writes into the model during the flush, so the model cannot be flushed twice | Review | — | Resolved | The cursor is an overlay instance drawn over the grid |
| Two parallel stacks, `unix-term` and the compositor | Review | — | Unaffected | Both would need the new format |
| The 3270 pane bypasses the model | Review | — | Unaffected | It must be rewritten to the record, or keep its own path |
| Global state in place of instance state | Review | — | Unaffected | `*cursor-blink-on*`, `*prefix-key*`, the window title, the 3270 pane's swatch cache |
| Mode state kept in two places: stubs on the screen, the real state in the handler | Review | — | Unaffected | The handler, not the cell format |
| Four palette slots | Review | — | Eased | A per-pane uniform or a per-cell slot lets every pane draw with its own; four remains the limit. The review assumes four can be used at once today; only the focused pane's is |
| Four colours per cell | Review | — | Kept by choice | Legibility; depth goes to a separate pipeline |
| `screen` drifts toward a god-struct | Review | — | Eased | Cell data becomes one array; the other slots remain |
| Scrollback stores a list per cell | Review | — | Resolved | Rows of records |
| Layered cells keyed by conses in hash tables | Review | — | Resolved | No hash tables |
| Reliance on babel's internals | Review | — | Unaffected | Encoding, not cells |
| The record's alignment in the Lisp heap | This survey | — | A new risk | See Mutation Kernels |

In the Source column, "review" is the review in the critique session. It gave
no severity labels but ranked its findings in three tiers: four "fragile
load-bearing components", led by the swatch table, then "adaptability limits",
then "smaller observations". Its ranking differs from the Eval's on two rows:
it put the duplicated stride (LEXTER-DRAFT-data-structures-1e-critique-O18)
and the unread dirty bits (LEXTER-DRAFT-data-structures-1e-critique-O22) in
its first tier, where the Eval rates them low. Its remedy for the swatch table
was a single authoritative intern table or content-addressed slots.

Three observations follow. The redesign resolves or eases most of the
medium- and low-severity findings, and almost all of them are about cells:
it makes the record, rather than each function, the keeper of a cell's
invariants, which is the fix the Eval's synthesis asks for under its second
theme. It leaves untouched the Eval's first theme, copies of the same data
with no owner, and the swatch findings in particular; it raises the stakes
of those, since copied rows need swatch indices that mean the same wherever
they go, and dirty-row uploads need trustworthy records. And it replaces the
part of the cell format the Eval found sound: the GPU instance layout agrees
byte for byte between packer and attribute setup. The case for the dense design is therefore
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
- copying a pane's rows into a composed grid, if there is one
  (LEXTER-DRAFT-layer-mechanics-O14).

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
([LEXTER-0010](Log.ScreenshotTestRig.md)), whose
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
  LEXTER-DRAFT-layer-mechanics-O5). With a grid per pane, the screen's array
  would itself be uploaded and there would be nothing to copy
  (LEXTER-DRAFT-layer-mechanics-O14).
- **Attributes need a home.** The SGR attributes that are drawn, underline
  and its relatives, become the record's line-attribute bits. Those that
  affect only how colours are chosen, such as bold as bright and reverse
  video, are resolved when the swatch is interned, as now; the rest could
  keep a side array.
- **Scrollback becomes rows of records.** A ring of record rows replaces the
  lists, and keeps layers. 2000 lines of 80 cells take about 5 MB, against
  about 9 MB for the lists. Lines of different widths, left by resizing,
  need a fixed maximum width or a vector per line.
- **The cursor leaves the model.** Drawing the cursor would no longer write
  into the model: the overlay list draws it over the grid, or, for the block
  style, the copy sets cursor bits in the grid's record (see Cursors and the
  Overlay List, LEXTER-DRAFT-layer-mechanics-O15).
- **The model grows.** A screen of 80×24 records is 61 KB, against about
  20 KB now. That is small, but it is three times larger.

## Swatch Ownership

The swatch findings of the data-structures critique come from one
arrangement: each screen interns swatches into a table of its own, numbered
from 0, and every pane copies its table into the single table of the display
grid, which the renderer mirrors on the GPU.

**Why the GPU's copy goes stale.** The grid's swatch counter has two meanings
(LEXTER-DRAFT-data-structures-1e-critique-O2). Every `set-swatch` on the grid
increments it, and the flush overwrites it with the model's counter after
copying the model's table. The cursor's reversed swatch, written into the
grid on every frame the cursor is drawn, leaves the grid one ahead of the
model. When the model then gains exactly one swatch, the two counters agree,
the flush skips its copy, and the renderer uploads a table that lacks the new
swatch. Later flushes repair the grid but reset its counter, and the cursor's
increment returns it to the number the renderer last recorded, so the GPU
stays stale until another swatch is interned. The cursor's write is the
trigger; the cause is a counter that can be assigned, and so can go down. A
cursor that writes no swatches (see Cursors and the Overlay List) removes the
trigger in a window with one terminal, but the 3270 pane,
`setup-default-swatches`, and decorators also write swatches into the grid,
and any of them can bring the coincidence back.

**A window-wide table.** One way out is a single swatch table per window,
owned by the compositor, into which every screen and every other writer
interns. Indices then mean the same everywhere, and the grid need not hold a
copy. It gives up more than it first appears to.

Table: What a window-wide swatch table gives up.

| Lost | Consequence |
|---|---|
| Per-screen numbering | A screen's indices mean something only in its window; moving a screen to another window, or `terminal-reset`, means interning again |
| Separate capacity | One colourful pane can use up entries the others need |
| The colour model in one place | LEXTER-D12 put the palette on the screen beside the swatch table it already owned; swatches would move to the window while palettes stay with screens |
| Local eviction | Freeing an unused swatch means scanning every screen's cells and scrollback |

Per-pane colour schemes do not depend on per-screen swatch tables. A swatch
holds palette indices, and the colours come from the palette (LEXTER-D12), so
two panes with different palettes can share the swatch (0 7 7 0) and still
show different colours.

**Per-screen swatch ranges.** The steward prefers to keep a swatch table per
screen and give each table its own range of one GPU swatch store:

- **One store, divided into ranges.** The texture buffer that
  [LEXTER-DRAFT-cell-field-format](Survey.CellFieldFormat.md) proposes holds
  65,536 swatches in 256 KB. Each table owns one range: each screen's, a
  table that replaces the 3270 pane's global cache, and one for chrome.
  Reserved swatches, which LEXTER-DRAFT-cell-field-format-O6 considers for
  animating colours, would be a part of a table's range that interning never
  hands out.
- **The grid holds indices only.** Cells keep the local indices of their
  screen's table. Each table uploads into its range when its identity or its
  count changes. A table that only grows has a version that only rises, its
  count, and the renderer records for each range which table it uploaded and
  how many entries.
- **Every writer interns.** Nothing calls `set-swatch` on a grid:
  `setup-default-swatches`, the 3270 pane, the demo, and decorators intern
  into a table.
- **The primary and alternate screens can share one table.** OSC colour
  changes already apply to the palettes of both buffers; one swatch table and
  range for both is the same idea for swatches.

There are two ways to draw from the ranges
(LEXTER-DRAFT-layer-mechanics-O14):

- **A grid per pane.** Each pane's cells are their own array, drawn by one
  instanced draw with the uniforms `u_swatch_base` and `u_palette_slot`.
  Indices stay local, a pane's dirty rows are uploaded from its own array
  with no composed grid to copy into, and each pane draws with its own
  palette slot, so cells need no palette-slot bits
  (LEXTER-DRAFT-layer-mechanics-O9). It costs a draw call per pane, and
  chrome needs a grid or overlay of its own. It is separation by surface, in
  the sense of Pipeline Separation.
- **One composed grid.** Panes are copied into one window-wide grid drawn in
  one call. The copy adds each table's base to every swatch index, so it is
  no longer a plain copy, and each pane's palette must travel in the
  palette-slot bits of its cells.

Table: The swatch findings under per-screen ranges.

| Finding | Effect |
|---|---|
| LEXTER-DRAFT-data-structures-1e-critique-O2 | Resolved: the grid holds no swatch copy, and each table's count only rises |
| LEXTER-DRAFT-data-structures-1e-critique-O4 | Resolved: ranges never overlap |
| LEXTER-DRAFT-data-structures-1e-critique-O5 | Resolved: the renderer's record names the table, so a replaced table is uploaded |
| LEXTER-DRAFT-data-structures-1e-critique-O6 | A capacity per table, at its range's size, with a local policy for a full table |

The first holds on two conditions: every writer interns, and a table that
changes other than by growing bumps a version that forces its range to be
uploaded again.

**Releasing ranges and swatches.** Two kinds of cleanup are needed, and
fixing LEXTER-DRAFT-data-structures-1e-critique-O2 needs neither. When a
screen goes away, because its pane is destroyed or `terminal-reset` replaces
it, its range returns to the allocator; that is an explicit release, not
garbage collection. Freeing unused swatches within a range when its table
fills is the collecting part, and it is how
LEXTER-DRAFT-data-structures-1e-critique-O6 would be fixed by eviction: mark
the indices still used by the screen's cells and scrollback, free the rest,
and bump the table's version, since eviction breaks the rule that a table
only grows. A range large enough, with a fallback when it fills such as the
nearest existing swatch, avoids eviction altogether. How ranges are sized and
released is LEXTER-DRAFT-layer-mechanics-O12, and where the swatches of
writers without a screen live is LEXTER-DRAFT-layer-mechanics-O13.

## Cursors and the Overlay List

**What the cursor costs today.** `flush-to-display` draws the cursor by
interning a reversed swatch into the screen's table, writing it into the
grid with `set-swatch`, and rewriting the cursor's cell as a plain narrow
cell (`src/model.lisp:flush-to-display@2d4d743`). The first is a write to the
model during the flush, the second is the trigger of
LEXTER-DRAFT-data-structures-1e-critique-O2, and the third breaks wide pairs
(LEXTER-DRAFT-data-structures-1e-critique-O1) and drops layers
(LEXTER-DRAFT-data-structures-1e-critique-O9). The rule that removes all
three is that the cursor belongs to the view, with its blink phase and focus
owned by the window, and is never written into a screen's cells or its
swatch table.

A block cursor needs no mask glyph in the mask code of Mask Encodings,
because the code can always express the negation of a layer's result:

Table: The mask code of a layer, and the code that negates its result.

| Layer's code | The same layer, result negated |
|---|---|
| none, display selector *s* | none, display selector not *s* |
| union | intersection, both selectors flipped |
| intersection | union, both selectors flipped |
| exclusion | exclusion, one selector flipped |

With the fill on, negating layer 0 is reverse video; in the transparent
overlay it is an inked block with a hole in the glyph's shape. Four ways to
draw the cursor follow from that.

- **A stopgap in the first edition.** The present layered format gives each
  layer its own ink and background slot
  (`src/grid.lisp:cell-layer@2d4d743`). Drawing the cursor's cell as layered,
  with layer 0's slots exchanged, gives reverse video without interning a
  swatch; the grid keeps the wide flag, and the next flush of the row removes
  the layer when the cursor moves.
- **A stamped mask.** The copy into the grid stamps the cursor on the grid's
  copy of the cell. A block negates layer 0; an underline or bar is a union
  with "▁" or "▏", which needs a free mask or a free layer. Contention is
  low. VT content uses one layer and no masks, since no escape sequence makes
  layers, and a diacritic, once combining marks are supported, is best drawn
  as a union mask on its letter's layer, which adds ink in the letter's own
  colour and leaves two layers free. Animating a stamped cursor rewrites the
  cell and uploads its row on every frame. It needs the dense design's masks.
- **A uniform cursor.** Uniforms set each frame give the cursor's cell,
  glyph, mask, code, and ink slot, and the shader applies them to that one
  cell as a fourth, virtual layer in the same pass. It writes no cells and
  competes for nothing, but every pixel compares its cell with each entry, so
  it suits one cursor and not dozens.
- **An overlay list.** Cursors and other sparse, moving glyphs are instances
  in a list of their own, drawn by a second instanced draw over the grid.
  Each instance carries a glyph, a mask or two (instances are not stored in
  cells, so they are not held to the record's one mask per layer), a mask
  code, a colour from a swatch table's range, and a position in cells or in
  pixels. Its cost follows the area the overlays cover, not the window's, so
  hundreds are cheap. It is drawn in list order, which keeps test captures
  deterministic, and moving or animating an instance marks for redraw the
  rows under its old and new positions (see Partial Redraw). Pixel positions
  free overlays from the grid: a smoothly moving cursor, a mouse pointer, a
  dragged item.

**The steward's choice.** The steward has chosen the overlay list, on the
principle of separation of concerns: the grid is a uniform and stable model
of text, the overlay list a model of ephemeral, sparse, and moving things,
and the two can be addressed and scaled independently. The choice fits the
deeper claim below, a format uniform within a surface and separate across
surfaces, with the overlay list as a surface of its own. It works with
today's renderer, as one more instanced draw, as well as with the dense
design. Its consequences:

- **The block cursor needs the cell beneath it.** Negating layer 0's coverage
  depends on that cell, which a pass drawn afterwards cannot read. Either the
  CPU copies layer 0's glyph and settings into the cursor's instance and
  refreshes them when the cell's row changes, or the block style stays in the
  grid pass as cursor bits in the record's header
  (LEXTER-DRAFT-layer-mechanics-O15).
- **The header's cursor bits may be freed.** If every style is drawn as an
  overlay, the two cursor bits of the header in
  [LEXTER-DRAFT-cell-field-format](Survey.CellFieldFormat.md) join the spare
  bits that LEXTER-DRAFT-cell-field-format-O7 counts.
- **Overlays need colours.** An overlay belongs to a pane or to chrome and
  takes its swatches from that table's range
  (LEXTER-DRAFT-layer-mechanics-O13).
- **Animation still costs frames.** An animated overlay writes no cells and
  uploads no rows, but the CPU still runs a tick, sets a time uniform, issues
  the draws, and presents the frame on every animation frame. The larger
  cost, redrawing the window, is what partial redraw limits. Animating only
  the focused pane, at a modest rate, and fixing time during test captures
  (LEXTER-DRAFT-layer-mechanics-O8) keep the cost small.
- **Exotic cursors become cheap.** A cursor that scans sideways like a wave
  is the lower one-eighth block "▁" cut by the left blocks "▏" to "▉". With
  one mask that gives a wipe: intersection with a growing left block, then
  with the background of a growing left block, sweeps across the cell. A
  short segment that travels needs three shapes, the underline and both of
  its ends, which an overlay instance with two masks can carry.

## Partial Redraw

Uploading less and drawing less are separate savings. The dense design
uploads only dirty rows, but Lexter redraws the whole window on every frame
it renders, and must: after a buffer swap the contents of the window's back
buffer are undefined. Drawing only what changed needs a target that keeps its
contents. The offscreen target of [LEXTER-0008](Log.OffscreenFBO.md) does,
but it is opt-in: LEXTER-D39 made it so because it "costs an extra
full-screen blit per frame". Partial redraw would keep it on, overturning
that decision, draw into it, and then present it. The blit is then the cost
that remains on every presented frame: cheap, but it covers the whole window.

A second route needs no offscreen target. The extensions `EGL_EXT_buffer_age`
and `GLX_EXT_buffer_age` report how many frames old the back buffer's
contents are, so a renderer can redraw only what has changed since then, and
`EGL_KHR_swap_buffers_with_damage` tells the system's compositor which
rectangles changed. They are extensions rather than core OpenGL, their
availability depends on the platform, and GLFW reaches them only through its
native-access functions.

With such a target, the dense design makes partial redraw simple:

- **Rows by instance range.** A cell's position comes from its instance
  number, so rows *r* to *r+k* of a grid are one instanced draw of
  `cols × (k+1)` instances. The draw needs two adjustments, because OpenGL
  3.3 has no base instance: `gl_InstanceID` restarts at 0, so a uniform gives
  the first cell's index for computing positions; and per-instance
  attributes are fetched from the start of the bound buffer, so the record's
  attribute pointers move to the first row's byte offset, as the renderer
  already moves them between layers. Reading records from a texture buffer by
  computed index is the alternative to moving pointers. Nothing outside those
  rows is processed, so no scissor rectangle is needed. Today's
  renderer stores positions and packs instances compactly, skipping
  continuation cells and separating layered ones, so its instances do not map
  onto rows.
- **What is redrawn** is each grid's dirty rows together with the rows under
  any overlay instance that appeared, moved, animated, or disappeared.
- **A row is enough.** A row costs about `cols` times as much as a cell to
  redraw, and both are small; a rectangle per cell is not worth its
  bookkeeping.
- **Per pane.** With a grid per pane, each pane redraws its own dirty rows.
- **Exceptions.** In the transparent overlay the scene beneath changes on
  every frame, so the whole window is composited each time. Replacing a
  grid, switching workspace, or resizing redraws everything, just as the
  rules under The Dense Cell Array upload everything in those cases. A
  workspace switch that schedules no repaint, as today's does
  (LEXTER-DRAFT-data-structures-1e-critique-O14), would leave the old
  workspace on screen.

The saving is in GPU work and power: an idle terminal whose cursor animates
redraws one row rather than the window, though it still presents the window
once per frame.

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

The rule has a precondition that the record cannot meet: each table a record
points into, swatches above all, needs a settled owner, and each record of
"what changed" needs an identity. Both critiques put swatch ownership first,
and the dense design leans on it harder than today's format does, so it
comes before the dense design rather than after it.

## A Development Sequence

The steward's intended order of work follows. The development plan will set
it out and decide it.

1. **The fixes needed under any design**, the first group of
   LEXTER-DRAFT-layer-mechanics-O11: the VT handler's part of
   LEXTER-DRAFT-data-structures-1e-critique-O1;
   LEXTER-DRAFT-data-structures-1e-critique-O3, -O7, -O11, -O13 to -O17, and
   -O20; and the inverted thumb of
   LEXTER-DRAFT-data-structures-1e-critique-O12.
2. **Per-screen swatch ranges**, which resolve
   LEXTER-DRAFT-data-structures-1e-critique-O2, -O4, and -O5 and give -O6 a
   capacity per table (see Swatch Ownership).
3. **The dense cell model.** It comes after the ranges: copying rows and
   uploading dirty rows both need swatch indices that mean the same wherever
   they go, and records of uploads that name their source.
4. **The overlay list**, with cursors as its first use (see Cursors and the
   Overlay List). It works with today's renderer and so could come earlier;
   until it does, the stopgap of exchanged slots removes the cursor's swatch
   writes in the first edition.
5. **Partial redraw**, optional: rows drawn by instance range into the
   persistent offscreen target, or into a back buffer whose age is known (see
   Partial Redraw). It depends on the dense model, whose instances map onto
   rows.
6. **Eviction within a range**, separately, and only if
   LEXTER-DRAFT-data-structures-1e-critique-O6 is fixed by evicting unused
   swatches rather than by a large range and a fallback.

Design questions remain within it: how ranges are sized and released, and
whether the primary and alternate screens share a table
(LEXTER-DRAFT-layer-mechanics-O12); where the swatches of writers without a
screen live (LEXTER-DRAFT-layer-mechanics-O13); a grid per pane or one
composed grid (LEXTER-DRAFT-layer-mechanics-O14); and how the block cursor
learns the cell beneath it (LEXTER-DRAFT-layer-mechanics-O15).

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
  does not stop panes overwriting each other's swatches
  (LEXTER-DRAFT-data-structures-1e-critique-O4) or make the change records
  trustworthy (LEXTER-DRAFT-data-structures-1e-critique-O2,
  LEXTER-DRAFT-data-structures-1e-critique-O5), and row copying and
  dirty-row uploads depend on both.
- **The present layout is sound.** The GPU instance layout is the part of
  the cell format the data-structures critique found correct; replacing it is
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
- **Ranges need an allocator.** Per-screen swatch ranges add range
  allocation and release, and a policy for a full table.
- **The overlay list is a second format.** It has its own instance layout,
  its own pass, and its own record of the rows it covers.
- **Partial redraw needs a persistent target or buffer age.** The offscreen
  target is opt-in today, for the cost of a full-window blit per frame
  (LEXTER-D39), and the buffer-age extensions depend on the platform. Either
  way partial redraw saves nothing in the transparent overlay, where the whole
  window is composited on every frame.

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
- [LEXTER-DRAFT-cell-field-format](Survey.CellFieldFormat.md) proposes the
  dense record's layout and the swatch store whose ranges Swatch Ownership
  describes; its header's cursor bits are among those the overlay list would
  free.
- [LEXTER-0004](Log.PalettePaging.md) introduced the four
  palette slots; a palette-slot uniform per pane, or a per-cell slot, would
  let every pane use its own.
- [LEXTER-0008](Log.OffscreenFBO.md) provides the offscreen
  target that a transparent overlay and the test rig both draw into, and that
  partial redraw would need to keep.
- [LEXTER-0007](Log.EnhancedDualWidth.md) defines wide
  glyphs, which the dense record would store as halves.
- [LEXTER-0010](Log.ScreenshotTestRig.md) checks
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
- **Hardware sprites**, on the Commodore 64's VIC-II (eight on screen) and
  the NES's PPU (64, at most eight on a scanline), are drawn over a
  background of tiles by separate hardware, as the overlay list is drawn over
  the grid.
- **Cursor planes** in display controllers, which Linux's DRM exposes as
  planes of the cursor type, keep the pointer out of the framebuffer
  altogether: the separation of concerns the overlay list adopts.
- **Sub-palettes chosen by region**: the NES's attribute table gives each
  two-by-two block of background tiles one of four four-colour palettes, and
  each Mega Drive tile selects one of four 16-colour palette lines. Each is a
  small base into a shared colour store, chosen per region, as
  `u_swatch_base` would be chosen per pane.
- **Damage tracking and buffer age**: `EGL_EXT_buffer_age`,
  `GLX_EXT_buffer_age`, and `EGL_KHR_swap_buffers_with_damage`, cited above,
  let a renderer redraw and present only what changed. Alacritty tracks
  damage, and its issue tracker proposes going further with buffer age to
  render only the damaged regions.

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
cell, or a generated glyph. A third possibility costs nothing in size: keep
three masks but give each a target layer, so that two can cut the same
layer. The mask-target update of
[LEXTER-DRAFT-cell-field-format](Survey.CellFieldFormat.md) records it, with
two encodings, as a possibility rather than a decision.

### LEXTER-DRAFT-layer-mechanics-O4 — Should the model store the grid's record?

Sharing the format makes the flush a copy and scrollback compact, and makes
the model three times larger. The model's attributes would need a place.

### LEXTER-DRAFT-layer-mechanics-O5 — Who owns the swatch namespace?

That panes must stop overwriting each other's swatches is settled by both
critiques (LEXTER-DRAFT-data-structures-1e-critique-O4); the question is the
owner. A swatch table owned by the compositor and shared by every writer; a
table per screen with its own range of one store, drawn from a grid per pane
or from one composed grid (LEXTER-DRAFT-layer-mechanics-O14); or
content-addressed slots, the review's alternative. The steward prefers
per-screen ranges, for what a window-wide table gives up (see Swatch
Ownership). The choice also decides how capacity is
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
than all of them with the focused pane's. With a grid per pane
(LEXTER-DRAFT-layer-mechanics-O14), a palette-slot uniform for each pane's
draw does the same, and the bits are needed only if palettes must vary
within a pane.

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
or to leave it for the second edition. The steward's intended order of work
is under A Development Sequence.

### LEXTER-DRAFT-layer-mechanics-O12 — How are swatch ranges sized and released?

Ranges can be fixed, for example 2048 entries each, which fits 32 tables in
65,536, or allocated as tables grow, with relocation. Relocating a range
changes only a base uniform with a grid per pane, but means re-copying cells
into a composed grid. Open with it: whether the primary and alternate screens
share one table, when a range is released, and whether a full table evicts
unused swatches or falls back to the nearest existing one.

### LEXTER-DRAFT-layer-mechanics-O13 — Where do the swatches of writers without a screen live?

Chrome drawn by decorators, the overlay list, and the 3270 pane write colours
without a VT screen's table. They could share a chrome table with a range of
its own, or intern into the table of the pane they belong to.

### LEXTER-DRAFT-layer-mechanics-O14 — A grid per pane, or one composed grid?

A grid per pane keeps swatch indices local, lets a pane's dirty rows be
uploaded straight from its own array, and gives each pane its palette slot by
a uniform, at the cost of a draw call per pane and a separate home for chrome.
One composed grid keeps a single draw call, but its copy must add each
table's base to every swatch index, and palettes must travel in each cell's
palette-slot bits.

### LEXTER-DRAFT-layer-mechanics-O15 — How does the block cursor learn the cell beneath it?

An overlay drawn after the grid cannot read the cell it negates. The CPU can
copy layer 0's glyph and settings into the cursor's instance and refresh them
when that row changes, or the block style can stay in the grid pass as cursor
bits in the record's header while the other styles are drawn as overlays.
