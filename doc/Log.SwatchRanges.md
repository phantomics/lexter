---
id:            LEXTER-0025
title:         "Swatch Ranges (Phase 2): Development Log"
genre:         Log
scope:         project
project:       Lexter
language:      en
status:        Accepted
authors:
  - Andrew Sengul
approved-by:   Andrew Sengul
reviewed:      2026-11-19
provenance:
  assistant:   opencode
  session:     "Phase 2: swatch ranges (2026-11-17); review revisions and pixel fixtures (2026-11-19)"
relates-to:
  - LEXTER-0017
  - LEXTER-0016
  - LEXTER-0015
  - LEXTER-0014
  - LEXTER-0024
  - LEXTER-0020
  - LEXTER-0010
  - LEXTER-0026
---

# Swatch Ranges (Phase 2): Development Log

This document records Phase 2 of the cell-model revision
([LEXTER-0017](Plan.CellModelRevision.md)): every swatch table given one owner
and ranges of one GPU store (LEXTER-D99), screens storing global indices
(LEXTER-D100), ranges sized and the display given a table of its own as
LEXTER-D123 decides, and palettes and swatches kept on
the GPU as integers (LEXTER-D109). The reproduction tests of LEXTER-O22,
LEXTER-O23, and LEXTER-O24 that Phase 0 wrote
([LEXTER-0020](Log.RegressionSuite.md)) now pass, and so does
that of LEXTER-O29, whose palette copy the terminal-fixes plan's LEXTER-D70
asks for in the function this phase changed.

## Problem

Each screen numbered its swatches from 0, and every flush copied its table
into the display grid's single table, so two panes overwrote each other's
colours (LEXTER-O22). The renderer uploaded the grid's table when a generation
counter changed, a counter that carried no identity, so a replay could find
the GPU holding another fixture's swatches (LEXTER-O23). A table that outgrew
the grid's 2048 entries failed the flush (LEXTER-O24). Chrome, decorators, the
demo, and the 3270 pane, whose cache was a global (LEXTER-D77), wrote swatches
into the grid by number. On the GPU, the swatch table was a normalised 1D
texture turned back into indices by multiplying by 255, and the palettes a
uniform buffer of floats with room for four.

## Design Decisions

The decisions are the plan's and the architecture's: LEXTER-D99, LEXTER-D100,
LEXTER-D109, LEXTER-D123, and, for palette slot 0,
LEXTER-D83 and LEXTER-D92. Choices made while building, the first four at the
steward's direction:

- **A store for each compositor.** The compositor makes a swatch store with
  itself, needing no GL, and a pane reaches it through its workspace. A screen
  made without a table, as the tests and standalone uses make them, gets a
  table in a store of its own. Compositors in one image, as Origin embeds them,
  keep their ranges and upload records apart.
- **Function panes draw in the display's table.** They have no screen and draw
  straight into the grid, as decorators do, and cost no range;
  LEXTER-D123 is amended to name them.
- **`display-swatch`.** Chrome, decorators, workspace clears, and function
  panes take their swatches from
  `src/panes/compositor.lisp:display-swatch@8451a08`, given a compositor, a
  workspace, or a pane; the decorator's arguments are unchanged, and the grid
  keeps no reference to a table. A target that no compositor draws gets global
  swatch 0.
- **Palette slot 0 fixed, and uploads recorded by owner.** Taking part of
  LEXTER-D92 early: the renderer gives slot 0 the default palette when it is
  made and never writes it again, a pane that names no slot draws in slot 1,
  and the renderer records for each slot the owner, by default the palette
  array, and its generation, so two palettes with equal generations are told
  apart. The allocator of slots still waits for Phase 3. Uploading to slot 0
  is an error.
- **The display's table is made by the store.** A store makes its display
  table when it is made, so range 0 and global swatch 0 belong to it
  without the compositor's help.
- **Each table has its own default.** A table interns the default swatch,
  background 0 and foreground 7, as its local 0, and a screen's cells start in
  it; global swatch 0 belongs to the display.
- **The nearest swatch is cached.** A full table remembers which swatch it
  gave for a refused key, so a program that keeps asking for new colours does
  not scan the table at every character. The answer is taken in the palette of
  the first request and kept if the palette changes later.
- **A released table interns nothing.** Asking it to signals an error, rather
  than writing into ranges another table may hold.
- **The 3270 cursor exchanges slots,** as the model's cursor has done since
  Phase 1 (LEXTER-D101, [LEXTER-0024](Log.FirstEditionRepairs.md)), in place
  of interning a reversed swatch.

