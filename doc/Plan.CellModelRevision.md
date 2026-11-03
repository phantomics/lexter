---
id:            LEXTER-DRAFT-cell-model-revision
title:         "Cell Model Revision: Development Plan"
genre:         Plan
scope:         project
project:       Lexter
language:      en
status:        Draft
provenance:
  assistant:   opencode
  session:     "Cell model revision plan (2026-11-02)"
relates-to:
  - LEXTER-DRAFT-layer-mechanics
  - LEXTER-DRAFT-cell-field-format
  - LEXTER-DRAFT-data-structures-1e
  - LEXTER-DRAFT-data-structures-1e-critique
  - LEXTER-0003
  - LEXTER-0007
  - LEXTER-0008
  - LEXTER-0010
decisions:
  - LEXTER-DRAFT-cell-model-revision-D1
  - LEXTER-DRAFT-cell-model-revision-D2
  - LEXTER-DRAFT-cell-model-revision-D3
  - LEXTER-DRAFT-cell-model-revision-D4
  - LEXTER-DRAFT-cell-model-revision-D5
  - LEXTER-DRAFT-cell-model-revision-D6
  - LEXTER-DRAFT-cell-model-revision-D7
  - LEXTER-DRAFT-cell-model-revision-D8
  - LEXTER-DRAFT-cell-model-revision-D9
  - LEXTER-DRAFT-cell-model-revision-D10
  - LEXTER-DRAFT-cell-model-revision-D11
open-questions:
  - LEXTER-DRAFT-cell-model-revision-O1
  - LEXTER-DRAFT-cell-model-revision-O2
  - LEXTER-DRAFT-cell-model-revision-O3
  - LEXTER-DRAFT-cell-model-revision-O4
  - LEXTER-DRAFT-cell-model-revision-O5
  - LEXTER-DRAFT-cell-model-revision-O6
  - LEXTER-DRAFT-cell-model-revision-O7
  - LEXTER-DRAFT-cell-model-revision-O8
  - LEXTER-DRAFT-cell-model-revision-O9
  - LEXTER-DRAFT-cell-model-revision-O10
cites:
  - title:    "Session transcript ses_febe-LexterCritique"
    locator:  "session-ses_febe-LexterCritique.md, the closing review"
    external: true
  - title:    "EGL_EXT_buffer_age and GLX_EXT_buffer_age"
    locator:  "Khronos EGL and OpenGL extension registries"
    external: true
---

# Cell Model Revision: Development Plan

This plan revises how Lexter stores, synchronises, and draws the cells of a
terminal. It first repairs the present data model, specified in
[LEXTER-DRAFT-data-structures-1e](Spec.DataStructures1e.md), so that it meets
its own contract; it then gives each screen's swatch table a range of one GPU
store, replaces the present cells with the dense 32-byte record explored in
[LEXTER-DRAFT-layer-mechanics](Survey.LayerMechanics.md) and laid out in
[LEXTER-DRAFT-cell-field-format](Survey.CellFieldFormat.md), using that
survey's alternative encoding of mask targets, and draws cursors and other
moving glyphs from an overlay list. It answers the cell-model findings of
[LEXTER-DRAFT-data-structures-1e-critique](Eval.Critique.DataStructures1e.md)
and of the earlier review cited above, and follows the development sequence
of the layer-mechanics survey. The record's tail types and other details of
the layout are to be refined after this plan is accepted.

## Problem

The critique of the present data model found faults of two kinds in the
structures that hold cells.

- **Invariants kept by one writer and broken by the others.** Wide characters
  never reach the GPU from a screen
  (LEXTER-DRAFT-data-structures-1e-critique-O1), and the operations that move
  or clear cells leave wide flags behind
  (LEXTER-DRAFT-data-structures-1e-critique-O8). Layered cells drift apart
  between the model and the grid, and vanish under the cursor
  (LEXTER-DRAFT-data-structures-1e-critique-O9). Glyph 0 and codepoint 32 are
  each used for two things (LEXTER-DRAFT-data-structures-1e-critique-O10).
  Each cell rule is honoured in one function and broken in several others.
