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
  - LEXTER-0016
  - LEXTER-0015
  - LEXTER-DRAFT-pane-profiles
  - LEXTER-0013
  - LEXTER-DRAFT-cell-field-format
  - LEXTER-DRAFT-data-structures-1e
  - LEXTER-0014
  - LEXTER-0003
  - LEXTER-0004
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
  - LEXTER-DRAFT-cell-model-revision-D12
  - LEXTER-DRAFT-cell-model-revision-D13
  - LEXTER-DRAFT-cell-model-revision-D14
  - LEXTER-DRAFT-cell-model-revision-D15
  - LEXTER-DRAFT-cell-model-revision-D16
  - LEXTER-DRAFT-cell-model-revision-D17
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
  - LEXTER-DRAFT-cell-model-revision-O11
  - LEXTER-DRAFT-cell-model-revision-O12
cites:
  - title:    "Session transcript ses_febe-LexterCritique"
    locator:  "session-ses_febe-LexterCritique.md, the closing review"
    external: true
  - title:    "Session transcript ses_1640-Lexter14"
    locator:  "session-ses_1640-Lexter14.md, lines 1719-1736 (a cell dump rejected because swatch indices depend on interning order)"
    external: true
  - title:    "Session transcript ses_2263-Lexter5"
    locator:  "session-ses_2263-Lexter5.md, line 2576 (the swatch table moved from usampler1D to normalised sampler1D because of cl-opengl limitations)"
    external: true
  - title:    "Session transcript ses_2263-Lexter9"
    locator:  "session-ses_2263-Lexter9.md, lines 1325-1437 (a font selector rendered on the CPU, bypassing the atlas and shaders)"
    external: true
  - title:    "Mesa llvmpipe"
    locator:  "https://docs.mesa3d.org/drivers/llvmpipe.html"
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
[LEXTER-0013](Survey.LayerMechanics.md) and specified by the cell-model
architecture, [LEXTER-0016](Arch.CellModel.md), draws cursors and other
moving glyphs from an overlay list, and adds a renderer on the CPU that draws
the same pixels as the GPU. It answers the cell-model findings of
[LEXTER-0014](Eval.Critique.DataStructures1e.md) and of the earlier review
cited above, and follows the development sequence of the layer-mechanics
survey.

The plan and the architecture divide the work. The architecture says what
the record is, bit by bit, and how a renderer draws it; this plan says in
what order Lexter gets there, and what the first edition must become on the
way. The architecture refines the layout this plan first adopted from
[LEXTER-DRAFT-cell-field-format](Survey.CellFieldFormat.md), and where the
two documents differ about the record, the architecture governs.

## Problem

The critique of the present data model found faults of two kinds in the
structures that hold cells.

- **Invariants kept by one writer and broken by the others.** Wide characters
  never reach the GPU from a screen
  (LEXTER-O19), and the operations that move
  or clear cells leave wide flags behind
  (LEXTER-O26). Layered cells drift apart
  between the model and the grid, and vanish under the cursor
  (LEXTER-O27). Glyph 0 and codepoint 32 are
  each used for two things (LEXTER-O28).
  Each cell rule is honoured in one function and broken in several others.
- **Copies of the same data with no owner.** Swatches live in each screen's
  table, in the display grid, and on the GPU, kept in step by counters that
  carry no identity. The GPU's table can stay stale for good
  (LEXTER-O20), panes overwrite each other's
  colours (LEXTER-O22), replays depend on the
  order of fixtures (LEXTER-O23), and the
  table can outgrow the grid and the GPU
  (LEXTER-O24).

Lesser faults sit beside them: constants defined twice
(LEXTER-O36), dirty bits maintained and
never read (LEXTER-O40), and descriptions
that no longer match the code
(LEXTER-O39).

Beyond the faults, the present format has limits that the steward's plans
outrun. A cell is either one glyph or a sparse stack of up to three layers in
a hash table keyed by conses; every frame packs every cell in Lisp and
uploads it whole; a glyph cannot be cut by another, so a scroll bar's thumb
can be placed only to the nearest cell; the cursor is a special case written
into the model during the flush; and, as the review found, the 3270 pane
keeps a screen of its own and writes the display grid directly, never
touching the model. The layer-mechanics survey argues for a dense record of
layers and masks, and the cell-model architecture specifies one: 32 bytes
holding a format word, a header word of colours, and up to six glyph words,
each a layer or a mask.

Drawing, too, has a single implementation, on the GPU. A replay needs a GL
context, a pixel checksum holds only on the GPU and driver that took it, and
a tool that draws outside Lexter's window, such as the font selector an
earlier session proposed, has no renderer it can use. On the way to the
screen, colours pass through floats, the palettes in a uniform buffer and the
swatches as normalised bytes, which leaves implementations room to round
differently.

## Thesis

A cell's rules belong to its representation, and a table's contents belong
to one owner. The first edition kept cell rules in functions and swatch
tables in several copies; this plan moves the rules into a record that every
operation copies whole, and the tables into ranges that only their owners
write.

## Goals

- Repair the present data model, in place, so that it meets its
  specification for every cell-model finding, and so that double-width text
  renders correctly now.
- Give every swatch table one owner and one range of a GPU store, so that
  panes cannot overwrite each other's colours and every upload record names
  its source, before any of the changes that depend on it.
- Replace the present cells with the dense 32-byte record, in which the
  record, not each function, keeps a cell's invariants.
- Draw cursors and other sparse, moving glyphs from an overlay list kept
  apart from the grid.
- Keep every repaired fault repaired, with a headless regression test for
  each.
- Check each test fixture's cells as well as its pixels, with a checksum of
  the normalised record array that needs no display.
- Draw the same pixels on the CPU as on the GPU, with a renderer that needs
  no GL, so that pixel checksums can be checked on any machine and tools
  outside Lexter's window can draw grids.
- Leave a second edition of the data-model specification, superseding the
  first.

## Settled Decisions

### LEXTER-DRAFT-cell-model-revision-D1 — The plan covers the cell model, and the other fixes have their own plan

**Status:** Proposed

**Context:** The layer-mechanics survey's development sequence begins with
fixes needed under any design. Some concern the cell model; others concern the
VT handler's state, the protocols, and the terminal paths: host input
(LEXTER-O21), TN3270E negotiation (LEXTER-O25), the cached screen
(LEXTER-O29), the scroll-bar thumb's inversion (LEXTER-O30), the TN3270
screen's size (LEXTER-O31), the workspace switch (LEXTER-O32), autowrap
(LEXTER-O33), the telnet client (LEXTER-O34), the headless PTY paths
(LEXTER-O35), package exports (LEXTER-O37), and backend sizing (LEXTER-O38).

**Decision:** This plan covers the cell model: the cells, their swatches,
how they are drawn, and the VT handler's writing of double-width characters,
which is part of how cells are made. The other fixes go in
[LEXTER-0015](Plan.TerminalFixes1e.md), except the
scroll-bar thumb and the scrollback viewport, which
[LEXTER-DRAFT-pane-profiles](Plan.PaneProfiles.md) already plans. Two of the
companion plan's fixes are prerequisites here and are named in the Roadmap:
the consolidation of the two terminal stacks
(LEXTER-D67) before Phase 1, and the workspace-switch
repaint (LEXTER-D71) before Phase 3. The review's
finding that the 3270 pane bypasses the model belongs to this plan
(LEXTER-DRAFT-cell-model-revision-O11).