## Implementation

### The store, `src/swatches.lisp`

A new file and package, `lexter/swatches`, with no GL:

- The swatch store, of 32 ranges of 2048 swatches, of which the first 16 are
  usable until Phase 3 frees bit 15 of the instances' swatch field, at most
  four to a table. `src/swatches.lisp:make-swatch-store@8451a08` makes the
  display table in range 0.
- The swatch table, moved out of `src/model.lisp`: an id from one global
  counter, its local data, the ranges it holds in the order it took them, and
  a version. `src/swatches.lisp:make-swatch-table@8451a08` gives a table the
  lowest free range; `src/swatches.lisp:intern-swatch@8451a08` returns global
  indices, takes another range when one fills, and falls back to the nearest
  swatch by squared RGB distance over the four slots, ties to the lowest;
  `append-swatch` adds an entry that interning never matches (LEXTER-O73);
  `release-swatch-table` returns the ranges; `store-swatch` reads any global
  index.
- `src/swatches.lisp:plan-swatch-uploads@8451a08`, the renderer's upload
  decision: for each owned range, the whole of what its table holds there when
  the range was last uploaded from another table or version, else the
  swatches added since, noted in the records it is given.
- The default palette, now RGBA bytes, moved here from the model.

### The model and the handler

- `src/model.lisp:make-screen@8451a08` takes `:swatches` and `:palette`, copies
  the palette, and starts every cell in its table's default swatch; screens
  keep palettes as 1024 bytes, and `set-palette-entry` takes bytes. The flush
  copies global indices unchanged and no longer copies a table into the grid.
- `src/vt-handler.lisp:%ensure-alt-screen@8451a08` gives the alternate screen
  the primary's table and a copy of its palette; the handler interns with the
  screen's palette for the fallback.

### The grid, `src/grid.lisp`

The grid loses its swatch data, count, and generation, and `set-swatch`,
`get-swatch`, and `swatch-as-array`.

### The renderer and shaders

- `src/renderer.lisp:make-renderer@8451a08` makes two `RGBA8UI` texture
  buffers: the swatch store of 65,536 texels, and the palette store of 128
  slots by default. `src/renderer.lisp:upload-swatches@8451a08` carries out the
  upload plan with `glBufferSubData`; `render-frame` takes the store.
  `src/renderer.lisp:upload-palette@8451a08` records owners.
- `src/shaders.lisp:+colour-functions+@8451a08` holds the one swatch fetch and
  the palette lookup that both fragment shaders share; the conversions from
  normalised values are gone. Blending of overlay layers is unchanged.

### Panes

- The compositor owns the store, renders with it, and drops
  `setup-default-swatches`; `compositor-reset-display` keeps the store.
- `src/panes/vt-pane.lisp:vt-pane-init-screen@8451a08` takes a table from the
  compositor's store, first releasing the table of a screen it replaces, as
  `terminal-reset` replaces it; `pane-destroy` releases it.
- `src/tn3270-pane/tn3270-pane.lisp:pane-swatch@8451a08` interns into the 3270
  pane's own table, made at initialization and released at destruction; the
  global cache is gone.
- Function panes, the workspace's decorations, and `clear-grid` document their
  swatches as global indices from `display-swatch`, by default global 0.
- `src/demo.lisp` interns its colours into a store's display table.

### The test rig, `src/test-rig.lisp`

- `src/test-rig.lisp:check-integer-texture-buffers@8451a08`, the check
  LEXTER-D109 asks for first.
- `src/test-rig.lisp:check-gpu-stores@8451a08` reads back the swatch and
  palette buffers and compares every swatch a table holds, palette slot 0, and
  the terminal's slot with their sources (LEXTER-D106).

### Elsewhere

`src/width.lisp`, written in Phase 1
([LEXTER-0024](Log.FirstEditionRepairs.md)), declared its three tables inside
a `multiple-value-bind`, which a fresh compile reported as four undefined
variables; they are now `defvar`s.

### Tests