- **Copies of the same data with no owner.** Swatches live in each screen's
  table, in the display grid, and on the GPU, kept in step by counters that
  carry no identity. The GPU's table can stay stale for good
  (LEXTER-DRAFT-data-structures-1e-critique-O2), panes overwrite each other's
  colours (LEXTER-DRAFT-data-structures-1e-critique-O4), replays depend on the
  order of fixtures (LEXTER-DRAFT-data-structures-1e-critique-O5), and the
  table can outgrow the grid and the GPU
  (LEXTER-DRAFT-data-structures-1e-critique-O6).

Lesser faults sit beside them: constants defined twice
(LEXTER-DRAFT-data-structures-1e-critique-O18), dirty bits maintained and
never read (LEXTER-DRAFT-data-structures-1e-critique-O22), and descriptions
that no longer match the code
(LEXTER-DRAFT-data-structures-1e-critique-O21).

Beyond the faults, the present format has limits that the steward's plans
outrun. A cell is either one glyph or a sparse stack of up to three layers in
a hash table keyed by conses; every frame packs every cell in Lisp and
uploads it whole; a glyph cannot be cut by another, so a scroll bar's thumb
can be placed only to the nearest cell; and the cursor is a special case
written into the model during the flush. The layer-mechanics survey argues
for a dense record in which every cell has room for three display glyphs and
three mask glyphs, and the cell-field-format survey proposes its layout.

## Goals

- Repair the present data model, in place, so that it meets its
  specification for every cell-model finding, and so that double-width text
  renders correctly now.
- Give every swatch table one owner and one range of a GPU store, so that
  panes cannot overwrite each other's colours and every upload record names
  its source.
- Replace the present cells with the dense 32-byte record, in which the
  record, not each function, keeps a cell's invariants.
- Draw cursors and other sparse, moving glyphs from an overlay list kept
  apart from the grid.
- Keep every repaired fault repaired, with a headless regression test for
  each.
- Leave a second edition of the data-model specification, superseding the
  first.

## Thesis

A cell's rules belong to its representation, and a table's contents belong
to one owner. The first edition kept cell rules in functions and swatch
tables in several copies; this plan moves the rules into a record that every
operation copies whole, and the tables into ranges that only their owners
write.

## Settled Decisions

### LEXTER-DRAFT-cell-model-revision-D1 — The plan covers the cell model, and the other fixes have their own plan

**Status:** Proposed

**Context:** The layer-mechanics survey's development sequence begins with
fixes needed under any design. Some concern the cell model; others concern
the VT handler's state, the protocols, and the terminal paths: host input
(LEXTER-DRAFT-data-structures-1e-critique-O3), TN3270E negotiation (-O7), the
cached screen (-O11), the scroll-bar thumb's inversion (-O12), the TN3270
screen's size (-O13), the workspace switch (-O14), autowrap (-O15), the
telnet client (-O16), the headless PTY paths (-O17), package exports (-O19),
and backend sizing (-O20).

**Decision:** This plan covers the cell model: the cells, their swatches,
how they are drawn, and the VT handler's writing of double-width characters,
which is part of how cells are made. The other fixes go in a separate plan.
Where one of them is a prerequisite here, this plan names it in its Roadmap.

**Alternatives:**
- One plan for the whole sequence. Rejected: the other fixes are independent
  of the cell format and can proceed in parallel, and a plan named for the
  cell model would hide them.

### LEXTER-DRAFT-cell-model-revision-D2 — The first edition is repaired in full before the second edition begins

**Status:** Proposed

**Context:** The layer-mechanics survey's
LEXTER-DRAFT-layer-mechanics-O11 sorts the cell-model findings into those
needed whichever course is taken and those the dense record would make
unnecessary, and asks whether to repair the second group in place or leave
it for the second edition. Double-width text is wrong today, and the
second edition is a large change that will take time.

**Decision:** Repair the first edition fully, in place, for the critique's
findings LEXTER-DRAFT-data-structures-1e-critique-O1, -O8, -O9, -O10, -O18,
and -O22: wide pairs in every operation, layer synchronisation, the glyph
sentinels, constants, and dirty bits, together with a cursor that writes no
swatches. The second edition starts from a first edition that meets its
specification.

**Alternatives:**
- Repair only what cannot wait, the VT handler's wide writes and enough of
  the flush to keep pairs. Rejected by the steward: it leaves known faults in
  a model that will be used for some time, and a model that meets its
  specification is the better baseline for testing the second edition.
- No repairs. Rejected: every CJK character stays wrong until the second
  edition lands.