**Alternatives:**
- One plan for the whole sequence. Rejected: the other fixes are independent
  of the cell format and can proceed in parallel, and a plan named for the
  cell model would hide them.

### LEXTER-DRAFT-cell-model-revision-D2 — The first edition is repaired in full before the second edition begins

**Status:** Proposed

**Context:** The layer-mechanics survey's
LEXTER-O14 sorts the cell-model findings into those
needed whichever course is taken and those the dense record would make
unnecessary, and asks whether to repair the second group in place or leave
it for the second edition. Double-width text is wrong today, and the
second edition is a large change that will take time.

**Decision:** Repair the first edition fully, in place, for the critique's
findings LEXTER-O19, LEXTER-O26, LEXTER-O27, LEXTER-O28, LEXTER-O36,
and LEXTER-O40: wide pairs in every operation, layer synchronisation, the glyph
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
colours (LEXTER-O22). The grid's counter is
both incremented and assigned, so the GPU's table can stay stale
(LEXTER-O20), and upload records carry no
identity (LEXTER-O23). The layer-mechanics
survey weighs a window-wide table against per-screen ranges under Swatch
Ownership, and the review recommended a single authoritative table.

**Decision:** Keep one swatch table per screen, and give each table a range
of one GPU store: a texture buffer of 65,536 swatches, as the
cell-field-format survey proposes. Tables only grow, so a table's count is
its version, and the renderer records for each range which table it
uploaded and how many entries. Every writer interns into a table, and
nothing calls `set-swatch` on a grid: `setup-default-swatches`, the 3270
pane, the demo, and decorators intern as screens do. Which table a writer
without a screen of its own uses, a chrome table or the table of the pane it
belongs to, is LEXTER-DRAFT-cell-model-revision-O4. A table that changes other
than by growing bumps a version that forces its range to be uploaded again.

**Alternatives:**
- One table per window, owned by the compositor. Rejected: it loses each
  screen's own numbering, shares one capacity among all panes, splits the
  colour model that LEXTER-D12 placed on the screen, and makes freeing a
  swatch a scan of every screen.
- Content-addressed slots, the review's other suggestion, which it did not
  describe further. Not chosen: an index derived from a swatch's contents
  still needs a store to resolve it, and does not say which table an upload
  came from.

### LEXTER-DRAFT-cell-model-revision-D5 — Ranges arrive in the first edition, and screens store global indices

**Status:** Proposed

**Context:** Swatch ownership is a precondition of everything after it in
this plan. The dense record copies rows and uploads dirty rows, which needs
swatch indices that mean the same wherever they are copied and upload
records that name their source; the record cannot supply either, which is
why the layer-mechanics survey puts swatch ownership before the dense design
rather than after it. The overlay list takes its colours from tables'
ranges, and eviction works within a range. Both editions draw one composed
grid (LEXTER-DRAFT-cell-model-revision-D12), into which every pane's cells
are copied.

**Decision:** Build the swatch ranges on the first edition. A screen's table
hands out global indices, its range's base plus the local number, and the
screen stores those in its cells, so the flush copies a cell's swatch index
unchanged and the shader reads swatches from the texture buffer. In the
second edition the same indices sit in the record, and composing a pane into
the grid is a plain copy of row segments. Because cells hold absolute
indices, moving a range would mean rewriting a screen's cells and
scrollback, so ranges are fixed in place
(LEXTER-DRAFT-cell-model-revision-O3).

**Alternatives:**
- Store local indices and translate them in the flush, adding each table's
  base as cells are written. Rejected: the copy is no longer plain, every
  copy path and kernel must add the base, and it gains only the freedom to
  move ranges, which fixed ranges do not need.
- Wait for the dense model and build the ranges into it. Rejected: the
  dense model depends on the ranges, not the other way round, and the swatch
  faults are high in severity and do not depend on the cell format.

### LEXTER-DRAFT-cell-model-revision-D6 — The first edition's cursor exchanges slots instead of interning a reversed swatch

**Status:** Proposed

**Context:** The flush draws the cursor by interning a reversed swatch into
the screen's table and writing it into the grid, which triggers LEXTER-O20,
adds to LEXTER-O24, and, through rewriting the cell, breaks wide pairs
(LEXTER-O19) and drops layers (LEXTER-O27).

**Decision:** Until the overlay list exists, the flush draws the cursor's
cell as a layered cell whose layer 0 exchanges its ink and background slots
(`src/grid.lisp:cell-layer@2d4d743`), keeping the grid's wide flag. Reverse
video then needs no swatch, and the next flush of the row removes the layer
when the cursor moves. A cursor on a layered cell exchanges the slots of its
layer 0.

**Alternatives:**
- Keep the reversed swatch until the overlay list. Rejected: it is the trigger
  of LEXTER-O20 and the cause of the cursor's part of LEXTER-O19 and
  LEXTER-O27, which LEXTER-DRAFT-cell-model-revision-D2 repairs.

### LEXTER-DRAFT-cell-model-revision-D7 — The dense record is the one the cell-model architecture specifies

**Status:** Proposed

**Context:** The cell-field-format survey lays out a 32-byte record: a
header, a word of settings, three display glyphs, and a three-word tail. Its
first layout gives mask *k* to layer *k*, so a thumb inside one cell cannot
be drawn. Its update on mask targets offers four operations without a
selector, which lose union and exclusion with a mask's uninked pixels, and an
alternative that keeps them (LEXTER-DRAFT-cell-field-format-O11). The
steward chose the alternative here first, with a target for each mask, the
fill rule, and a tail type folded into unused masks, and then refined the
whole record in the cell-model architecture,
[LEXTER-0016](Arch.CellModel.md).

**Decision:** Phase 3 builds the record that LEXTER-0016 specifies, and this
plan does not restate its bits:

- **A format word and a header word.** The first byte names the cell's
  format, and the wide bits sit at fixed places (LEXTER-D81, LEXTER-D82); the
  header word holds the swatch index, an eight-bit palette slot, and the
  cell's background slot (LEXTER-D87).
- **Glyph words.** Each holds a 24-bit glyph and its own settings byte
  (LEXTER-D84). The format word gives the number of glyphs and which are
  masks (LEXTER-D83), and each mask cuts the layers before it, as far as its
  reach (LEXTER-D85).
- **Layers without fills.** A layer inks the pixels it covers; the rest show
  the layers beneath or the cell's background slot (LEXTER-D86, LEXTER-D90).
- **Masks as chosen here.** Each mask keeps a selector, so union and
  exclusion with a mask's uninked pixels are not lost, and operation 3 is the
  mask less the running coverage.

**Alternatives:**
- The layout this plan first adopted, with the settings of three layers and
  three masks in word 1, a target in each mask, the fill rule, and a tail
  type in the bits of unused masks. Superseded by the architecture, which
  keeps each glyph's settings with its glyph, gives masks their place by
  order, and names every special cell by one format byte.
- Four operations and no selector. Rejected: the two operations it drops can
  be recovered only by spending a layer.
- One mask per layer, the survey's first layout. Rejected: it cannot draw a
  band inside one cell.

### LEXTER-DRAFT-cell-model-revision-D8 — The second edition stores a double-width glyph as two halves

**Status:** Proposed

**Context:** Today a double-width glyph is one instance two cells wide, drawn
from its left cell, with a continuation cell that must never be written on
its own. A broken pair corrupts flags.

