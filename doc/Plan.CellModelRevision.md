---
id:            LEXTER-0017
title:         "Cell Model Revision: Development Plan"
genre:         Plan
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
  session:     "Cell model revision plan (2026-11-02); widths, history, and rows (2026-11-17)"
relates-to:
  - LEXTER-0018
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
  - LEXTER-D96
  - LEXTER-D97
  - LEXTER-D98
  - LEXTER-D99
  - LEXTER-D100
  - LEXTER-D101
  - LEXTER-D102
  - LEXTER-D103
  - LEXTER-D104
  - LEXTER-D105
  - LEXTER-D106
  - LEXTER-D107
  - LEXTER-D108
  - LEXTER-D109
  - LEXTER-D110
  - LEXTER-D111
  - LEXTER-D112
  - LEXTER-D117
  - LEXTER-D118
  - LEXTER-D119
  - LEXTER-DRAFT-cell-model-revision-D21
  - LEXTER-DRAFT-cell-model-revision-D22
  - LEXTER-DRAFT-cell-model-revision-D23
  - LEXTER-DRAFT-cell-model-revision-D24
open-questions:
  - LEXTER-O56
  - LEXTER-O57
  - LEXTER-O58
  - LEXTER-O59
  - LEXTER-O60
  - LEXTER-O61
  - LEXTER-O62
  - LEXTER-O63
  - LEXTER-O64
  - LEXTER-O65
  - LEXTER-O66
  - LEXTER-O67
  - LEXTER-O68
  - LEXTER-O79
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

### LEXTER-D96 — The plan covers the cell model, and the other fixes have their own plan

**Status:** Accepted

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
(LEXTER-O66).

**Alternatives:**
- One plan for the whole sequence. Rejected: the other fixes are independent
  of the cell format and can proceed in parallel, and a plan named for the
  cell model would hide them.

### LEXTER-D97 — The first edition is repaired in full before the second edition begins

**Status:** Accepted

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

### LEXTER-D98 — Wide pairs are kept by per-cell helpers, with a row check at the flush
**Status:** Accepted

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

Where the width comes from is amended by
LEXTER-D117: the handler asks Lexter's width table,
not the atlas, and the atlas fits its glyphs to the width. The rest of this
decision stands.

**Alternatives:**
- Helpers alone. Rejected: every future operation must remember them, and
  the critique showed that one writer keeping a rule does not stop others
  breaking it.
- The row check alone. Rejected: it repairs states after the fact and cannot
  give the exact behaviour of a terminal, which blanks the other half of a
  pair when one half is overwritten.

### LEXTER-D99 — Each swatch table owns a range of one GPU swatch store

**Status:** Accepted

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
belongs to, is LEXTER-O59. A table that changes other
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

### LEXTER-D100 — Ranges arrive in the first edition, and screens store global indices

**Status:** Accepted

**Context:** Swatch ownership is a precondition of everything after it in
this plan. The dense record copies rows and uploads dirty rows, which needs
swatch indices that mean the same wherever they are copied and upload
records that name their source; the record cannot supply either, which is
why the layer-mechanics survey puts swatch ownership before the dense design
rather than after it. The overlay list takes its colours from tables'
ranges, and eviction works within a range. Both editions draw one composed
grid (LEXTER-D107), into which every pane's cells
are copied.

**Decision:** Build the swatch ranges on the first edition. A screen's table
hands out global indices, its range's base plus the local number, and the
screen stores those in its cells, so the flush copies a cell's swatch index
unchanged and the shader reads swatches from the texture buffer. In the
second edition the same indices sit in the record, and composing a pane into
the grid is a plain copy of row segments. Because cells hold absolute
indices, moving a range would mean rewriting a screen's cells and
scrollback, so ranges are fixed in place
(LEXTER-O58).

**Alternatives:**
- Store local indices and translate them in the flush, adding each table's
  base as cells are written. Rejected: the copy is no longer plain, every
  copy path and kernel must add the base, and it gains only the freedom to
  move ranges, which fixed ranges do not need.
- Wait for the dense model and build the ranges into it. Rejected: the
  dense model depends on the ranges, not the other way round, and the swatch
  faults are high in severity and do not depend on the cell format.

### LEXTER-D101 — The first edition's cursor exchanges slots instead of interning a reversed swatch

**Status:** Accepted

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
  LEXTER-O27, which LEXTER-D97 repairs.

### LEXTER-D102 — The dense record is the one the cell-model architecture specifies

**Status:** Accepted

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
  format, and the drawing flags, wide and blink, sit at fixed places
  (LEXTER-D81, LEXTER-D82, LEXTER-D94); the
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

### LEXTER-D103 — The second edition stores a double-width glyph as two halves

**Status:** Accepted

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

### LEXTER-D104 — One descriptor defines the record for Lisp and the shader

**Status:** Accepted

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

### LEXTER-D105 — Cursors and moving glyphs are drawn from an overlay list

**Status:** Accepted

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
- Cursor bits in the record's header. Rejected for every style: the block
  cursor, too, is an overlay, a transformed copy of the cell beneath it, as
  the resolution of LEXTER-O60 records.

### LEXTER-D106 — Every repaired finding gets a headless regression test

**Status:** Accepted

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
headless suite. The suite's form is given by
LEXTER-DRAFT-cell-model-revision-D21.

**Alternatives:**
- Screenshot fixtures alone. Rejected: they need a display, and cannot see
  stale state that a capture happens not to show.

### LEXTER-D107 — One composed grid holds every text pane and its chrome

**Status:** Accepted

**Context:** LEXTER-O56 asked whether the second
edition draws a grid per pane or one composed grid. A grid per pane needs no
copy and lets panes differ in font, cell size, pixel offset, and effect, and
overlap with transparency; but it costs a draw and an upload record per pane,
needs a separate grid for the decorations in the space between panes, and
breaks the idea that the window is one grid of characters. The case against
a composed grid was translating each pane's swatch indices as it is copied,
which global indices (LEXTER-D100) remove. The
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
  reasons LEXTER-D100 gives.

### LEXTER-D108 — Phase 3's tests also check a checksum of the normalised record array

**Status:** Accepted

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
LEXTER-D106 cover.

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

### LEXTER-D109 — Palettes and swatches are stored as integers in texture buffers

**Status:** Accepted

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
  (LEXTER-D111) reads the values the GPU reads.
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
  LEXTER-D110, and the buffer holds four palettes.
- Pack four colours into each `uvec4` of the existing uniform buffer, for 16
  palettes in 16 KB. Not chosen: it keeps a second kind of colour store
  beside the swatch texture buffer, and a smaller one.
- A 1D RGBA8 texture of palettes, LEXTER-D16's Option B. Rejected: OpenGL 3.3
  guarantees a 1D texture only 1024 texels, which is four palettes.

### LEXTER-D110 — The shaders select one palette entry for each pixel, without blending

**Status:** Accepted

**Context:** Every pixel of a glyph or mask in Lexter is inked or not; quads
are placed on whole pixels and textures sampled at the nearest texel at
integer scale. The room left for implementations to differ is arithmetic on
colours: converting floats to bytes, and blending. The Dense Cell Model
plan had first planned to composite layers with premultiplied colour. A pixel
checksum that holds across implementations, and the comparison of the GPU
with the CPU renderer (LEXTER-D112), need every
implementation to write the same bytes.

**Decision:** From Phase 3, the grid's shader decides for each pixel, by the
procedure of the cell-model architecture (LEXTER-0016, Drawing a Pixel) with
integer tests, which layer is the topmost to cover it after its masks, or that
the cell's background slot shows. It reads that one palette entry from the
integer store (LEXTER-D109) and writes it divided by
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

### LEXTER-D111 — A renderer on the CPU draws grids as the GPU does

**Status:** Accepted

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
  LEXTER-D108 separates from the texture, or a
  font's own bitmaps, so that each entry may have its own font and cell size.
- **The same rules.** It follows the architecture's procedure for drawing a
  pixel (LEXTER-0016, Drawing a Pixel), with the integer stores of
  LEXTER-D109 and the selection of
  LEXTER-D110, and reads records through accessors
  generated from LEXTER-D104's descriptor. For a grid
  and its overlays it produces exactly the GPU's pixels.