The cost is work that the second edition replaces. The regression tests
written for the repairs carry over and are the lasting product of this
phase.

### LEXTER-DRAFT-cell-model-revision-D3 — Wide pairs are kept by per-cell helpers, with a row check at the flush

**Status:** Proposed

**Context:** The screen marks the left half of a double-width character and
implies the right half by glyph 0. `write-char-at` keeps that pair, but the
VT handler never makes one, the flush and the cursor break it, and the row
and range operations ignore it
(`src/model.lisp:flush-to-display@2d4d743`,
`src/model.lisp:%copy-row@2d4d743`,
`src/vt-handler.lisp:%print-codepoint@2d4d743`).

**Decision:** Every model operation that moves or clears cells goes through
per-cell helpers that copy or clear a cell's glyph, swatch, attributes, wide
flag, and layered entry together, and every range operation repairs a pair
it cuts at its edges. The VT handler asks the atlas whether a glyph is wide,
writes a pair, and advances by two, wrapping first when a wide character
would start in the last column. The flush writes each pair once, skipping
the right half, and clips a pair at a pane's or the grid's right edge. The
cursor keeps the grid's wide flag. As a safety net, the flush checks each
dirty row before copying it and blanks any left half without its right half.

**Alternatives:**
- Helpers alone. Rejected: every future operation must remember them, and
  the critique showed that one writer keeping a rule does not stop others
  breaking it.
- The row check alone. Rejected: it repairs states after the fact and cannot
  give the exact behaviour of a terminal, which blanks the other half of a
  pair when one half is overwritten.

### LEXTER-DRAFT-cell-model-revision-D4 — Each swatch table owns a range of one GPU swatch store

**Status:** Proposed

**Context:** Each screen numbers its swatches from 0, and every pane copies
its table into the grid's single table, so panes overwrite each other's
colours (LEXTER-DRAFT-data-structures-1e-critique-O4). The grid's counter is
both incremented and assigned, so the GPU's table can stay stale
(LEXTER-DRAFT-data-structures-1e-critique-O2), and upload records carry no
identity (LEXTER-DRAFT-data-structures-1e-critique-O5). The layer-mechanics
survey weighs a window-wide table against per-screen ranges under Swatch
Ownership, and the review recommended a single authoritative table.

**Decision:** Keep one swatch table per screen, and give each table a range
of one GPU store: a texture buffer of 65,536 swatches, as the
cell-field-format survey proposes. Tables only grow, so a table's count is
its version, and the renderer records for each range which table it
uploaded and how many entries. Every writer interns into a table, and
nothing calls `set-swatch` on a grid: `setup-default-swatches`, the 3270
pane, the demo, and decorators get tables of their own. A table that changes
other than by growing bumps a version that forces its range to be uploaded
again.

**Alternatives:**
- One table per window, owned by the compositor. Rejected: it loses each
  screen's own numbering, shares one capacity among all panes, splits the
  colour model that LEXTER-D12 placed on the screen, and makes freeing a
  swatch a scan of every screen.
- Content-addressed slots, the review's other suggestion, which it did not
  describe further. Not chosen: an index derived from a swatch's contents
  still needs a store to resolve it, and does not say which table an upload
  came from.

### LEXTER-DRAFT-cell-model-revision-D5 — Ranges arrive in the first edition, with indices translated in the flush

**Status:** Proposed

**Context:** Whether the second edition draws a grid per pane or one
composed grid is open (LEXTER-DRAFT-cell-model-revision-O1). The first
edition has one composed display grid and one draw call.

**Decision:** Build the swatch ranges on the first edition. The flush adds the
screen table's base to each swatch index as it writes the composed grid, and
the shader reads swatches from the texture buffer. The second edition then
keeps translation or draws per pane, as LEXTER-DRAFT-cell-model-revision-O1
decides, without changing the store.

**Alternatives:**
- Wait for the dense model and build the ranges into it. Rejected: the
  swatch faults are high in severity and do not depend on the cell format.

### LEXTER-DRAFT-cell-model-revision-D6 — The first edition's cursor exchanges slots instead of interning a reversed swatch

**Status:** Proposed

**Context:** The flush draws the cursor by interning a reversed swatch into
the screen's table and writing it into the grid, which triggers
LEXTER-DRAFT-data-structures-1e-critique-O2, adds to -O6, and, through
rewriting the cell, breaks wide pairs (-O1) and drops layers (-O9).