**Decision:** Store the glyph in both cells, with the wide bit in both and
the right-half bit in the second, kept in the record's format word
(LEXTER-D81), and let each cell draw its own
half. Every quad is one cell, continuation flags go away, and a broken pair
shows half a glyph instead of corrupting state. Writers still write and
erase both halves together, as a terminal must. The atlas keeps each wide
glyph in two adjacent columns, as [LEXTER-0007](Log.EnhancedDualWidth.md)
packs them, and the right half samples the second.

**Alternatives:**
- Keep one double-width instance. Rejected: it is how wide characters are
  lost today. It makes what a cell draws depend on its neighbour, and leaves
  a continuation cell that must never be written on its own.

### LEXTER-DRAFT-cell-model-revision-D9 — One descriptor defines the record for Lisp and the shader

**Status:** Proposed

**Context:** The present instance format is written out three times, in the
packer, the attribute setup, and the shader, and its stride is defined twice
(LEXTER-O36).

**Decision:** A single descriptor, a macro such as `define-cell-layout`,
generates the record's Lisp accessors, the GLSL that decodes it, and the
vertex attribute setup from one definition, written from the tables of
[LEXTER-0016](Arch.CellModel.md). The generated accessors are the only
writers of a record's fields: one that writes a glyph or a single setting
masks the rest of its word (LEXTER-D84). In debugging builds they assert the
record's invariants, which the architecture lists.

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
one instanced draw after the grid, in list order. The cell-model
architecture makes each instance a full record followed by its position and
flags, so that an instance carries whatever a cell can, and the grid's
decoder reads it (LEXTER-D93).

**Alternatives:**
- A stamped mask. Rejected because it writes ephemeral state into the stable
  model of text, which the separation above keeps apart. Secondary costs:
  animating it rewrites a cell and uploads its row on every frame, and it
  needs a free mask or layer, though the survey found such contention rare,
  since VT content uses one layer and a diacritic can be a union mask.
- A uniform cursor. Rejected because it puts the cursor into the work of
  every pixel rather than into a model of its own: every pixel compares its
  cell with every entry, so it does not scale past a few cursors.
- Cursor bits in the record's header. Rejected for the styles that can be
  overlays; whether the block style keeps them is
  LEXTER-DRAFT-cell-model-revision-O5.

### LEXTER-DRAFT-cell-model-revision-D11 — Every repaired finding gets a headless regression test

**Status:** Proposed

**Context:** The critique reproduced most of its findings headlessly in SBCL,
with no display, and the screenshot test rig
([LEXTER-0010](Log.ScreenshotTestRig.md)) cannot detect
LEXTER-O20 or LEXTER-O23, which depend on what the
renderer recorded before a capture.

**Decision:** Before each finding is repaired, a test that reproduces it is
added to a new test system, using FiveAM and cl-hamcrest as the Origin tests
do. Tests are written against behaviour that both editions share, so that
they carry over: the screen's API, what a flush or upload produces for a
cell, and a stand-in for the renderer's upload rule, as the critique used.
Tests that must inspect first-edition internals, such as its wide and
continuation flag vectors, are rewritten in Phase 3. A check that compares
the swatch data the renderer last uploaded with its source needs a GL
context, so it runs in the screenshot test rig's hidden window, not in the
headless suite.

**Alternatives:**
- Screenshot fixtures alone. Rejected: they need a display, and cannot see
  stale state that a capture happens not to show.

### LEXTER-DRAFT-cell-model-revision-D12 — One composed grid holds every text pane and its chrome

**Status:** Proposed

**Context:** LEXTER-DRAFT-cell-model-revision-O1 asked whether the second
edition draws a grid per pane or one composed grid. A grid per pane needs no
copy and lets panes differ in font, cell size, pixel offset, and effect, and
overlap with transparency; but it costs a draw and an upload record per pane,
needs a separate grid for the decorations in the space between panes, and
breaks the idea that the window is one grid of characters. The case against
a composed grid was translating each pane's swatch indices as it is copied,
which global indices (LEXTER-DRAFT-cell-model-revision-D5) remove. The
steward judges multiple fonts and filters for each screen to stray from
Lexter's design goals and, in most situations, to be confusing and harmful
to usability.

**Decision:** The window has one composed grid of records, drawn in one call.
Every text pane, and the chrome drawn by decorators, are cells in it. A
pane's records hold global swatch indices and the pane's palette slot, in the
header word (LEXTER-D87); composing a pane into the grid copies its row
segments unchanged. What a grid per pane alone would give, such as a
different font or an effect of its own, is provided where it is wanted by a
surface: cells of the void format, which reference a surface drawn in their
area (LEXTER-D82). A surface may hold a video, an image, or a
sub-terminal with a grid and font of its own. Surfaces and effects are left
to a later survey.

**Alternatives:**
- A grid per pane. Rejected: its unique abilities are exceptions, better
  given to the area that needs them than paid for by every pane, and the
  steward judges them contrary to the design in ordinary use.
- One composed grid with indices translated on the copy. Rejected for the
  reasons LEXTER-DRAFT-cell-model-revision-D5 gives.

### LEXTER-DRAFT-cell-model-revision-D13 — Phase 3's tests also check a checksum of the normalised record array

**Status:** Proposed

**Context:** The test rig checks the exact pixels of a replay
(LEXTER-D47). That checks the whole path from parser to shader, but it needs
a GL context, holds only on one GPU and driver, and cannot say which stage
failed. LEXTER-D45 rejected the cell matrix as the fixture, because it is
lossy as a description of the input, not as an assertion about the output.
An earlier session rejected a cell dump because swatch indices depend on the
order in which swatches were interned (*Session transcript
ses_1640-Lexter14*, lines 1719-1736). A replay today cannot run without a GL
context even to produce cells, because building the atlas queries
`GL_MAX_TEXTURE_SIZE` and uploads a texture
(`src/atlas.lisp:build-atlas@2d4d743`).

**Decision:** From Phase 3, each fixture records, beside its pixel checksum,
a checksum of the grid's record array and the overlay instances after the
replay.

- **Computed with no display.** The atlas's packing, which assigns each glyph
  its position and keeps its pixels, is separated from the upload of its
  texture, and its column count is fixed by the fixture's configuration
  instead of being derived from the GPU's maximum texture size, so glyph
  positions do not depend on the machine. The handler, the model, and
  composition already need no GL. The cell checksum is then computed by
  replaying a blob in a terminal that has no window, which runs on any
  machine.
- **Normalised.** Each swatch index, in the header word and in a tile cell's
  payload, is replaced by the four palette indices it resolves to, so that
  the order of interning does not matter, and glyph
  words beyond the glyph count, payload words a format does not define, and
  reserved bits are taken as zero, as the cell-model architecture requires
  writers to leave them. Glyph indices stay atlas positions,
  since the fixture's configuration fixes the font.
- **Palettes included.** The contents of every palette that a cell's
  header word selects are hashed with the cells, so that a palette
  changed by the host, through OSC 4 or OSC 104, changes the cell checksum
  as well as the pixels.
- **Kept with the test.** The checksum is a literal in the test source beside
  the pixel checksum, as LEXTER-D49 keeps references apart from blobs, so the
  blob format does not change.

Read together, the two checksums place a failure: a changed cell checksum
points to the parser, handler, model, palettes, or composition; a changed
pixel checksum with an unchanged cell checksum points to the atlas's texture,
the renderer, the shaders, or the uploads. The cell checksum cannot see a GPU
copy that has gone stale, which the pixel checksum and the check of
LEXTER-DRAFT-cell-model-revision-D11 cover.

**Alternatives:**
- Compute the cell checksum only during the hidden-window replay that takes
  the pixel checksum. Rejected: it would need a GL context, so it could not
  run on a server without one.