The suite `swatches` has 19 tests, of which the 4 reproduction tests are
rewritten for the store, with the same intent: the GPU's copy is a byte vector
filled by `plan-swatch-uploads`, in place of the stand-in for the old rule. The
new ones cover global swatch 0, global indices, the flush's plain copy, a second
range, the limit of four, the nearest swatch at the limit and with no range
free, reuse lowest first, a released table, the shared alternate table, the
three upload cases, `display-swatch`, and a terminal pane's table across
initialization, replacement, and destruction. The suite `structure` replaces
its test of `setup-default-swatches` with one of global swatch 0, and adds one
that the grid holds no swatches and that no source defines or calls
`set-swatch`. A scrollback test that compared a swatch with 0 now compares it
with the screen's default and checks that no cursor made the cell layered.

## Verification

- **The cl-opengl check.** On the NVIDIA GL 4.6 driver, cl-opengl creates and
  fills an `RGBA8UI` texture buffer through `%gl:tex-buffer`, which has no
  wrapper in `gl`, and a shader reads all 256 texels back exactly through
  `usamplerBuffer`.
- **The suite.** `(asdf:test-system :lexter)` runs 108 tests and 251 checks:
  230 pass and 21 fail. The reproduction tests of LEXTER-O22, LEXTER-O23,
  LEXTER-O24, and LEXTER-O29 pass. The 14 tests that fail belong to the
  terminal-fixes plan (LEXTER-O21, LEXTER-O25, LEXTER-O31, LEXTER-O33,
  LEXTER-O34, LEXTER-O35), and fail as they did before the phase.
- **The plan's conditions.** The plan counts Phase 2 complete when every
  swatch writer interns into a table with its own range, nothing calls
  `set-swatch` on a grid, and every upload record names its table. The
  writers are listed under Panes; the structural test
  `the-grid-holds-no-swatches` finds no `set-swatch` defined or called in any
  source, nor any swatch data in the grid; and `plan-swatch-uploads` records
  each range's table by its id and version.
- **Pixels.** In the test rig's hidden terminal
  ([LEXTER-0010](Log.ScreenshotTestRig.md)), of 40 columns by 8 rows, four
  fixtures of colours, reverse video, cursor movement, and SGR 256 and
  truecolour; of OSC 4 palette changes; of CJK text; and of the alternate
  screen give the checksums they gave before the phase, in Terminus and in
  Unifont. Bytes divided by 255 are the floats that were stored before. A
  fifth fixture, which interns 2304 swatches and so needs a second range,
  could not be replayed before the phase.
- **Order.** The four original fixtures already gave the same checksums
  replayed in reverse order before the phase: none of them happened to
  trigger LEXTER-O23, so their order shows that nothing regressed, not the
  repair, which the reproduction test
  `replay-does-not-depend-on-earlier-fixtures` shows. The fifth fixture also
  gives the same checksum in either order.
- **The GPU's stores.** After every replay, `check-gpu-stores` finds every
  swatch held by a table, 2305 for the fifth fixture, equal on the GPU, and
  palette slot 0 and the terminal's slot equal to their sources. A cell drawn
  from range 2 shows palette colour 255.

Table: Pixel checksums of the fixtures, on an NVIDIA GL 4.6 driver; the four original fixtures gave the same before the phase.

| Fixture | Terminus | Unifont 17.0.04 |
|---|---|---|
| colours | `#x0AA0C7479DECC3D4` | `#xA1BF8B8BFCDCDFFA` |
| palette | `#x6F228D86413D573C` | `#xC03D510C21B0C7FD` |
| cjk | `#xD3758C95BC11B3B5` | `#xE04CD998C68F6774` |
| alt | `#x1E7393F293E8303D` | `#xF4D9A7010B64A71F` |
| many | `#xFF822E35378CA846` | `#xD790B48E4BBF36CD` |

- **The fixtures kept.** The five fixtures were first byte streams in a script
  outside the repository. In review they were written, from the same bytes,
  as the test rig's blobs in `tests/fixtures/`, with
  `tools/check-pixel-fixtures.lisp`, which replays them in order and in
  reverse in each font, checks the checksums above, and compares the GPU's
  stores after each replay; it reproduces every checksum. The checksums hold
  on the driver they were taken on, until Phase 3 re-authors the fixtures on a
  pinned llvmpipe (LEXTER-D112).
- **Running.** Both demos and a terminal running `/bin/sh` draw without error.
- **The other test systems.** `lexter/mouse-tests` passes, 32 checks;
  `lexter/origin-tests` gives its same 23 passes and 28 failures.
- **Loading.** Every system compiles with no warnings; one style warning, an
  unused variable in `src/pcf.lisp`, predates the phase.

## Files

Table: Files added or changed in Phase 2: the code and tests in commit `8451a08`, the documents in commit `0dc327c`, and the pixel fixtures in review.