**Decision:** Until the overlay list exists, the flush draws the cursor's
cell as a layered cell whose layer 0 exchanges its ink and background slots
(`src/grid.lisp:cell-layer@2d4d743`), keeping the grid's wide flag. Reverse
video then needs no swatch, and the next flush of the row removes the layer
when the cursor moves. A cursor on a layered cell exchanges the slots of its
layer 0.

**Alternatives:**
- Keep the reversed swatch until the overlay list. Rejected: it is the
  trigger of LEXTER-DRAFT-data-structures-1e-critique-O2 and the cause of the
  cursor's part of -O1 and -O9, which LEXTER-DRAFT-cell-model-revision-D2
  repairs.

### LEXTER-DRAFT-cell-model-revision-D7 — The dense record uses the mask-target encoding with a selector for each mask

**Status:** Proposed

**Context:** The cell-field-format survey lays out a 32-byte record: a
header, a word of settings, three display glyphs, and a three-word tail. Its
first layout gives mask *k* to layer *k*, so a layer takes one mask, and a
thumb inside one cell cannot be drawn. Its update on mask targets offers a
four-bit control field with four operations and no selector, which loses
union and exclusion with a mask's uninked pixels, and an alternative that
keeps them (LEXTER-DRAFT-cell-field-format-O11).

**Decision:** Use the alternative. Each mask has a five-bit control field:

Table: A mask's control field.

| Bits | Width | Field | Values |
|---|---|---|---|
| 0–1 | 2 | Operation | 0 union, 1 intersection, 2 exclusion, 3 the mask's pixels less the running coverage |
| 2 | 1 | Mask selector | 0 = the mask glyph's inked pixels; 1 = its uninked pixels |
| 3–4 | 2 | Target | 0, 1, 2 = the layer it cuts; 3 = the mask is unused |

Word 1 holds the three layers' settings, five bits each under the fill rule
(a fill slot equal to the ink slot means no fill), then the three masks'
control fields, leaving two bits spare. Masks apply to their targets in
index order, after the display selector, so two or three masks may cut one
layer. When any target is 0, 1, or 2, the tail holds the three mask glyphs.
When all three targets are 3, mask 0's operation and selector bits give the
tail type, and those of masks 1 and 2 give six bits for the payload. One
tail-type value means that the tail holds nothing. Operation 3 removes the
running coverage from the mask's pixels, a function no other value
expresses. The tail types and the use of the six bits are refined after this
plan (LEXTER-DRAFT-cell-model-revision-O7).

**Alternatives:**
- Four operations and no selector. Rejected: the two operations it drops can
  be recovered only by spending a layer, and layers are what the record is
  shortest of.
- One mask per layer, the survey's first layout. Rejected: it cannot draw a
  band inside one cell.
- A single four-bit code for operation and target. Rejected: decoding it
  divides by five, and a kernel could not change a target or an operation
  alone.

### LEXTER-DRAFT-cell-model-revision-D8 — The second edition stores a double-width glyph as two halves

**Status:** Proposed

**Context:** Today a double-width glyph is one instance two cells wide, drawn
from its left cell, with a continuation cell that must never be written on
its own. A broken pair corrupts flags.

**Decision:** Store the glyph in both cells, with the header's wide bit in
both and the right-half bit in the second, and let each cell draw its own
half. Every quad is one cell, continuation flags go away, and a broken pair
shows half a glyph instead of corrupting state. Writers still write and
erase both halves together, as a terminal must.

**Alternatives:**
- Keep one double-width instance. Rejected: it is how wide characters are
  lost today, and it makes the record's size depend on its neighbour.

### LEXTER-DRAFT-cell-model-revision-D9 — One descriptor defines the record for Lisp and the shader

**Status:** Proposed

**Context:** The present instance format is written out three times, in the
packer, the attribute setup, and the shader, and its stride is defined twice
(LEXTER-DRAFT-data-structures-1e-critique-O18).

**Decision:** A single descriptor, a macro such as `define-cell-layout`,
generates the record's Lisp accessors, the GLSL that decodes it, and the
vertex attribute setup from one definition.

**Alternatives:**
- Write the three by hand and test that they agree. Rejected: tests find
  disagreement after the fact; one definition prevents it.

### LEXTER-DRAFT-cell-model-revision-D10 — Cursors and moving glyphs are drawn from an overlay list