- Resolve each swatch slot to its RGB colour instead of hashing the palettes.
  Not chosen: it would fold a change of palette and a change of swatch into
  one difference, where hashing the palettes beside the cells keeps both
  visible in the data.
- The raw record bytes. Rejected: they change with the order of interning
  and with garbage in fields the shader ignores, failing tests whose
  pictures are unchanged.
- Codepoints from the text array in place of atlas positions. Rejected: the
  checksum would no longer see a wrong lookup in the atlas.
- Hash the first edition's instance buffers now. Not chosen: every checksum
  would be re-authored at Phase 3.

### LEXTER-DRAFT-cell-model-revision-D14 — Palettes and swatches are stored as integers in texture buffers

**Status:** Proposed

**Context:** The first edition keeps colours on the GPU as floats. The
palettes are a uniform buffer of `vec4` floats, which LEXTER-D16 chose
because floats map cleanly to `std140` arrays, and which LEXTER-D17 limited
to four slots because a uniform buffer is guaranteed only 16 KB
([LEXTER-0004](Log.PalettePaging.md)). The swatch table is a normalised
RGBA8 texture read through `sampler1D`, which the shaders turn back into
indices by multiplying by 255 and rounding
(`src/shaders.lisp:+layered-frag+@2d4d743`). It was first an `RGBA8UI`
texture read through `usampler1D`, and moved to normalised values because of
cl-opengl limitations that the session did not describe further (*Session
transcript ses_2263-Lexter5*, line 2576). The model keeps palette entries as
floats as well (`src/model.lisp:make-default-palette@2d4d743`).

**Decision:** From Phase 2, both stores are texture buffers with the
internal format `GL_RGBA8UI`, read in the shaders as `usamplerBuffer` with
`texelFetch`.

- **Swatches.** Each texel holds a swatch's four palette indices as integers,
  with no conversion from normalised values.
- **Palettes.** Each palette is 256 texels, one colour to a texel, and a
  palette slot's entries begin at the slot's number times 256. The uniform
  buffer is removed. The store's guaranteed 65,536 texels lift the limit of
  LEXTER-D17, which belonged to the float uniform buffer. The record's
  palette slot is eight bits wide, and the configuration sets how many slots
  the store holds (LEXTER-D87, LEXTER-D92).
- **Bytes on the CPU.** The model keeps palette entries as bytes, so that the
  upload copies them unchanged and the CPU renderer
  (LEXTER-DRAFT-cell-model-revision-D16) reads the values the GPU reads.
- **A check first.** Phase 2 begins by confirming, in a small test, that
  cl-opengl can create an `RGBA8UI` texture buffer, by its keyword or by the
  numeric constant, and that a shader reads it through `usamplerBuffer`. The
  earlier limitation concerned a 1D texture, whereas a texture buffer is
  filled through an ordinary buffer object, so it may not apply. A failure is
  brought to the steward before the stores change.

**Alternatives:**
- Keep floats: normalised RGBA8 swatches and the float uniform buffer.
  Rejected: converting through floats is where implementations may round
  differently, against the exact shader of
  LEXTER-DRAFT-cell-model-revision-D15, and the buffer holds four palettes.
- Pack four colours into each `uvec4` of the existing uniform buffer, for 16
  palettes in 16 KB. Not chosen: it keeps a second kind of colour store
  beside the swatch texture buffer, and a smaller one.
- A 1D RGBA8 texture of palettes, LEXTER-D16's Option B. Rejected: OpenGL 3.3
  guarantees a 1D texture only 1024 texels, which is four palettes.

### LEXTER-DRAFT-cell-model-revision-D15 — The shaders select one palette entry for each pixel, without blending

**Status:** Proposed

**Context:** Every pixel of a glyph or mask in Lexter is inked or not; quads
are placed on whole pixels and textures sampled at the nearest texel at
integer scale. The room left for implementations to differ is arithmetic on
colours: converting floats to bytes, and blending. The Dense Cell Model
section had planned to composite layers with premultiplied colour. A pixel
checksum that holds across implementations, and the comparison of the GPU
with the CPU renderer (LEXTER-DRAFT-cell-model-revision-D17), need every
implementation to write the same bytes.

**Decision:** From Phase 3, the grid's shader decides for each pixel, by the
procedure of the cell-model architecture (LEXTER-0016, Drawing a Pixel) with
integer tests, which layer is the topmost to cover it after its masks, or that
the cell's background slot shows. It reads that one palette entry from the
integer store (LEXTER-DRAFT-cell-model-revision-D14) and writes it divided by
255, with no blending, which every conformant implementation stores as the
original bytes. The overlay pass of Phase 4 writes the entry of a covered
pixel in the same way; an uncovered pixel takes the instance's background slot
when its flags say it draws its background, as the block cursor's does, and is
discarded otherwise (LEXTER-D93). Blending that a surface or effect adds later
lies outside this guarantee, and outside the fixtures that rely on it.

**Alternatives:**
- Composite the layers with premultiplied floats. Rejected: with coverage of
  0 or 1, blending computes a selection by arithmetic that implementations
  may round differently.

### LEXTER-DRAFT-cell-model-revision-D16 — A renderer on the CPU draws grids as the GPU does

**Status:** Proposed

**Context:** Drawing needs a GL context: the test rig's pixel checksums are
taken in a hidden window, and a server without a GPU can check them only
through a software implementation of OpenGL. An earlier session proposed a
font selector rendered on the CPU, bypassing the atlas and the shaders,
because the main renderer has one atlas with one cell size and cannot show
many fonts at their own sizes (*Session transcript ses_2263-Lexter9*, lines
1325-1437). The dense record, with fixed offsets, no hash tables, and rows
that do not depend on each other, is quicker to read on the CPU than the
first edition's cells.

**Decision:** Phase 5, after the overlay list, adds a general-purpose
renderer, written in Lisp, that runs on the CPU and needs no GL.

- **What it draws.** It takes a list of entries, each a grid of records with
  its overlay instances, a glyph source, and an origin in pixels, and draws
  them into one RGB image.
- **Glyph sources.** The glyph pixels that the atlas's packing keeps in its
  `position-pixels` table (`src/atlas.lisp:atlas@2d4d743`), which
  LEXTER-DRAFT-cell-model-revision-D13 separates from the texture, or a
  font's own bitmaps, so that each entry may have its own font and cell size.
- **The same rules.** It follows the architecture's procedure for drawing a
  pixel (LEXTER-0016, Drawing a Pixel), with the integer stores of
  LEXTER-DRAFT-cell-model-revision-D14 and the selection of
  LEXTER-DRAFT-cell-model-revision-D15, and reads records through accessors
  generated from LEXTER-DRAFT-cell-model-revision-D9's descriptor. For a grid
  and its overlays it produces exactly the GPU's pixels.
- **Exclusions at first.** Surfaces and effects, which are left to a later
  survey (LEXTER-DRAFT-cell-model-revision-D12). A cell of a format it does
  not draw is drawn blank, in its background slot, as both renderers do
  (LEXTER-D82).
- **Uses.** It is the second renderer against which the GPU is tested
  (LEXTER-DRAFT-cell-model-revision-D17). Its first use outside the tests is
  the font selector: a popup window with its own rendering pipeline,
  bypassing the OpenGL window of Lexter's main display, which shows many
  fonts at once as many small grids. The font selector is designed in a
  survey of its own.
- **Threads.** Whether it draws with more than one thread is
  LEXTER-DRAFT-cell-model-revision-O12.