- **Exclusions at first.** Surfaces and effects, which are left to a later
  survey (LEXTER-D107). A cell of a format it does
  not draw is drawn blank, in its background slot, as both renderers do
  (LEXTER-D82).
- **Uses.** It is the second renderer against which the GPU is tested
  (LEXTER-D112). Its first use outside the tests is
  the font selector: a popup window with its own rendering pipeline,
  bypassing the OpenGL window of Lexter's main display, which shows many
  fonts at once as many small grids. The font selector is designed in a
  survey of its own.
- **Threads.** Whether it draws with more than one thread is
  LEXTER-O67.

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

### LEXTER-D112 — Pixel checksums are produced by both renderers and compared

**Status:** Accepted

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
  renderer (LEXTER-D111), in the headless suite,
  and by the GPU on the pinned llvmpipe. Each produces a pixel checksum, and
  the test requires both to equal the fixture's literal. When the two
  differ, the test compares their images and reports the first cell in
  which they differ.
- **Carried over.** If the shaders are exact
  (LEXTER-D110), the CPU renderer reproduces the
  checksums authored in Phase 3 without re-authoring them; a fixture it does
  not reproduce marks a disagreement to be fixed.
- **Real GPUs.** A real GPU may run the same comparison, as a check of its
  driver, but no fixture is authored on one.

With the cell checksum of LEXTER-D108, the checks
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

### LEXTER-D117 — A character's width is decided by the path that writes it, once, and stored

**Status:** Proposed

**Context:** LEXTER-D98 has the VT handler ask the atlas whether a glyph is
wide (`src/atlas.lisp:atlas-glyph-wide-p@2d4d743`), and the atlas's wide set
is built from whether a glyph's bitmap is wider than the cell
(`src/pcf.lisp:%parse-bitmaps@2d4d743`, as
[LEXTER-0007](Log.EnhancedDualWidth.md) describes). A program on the other
end of a byte stream, such as a shell, readline, ncurses, or an editor,
decides each character's width itself, from the Unicode tables of its own C
library, and moves the cursor by its count. When the terminal disagrees,
every later character on the line lands out of place until the next absolute
cursor movement; a multiplexer, such as tmux, keeps a grid of its own with
its own widths, and a remote host uses that machine's tables. Every terminal
in the prior-art evaluation decides width from Unicode's data
([LEXTER-0018](Eval.CellModels.PriorArt.md), R4). Lexter's own writers,
such as chrome, decorators, function panes, and Common Lisp applications that
write cells through the API, have no program at the other end that counts
columns, and the steward wants Lexter to be free to draw some characters
wide that Unicode makes narrow. A glyph's bitmap and its character's width
can differ in either direction, and the left half of a wide glyph can read
as another character: the left half of 好 is 女.

**Decision:** The path by which a cell is written decides its character's
width.

Table: Who decides a character's width, by the path that writes it.

| Path | Width decided by |
|---|---|
| The VT parser: shells, telnet, SSH, bulletin boards | Lexter's width table |
| The API: chrome, decorators, function panes, Common Lisp applications | The caller, by default the natural width of the glyph of the first font in the chain that covers the codepoint |
| The 3270 data stream | The data stream: one buffer address is one cell, and a double-byte character, where supported, takes two |

- **The path, not the owner.** A Common Lisp program that sends escape
  sequences into a VT pane writes through the parser, so the width table
  decides its widths.
- **The width table** is generated from one version of Unicode's data, the
  East Asian Width property and emoji presentation, and is kept apart from
  the atlas, with no GL, so that the handler and headless replays need no
  font. The configuration may make characters of ambiguous width wide, and
  override the width of single codepoints or ranges; a user who does so
  makes the same setting in the programs that run in the terminal. The table
  gives width 0 to combining marks and other zero-width characters, which
  join the cell of the character before them
  (LEXTER-D119). The widths of grapheme clusters, as
  mode 2027 asks, are a later addition to the table.
- **Decided once, and stored.** A character's width is decided when its cell
  is written, and stored: in the record's halves
  (LEXTER-D103) and in the text grid's wide bit
  (LEXTER-D119). Copying, selection, cursor
  movement, and reflow read the stored width and never decide it again, so
  content written under different rules keeps its widths.
- **The atlas fits glyphs to widths.** Atlas entries are keyed by codepoint
  and width, and the fitting is done when the atlas is built, from the width
  table, so that it is deterministic for the cell checksum
  (LEXTER-D108); changing the width configuration rebuilds the atlas, as
  changing a font does. For a codepoint, the first font in the chain whose
  glyph has the width is chosen; when none has, the first font that covers
  the codepoint is chosen, and its glyph is fitted:
  - *A narrow glyph at width 2* is placed in a wide entry, centred, at
    column ⌊*w* / 2⌋, where *w* is the cell's width.
  - *A wide glyph at width 1* has its inked columns measured. When they fit
    in *w* columns, the narrow entry is the window of *w* columns that holds
    all of the ink, centred on it: the window begins at
    ⌊(*lo* + *hi* + 1 − *w*) / 2⌋, where *lo* and *hi* are the first and last
    inked columns, and a glyph with no ink takes the middle window. Nothing
    is lost, so the narrow glyph is exact; a letter that a CJK font centres
    in a wide box is drawn whole. When the ink is wider than *w* columns,
    the cell draws the replacement glyph, generated glyph 5
    (LEXTER-D89), so that no fragment of a glyph is shown
    as though it were a character.

This decision settles LEXTER-O79 and amends
LEXTER-D98, whose handler now asks the width table.
The width table, and the fitting, arrive with Phase 1, whose repair of the
handler's wide writes (LEXTER-O19) uses them.

**Alternatives:**
- Width from the atlas for every path, as LEXTER-D98
  had it and as the steward first leaned. Rejected: programs on a byte stream
  count columns themselves, so the line drifts wherever the font and Unicode
  differ; the font's coverage would decide widths by accident; and the
  handler would need a loaded font.
- Unicode's table for every path. Rejected: Lexter's own writers have no
  program to agree with, and should be free to draw a glyph at its own width.
- Clipping a wide glyph to its left half, which needs no atlas entry of its
  own. Rejected: the left half of an ideograph can read as another
  character; a letter centred in a wide box is cut in two; and a vertical
  box-drawing stroke at the middle of the glyph may fall at the cut.
- A fixed centre crop, the middle *w* columns. Not chosen: ink that is not
  centred is cut, and ink wider than the cell is still shown as a fragment
  that misleads.
- The replacement glyph for every wide glyph at width 1. Not chosen: it
  hides glyphs that a crop draws exactly.
- Deciding width again whenever it is read. Rejected: content written by one
  path would be read under another's rule.

### LEXTER-D118 — History keeps text and styles, and records exist only for the rows on screen

**Status:** Proposed

**Context:** Phase 3 kept scrollback as rows of records. At 32 bytes a cell,
100,000 lines of 200 columns are about 640 MB; Ghostty compresses pages of
history, VTE freezes rows into compressed streams on disk, and WezTerm keeps
text with runs of attributes
([LEXTER-0018](Eval.CellModels.PriorArt.md), Synthesis). Layers, masks,
and tiles are meant for interfaces drawn on screen, such as the chrome around
terminals and the TUIs of applications, and the terminal path writes only
text with SGR attributes. The cell-model architecture models what is drawn,
not what is remembered ([LEXTER-0016](Arch.CellModel.md), Thesis).

**Decision:** The cell model models the content on screen. A row that leaves
a screen's top is kept in its history as text and styles.

- **A history cell** holds its characters as the text grid does, with its
  wide bit, and a style id (LEXTER-D119). The cells
  that continue a character are dropped, since history's rows never change
  and are read from left to right. Each history row keeps its terminal row,
  so that soft wraps and prompt marks survive.
- **A style** is interned in a table of the terminal's, and holds the SGR
  attributes that the handler records: the foreground, the background, and
  the SGR 58 underline colour, each a colour that is the default, a palette
  index, or a 24-bit RGB value; and bold, the lines and their style, reverse
  video, blink, and invisible. Room for 24-bit colour is there from the start,
  though Phase 3 writes only palette colours, so that history keeps truecolour
  once the inline-colour format writes it (see Later Formats).