**Status:** Proposed

**Context:** The layer-mechanics survey weighs four ways to draw a cursor:
the first edition's exchanged slots, a mask stamped into the grid's record,
a uniform that adds a virtual layer to one cell, and an overlay list drawn
over the grid.

**Decision:** The steward chose the overlay list, on the principle of
separation of concerns: the grid is a uniform and stable model of text, the
overlay list a model of ephemeral, sparse, and moving things, and the two
are addressed and scaled independently. Each overlay instance carries a
glyph, up to two masks with the record's mask code, a colour from a swatch
table's range, and a position in cells or pixels, and the list is drawn by
one instanced draw after the grid, in list order.

**Alternatives:**
- A stamped mask. Rejected: it competes with text for layers and masks, and
  animating it rewrites a cell and uploads its row on every frame.
- A uniform cursor. Rejected: every pixel compares its cell with every
  entry, so it does not scale past a few cursors.
- Cursor bits in the record's header. Rejected for the styles that can be
  overlays; whether the block style keeps them is
  LEXTER-DRAFT-cell-model-revision-O5.

### LEXTER-DRAFT-cell-model-revision-D11 — Every repaired finding gets a headless regression test

**Status:** Proposed

**Context:** The critique reproduced most of its findings headlessly in SBCL,
with no display, and the screenshot test rig
([LEXTER-0010](Log.ScreenshotTestRig.md)) cannot detect
LEXTER-DRAFT-data-structures-1e-critique-O2 or -O5, which depend on what the
renderer recorded before a capture.

**Decision:** Before each finding is repaired, a test that reproduces it is
added to a new test system, using FiveAM and cl-hamcrest as the Origin tests
do. Faults on the GPU side are tested against a stand-in for the renderer's
upload rule, as the critique did, and by a check that compares the swatch
data the renderer last uploaded with its source. The tests run against both
editions.

**Alternatives:**
- Screenshot fixtures alone. Rejected: they need a display, and cannot see
  stale state that a capture happens not to show.

## The First Edition Repaired

Phase 1 repairs the present structures in place
(LEXTER-DRAFT-cell-model-revision-D2).

Table: First-edition repairs by finding.

| Finding | Repair |
|---|---|
| LEXTER-DRAFT-data-structures-1e-critique-O1 | The VT handler writes pairs and advances by two; the flush writes each pair once; the cursor keeps the wide flag (LEXTER-DRAFT-cell-model-revision-D3, -D6) |
| LEXTER-DRAFT-data-structures-1e-critique-O8 | Per-cell helpers in every row and range operation, edge repair, `resize-grid` copying both flag vectors, and the row check (LEXTER-DRAFT-cell-model-revision-D3) |
| LEXTER-DRAFT-data-structures-1e-critique-O9 | The flush writes a layered cell's whole record, empty layers included; `write-char-at` on a layered cell honours its swatch and attributes; the cursor no longer rewrites the cell (LEXTER-DRAFT-cell-model-revision-D6) |
| LEXTER-DRAFT-data-structures-1e-critique-O10 | Atlas position 0 is reserved for an empty glyph at build time, and every writer takes its blank from the atlas instead of writing codepoint 32 |
| LEXTER-DRAFT-data-structures-1e-critique-O18 | One home for the cell constants that the model, grid, and renderer share, one `+layered-stride+`, one default palette, one `setup-default-swatches`, and one name for each layer slot |
| LEXTER-DRAFT-data-structures-1e-critique-O22 | The grid's description is made true: `build-render-data` loses the unused `force-full` and its claim of incremental rebuilds, and the dirty bits stay for the second edition to upload by |
| Review: the cursor writes into the model during the flush | The cursor exchanges slots (LEXTER-DRAFT-cell-model-revision-D6) |

The repair of LEXTER-DRAFT-data-structures-1e-critique-O22 makes the first
edition honest rather than incremental. Rebuilding only dirty rows would need
instances laid out by row, which the first edition's compact packing does not
have and the second edition provides.

## Swatch Ranges

Phase 2 builds the ranges of LEXTER-DRAFT-cell-model-revision-D4 on the first
edition, as LEXTER-DRAFT-cell-model-revision-D5 describes.

- **The store.** The swatch texture becomes a texture buffer sampled as a
  `samplerBuffer`, core since OpenGL 3.1 and guaranteed at least 65,536
  texels in OpenGL 3.3.