**Alternatives:**
- No CPU renderer, with pixel checksums from a software OpenGL alone.
  Rejected: the shaders would have no second implementation to be compared
  with, and the font selector would need a renderer of its own anyway.
- A CPU reference for single cells, used only as a test oracle. Not chosen:
  the font selector needs whole grids, and since rows are independent, a
  renderer of grids costs little more than one of cells.
- Build it on the first edition. Rejected: it would read the hash tables of
  layered cells and the instance packer that Phase 3 removes.
- Build it straight after Phase 3, adding overlays later. Not chosen: the
  steward placed it after the overlay list, so that it draws from the start
  everything the GPU's text passes draw.

### LEXTER-DRAFT-cell-model-revision-D17 — Pixel checksums are produced by both renderers and compared

**Status:** Proposed

**Context:** The test rig's pixel checksums (LEXTER-D47) are taken on one
GPU and driver, and its Log notes that a software rasterizer, selected with
`LIBGL_ALWAYS_SOFTWARE=1`, would make them hold across machines
([LEXTER-0010](Log.ScreenshotTestRig.md)). Mesa's llvmpipe is such a
rasterizer, supports OpenGL 3.3, and runs on a server with no GPU.

**Decision:**

- **From Phase 3,** pixel checksums are taken on a pinned version of Mesa's
  llvmpipe, in the test rig's hidden window under a virtual X server, so
  that they can be checked on any machine before the CPU renderer exists.
- **From Phase 5,** each fixture is rendered by both renderers: by the CPU
  renderer (LEXTER-DRAFT-cell-model-revision-D16), in the headless suite,
  and by the GPU on the pinned llvmpipe. Each produces a pixel checksum, and
  the test requires both to equal the fixture's literal. When the two
  differ, the test compares their images and reports the first cell in
  which they differ.
- **Carried over.** If the shaders are exact
  (LEXTER-DRAFT-cell-model-revision-D15), the CPU renderer reproduces the
  checksums authored in Phase 3 without re-authoring them; a fixture it does
  not reproduce marks a disagreement to be fixed.
- **Real GPUs.** A real GPU may run the same comparison, as a check of its
  driver, but no fixture is authored on one.

With the cell checksum of LEXTER-DRAFT-cell-model-revision-D13, the checks
place a failure: a changed cell checksum points to the model; pixel
checksums that change together, with the cell checksum unchanged, point to
the atlas's packing or to a rule both renderers share; renderers that
disagree point to one of them, the shaders, or the uploads.

**Alternatives:**
- Checksums taken on the developer's GPU, as today. Rejected: they hold on
  one GPU and driver, and need a GPU wherever they are checked.
- The CPU renderer's checksums alone. Rejected: the shaders, the uploads,
  and the attribute setup would go unchecked.
- Compare images within a tolerance. Rejected: a tolerance hides the
  off-by-one colours and misplaced pixels that the checksums exist to find,
  and exact shaders make it unnecessary.

## The First Edition Repaired

Phase 1 repairs the present structures in place
(LEXTER-DRAFT-cell-model-revision-D2).

Table: First-edition repairs by finding.

| Finding | Repair |
|---|---|
| LEXTER-O19 | The VT handler writes pairs and advances by two; the flush writes each pair once; the cursor keeps the wide flag (LEXTER-DRAFT-cell-model-revision-D3, LEXTER-DRAFT-cell-model-revision-D6) |
| LEXTER-O26 | Per-cell helpers in every row and range operation, edge repair, `resize-grid` copying both flag vectors, and the row check (LEXTER-DRAFT-cell-model-revision-D3) |
| LEXTER-O27 | The flush writes a layered cell's whole record, empty layers included; `write-char-at` on a layered cell honours its swatch and attributes; the cursor no longer rewrites the cell (LEXTER-DRAFT-cell-model-revision-D6) |
| LEXTER-O28 | Atlas positions 0–63 are reserved at build time, position 0 for an empty glyph and the rest for generated glyphs, which the atlas names from 0x110000 instead of private-use codepoints, so the cursor glyphs move to positions 1–4 (LEXTER-D89); every writer takes its blank from the atlas instead of writing codepoint 32 |
| LEXTER-O36 | One home for the cell constants that the model, grid, and renderer share, one `+layered-stride+`, one default palette, one `setup-default-swatches`, and one name for each layer slot |
| LEXTER-O40 | The grid's description is made true: `build-render-data` loses the unused `force-full` and its claim of incremental rebuilds, and the dirty bits stay for the second edition to upload by |
| Review: the cursor writes into the model during the flush | The cursor exchanges slots (LEXTER-DRAFT-cell-model-revision-D6) |

The repair of LEXTER-O40 makes the first
edition honest rather than incremental. Rebuilding only dirty rows would need
instances laid out by row, which the first edition's compact packing does not
have and the second edition provides.

## Swatch Ranges

Phase 2 builds the ranges of LEXTER-DRAFT-cell-model-revision-D4 on the first
edition, as LEXTER-DRAFT-cell-model-revision-D5 describes.

- **The check of cl-opengl.** The phase begins by confirming that cl-opengl
  can create and fill an `RGBA8UI` texture buffer that a shader reads through
  `usamplerBuffer` (LEXTER-DRAFT-cell-model-revision-D14).
- **The store.** The swatch texture becomes an `RGBA8UI` texture buffer read
  as a `usamplerBuffer`, core since OpenGL 3.1 and guaranteed at least 65,536
  texels in OpenGL 3.3.
- **Palettes.** The palette uniform buffer becomes an `RGBA8UI` texture
  buffer of 256 texels for each slot, and the model keeps palette entries as
  bytes (LEXTER-DRAFT-cell-model-revision-D14). The configuration sets how
  many slots the store holds, 128 by default (LEXTER-D92). The first
  edition still chooses a slot for each draw; allocating slots to terminals
  waits for the record's palette slot in Phase 3.
- **Ranges.** An allocator hands each table a range and takes it back when
  its screen goes away, because its pane is destroyed or `terminal-reset`
  replaces it. Sizing, the alternate screen, and what a full table does are
  LEXTER-DRAFT-cell-model-revision-O3.
- **Defaults at zero.** Global swatch 0 and palette slot 0 always hold valid
  default colours, so that a record of zeros in the second edition is a
  blank cell (LEXTER-D83); the allocator reserves them, for the table that
  LEXTER-DRAFT-cell-model-revision-O4 decides.
- **Writers.** The 3270 pane's global cache becomes a table; chrome,
  decorators, and the demo intern into tables
  (LEXTER-DRAFT-cell-model-revision-O4).
- **Uploads.** The renderer records, for each range, the table it uploaded
  and the count, and uploads the new tail of a table that has grown, or the
  whole range for a table that is new or has bumped its version.
- **Global indices.** A table hands out global indices, its range's base
  plus the local number, and screens store them, so the flush copies each
  swatch index unchanged (LEXTER-DRAFT-cell-model-revision-D5).
- **The wide bit.** The first edition's instances carry the wide flag in bit
  15 of their swatch field (`src/grid.lisp:build-render-data@2d4d743`), so a
  global index must stay below 32,768. Until Phase 3 gives the swatch
  index 16 bits and the wide flag a bit of its own, the allocator uses only
  the store's first 32,768 entries. Moving the flag into the instance's
  padding bytes would lift the limit sooner, at the cost of changing the
  first edition's shaders and attribute setup once more.

When the phase is done, LEXTER-O20, LEXTER-O22, and LEXTER-O23 are resolved,
and LEXTER-O24 is a limit per table with a policy for a full table.