- **From the screen to history.** Each character's cell in the screen's
  text grid already holds its style id
  (LEXTER-D119), so a row that leaves the screen is
  moved into history by copying its text, wide bits, style ids, and terminal
  row; nothing is read back from its records. A record cannot give back what
  a style holds: bold is a choice of glyph, which the record does not mark
  (LEXTER-D116 in [LEXTER-0016](Arch.CellModel.md)); an
  invisible cell has no glyphs, as a blank one has; and reverse video is only
  a pair of exchanged slots. Layers, masks, and tiles beyond what a style
  holds are not kept.
- **From a style to a record.** Viewing history rebuilds the rows shown with
  the function by which the handler writes a cell, so that one function makes
  records from text and styles wherever they come from. The pane-profiles
  plan draws the history in `flush-to-display`
  (LEXTER-DRAFT-pane-profiles-D5), and in the second edition its viewport
  builds the history rows it shows with this function. That plan's history
  cells of glyph, swatch, and attributes, and the lossy history and shared
  swatch problem its tensions list
  ([LEXTER-DRAFT-pane-profiles](Plan.PaneProfiles.md), Scrollback Viewing),
  belong to the first edition; this decision replaces them.
- **Swatches in use.** History holds palette indices, not swatch indices, so
  only the cells on screen keep swatches in use, and eviction (Phase 7) marks
  only them. A palette changed by OSC 4 recolours the history, as it does in
  xterm.
- **Reflow** rebuilds lines from the text and the soft wraps of the terminal
  rows, with the stored widths
  (LEXTER-D117).
- **Rich scrollback,** rows kept as records while a program's interface asks
  for it, is a candidate for the host protocol
  (LEXTER-O76), and is not the default.
- **Packing.** How history's rows are packed in memory, as runs of styles or
  as compressed pages, is not decided here.

Whether a screen stores records for its rows on screen remains
LEXTER-O57. This decision replaces Phase 3's scrollback of records.

**Alternatives:**
- Rows of records, as Phase 3 had them. Rejected: they cost a record for
  every cell of history, to keep graphics that are seldom scrolled back to.
- Records in compressed pages, as Ghostty keeps its history. Not chosen: it
  keeps the cost of what history does not need, and compression can be added
  over text and styles later.
- Styles read back from the records as a row leaves the screen. Rejected:
  bold, invisible text, and reverse video cannot be recovered from a record,
  so the screen's text grid keeps each cell's style id instead.
- Styles that hold palette indices only. Rejected: history would lose
  truecolour even after the inline-colour format arrives, and the style
  format would have to change.
- History in a file on disk, as VTE keeps it. Not chosen now; it may follow,
  under the packing left open above.

### LEXTER-D119 — The text grid marks every cell a character covers, and a terminal row lies beside it

**Status:** Proposed

**Context:** The characters each cell shows are kept apart from the record,
in a text grid whose form is LEXTER-O63. The first
edition marks only the left half of a double-width character and implies the
right half, and the operations that move or clear cells break such pairs
(LEXTER-O26). An operation can begin at the
right half without having read the left: a selection or a click, the cursor,
an erase or an overwrite of that cell alone, the edge of a scroll region. On a
DEC double-width line a narrow character also covers two cells, which has
nothing to do with its width. The prior-art evaluation found that every
terminal it surveyed except Alacritty keeps something for each row: soft
wraps, OSC 133 prompt marks, and in xterm and WezTerm the DEC line
attributes ([LEXTER-0018](Eval.CellModels.PriorArt.md), Synthesis);
the first edition keeps none of them.

**Decision:**

- **The character's cell** in the screen's text grid holds its codepoints, a
  wide bit, the width that the writing path decided
  (LEXTER-D117), and a style id, naming the style
  in which the terminal wrote it (LEXTER-D118).
  Attribute reports, copying with formatting, and the move of a row into
  history read a cell's attributes from its style, not from its record.
- **Zero-width characters,** such as combining marks, the zero-width joiner,
  and variation selectors, to which the width table gives width 0, are added
  to the codepoints of the cell of the character before them. How they are
  drawn, as a layer, as a mask, or not at all, is open
  (LEXTER-O63; for hosts, LEXTER-O74).
- **Every other cell the character covers** holds a continuation marker, a
  value beyond Unicode, distinct from the names of generated glyphs at
  0x110000 and above (LEXTER-D89). The columns a
  character spans are one more than the continuations after it: two for a
  wide character, two for a narrow one on a double-width line, and four for a
  wide one on a double-width line. A double-height line is two rows, each
  holding the characters, as the host sends them. Every cell describes
  itself, and writers write and erase all of a character's cells together,
  as they do the halves of a record.
- **History** keeps the wide bit and drops the continuations
  (LEXTER-D118).
- **The terminal row.** Beside the text grid, each row of a screen and of its
  history has a terminal row:

Table: The fields of a terminal row.

| Field | Bits | Values and use |
|---|---|---|
| Soft wrap | 1 | 1 = the row's text continues on the next row because autowrap carried it there; read by reflow, copying, selection, and search |
| Prompt kind | 2 | 0 none, 1 prompt, 2 input, 3 output: the OSC 133 zone at the row's start, for moving between prompts and selecting a command's output |
| Line size | 2 | 0 single, 1 double width, 2 the top of double height, 3 the bottom: the DEC line attribute, by which the writer limits the cursor to half the columns and sets the cells' line-size flags |

- **Not drawn.** Renderers never read the terminal row. The writer turns its
  line size into the records' line-size flags
  (LEXTER-D114 in [LEXTER-0016](Arch.CellModel.md)), so that
  a pane's double-size lines survive composition into the shared grid, and
  the grid's own rows carry only what renderers read
  (LEXTER-D113).
- **Left for later.** Which operations clear the soft wrap follows xterm's
  behaviour, settled in Phase 3. The exit codes that OSC 133 reports, and a
  list of commands, may be kept in a table beside the rows.

This decision settles part of LEXTER-O63; how the
text grid holds codepoints and grapheme clusters remains open.

**Alternatives:**
- A wide bit on the left cell alone, with the right cell implied. Rejected
  for the screen: it is the arrangement whose pairs the first edition breaks,
  and an operation that begins at the right cell cannot tell what it is. Kept
  for history, whose rows never change.
- Width taken from the records' wide bits on screen. Not chosen: the text
  grid must stand alone in history, where there are no records, and the cells
  a character covers on a double-size line are not its width.
- Line size as an attribute of the composed grid's rows. Rejected in the
  architecture (LEXTER-D114): one row of the grid holds
  several panes.
- OSC 133 zones for each cell, as WezTerm keeps them. Not chosen: a zone for
  each row serves moving between prompts and selecting output; zones for
  cells can be added if they prove needed.

### LEXTER-DRAFT-cell-model-revision-D21 — The regression suite follows Square, and stays red until each fix lands

**Status:** Proposed

**Context:** LEXTER-D106 asks for a headless test system written with FiveAM
and cl-hamcrest, as the Origin tests are; that pair is the stack of the
Square testing standard, which fixes a test system's package, suites,
runners, and `test-op`. Lexter has two test systems: `lexter/mouse-tests`
defines its own `check` macro (`tests/mouse-tests.lisp`), which Square does
not admit, and `lexter/origin-tests` is written with FiveAM and cl-hamcrest
but has a package and root suite of its own
(`tests/origin-impulse-tests.lisp`). FiveAM has no mark
for a test expected to fail, and a test that reproduces a finding fails
until the finding is repaired.

**Decision:**

- **Square.** The suite conforms to the Square standard: the system
  `lexter/tests`, defined in `lexter.asd`, with its files in `tests/`; the
  package `lexter-tests`; a root suite `lexter` with a child suite for each
  subsystem, beginning with `atlas`, `handler`, `model`, `grid`, and
  `swatches`, to which the terminal-fixes plan's tests add theirs
  (LEXTER-D80); and the main system's `test-op` runs it. The Square block of
  `AGENTS.md` names the standard for later sessions.
- **Red until fixed.** A test that reproduces a finding asserts the
  behaviour the repair gives, names the finding in its docstring, and fails
  until the repair lands; the suite stays red until every such test passes.
  The first edition's internals that a test must inspect are named as
  LEXTER-D106 allows, and such tests are rewritten in Phase 3.
- **Structural tests.** Findings about how the code is arranged rather than
  how it behaves, constants defined more than once
  (LEXTER-O36) and dirty bits that nothing reads
  (LEXTER-O40), are tested structurally: for example,
  that the model, the grid, and the renderer share one definition of a
  constant.