- **Ranges.** An allocator hands each table a range and takes it back when
  its screen goes away, because its pane is destroyed or `terminal-reset`
  replaces it. Sizing, the alternate screen, and what a full table does are
  LEXTER-DRAFT-cell-model-revision-O3.
- **Writers.** The 3270 pane's global cache becomes a table; chrome,
  decorators, and the demo intern into tables
  (LEXTER-DRAFT-cell-model-revision-O4).
- **Uploads.** The renderer records, for each range, the table it uploaded
  and the count, and uploads the new tail of a table that has grown, or the
  whole range for a table that is new or has bumped its version.
- **The flush.** Indices are translated to the store's numbering as cells are
  written into the composed grid.
- **The wide bit.** The first edition's instances carry the wide flag in bit
  15 of their swatch field (`src/grid.lisp:build-render-data@2d4d743`), so a
  translated index must stay below 32,768. Until Phase 3 gives the swatch
  index 16 bits and the wide flag a bit of its own, the allocator uses only
  the store's first 32,768 entries. Moving the flag into the instance's
  padding bytes would lift the limit sooner, at the cost of changing the
  first edition's shaders and attribute setup once more.

When the phase is done, LEXTER-DRAFT-data-structures-1e-critique-O2, -O4, and
-O5 are resolved, and -O6 is a limit per table with a policy for a full table.

## The Dense Cell Model

Phase 3 replaces the present cells with the record of
LEXTER-DRAFT-cell-model-revision-D7, laid out as the cell-field-format survey
proposes, with mask targets.

Table: The record, by word.

| Word | Contents |
|---|---|
| 0 | Header: swatch index, wide and right-half bits, layer count, line attributes, and the bits whose use is open (palette slot, cursor) |
| 1 | Layer settings under the fill rule, and the three masks' control fields (LEXTER-DRAFT-cell-model-revision-D7) |
| 2–4 | The display glyphs of layers 0–2 |
| 5–7 | Tail: the three mask glyphs when any mask has a target, or a payload named by the tail type |

- **The grid's array is its upload buffer.** Cells are stored row by row, so
  each dirty row is one contiguous range, uploaded by itself. The renderer
  records which grid it uploaded, by an identity or an epoch from one global
  counter, and uploads the whole grid when the grid is replaced, the workspace
  changes, or the size changes.
- **One draw per grid.** The shader computes a cell's position from its
  instance number, composites the three layers in order with their masks, and
  writes premultiplied colour, so there are no passes per layer.
- **Halves.** Double-width glyphs are stored as halves
  (LEXTER-DRAFT-cell-model-revision-D8). How a mask applies to a half is
  LEXTER-DRAFT-cell-model-revision-O6.
- **Text beside the record.** The characters each cell shows are kept in a
  side array, not in the record, for selection, copying, search, and screen
  readers. Its form is LEXTER-DRAFT-cell-model-revision-O8.
- **Scrollback as rows of records.** History keeps layers and costs a record
  per cell, not a list.
- **The model's storage and the pane's grid** are
  LEXTER-DRAFT-cell-model-revision-O2 and -O1, both settled before the phase
  begins.
- **Kernels follow correctness.** Typed Lisp loops over the record come first;
  generated kernels, and where the grid lives in memory, are
  LEXTER-DRAFT-cell-model-revision-O10.

The first edition's simple and layered paths, its hash tables of layered
cells, the instance packer, and the per-layer draws are removed.

## The Overlay List

Phase 4 adds the overlay list of LEXTER-DRAFT-cell-model-revision-D10, with
cursors as its first use.

- **A pass of its own.** One instanced draw after the grid, with its own
  instance layout and the same coverage function as the record.
- **Positions in cells or pixels**, so an overlay can move smoothly and is not
  bound to the grid.
- **Colours** from the swatch table of the pane or chrome it belongs to
  (LEXTER-DRAFT-cell-model-revision-O4).
- **The block cursor** needs the cell beneath it
  (LEXTER-DRAFT-cell-model-revision-O5).
- **Redraw.** Moving, adding, removing, or animating an instance marks the
  rows under its old and new positions for redraw.
- **Time.** Animation reads a time uniform that the test rig can fix, and
  animates only the focused pane by default.