**Phase 2 is a precondition of every later phase.** It is complete when every
swatch writer interns into a table with its own range, nothing calls
`set-swatch` on a grid, and every upload record names its table. Each later
phase depends on that:

Table: What each later phase needs from swatch ownership.

| Phase | Needs |
|---|---|
| 3, the dense cell model | Swatch indices that mean the same wherever rows are copied, and upload records that name their source, for dirty-row uploads |
| 4, the overlay list | A table and range from which each overlay takes its colours |
| 5, the CPU renderer | Swatch indices that mean the same in every grid it draws, and the integer stores whose bytes it shares with the GPU |
| 6, partial redraw | The dense model's dirty-row uploads, and so Phase 2 through Phase 3 |
| 7, eviction | Ranges to evict within, and tables whose versions force a range to be uploaded again |

## The Dense Cell Model

Phase 3 replaces the present cells with the record of the cell-model
architecture, [LEXTER-0016](Arch.CellModel.md), as
LEXTER-DRAFT-cell-model-revision-D7 decides. The architecture specifies the
record; the phase builds it in this order of concerns.

Table: What Phase 3 builds from the architecture.

| Part | What is built | Architecture |
|---|---|---|
| The record | The format word, the header word, and glyph words with their settings, generated from one descriptor | LEXTER-D81, LEXTER-D84, LEXTER-D87 |
| The plain format | The glyph count and type bits, layers interleaved with masks, each mask cutting the layers before it as far as its reach | LEXTER-D83, LEXTER-D85 |
| Backgrounds | The cell's background slot in place of fills; reverse video through the background slot, so the handler no longer interns a reversed swatch | LEXTER-D86, LEXTER-D90 |
| Lines | The single underline, strikethrough, and overline as generated glyphs: the text's last mask in its colour, or the last layer for an SGR 58 underline | LEXTER-D88, LEXTER-D89 |
| Palette slots | An allocator that gives each terminal a palette slot and records each upload by owner, replacing slots chosen by hand and generations compared by slot | LEXTER-D92 |
| The shader | The procedure of Drawing a Pixel, with selection and no blending | LEXTER-0016, Drawing a Pixel |

- **Swatch ownership comes first.** The phase begins only when Phase 2 is
  complete (see Swatch Ranges): the record holds swatch indices but cannot
  make them mean the same in every copy, nor tell the renderer where an upload
  came from.
- **The 3270 pane.** It keeps a screen of its own and writes the grid
  directly; whether it is rewritten to write records or keeps a path of its
  own is LEXTER-DRAFT-cell-model-revision-O11.
- **The grid's array is its upload buffer.** Cells are stored row by row, so
  each dirty row is one contiguous range, uploaded by itself. The renderer
  records which grid it uploaded, by an identity or an epoch from one global
  counter, and uploads the whole grid when the grid is replaced, the workspace
  changes, or the size changes.
- **One composed grid, one draw** (LEXTER-DRAFT-cell-model-revision-D12). The
  shader computes a cell's position from its instance number, and for each
  pixel selects the palette entry of the topmost layer that covers it after
  its masks, or of the background, writing it without blending
  (LEXTER-DRAFT-cell-model-revision-D15), so there are no passes per layer.
- **Halves.** Double-width glyphs are stored as halves
  (LEXTER-DRAFT-cell-model-revision-D8). How a mask applies to a half is
  LEXTER-DRAFT-cell-model-revision-O6.
- **Text beside the record.** The characters each cell shows are kept in a
  side array, not in the record, for selection, copying, search, and screen
  readers. The architecture leaves this text grid, like hyperlink ids and
  protected cells, to state that Lexter keeps apart from the cell model, and
  writers keep the two in step. Its form is
  LEXTER-DRAFT-cell-model-revision-O8.
- **Scrollback as rows of records.** History keeps layers and costs a record
  per cell, not a list.
- **The model's storage** is LEXTER-DRAFT-cell-model-revision-O2, settled
  before the phase begins. Panes are copied into the one composed grid by row
  segments (LEXTER-DRAFT-cell-model-revision-D12).
- **Kernels follow correctness.** Typed Lisp loops over the record come first;
  generated kernels, and where the grid lives in memory, are
  LEXTER-DRAFT-cell-model-revision-O10. Where the grid lives is settled before
  the phase, because it decides how rows are uploaded; the route for kernels
  can wait.
- **The plain format first.** The phase builds the plain format, which every
  text cell uses; the void, inline-colour, effect, and tile formats are added
  after it, each as its own step (see Later Formats), since a renderer draws
  a format it does not yet know as a blank cell (LEXTER-D82) and no writer
  produces one before it is drawn.

The first edition's simple and layered paths, its hash tables of layered
cells, the instance packer, and the per-layer draws are removed.

## The Overlay List

Phase 4 adds the overlay list of LEXTER-DRAFT-cell-model-revision-D10, with
cursors as its first use.

- **A pass of its own.** One instanced draw after the grid, whose instances
  are records followed by a position and flags, decoded as the grid's records
  are (LEXTER-D93).
- **Positions in cells or pixels**, so an overlay can move smoothly and is not
  bound to the grid.
- **Colours** from the swatch table and range of the pane or chrome it
  belongs to, which Phase 2 provides (LEXTER-DRAFT-cell-model-revision-O4).
- **The block cursor** is a copy of the cell beneath it, with its background
  slot and its first layer's ink slot exchanged, in an instance that draws
  its background; the flush copies it again when the cursor moves or its row
  changes (LEXTER-D93). The underline and bar cursors, and a hyperlink lit
  by the pointer, are instances that do not draw their background.
- **Redraw.** Moving, adding, removing, or animating an instance marks the
  rows under its old and new positions for redraw.
- **Time.** Animation reads a time uniform that the test rig can fix, and
  animates only the focused pane by default.

LEXTER-DRAFT-cell-model-revision-D6's exchanged slots are removed when the
overlay cursor arrives.

## The CPU Renderer

Phase 5 adds the CPU renderer of LEXTER-DRAFT-cell-model-revision-D16 and
the comparison of renderers of LEXTER-DRAFT-cell-model-revision-D17.

- **Glyphs without GL.** Glyph pixels come from the atlas's packing, which
  Phase 3 separates from its upload (LEXTER-DRAFT-cell-model-revision-D13),
  or from a font's bitmaps.
- **One rule, two implementations.** The record's accessors come from the
  descriptor (LEXTER-DRAFT-cell-model-revision-D9); the architecture's
  procedure for drawing a pixel (LEXTER-0016, Drawing a Pixel), with the
  selection of an entry (LEXTER-DRAFT-cell-model-revision-D15), is written
  once more in Lisp.
- **Overlays.** Each grid's overlay instances are drawn over it in list
  order, as the overlay pass draws them, at a time that the caller fixes, as
  the test rig fixes the time uniform.
- **Fixtures.** Every fixture's pixel checksum is checked against both
  renderers; the checksums authored on llvmpipe in Phase 3 carry over.
- **Surfaces and effects** are not drawn at first.
- **Threads** are LEXTER-DRAFT-cell-model-revision-O12; a renderer on one
  thread comes first.
- **The font selector** is its first use outside the tests, and is designed in
  a survey of its own.

## Later Formats

The formats beyond the plain format, and the line styles beyond the single
underline, are added after Phase 5, each as a step of its own that adds it
to the descriptor, to both renderers, and to the writers that produce it,
with fixtures checked by both renderers.