- **Fonts made in the tests.** Tests build their fonts in memory, so that no
  font file is needed and every packing is the same on every machine.
- **The existing tests.** `lexter/mouse-tests` and `lexter/origin-tests` are
  left as they are, and move into `lexter/tests` in a later step: the mouse
  tests converted from their `check` macro to FiveAM and cl-hamcrest, and the
  Origin tests given a child suite of the root.

**Alternatives:**
- A suite of FiveAM tests outside Square's shape. Not chosen: Square gives
  the suite a form that its skills can write, run, and review.
- Reproduction tests kept apart in a suite of known faults, outside the
  default run, until each is repaired. Not chosen by the steward: a red suite
  shows plainly what remains to be repaired.
- Tests that assert today's faulty behaviour, inverted when the repair
  lands. Rejected: each repair would rewrite its test, and the test would not
  state what is wanted.
- Moving the existing tests into the suite now. Not chosen: it is not needed
  to begin the repairs, and can be done at any time.

### LEXTER-DRAFT-cell-model-revision-D22 — The atlas's packing is separated from its upload in Phase 0, with a column count the caller fixes

**Status:** Proposed

**Context:** LEXTER-D108 separates the atlas's packing from the upload of
its texture, and fixes its column count from the fixture's configuration, so
that the cell checksum needs no display; it places that change in Phase 3.
`build-atlas` queries `GL_MAX_TEXTURE_SIZE` and uploads a texture
(`src/atlas.lisp:build-atlas@2d4d743`), and `add-cursor-glyphs` uploads it
again (`src/atlas.lisp:add-cursor-glyphs@2d4d743`), so no test can build an
atlas without a GL context. The critique worked around this with an atlas
struct built by hand ([LEXTER-0014](Eval.Critique.DataStructures1e.md),
Method). The tests of Phase 1's findings, and of the width fitting of
LEXTER-D117, need atlases packed from fonts.

**Decision:** Phase 0 makes this part of LEXTER-D108.

- **`pack-atlas`** assigns each glyph its position and keeps its pixels,
  with no GL, and takes its column count from its caller.
- **`upload-atlas`** creates the texture from a packed atlas.
- **`build-atlas`** packs and uploads, choosing its column count from the
  GPU's maximum texture size unless it is given one, as it does now.
- **`add-cursor-glyphs`** adds its glyphs to the packing, and rebuilds the
  texture only when the atlas has been uploaded.

The change is a refactoring: positions, pixels, and the test rig's pixel
checksums do not change, which the rig's fixtures confirm when replayed on a
display. The rest of LEXTER-D108 stays in Phase 3.

**Alternatives:**
- An atlas struct built by hand in each test, as the critique did. Rejected:
  the tests would not exercise the packing that Phase 1 changes, and every
  change to the struct would break them.
- The split in Phase 1, with the repairs. Not chosen by the steward: the
  reproduction tests come first, and need it.

### LEXTER-DRAFT-cell-model-revision-D23 — Phase 1 takes widths from Unicode 17.0, draws a "no glyph" glyph for an uncovered codepoint, and drops zero-width characters

**Status:** Proposed

**Context:** LEXTER-D117 has the VT handler take widths from a table
generated from one version of Unicode's data, without naming the version.
The C library's tables that programs use, and those of the terminals in the
prior-art evaluation, are generated from recent versions: kitty's and
Alacritty's from Unicode 17.0
([LEXTER-0018](Eval.CellModels.PriorArt.md), R4). SBCL's own
`sb-unicode:east-asian-width` is older: under SBCL 2.3.4 it reports U+1FAE8,
added in Unicode 15.0, as narrow, and its version follows SBCL's. Today the
handler skips a codepoint that no font covers without moving the cursor
(`src/vt-handler.lisp:%print-codepoint@2d4d743`), so the program and the
terminal disagree from that column on. The first edition has no text grid,
so a zero-width character has no cell to join
(LEXTER-D119).

**Decision:**

- **Unicode 17.0.** The width table is generated from the data files of
  Unicode 17.0: East Asian Width, emoji presentation, and the general
  categories that make a character zero-width. The generator and the files'
  version are kept with the table, and moving to another version is a
  deliberate step.
- **A codepoint that no font covers** is written at its width from the
  table, and moves the cursor by that width, like any other. Its cell draws
  the "no glyph" glyph, generated glyph 6
  (LEXTER-D89), narrow, in each cell of a wide
  character. The text grid of Phase 3 keeps its codepoint, so that it is
  copied as written.
- **Zero-width characters** are dropped, and do not move the cursor, until
  the text grid of Phase 3 gives them a cell to join; how they are then drawn
  is LEXTER-O63.

**Alternatives:**
- SBCL's `sb-unicode`. Rejected: it is older than Unicode 15.0 in the SBCL
  in use, and its version would change with SBCL's.
- Skipping an uncovered codepoint, as now. Rejected: the cursor would no
  longer follow the program's count.
- Blank cells for an uncovered codepoint. Not chosen: the user could not
  tell a missing glyph from a space.
- The replacement glyph for an uncovered codepoint. Not chosen: it marks a
  glyph too wide for its cell, which is another fault, and the two should be
  told apart.
- Each zero-width character as a cell of its own, as some are now. Rejected:
  it moves every later character on the line out of place.

### LEXTER-DRAFT-cell-model-revision-D24 — Tables take ranges of 2048 swatches as they grow, and the display has a table of its own

**Status:** Proposed

**Context:** LEXTER-D99 gives each swatch table a range of one GPU store, and
LEXTER-D100 has screens store global indices, so a range cannot move once its
indices are in cells. How ranges are sized, how many a table may take, and
what a full table does were LEXTER-O58; which table holds the swatches of
writers without a screen of their own was LEXTER-O59. Until Phase 3 only the
store's first 32,768 entries are usable, because the first edition's
instances carry the wide flag in bit 15 of their swatch field. Today chrome,
decorators, and workspace clears write swatch indices into the grid
directly, the 3270 pane keeps a global cache of swatches it sets on the grid,
and a terminal's alternate screen has a table of its own.

**Decision:**

- **Ranges of 2048 swatches.** The store is divided into ranges of 2048
  entries: 16 in Phase 2, 32 once Phase 3 opens the whole store of 65,536. A
  table takes one range when it is made, and another when it fills, so most
  tables hold one range and some hold several, not necessarily adjacent. A
  table's local number N is held in its range N / 2048, at offset N mod 2048,
  and the global index it hands out is that range's base plus the offset.
  Ranges never move.
- **Four ranges at most** for one table, 8192 swatches, so that a pane drawing
  many colours cannot take the whole store from the others. The limit may be
  raised when Phase 3 doubles the store.
- **A full table** — one at its limit, or one that needs a range when none is
  free — interns no new swatch: it returns its existing swatch whose colours
  are nearest, by the distance between the RGB values of their slots in the
  palette they are drawn in. Drawing never fails, and colours degrade only
  when the store is exhausted. Whether eviction (Phase 7) is added remains
  open.
- **Release.** A table's ranges return to the free list when its terminal goes
  away, because its pane is destroyed or `terminal-reset` replaces its
  screens.
- **One table for a terminal's two screens.** The primary and alternate
  screens share a table, as they share palette changes, so a full-screen
  program takes no range of its own and colours keep their indices across the
  switch.
- **The display's table.** The compositor owns one table for everything drawn
  at the level of Lexter's display rather than of a pane: chrome, decorators,
  workspace clears, and the demo. It takes the first range, so global swatch 0
  is its local 0, the default colours, which the allocator reserves
  (LEXTER-D83). The 3270 pane is a pane, and its cache becomes a table of its
  own; an overlay that belongs to a pane takes its colours from the pane's
  table.

**Alternatives:**
- Fixed ranges, one per table. Not chosen: a table that outgrows one range has
  nowhere to go, and a large fixed range wastes the store on tables that need
  little.
- Ranges relocated as tables grow. Rejected: screens store global indices, so
  moving a range would mean rewriting a screen's cells.
- No limit on a table's ranges. Not chosen: one pane could exhaust the store.
- Falling back to the table's default swatch. Not chosen: text written after
  the store fills would lose its colours entirely.