LEXTER-DRAFT-cell-model-revision-D6's exchanged slots are removed when the
overlay cursor arrives.

## Partial Redraw and Eviction

Phase 5, optional, redraws only the dirty rows and the rows under changed
overlays: rows by instance range, with the record's attribute pointers moved
to the first row, since OpenGL 3.3 has no base instance. It needs either the
offscreen target kept on, which overturns LEXTER-D39 and leaves one
full-window blit per presented frame, or the buffer-age extensions cited
above (LEXTER-DRAFT-cell-model-revision-O9).

Phase 6, conditional, evicts unused swatches within a range, if
LEXTER-DRAFT-cell-model-revision-O3 chooses eviction over a large range and a
fallback: mark the indices that a screen's cells and scrollback still use,
free the rest, and bump the table's version.

## Tensions and Risks

- **Work the second edition discards.** Phase 1 repairs code that Phase 3
  replaces. LEXTER-DRAFT-cell-model-revision-D2 accepts that cost for correct
  text now and a sound baseline; the tests of
  LEXTER-DRAFT-cell-model-revision-D11 are what carries over.
- **Changed pixels.** Phase 3 changes how every cell is drawn, so every
  screenshot fixture's checksum changes and the fixtures are re-authored.
- **Alignment.** SBCL does not place grid-sized arrays on 32-byte boundaries;
  records laid from the start of an array split cache lines
  (LEXTER-DRAFT-cell-model-revision-O10).
- **Dependence on the other plan.** Dirty-row uploads would leave a stale
  workspace on screen until the workspace switch schedules a repaint
  (LEXTER-DRAFT-data-structures-1e-critique-O14), which the separate plan
  fixes.
- **Spare bits.** The header has three and word 1 two; the palette-slot and
  cursor bits may be freed (LEXTER-DRAFT-cell-model-revision-O1, -O5), but
  underline styles, a hover bit, and a protected bit compete for them
  (LEXTER-DRAFT-cell-field-format-O7).
- **A larger model.** A screen of 80×24 records is 61 KB, three times today's
  size; small, but it grows with every pane and its scrollback.

## Open Questions

### LEXTER-DRAFT-cell-model-revision-O1 — A grid per pane, or one composed grid?

A grid per pane keeps swatch indices local, uploads a pane's dirty rows from
its own array, and gives each pane its palette slot by a uniform, freeing the
header's palette-slot bits, at the cost of a draw call per pane and a home
for chrome. One composed grid keeps one draw call, but its copy translates
every swatch index, and palettes travel in each cell's bits. It is
LEXTER-DRAFT-layer-mechanics-O14, and it is settled before Phase 3.

### LEXTER-DRAFT-cell-model-revision-O2 — Does the model store the record?

Storing the record makes the flush a copy, or no step at all with a grid per
pane, and makes scrollback compact; it triples the model's size, and the
model's attributes need a place. It is LEXTER-DRAFT-layer-mechanics-O4, and it
depends on LEXTER-DRAFT-cell-model-revision-O1.

### LEXTER-DRAFT-cell-model-revision-O3 — How are swatch ranges sized and released, and what does a full table do?

Fixed ranges, such as 2048 entries for each of 32 tables, or ranges allocated
and relocated as tables grow. Whether the primary and alternate screens share
one table. Whether a full table evicts unused swatches (Phase 6) or falls
back to the nearest existing one. It is LEXTER-DRAFT-layer-mechanics-O12.

### LEXTER-DRAFT-cell-model-revision-O4 — Where do the swatches of writers without a screen live?

Chrome, decorators, the overlay list, and the 3270 pane need tables: one
chrome table with a range of its own, or the table of the pane each belongs
to. It is LEXTER-DRAFT-layer-mechanics-O13.

### LEXTER-DRAFT-cell-model-revision-O5 — How does the block cursor learn the cell beneath it?

The CPU copies layer 0's glyph and settings into the cursor's overlay
instance and refreshes them when the row changes, or the block style keeps
cursor bits in the header and is drawn in the grid's pass. It is
LEXTER-DRAFT-layer-mechanics-O15.

### LEXTER-DRAFT-cell-model-revision-O6 — How does a mask apply to a wide display glyph?

A narrow mask applied to one half, or the matching half of a wide mask
glyph. It is LEXTER-DRAFT-cell-field-format-O12.

### LEXTER-DRAFT-cell-model-revision-O7 — Which tail types are there, and what do the six payload bits carry?