Table: The later additions and what each waits for.

| Addition | Waits for |
|---|---|
| Inline colours (LEXTER-D82) | Nothing beyond Phase 5 |
| Tiles and their texture (LEXTER-D91) | The cursor over a tile cell (LEXTER-O45), palette slots running out (LEXTER-O50), and the fitting of tile sets (LEXTER-O51) |
| The void and effects (LEXTER-D82) | The survey of surfaces and effects, and what they carry (LEXTER-O53) |
| Further underline styles (LEXTER-D89) | How their patterns meet from cell to cell (LEXTER-O48) |

## Partial Redraw and Eviction

Phase 6, optional, redraws only the dirty rows and the rows under changed
overlays: rows by instance range, with the record's attribute pointers moved
to the first row, since OpenGL 3.3 has no base instance. It needs either the
offscreen target kept on, which overturns LEXTER-D39 and leaves one
full-window blit per presented frame, or the buffer-age extensions cited
above (LEXTER-DRAFT-cell-model-revision-O9).

Phase 7, conditional, evicts unused swatches within a range, if
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
- **Dependence on the other plans.** Phase 1 waits for the consolidation of
  the two terminal stacks (LEXTER-D67), so that its
  repairs land once. Dirty-row uploads would leave a stale workspace on screen
  until the workspace switch schedules a repaint
  (LEXTER-O32), which
  LEXTER-D71 fixes before Phase 3. The pane-profiles
  plan also changes `flush-to-display`, to draw the history, so its order with
  Phase 1 is settled when the phases are scheduled.
- **A larger model.** A screen of 80×24 records is 61 KB, three times today's
  size; small, but it grows with every pane and its scrollback.
- **Two renderers to keep in step.** The descriptor generates both
  renderers' decoders, but the coverage rule and the selection of an entry
  are written twice, in GLSL and in Lisp, and every change to the record's
  drawing is made in both. The comparison of
  LEXTER-DRAFT-cell-model-revision-D17 finds a change made in only one.
- **A pinned rasterizer.** The fixtures depend on one version of Mesa in CI,
  and llvmpipe's output could in principle differ between CPU instruction
  sets, so the CI image is pinned as a whole; moving to a new version of Mesa
  is a deliberate step, checked against the CPU renderer.

## Open Questions

### LEXTER-DRAFT-cell-model-revision-O1 — A grid per pane, or one composed grid?

A grid per pane keeps swatch indices local, uploads a pane's dirty rows from
its own array, and gives each pane its palette slot by a uniform, freeing the
header's palette-slot bits, at the cost of a draw call per pane and a home
for chrome. One composed grid keeps one draw call, but its copy translates
every swatch index, and palettes travel in each cell's bits. It is
LEXTER-O17, and it is settled before Phase 3.

**Resolution:** 2026-11-03 — accepted, recorded at the steward's direction:
one composed grid, with global swatch indices so that composing needs no
translation, and surfaces for the areas that need a font or effect of their
own (LEXTER-DRAFT-cell-model-revision-D12, LEXTER-DRAFT-cell-model-revision-D5).

### LEXTER-DRAFT-cell-model-revision-O2 — Does the model store the record?

Storing the record makes the flush a copy and makes scrollback compact; it
triples the model's size, and the model's attributes need a place. It is
LEXTER-O7. The decisions for one composed grid and global indices
(LEXTER-DRAFT-cell-model-revision-D12, LEXTER-DRAFT-cell-model-revision-D5)
make it more attractive: a screen whose cells are records, with their global
swatch indices and palette slot already set, composes into the grid by a plain
copy of row segments, which a kernel can do as one block move per row. The
architecture adds a consideration: it reads a cell's lines back from its
glyph words, for DECCARA, DECRARA, and attribute reports (LEXTER-D88), which
assumes the records are at hand; a model that does not store them keeps each
cell's SGR attributes itself.

### LEXTER-DRAFT-cell-model-revision-O3 — How are swatch ranges sized and released, and what does a full table do?

Fixed ranges, such as 2048 entries for each of 32 tables, or ranges allocated
and relocated as tables grow. The steward leans to fixed ranges: screens store
global indices (LEXTER-DRAFT-cell-model-revision-D5), so moving a range would
mean rewriting a screen's cells and its scrollback. What remains open is their
size. In Phase 2 only the store's first 32,768 entries are usable, because the
first edition's instances carry the wide flag in bit 15 of their swatch field
(see Swatch Ranges), so ranges of 2048 entries give 16 tables until Phase 3.
Ranges are fixed in place, so those allocated in Phase 2 carry into Phase 3
unchanged, and Phase 3 opens the rest of the store. Also open: whether the
primary and alternate screens share one table, and whether a full table
evicts unused swatches (Phase 7) or falls back to the nearest existing one.
It is LEXTER-O15.

### LEXTER-DRAFT-cell-model-revision-O4 — Where do the swatches of writers without a screen live?

Chrome, decorators, the overlay list, and the 3270 pane need tables: one
chrome table with a range of its own, or the table of the pane each belongs
to. It is LEXTER-O16.

### LEXTER-DRAFT-cell-model-revision-O5 — How does the block cursor learn the cell beneath it?

The CPU copies layer 0's glyph and settings into the cursor's overlay
instance and refreshes them when the row changes, or the block style keeps
cursor bits in the header and is drawn in the grid's pass. It is
LEXTER-O18.

**Resolution:** 2026-11-03 — accepted, recorded at the steward's direction:
the block cursor's overlay instance carries a full copy of the record
beneath it, and the header has no cursor bits
(LEXTER-D93 in [LEXTER-0016](Arch.CellModel.md)).
The steward has since settled that the copy is inverted by exchanging its
background slot with its first layer's ink slot, and that the instance draws
its background.

### LEXTER-DRAFT-cell-model-revision-O6 — How does a mask apply to a wide display glyph?

A narrow mask applied to one half, or the matching half of a wide mask
glyph. It is LEXTER-DRAFT-cell-field-format-O12, which the cell-model
architecture carries as LEXTER-O52: its line glyphs are narrow and applied to
each half's cell, so the rule chosen must let a narrow mask apply to one
half.

### LEXTER-DRAFT-cell-model-revision-O7 — Which tail types are there, and what do the six payload bits carry?

The layout this plan first adopted fixed how a tail type was found, in the
bits of unused masks, but not its values. Candidates from the
cell-field-format survey are a reference to a surface, inline colours, an
effect, and tiles, with one value for no payload.

The reference to a surface is the steward's **void**: a cell whose un-inked
pixels the grid leaves undrawn, so that a surface drawn separately shows
through them in the cell's area. The steward's uses for it are a video
player, an image in a gallery, and a sub-terminal with a grid and font of its
own, which gives a pane the abilities a separate grid would (see
LEXTER-DRAFT-cell-model-revision-D12). Void cells would also mark the area
that effects applied to the whole grid, such as scanlines or a tint, pass
over, so that the surface can take an effect of its own; glyph layers may sit
over a void, as captions over a video.

**Resolution:** 2026-11-04 — accepted, recorded at the steward's direction:
tail types and escape cells become one namespace of formats, named by the
first byte of the record: plain, void, inline colours, effect, and tiles
(LEXTER-D82 in [LEXTER-0016](Arch.CellModel.md)). What the void and the
effect carry remains open in the architecture, as LEXTER-O53, for the survey
of surfaces and effects.

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
LEXTER-O10.

### LEXTER-DRAFT-cell-model-revision-O11 — Is the 3270 pane rewritten to the record, or does it keep its own path?