- Eviction in Phase 2. Not chosen: it is Phase 7's, and the fallback keeps
  drawing correct until then.
- A table for each screen, the alternate included. Not chosen: it spends a
  second range for each full-screen program.
- Chrome in the table of the pane it borders. Not chosen: chrome and the
  workspace belong to the display, and some of it borders no pane.

## The First Edition Repaired

Phase 1 repairs the present structures in place
(LEXTER-D97).

Table: First-edition repairs by finding.

| Finding | Repair |
|---|---|
| LEXTER-O19 | The VT handler decides each character's width from the width table of Unicode 17.0, writes pairs, and advances by two, also for a codepoint no font covers, and drops zero-width characters; the atlas fits its glyphs to the table's widths; the flush writes each pair once; the cursor keeps the wide flag (LEXTER-D98, LEXTER-D117, LEXTER-D101) |
| LEXTER-O26 | Per-cell helpers in every row and range operation, edge repair, `resize-grid` copying both flag vectors, and the row check (LEXTER-D98) |
| LEXTER-O27 | The flush writes a layered cell's whole record, empty layers included; `write-char-at` on a layered cell honours its swatch and attributes; the cursor no longer rewrites the cell (LEXTER-D101) |
| LEXTER-O28 | Atlas positions 0–63 are reserved at build time, position 0 for an empty glyph and the rest for generated glyphs, which the atlas names from 0x110000 instead of private-use codepoints, so the cursor glyphs move to positions 1–4, the outlined block added beside the three of today, position 5 holds the replacement glyph of width fitting (LEXTER-D117), and position 6 the "no glyph" glyph for a codepoint no font covers (LEXTER-DRAFT-cell-model-revision-D23), with 7 reserved (LEXTER-D89); every writer takes its blank from the atlas instead of writing codepoint 32 |
| LEXTER-O36 | One home for the cell constants that the model, grid, and renderer share, one `+layered-stride+`, one default palette, one `setup-default-swatches`, and one name for each layer slot |
| LEXTER-O40 | The grid's description is made true: `build-render-data` loses the unused `force-full` and its claim of incremental rebuilds, and the dirty bits stay for the second edition to upload by |
| Review: the cursor writes into the model during the flush | The cursor exchanges slots (LEXTER-D101) |

The repair of LEXTER-O40 makes the first
edition honest rather than incremental. Rebuilding only dirty rows would need
instances laid out by row, which the first edition's compact packing does not
have and the second edition provides.

## Swatch Ranges

Phase 2 builds the ranges of LEXTER-D99 on the first
edition, as LEXTER-D100 describes.

- **The check of cl-opengl.** The phase begins by confirming that cl-opengl
  can create and fill an `RGBA8UI` texture buffer that a shader reads through
  `usamplerBuffer` (LEXTER-D109).
- **The store.** The swatch texture becomes an `RGBA8UI` texture buffer read
  as a `usamplerBuffer`, core since OpenGL 3.1 and guaranteed at least 65,536
  texels in OpenGL 3.3.
- **Palettes.** The palette uniform buffer becomes an `RGBA8UI` texture
  buffer of 256 texels for each slot, and the model keeps palette entries as
  bytes (LEXTER-D109). The configuration sets how
  many slots the store holds, 128 by default (LEXTER-D92). The first
  edition still chooses a slot for each draw; allocating slots to terminals
  waits for the record's palette slot in Phase 3.
- **Ranges.** An allocator hands each table a range of 2048 swatches when it
  is made, and another when it fills, up to four, and takes them back when
  its terminal goes away, because its pane is destroyed or `terminal-reset`
  replaces its screens. A terminal's two screens share one table, and a full
  table returns its nearest existing swatch
  (LEXTER-DRAFT-cell-model-revision-D24).
- **Defaults at zero.** Global swatch 0 and palette slot 0 always hold valid
  default colours, so that a record of zeros in the second edition is a
  blank cell (LEXTER-D83); the allocator reserves global swatch 0 by giving
  the display's table the first range
  (LEXTER-DRAFT-cell-model-revision-D24).
- **Writers.** The 3270 pane's global cache becomes a table of its own;
  chrome, decorators, workspace clears, and the demo intern into the
  display's table (LEXTER-DRAFT-cell-model-revision-D24).
- **Uploads.** The renderer records, for each range, the table it uploaded
  and the count, and uploads the new tail of a table that has grown, or the
  whole range for a table that is new or has bumped its version.
- **Global indices.** A table hands out global indices, its range's base
  plus the local number, and screens store them, so the flush copies each
  swatch index unchanged (LEXTER-D100).
- **The wide bit.** The first edition's instances carry the wide flag in bit
  15 of their swatch field (`src/grid.lisp:build-render-data@2d4d743`), so a
  global index must stay below 32,768. Until Phase 3 gives the swatch
  index 16 bits and the wide flag a bit of its own, the allocator uses only
  the store's first 32,768 entries, 16 ranges. Moving the flag into the instance's
  padding bytes would lift the limit sooner, at the cost of changing the
  first edition's shaders and attribute setup once more.
- **Room for swatch reindexing.** Shifting a range of swatches on a clock,
  as the host-protocol survey proposes (LEXTER-O73), is
  designed after the cell model. Three things built from this phase on keep
  it possible:
  - *One swatch fetch.* Each renderer looks up swatches in one place: the
    first edition's shader, and in Phases 3 and 5 one function, generated
    from the descriptor (LEXTER-D104), through which glyph layers and tiles
    alike read swatches, so that a remap is added once.
  - *Entries outside interning.* A table can append swatches that its
    interner never matches, and nothing assumes that every entry is in its
    lookup map; eviction (Phase 7) leaves such entries alone.
  - *Bits left unspent.* Bit 31 of a tile cell's header word and the glyph
    formats' colour parameters are not spent without asking whether
    reindexing needs them, in case a cell must opt in to it.

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
LEXTER-D102 decides. The architecture specifies the
record; the phase builds it in this order of concerns.

Table: What Phase 3 builds from the architecture.

| Part | What is built | Architecture |
|---|---|---|
| The record | The format word, the header word, and glyph words with their settings, generated from one descriptor | LEXTER-D81, LEXTER-D84, LEXTER-D87 |
| The plain format | The glyph count and type bits, layers interleaved with masks, each mask cutting the layers before it as far as its reach | LEXTER-D83, LEXTER-D85 |
| Backgrounds | The cell's background slot in place of fills; reverse video through the background slot, so the handler no longer interns a reversed swatch | LEXTER-D86, LEXTER-D90 |
| Lines | The single underline as a generated glyph, the text's last mask in its colour; the handler already records it, though the first edition never draws it. The other line styles are Later Formats | LEXTER-D88, LEXTER-D89 |
| Invisible and blinking text | An invisible cell (SGR 8) is written with a glyph count of 0, its characters kept in the text grid. A blinking cell (SGR 5) carries the blink flag, and both renderers hide its topmost layer, the text, while the blink phase is off; the phase is set by the configuration and shares the cursor's clock, and nothing in the record changes as the cell blinks | LEXTER-D83, LEXTER-D94 |
| Palette slots | An allocator that gives each terminal a palette slot and records each upload by owner, replacing slots chosen by hand and generations compared by slot | LEXTER-D92 |
| The shader | The procedure of Drawing a Pixel, with selection and no blending | LEXTER-0016, Drawing a Pixel |

- **Swatch ownership comes first.** The phase begins only when Phase 2 is
  complete (see Swatch Ranges): the record holds swatch indices but cannot
  make them mean the same in every copy, nor tell the renderer where an upload
  came from.
- **The 3270 pane.** It keeps a screen of its own and writes the grid
  directly; whether it is rewritten to write records or keeps a path of its
  own is LEXTER-O66.
- **The grid's array is its upload buffer.** Cells are stored row by row, so
  each dirty row is one contiguous range, uploaded by itself. The renderer
  records which grid it uploaded, by an identity or an epoch from one global
  counter, and uploads the whole grid when the grid is replaced, the workspace
  changes, or the size changes.
- **One composed grid, one draw** (LEXTER-D107). The
  shader computes a cell's position from its instance number, and for each
  pixel selects the palette entry of the topmost layer that covers it after
  its masks, or the cell's background slot, writing it without blending
  (LEXTER-D110), so there are no passes per layer.