LEXTER-DRAFT-cell-model-revision-D7 fixes how the tail type is found, not its
values. Candidates from the cell-field-format survey are a reference to a
surface, inline colours, an effect, and tiles, with one value for no payload;
the six bits from masks 1 and 2 could carry a mode, as tile mode's mode field
would.

### LEXTER-DRAFT-cell-model-revision-O8 — What does the text array hold?

Codepoints, combining marks, and grapheme clusters need a form, such as a
fixed number of codepoints per cell with an overflow pool. It must stay
consistent with the record under every operation. It is
LEXTER-DRAFT-cell-field-format-O8.

### LEXTER-DRAFT-cell-model-revision-O9 — A persistent target or buffer age for partial redraw?

The offscreen target works everywhere but overturns LEXTER-D39 and costs a
full-window blit per frame; the buffer-age extensions need no extra target
but depend on the platform and are reached outside GLFW's portable API.

### LEXTER-DRAFT-cell-model-revision-O10 — Where does the grid live, and which route do kernels take?

The Lisp heap with records offset by 16 bytes, foreign memory, or mapped GPU
memory; and custom VOPs, sb-simd, or typed Lisp. It is
LEXTER-DRAFT-layer-mechanics-O7.

## Prior Art

Table: Prior systems and what this plan draws from each.

| System | What to draw from |
|---|---|
| VGA text mode | A dense array of fixed-size cells that the display reads directly |
| kitty | Separate records for what the GPU draws and what the CPU reads, such as each cell's text |
| notcurses | A fixed-size cell with an overflow pool for long grapheme clusters |
| X11 drawing functions, Win32 ROP2 codes | Logical combination of two sources, here encoded as operation, selector, and target |
| Porter and Duff's compositing operators | Masks as operations on coverage: in, out, and xor |
| NES attribute tables, Mega Drive palette lines | A small base into a shared colour store chosen per region, as each table's range is |
| Hardware sprites (C64 VIC-II, NES PPU), DRM cursor planes | Moving objects drawn apart from the background, as the overlay list is |
| Buffer age and damage tracking (EGL, GLX, Alacritty) | Redrawing and presenting only what changed |

## Roadmap

1. **Phase 0: the regression suite.** A headless test system with a test for
   each finding in scope, reproducing it before it is repaired
   (LEXTER-DRAFT-cell-model-revision-D11).
2. **Phase 1: the first edition repaired.** The repairs of The First Edition
   Repaired, finding by finding, each turning its test green. Double-width
   text renders through the VT path. A Log records the phase.
3. **Phase 2: swatch ranges.** The store, the allocator, interning by every
   writer, upload records that name their tables, and indices translated in
   the flush (LEXTER-DRAFT-cell-model-revision-D4, -D5). Fixtures replay the
   same in any order. LEXTER-DRAFT-cell-model-revision-O3 and -O4 are settled
   first. A Log records the phase.
4. **Gate.** LEXTER-DRAFT-cell-model-revision-O1, -O2, -O6, and -O8 are
   settled, and the separate plan's repair of the workspace switch has
   landed.
5. **Phase 3: the dense cell model.** The descriptor
   (LEXTER-DRAFT-cell-model-revision-D9), the record
   (LEXTER-DRAFT-cell-model-revision-D7), halves
   (LEXTER-DRAFT-cell-model-revision-D8), the text array, scrollback of
   records, one draw per grid, and dirty-row uploads. The suite passes on the
   new model, and fixtures are re-authored. A Log records the phase.
6. **Phase 4: the overlay list.** The pass, cursors as overlays, and the
   removal of LEXTER-DRAFT-cell-model-revision-D6's exchanged slots, after
   LEXTER-DRAFT-cell-model-revision-O5 is settled. A Log records the phase.
7. **Phase 5, optional: partial redraw**, after
   LEXTER-DRAFT-cell-model-revision-O9 is settled.
8. **Phase 6, conditional: eviction within a range**, if
   LEXTER-DRAFT-cell-model-revision-O3 chooses it.
9. **The second edition specified.** A specification of the new data model,
   Spec.DataStructures2e, superseding
   [LEXTER-DRAFT-data-structures-1e](Spec.DataStructures1e.md), and README.md
   brought up to date (LEXTER-DRAFT-data-structures-1e-critique-O21).