| File | Action | Description |
|---|---|---|
| `src/swatches.lisp` | **New** | Swatch stores, tables, interning, the default palette, and the upload decision |
| `src/packages.lisp` | Modified | The `lexter/swatches` package; the grid's swatch exports removed; the renderer's and model's imports |
| `lexter.asd` | Modified | The swatch file |
| `src/model.lisp` | Modified | Tables and palettes from `lexter/swatches`; byte palettes; screens' default swatch; the flush's plain copy |
| `src/grid.lisp` | Modified | Its swatch table removed |
| `src/renderer.lisp` | Modified | Integer texture buffers for swatches and palettes; uploads by plan and by owner |
| `src/shaders.lisp` | Modified | The shared swatch fetch and palette lookup |
| `src/vt-handler.lisp` | Modified | The alternate screen's table and palette; interning with the palette |
| `src/panes/compositor.lisp` | Modified | The store; `display-swatch`; `swatch-store-of`; the default palette slot |
| `src/panes/vt-pane.lisp` | Modified | The terminal's table taken and released |
| `src/panes/workspace.lisp`, `function-pane.lisp`, `packages.lisp` | Modified | Global swatch indices documented; exports |
| `src/tn3270-pane/tn3270-pane.lisp` | Modified | A table of its own; the cursor by exchanged slots |
| `src/demo.lisp` | Modified | Colours interned into a display table |
| `src/test-rig.lisp` | Modified | The texture-buffer check and the check of the GPU's stores |
| `src/width.lisp` | Modified | Its tables declared before they are set |
| `tests/helpers.lisp` | Modified | The store in the fixtures; the GPU's copy filled by the upload plan |
| `tests/test-swatches.lisp` | Modified | The swatch suite rewritten and extended |
| `tests/test-structure.lisp` | Modified | Global swatch 0; no swatches in the grid |
| `tests/test-scrollback.lisp` | Modified | The cursor test compares the screen's default swatch |
| `doc/Plan.CellModelRevision.md` | Modified | LEXTER-D123 amended to name function panes; the early parts of LEXTER-D92 recorded in Swatch Ranges |
| `doc/Log.FirstEditionRepairs.md` | Modified | A "Since done" pointer to this Log |
| `doc/Plan.TerminalFixes1e.md` | Modified | LEXTER-D77's cross-reference to this Log |
| `tests/fixtures/colours.ptyb`, `palette.ptyb`, `cjk.ptyb`, `alt.ptyb`, `many.ptyb` | **New** | The pixel fixtures, as the test rig's blobs |
| `tools/check-pixel-fixtures.lisp` | **New** | Replays the fixtures and checks their checksums and the GPU's stores |

## Outstanding Work

- **Released ranges and the grid.** A pane destroyed while the grid still
  shows its cells leaves them pointing into a range that the next table made
  takes; the cells keep their indices until something redraws them. Panes are
  not yet destroyed while the compositor runs, so this has not arisen.
- **The fallback in another palette.** A full table keeps the nearest swatch
  it chose for a key in the palette of the first request; eviction (Phase 7)
  would revisit it.
- **Palettes still one per frame.** The first edition draws every pane in the
  focused pane's palette slot; the record's palette slot of Phase 3 lets each
  pane draw in its own.
- **The 3270 pane's table is untested,** since the suite does not load the
  3270 pane, whose initialization connects to a host.
- **The palette half of LEXTER-O23 is untested.** Two screens' palette
  generations can be equal for different palettes, which the regression
  suite's Log left to be tested once uploads are recorded by owner
  ([LEXTER-0020](Log.RegressionSuite.md)). The renderer now
  records them (`src/renderer.lisp:upload-palette@8451a08`), but its decision
  is made beside the GL calls, so no headless test reaches it; separating the
  decision from the upload, as `plan-swatch-uploads` is separated for
  swatches, would let the suite test it. `check-gpu-stores` compares only the
  slot the terminal draws in, after one replay.
- **Phase 3's gate.** LEXTER-O57, LEXTER-O61, LEXTER-O63, and LEXTER-O66,
  with where the grid lives (LEXTER-O65), and the terminal-fixes plan's
  workspace-switch repaint (LEXTER-D71). Since done: the questions are
  settled by LEXTER-D124 to LEXTER-D129, all but how the characters that join
  a cell are drawn, which the gate lets wait; and the repaint has landed
  ([LEXTER-0026](Log.WorkspaceRepaint.md)).