- **Halves.** Double-width glyphs are stored as halves
  (LEXTER-D103). How a mask applies to a half is
  LEXTER-O61.
- **Text beside the record.** The characters each cell shows are kept in a
  side array, not in the record, for selection, copying, search, and screen
  readers. The architecture leaves this text grid, like hyperlink ids and
  protected cells, to state that Lexter keeps apart from the cell model, and
  writers keep the two in step. Each character's cell holds its wide bit and
  style id, the other cells it covers hold continuation markers, and a terminal row of
  soft wrap, prompt kind, and line size lies beside each row
  (LEXTER-D119); how it holds codepoints and
  clusters is LEXTER-O63.
- **History as text and styles.** Rows that leave the screen are kept as
  text, wide bits, style ids, and terminal rows, with styles that can hold
  24-bit colour, and records are rebuilt only for the rows shown
  (LEXTER-D118).
- **Drawn rows.** Each grid keeps, beside its records, a change stamp and a
  clock mask for each row, as the architecture specifies
  (LEXTER-D113); uploads follow the change stamps.
- **The model's storage** is LEXTER-O57, settled
  before the phase begins. Panes are copied into the one composed grid by row
  segments (LEXTER-D107).
- **Kernels follow correctness.** Typed Lisp loops over the record come first;
  generated kernels, and where the grid lives in memory, are
  LEXTER-O65. Where the grid lives is settled before
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

Phase 4 adds the overlay list of LEXTER-D105, with
cursors as its first use.

- **A pass of its own.** One instanced draw after the grid, whose instances
  are records followed by a position and flags, decoded as the grid's records
  are (LEXTER-D93).
- **Positions in cells or pixels**, so an overlay can move smoothly and is not
  bound to the grid.
- **Colours** from the swatch table and range of the pane or chrome it
  belongs to, which Phase 2 provides (LEXTER-O59).
- **The block cursor** is a copy of the cell beneath it, with its background
  slot and its topmost layer's ink slot exchanged, in an instance that draws
  its background; the flush copies it again when the cursor moves or its row
  changes (LEXTER-D93). The underline and bar cursors, and a hyperlink lit
  by the pointer, are instances that do not draw their background.
- **Selection highlighting** is drawn by overlay instances over the selected
  cells, and costs no bits of the record (LEXTER-D115).
- **Redraw.** Moving, adding, removing, or animating an instance marks the
  rows under its old and new positions for redraw.
- **Time.** Animation reads a time uniform that the test rig can fix, and
  animates only the focused pane by default.

LEXTER-D101's exchanged slots are removed when the
overlay cursor arrives.

## The CPU Renderer

Phase 5 adds the CPU renderer of LEXTER-D111 and
the comparison of renderers of LEXTER-D112.

- **Glyphs without GL.** Glyph pixels come from the atlas's packing, which
  Phase 3 separates from its upload (LEXTER-D108),
  or from a font's bitmaps.
- **One rule, two implementations.** The record's accessors come from the
  descriptor (LEXTER-D104); the architecture's
  procedure for drawing a pixel (LEXTER-0016, Drawing a Pixel), with the
  selection of an entry (LEXTER-D110), is written
  once more in Lisp.
- **Overlays.** Each grid's overlay instances are drawn over it in list
  order, as the overlay pass draws them, at a time that the caller fixes, as
  the test rig fixes the time uniform.
- **Fixtures.** Every fixture's pixel checksum is checked against both
  renderers; the checksums authored on llvmpipe in Phase 3 carry over.
- **Surfaces and effects** are not drawn at first.
- **Threads** are LEXTER-O67; a renderer on one
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
| Inline colours (LEXTER-D82) | Nothing beyond Phase 5; the handler then writes inline-colour cells for truecolour SGR (38;2 and 48;2) instead of mapping them to the 256-colour palette |
| Strikethrough, overline, and coloured underlines (LEXTER-D88) | Nothing beyond Phase 5; the handler gains SGR 9 and 29, 53 and 55, and 58 and 59, and the model the attributes that hold them. A coloured underline is a layer beneath the text, as CSS paints underlines |
| Tiles and their texture, with flips, a top tile that may pass in front of the glyphs, and colour cycling by swatch pair on two clocks (LEXTER-D91, LEXTER-D95) | The cursor over a tile cell (LEXTER-O45), palette slots running out (LEXTER-O50), and the fitting of tile sets (LEXTER-O51) |
| Colour cycling in glyph cells | How a cell of four slots cycles its colours (LEXTER-O54) |
| Masks that cut a cell's tiles | The first tiles, and how masks reach into them (LEXTER-O55) |
| Swatch runs: tile cells that name their swatches by pair, and a glyph format of eight slots | The design of runs (LEXTER-O77); the glyph format also waits for glyph cycling (LEXTER-O54), whose bits it shares |
| The void and effects (LEXTER-D82) | The survey of surfaces and effects, and what they carry (LEXTER-O53) |
| Further underline styles (LEXTER-D89) | How their patterns meet from cell to cell (LEXTER-O48), and whether SGR 21, which the handler now reads as resetting bold, is the double underline that xterm and ECMA-48 make it |
| DEC double-size lines: the line-size flags in both renderers, and the handler's DECSWL, DECDWL, and DECDHL writing the terminal row's line size (LEXTER-D114, LEXTER-D119) | Nothing beyond Phase 5 |
| Bold glyphs from a bold font in the chain (LEXTER-D116) | Nothing beyond Phase 5; until then bold is drawn with the regular glyph, or as bright colour where the terminal is set so |

## Partial Redraw and Eviction

Phase 6, optional, redraws only the damaged rows, which are the dirty rows,
the rows that a clock changes, and the rows under changed overlays
(LEXTER-D113): rows by instance range, with the record's attribute pointers moved
to the first row, since OpenGL 3.3 has no base instance. It needs either the
offscreen target kept on, which overturns LEXTER-D39 and leaves one
full-window blit per presented frame, or the buffer-age extensions cited
above (LEXTER-O64).

Some cells change on screen with a clock, without any row becoming dirty:
blinking cells at each change of the blink phase
(LEXTER-D94), and tile cells whose colours cycle at each
step of the first or second cycle clock, which drive the swatch pairs A–B
and C–D (LEXTER-D95). So
each drawn row carries a clock mask (LEXTER-D113), of
three bits to begin with, one for each clock,
set when the row holds a cell that the clock changes, and redraws the rows
whose bit is set when that clock moves. The mask is not maintained by
writers: the renderer recomputes a row's bits whenever it uploads the row,
from the blink flags and cycle fields of its records, so it cannot drift from
the grid. The rows under the cursor, which shares the blink clock, are
marked as moving or animating an instance marks them. The mask is a set of
bits that can grow rather than three fixed ones: a clock that shifts a range
of swatches (LEXTER-O73) would add a bit, set for a row
that holds a swatch index in the range.

Phase 7, conditional, evicts unused swatches within a table's ranges, if the
steward chooses to add eviction to the fallback to the nearest swatch
(LEXTER-DRAFT-cell-model-revision-D24): mark the indices that a screen's cells still use, free the rest,
and bump the table's version. History holds palette indices, not swatch
indices (LEXTER-D118), so it need not be scanned.

## Tensions and Risks

- **Work the second edition discards.** Phase 1 repairs code that Phase 3
  replaces. LEXTER-D97 accepts that cost for correct
  text now and a sound baseline; the tests of
  LEXTER-D106 are what carries over.
- **Changed pixels.** Phase 3 changes how every cell is drawn, so every
  screenshot fixture's checksum changes and the fixtures are re-authored.
- **Alignment.** SBCL does not place grid-sized arrays on 32-byte boundaries;
  records laid from the start of an array split cache lines
  (LEXTER-O65).
- **Dependence on the other plans.** Phase 1 waits for the consolidation of
  the two terminal stacks (LEXTER-D67), so that its
  repairs land once. Dirty-row uploads would leave a stale workspace on screen
  until the workspace switch schedules a repaint
  (LEXTER-O32), which
  LEXTER-D71 fixes before Phase 3. The pane-profiles
  plan also changes `flush-to-display`, to draw the history; the steward has
  placed that change before Phase 1, so that Phase 1 repairs the flush as the
  history drawing leaves it.