The 3270 pane keeps a screen of its own, of codepoints and field attributes,
and writes the display grid directly
(`src/tn3270-pane/tn3270-pane.lisp:get-or-create-swatch@2d4d743`); the review
found that it never touches the model. Under the dense model it can be
rewritten to keep its screen as records, or keep its own screen and write
records into its region of the composed grid
(LEXTER-DRAFT-cell-model-revision-D12). Either way, Phase 2 gives it a swatch
table in place of its global cache. It is settled before Phase 3.

### LEXTER-DRAFT-cell-model-revision-O12 — Does the CPU renderer draw with more than one thread?

Rows are independent, so bands of rows could be drawn by threads, through
`sb-thread` or a library such as lparallel. The threads would read rows,
glyph pixels, swatches, and palettes that nothing writes while they run,
either a snapshot or state the main loop leaves alone until the bands are
done, and would never touch GL; Lexter's main loop stays single-threaded, as
it is designed to be. Inner loops that do not allocate keep garbage
collection, which stops every thread, out of a frame. What remains open is
whether the gain, for the tests and the font selector, is worth the
dependence and the snapshot. It need not be settled before Phase 5: a
renderer on one thread is correct, and bands can be added after it.

## Prior Art

Table: Prior systems and what this plan draws from each.

| System | What to draw from |
|---|---|
| VGA text mode | A dense array of fixed-size cells that the display reads directly |
| kitty | Separate records for what the GPU draws and what the CPU reads, such as each cell's text |
| notcurses | A fixed-size cell with an overflow pool for long grapheme clusters |
| X11 drawing functions, Win32 ROP2 codes | Logical combination of two sources, here encoded as operation, selector, and reach |
| Porter and Duff's compositing operators | Masks as operations on coverage: in, out, and xor |
| NES attribute tables, Mega Drive palette lines | A small base into a shared colour store chosen per region, as each table's range is |
| Hardware sprites (C64 VIC-II, NES PPU), DRM cursor planes | Moving objects drawn apart from the background, as the overlay list is |
| Buffer age and damage tracking (EGL, GLX, Alacritty) | Redrawing and presenting only what changed |
| kitty, tmux, Alacritty's reference tests, VTE | Tests that assert on the screen model rather than on pixels, as the screenshot-test-rig Log ([LEXTER-0010](Log.ScreenshotTestRig.md)) records; the cell checksum adds such an assertion beside the pixel checksum |
| Direct3D's reference rasterizer, Mesa's softpipe and llvmpipe | A software renderer kept as the reference against which other implementations' output is compared, as the CPU renderer is |

## Roadmap

1. **Phase 0: the regression suite.** A headless test system with a test for
   each finding in scope, reproducing it before it is repaired
   (LEXTER-DRAFT-cell-model-revision-D11).
2. **Phase 1: the first edition repaired.** It starts after the companion
   plan's consolidation of the two terminal stacks (LEXTER-D67). The repairs
   of The First Edition Repaired, finding by finding, each turning its test
   green. Double-width text renders through the VT path. A Log records the
   phase.
3. **Phase 2: swatch ranges.** The store, the allocator, interning by every
   writer, upload records that name their tables, and global indices stored by
   screens (LEXTER-DRAFT-cell-model-revision-D4,
   LEXTER-DRAFT-cell-model-revision-D5), with palettes and swatches in integer
   stores after a check of cl-opengl (LEXTER-DRAFT-cell-model-revision-D14).
   Fixtures replay the same in any order. LEXTER-DRAFT-cell-model-revision-O3
   and LEXTER-DRAFT-cell-model-revision-O4 are settled first. A Log records
   the phase. Every later phase waits for it.
4. **Gate.** Phase 2 is complete, as Swatch Ranges defines;
   LEXTER-DRAFT-cell-model-revision-O2, LEXTER-DRAFT-cell-model-revision-O6,
   LEXTER-DRAFT-cell-model-revision-O8, and
   LEXTER-DRAFT-cell-model-revision-O11 are settled, with the half of
   LEXTER-DRAFT-cell-model-revision-O10 that decides where the grid lives; and
   the companion plan's workspace-switch repaint (LEXTER-D71) has landed. The
   formats other than the plain format (LEXTER-DRAFT-cell-model-revision-O7)
   may wait until after Phase 3.
5. **Phase 3: the dense cell model.** The descriptor
   (LEXTER-DRAFT-cell-model-revision-D9); the record of
   [LEXTER-0016](Arch.CellModel.md) in its plain format
   (LEXTER-DRAFT-cell-model-revision-D7), with halves
   (LEXTER-DRAFT-cell-model-revision-D8), backgrounds, lines as glyphs, and
   palette slots allocated to terminals; the text array; scrollback of
   records; one composed grid drawn in one call
   (LEXTER-DRAFT-cell-model-revision-D12) by a shader that selects without
   blending (LEXTER-DRAFT-cell-model-revision-D15); and dirty-row uploads.
   The suite passes on the new model, and fixtures are re-authored on a
   pinned llvmpipe with a cell checksum beside each pixel checksum
   (LEXTER-DRAFT-cell-model-revision-D13,
   LEXTER-DRAFT-cell-model-revision-D17). A Log records the phase.
6. **Phase 4: the overlay list.** The pass, the block cursor as a transformed
   copy of the cell beneath it and the other cursors as overlays (LEXTER-D93),
   and the removal of LEXTER-DRAFT-cell-model-revision-D6's exchanged slots.
   A Log records the phase.
7. **Phase 5: the CPU renderer.** Grids and their overlays drawn on the CPU
   (LEXTER-DRAFT-cell-model-revision-D16), and every fixture checked against
   both renderers (LEXTER-DRAFT-cell-model-revision-D17). A Log records the
   phase.
8. **Later formats.** Inline colours, tiles, the void and effects, and further
   underline styles, each as its own step when what it waits for is settled
   (see Later Formats). A Log records each.
9. **Phase 6, optional: partial redraw**, after
   LEXTER-DRAFT-cell-model-revision-O9 is settled.
10. **Phase 7, conditional: eviction within a range**, if
    LEXTER-DRAFT-cell-model-revision-O3 chooses it.
11. **The second edition specified.** A specification of the new data model,
    Spec.DataStructures2e, superseding
    [LEXTER-DRAFT-data-structures-1e](Spec.DataStructures1e.md), and README.md
    brought up to date (LEXTER-O39).

Three plans work in this area: this one,
[LEXTER-0015](Plan.TerminalFixes1e.md), and
[LEXTER-DRAFT-pane-profiles](Plan.PaneProfiles.md). Their steps interleave as
follows.

Table: The order of work across the three plans.

| Order | Step | Waits for |
|---|---|---|
| 1 | This plan's Phase 0: the regression suite | — |
| 2 | The terminal-fixes plan's tests, in that suite | 1 |
| 3 | The terminal-fixes plan's consolidation of the two stacks (LEXTER-D67) | 2 |
| 4 | This plan's Phase 1: the first edition repaired | 3 |
| 5 | This plan's Phase 2: swatch ranges | 4 |
| 6 | The terminal-fixes plan's workspace-switch repaint (LEXTER-D71) | 3 |
| 7 | This plan's Phase 3 and later | 5, 6, and the gate's questions |
| — | The pane-profiles plan's history drawing in `flush-to-display` | Its order relative to step 4 is settled when the phases are scheduled |
| — | The terminal-fixes plan's protocol fixes (LEXTER-D72, LEXTER-D73) | Nothing; at any time |