- **A larger model.** A screen of 80×24 records is 61 KB, three times today's
  size; small, but it grows with every pane. History is kept as text and
  styles, not records (LEXTER-D118), so it does not
  grow with the record.
- **Two renderers to keep in step.** The descriptor generates both
  renderers' decoders, but the coverage rule and the selection of an entry
  are written twice, in GLSL and in Lisp, and every change to the record's
  drawing is made in both. The comparison of
  LEXTER-D112 finds a change made in only one.
- **A pinned rasterizer.** The fixtures depend on one version of Mesa in CI,
  and llvmpipe's output could in principle differ between CPU instruction
  sets, so the CI image is pinned as a whole; moving to a new version of Mesa
  is a deliberate step, checked against the CPU renderer.

## Open Questions

### LEXTER-O56 — A grid per pane, or one composed grid?

A grid per pane keeps swatch indices local, uploads a pane's dirty rows from
its own array, and gives each pane its palette slot by a uniform, freeing the
header's palette-slot bits, at the cost of a draw call per pane and a home
for chrome. One composed grid keeps one draw call, but its copy translates
every swatch index, and palettes travel in each cell's bits. It is
LEXTER-O17, and it is settled before Phase 3.

**Resolution:** 2026-11-03 — accepted, recorded at the steward's direction:
one composed grid, with global swatch indices so that composing needs no
translation, and surfaces for the areas that need a font or effect of their
own (LEXTER-D107, LEXTER-D100).

### LEXTER-O57 — Does the model store the record?

Storing the record makes the flush a copy and makes scrollback compact; it
triples the model's size, and the model's attributes need a place. It is
LEXTER-O7. The decisions for one composed grid and global indices
(LEXTER-D107, LEXTER-D100)
make it more attractive: a screen whose cells are records, with their global
swatch indices and palette slot already set, composes into the grid by a plain
copy of row segments, which a kernel can do as one block move per row. The
architecture adds a consideration: it reads a cell's lines back from its
glyph words, for DECCARA, DECRARA, and attribute reports (LEXTER-D88), which
assumes the records are at hand; a model that does not store them keeps each
cell's SGR attributes itself.

Since 2026-11-17 the question is narrower: history is kept as text and
styles, not records (LEXTER-D118), so the compact
scrollback above no longer argues for storing records. The screen keeps each
cell's attributes as a style id in its text grid
(LEXTER-D119), so the model's attributes have their
place, and the records are not needed to report or copy them. What remains
is whether a screen stores records for its rows on screen beside its text
grid, or builds them as it copies its rows into the composed grid.

### LEXTER-O58 — How are swatch ranges sized and released, and what does a full table do?

Fixed ranges, such as 2048 entries for each of 32 tables, or ranges allocated
and relocated as tables grow. The steward leans to fixed ranges: screens store
global indices (LEXTER-D100), so moving a range would
mean rewriting a screen's cells and its scrollback; from Phase 3, history
holds palette indices (LEXTER-D118), so only the cells on screen would be
rewritten. What remains open is their size. In Phase 2 only the store's first
32,768 entries are usable, because the first edition's instances carry the
wide flag in bit 15 of their swatch field (see Swatch Ranges), so ranges of
2048 entries give 16 tables until Phase 3. Ranges are fixed in place, so
those allocated in Phase 2 carry into Phase 3 unchanged, and Phase 3 opens
the rest of the store. Also open: whether the primary and alternate screens
share one table, and whether a full table evicts unused swatches (Phase 7)
or falls back to the nearest existing one. It is LEXTER-O15.

**Resolution:** 2026-11-17 — accepted, recorded at the steward's direction:
ranges of 2048 entries, allocated to a table as it grows, so that most tables
hold one range and some several, at most four; 16 ranges in Phase 2 and 32
once Phase 3 is complete. A terminal's primary and alternate screens share a
table, and a full table falls back to its nearest existing swatch. Whether
Phase 7 adds eviction remains open
(LEXTER-DRAFT-cell-model-revision-D24).

### LEXTER-O59 — Where do the swatches of writers without a screen live?

Chrome, decorators, the overlay list, and the 3270 pane need tables: one
chrome table with a range of its own, or the table of the pane each belongs
to. It is LEXTER-O16.

**Resolution:** 2026-11-17 — accepted, recorded at the steward's direction:
one table with a range of its own, for chrome and everything else drawn at
the level of Lexter's display rather than of a pane, decoration and content
alike. The 3270 pane, being a pane, has a table of its own
(LEXTER-DRAFT-cell-model-revision-D24).

### LEXTER-O60 — How does the block cursor learn the cell beneath it?

The CPU copies layer 0's glyph and settings into the cursor's overlay
instance and refreshes them when the row changes, or the block style keeps
cursor bits in the header and is drawn in the grid's pass. It is
LEXTER-O18.

**Resolution:** 2026-11-03 — accepted, recorded at the steward's direction:
the block cursor's overlay instance carries a full copy of the record
beneath it, and the header has no cursor bits
(LEXTER-D93 in [LEXTER-0016](Arch.CellModel.md)).
The steward has since settled that the copy is inverted by exchanging its
background slot with its topmost layer's ink slot, and that the instance draws
its background.

### LEXTER-O61 — How does a mask apply to a wide display glyph?

A narrow mask applied to one half, or the matching half of a wide mask
glyph. It is LEXTER-DRAFT-cell-field-format-O12, which the cell-model
architecture carries as LEXTER-O52: its line glyphs are narrow and applied to
each half's cell, so the rule chosen must let a narrow mask apply to one
half.

### LEXTER-O62 — Which tail types are there, and what do the six payload bits carry?

The layout this plan first adopted fixed how a tail type was found, in the
bits of unused masks, but not its values. Candidates from the
cell-field-format survey are a reference to a surface, inline colours, an
effect, and tiles, with one value for no payload.

The reference to a surface is the steward's **void**: a cell whose un-inked
pixels the grid leaves undrawn, so that a surface drawn separately shows
through them in the cell's area. The steward's uses for it are a video
player, an image in a gallery, and a sub-terminal with a grid and font of its
own, which gives a pane the abilities a separate grid would (see
LEXTER-D107). Void cells would also mark the area
that effects applied to the whole grid, such as scanlines or a tint, pass
over, so that the surface can take an effect of its own; glyph layers may sit
over a void, as captions over a video.

**Resolution:** 2026-11-04 — accepted, recorded at the steward's direction:
tail types and escape cells become one namespace of formats, named by the
first byte of the record: plain, void, inline colours, effect, and tiles
(LEXTER-D82 in [LEXTER-0016](Arch.CellModel.md)). What the void and the
effect carry remains open in the architecture, as LEXTER-O53, for the survey
of surfaces and effects.

### LEXTER-O63 — What does the text array hold?

Codepoints, combining marks, and grapheme clusters need a form, such as a
fixed number of codepoints per cell with an overflow pool. It must stay
consistent with the record under every operation. It is
LEXTER-DRAFT-cell-field-format-O8.

Since 2026-11-17 part of it is settled: a character's cell holds its wide
bit and style id, the other cells it covers hold continuation markers, and a terminal row
of soft wrap, prompt kind, and line size lies beside each row
(LEXTER-D119). How the codepoints and grapheme
clusters of a cell are held remains open, and so does how the zero-width
characters that join a cell are drawn.

### LEXTER-O64 — A persistent target or buffer age for partial redraw?

The offscreen target works everywhere but overturns LEXTER-D39 and costs a
full-window blit per frame; the buffer-age extensions need no extra target
but depend on the platform and are reached outside GLFW's portable API.

### LEXTER-O65 — Where does the grid live, and which route do kernels take?

The Lisp heap with records offset by 16 bytes, foreign memory, or mapped GPU
memory; and custom VOPs, sb-simd, or typed Lisp. It is
LEXTER-O10.

### LEXTER-O66 — Is the 3270 pane rewritten to the record, or does it keep its own path?

The 3270 pane keeps a screen of its own, of codepoints and field attributes,
and writes the display grid directly
(`src/tn3270-pane/tn3270-pane.lisp:get-or-create-swatch@2d4d743`); the review
found that it never touches the model. Under the dense model it can be
rewritten to keep its screen as records, or keep its own screen and write
records into its region of the composed grid
(LEXTER-D107). Either way, Phase 2 gives it a swatch
table in place of its global cache. It is settled before Phase 3.

### LEXTER-O67 — Does the CPU renderer draw with more than one thread?

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

### LEXTER-O68 — How does a blinking cell keep its glyphs while it is blanked?

The steward directs that blink belongs to the grid, not to the overlay list:
unlike a cursor, it is a property of the text, and lasts until the text
changes. A blinking cell is blanked at intervals by an animation function
that makes it read as having no glyphs, without storing its layers
elsewhere. The cell-model architecture requires the glyph words beyond a
cell's glyph count to be zero, and the cell checksum relies on it
(LEXTER-D83), so setting the count to 0 while the words stay would break
that invariant, and the count to restore would itself need a place. Three
ways fit the architecture:

- **A blanking bit.** A bit of the format word, from those the plain format
  reserves, that renderers read as a glyph count of 0 while it is set. The
  animation toggles it in every blinking cell, and the rows are uploaded
  again. A second bit marks the cell as blinking, so that the animation
  finds its cells by a kernel pass, and an invisible cell is never revealed
  by the blink.
- **A blinking bit and a phase.** Only the bit that marks the cell as
  blinking is stored; the shader, and the CPU renderer, read the blink phase
  as a uniform, as overlays read the time, and draw a blinking cell with no
  glyphs in the off phase. Nothing is rewritten or uploaded as the cell
  blinks.
- **The count itself.** The count is set to 0 and restored from the text
  grid and the cell's attributes, which rebuilds the record each time.

Either bit is an addition to the architecture, which the steward makes there.
The test rig fixes the phase, as it fixes the time uniform, so that blinking
cells have one checksum. It is settled before Phase 3.

**Resolution:** 2026-11-06 — accepted, recorded at the steward's direction:
a blink flag and a phase. Bit 18 of the format word marks a blinking cell,
at the same place in every format, and both renderers hide its topmost
layer, the text, while the blink phase is off; the layers beneath and the
background stay. The phase is set by the configuration and shares the
cursor's clock. Nothing in the record changes as a cell blinks, and the
glyph words keep their place within the glyph count
(LEXTER-D94 in [LEXTER-0016](Arch.CellModel.md)).
Partial redraw finds the rows to redraw at a change of phase from a mask it
derives as rows are uploaded (see Partial Redraw and Eviction).

### LEXTER-O79 — Should a character's width come from Unicode's tables rather than the atlas?

LEXTER-D98 has the VT handler ask the atlas whether a glyph is wide
(`src/atlas.lisp:atlas-glyph-wide-p@2d4d743`), so a character's width is a
property of the font that happens to be loaded. Applications decide widths
from Unicode's East Asian Width property, through wcwidth and the tables
that shells, readline, ncurses, and editors carry, and place the cursor by
them; a terminal that disagrees moves every later character on the line out
of place, and the application's idea of the screen drifts from the
terminal's. A dual-width font (LEXTER-0007) can supply wide glyphs for
characters that Unicode makes narrow, and narrow glyphs for some it makes
wide. The choices:

- **Width from Unicode's tables.** The handler decides each character's
  width from a table generated from one version of Unicode's data, as every
  terminal in the prior-art evaluation does
  ([LEXTER-0018](Eval.CellModels.PriorArt.md), R4),
  and the atlas is fitted to the width: a narrow glyph in a wide pair is
  centred or padded, and a glyph wider than its character's width is clipped
  or replaced.
- **Width from the atlas,** as LEXTER-D98 has it. It matches what the font
  draws, at the cost of disagreeing with applications.
- **Unicode's tables with settings.** As the first, with a setting for
  characters of ambiguous width, which some terminals let the user make wide,
  and later the grapheme-cluster widths of mode 2027.

It is settled before Phase 1, whose repair of the handler's wide writes
(LEXTER-O19) depends on it.

**Resolution:** 2026-11-17 — accepted, recorded at the steward's direction:
the path that writes a cell decides its character's width. The VT parser
uses Lexter's width table, generated from Unicode's data and adjustable by
the configuration; the API's writers choose, by default the atlas's width;
the 3270 data stream decides by its own addressing. Widths are decided once
and stored, and the atlas fits its glyphs to them, centring a narrow glyph in
a wide entry and cropping a wide one to its ink where the ink fits, or
drawing the replacement glyph where it does not
(LEXTER-D117).

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

1. **Phase 0: the regression suite.** A headless test system, following
   Square, with a test for each finding in scope, reproducing it before it is
   repaired, and red until the repair lands (LEXTER-D106,
   LEXTER-DRAFT-cell-model-revision-D21); and the atlas's packing separated
   from its upload, so that tests pack atlases without GL
   (LEXTER-DRAFT-cell-model-revision-D22). A short Log records the phase.
2. **Phase 1: the first edition repaired.** It starts after the companion
   plan's consolidation of the two terminal stacks (LEXTER-D67), and after
   the pane-profiles plan's history drawing. The repairs
   of The First Edition Repaired, finding by finding, each turning its test
   green, with the width table of Unicode 17.0 and the atlas's fitting of
   glyphs to it (LEXTER-D117, LEXTER-DRAFT-cell-model-revision-D23), which
   settles LEXTER-O79. Double-width text renders through the VT path. A Log records the
   phase.
3. **Phase 2: swatch ranges.** The store, the allocator, interning by every
   writer, upload records that name their tables, and global indices stored by
   screens (LEXTER-D99,
   LEXTER-D100), with palettes and swatches in integer
   stores after a check of cl-opengl (LEXTER-D109).
   Fixtures replay the same in any order. LEXTER-O58
   and LEXTER-O59 are settled first
   (LEXTER-DRAFT-cell-model-revision-D24). A Log records
   the phase. Every later phase waits for it.
4. **Gate.** Phase 2 is complete, as Swatch Ranges defines;
   LEXTER-O57, LEXTER-O61,
   LEXTER-O63, LEXTER-O66,
   and LEXTER-O68 are settled, with the half of
   LEXTER-O65 that decides where the grid lives; and
   the companion plan's workspace-switch repaint (LEXTER-D71) has landed. The
   formats other than the plain format (LEXTER-O62)
   may wait until after Phase 3.
5. **Phase 3: the dense cell model.** The descriptor
   (LEXTER-D104); the record of
   [LEXTER-0016](Arch.CellModel.md) in its plain format
   (LEXTER-D102), with halves
   (LEXTER-D103), backgrounds, the single underline
   as a line glyph, invisible and blinking text, and palette slots allocated
   to terminals; the text grid with its terminal rows
   (LEXTER-D119); history kept as text and styles
   (LEXTER-D118); one composed grid drawn in one
   call (LEXTER-D107) by a shader that selects without
   blending (LEXTER-D110); and uploads that follow the drawn rows' change
   stamps (LEXTER-D113).
   The suite passes on the new model, and fixtures are re-authored on a
   pinned llvmpipe with a cell checksum beside each pixel checksum
   (LEXTER-D108,
   LEXTER-D112). A Log records the phase.
6. **Phase 4: the overlay list.** The pass, the block cursor as a transformed
   copy of the cell beneath it and the other cursors as overlays (LEXTER-D93),
   and the removal of LEXTER-D101's exchanged slots.
   A Log records the phase.
7. **Phase 5: the CPU renderer.** Grids and their overlays drawn on the CPU
   (LEXTER-D111), and every fixture checked against
   both renderers (LEXTER-D112). A Log records the
   phase.
8. **Later formats.** Inline colours, the other line styles, tiles, and the
   void and effects, each as its own step when what it waits for is settled
   (see Later Formats). A Log records each.
9. **Phase 6, optional: partial redraw**, after
   LEXTER-O64 is settled.
10. **Phase 7, conditional: eviction within a range**, if the steward adds
    it to the fallback of LEXTER-DRAFT-cell-model-revision-D24.
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
| 4 | The pane-profiles plan's history drawing in `flush-to-display` | 3 |
| 5 | This plan's Phase 1: the first edition repaired | 4 |
| 6 | This plan's Phase 2: swatch ranges | 5 |
| 7 | The terminal-fixes plan's workspace-switch repaint (LEXTER-D71) | 3 |
| 8 | This plan's Phase 3 and later | 6, 7, and the gate's questions |
| — | The terminal-fixes plan's protocol fixes (LEXTER-D72, LEXTER-D73) | Nothing; at any time |