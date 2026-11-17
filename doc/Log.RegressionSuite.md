---
id:            LEXTER-DRAFT-regression-suite
title:         "Regression Suite (Phase 0): Development Log"
genre:         Log
scope:         project
project:       Lexter
language:      en
status:        Draft
provenance:
  assistant:   opencode
  session:     "Phase 0: the regression suite (2026-11-17)"
relates-to:
  - LEXTER-0017
  - LEXTER-0014
  - LEXTER-0015
  - LEXTER-0016
---

# Regression Suite (Phase 0): Development Log

This document records Phase 0 of the cell-model revision
([LEXTER-0017](Plan.CellModelRevision.md)): a headless regression suite,
`lexter/tests`, written to the Square testing standard, with a test that
reproduces each cell-model finding of the critique
([LEXTER-0014](Eval.Critique.DataStructures1e.md)) before it is repaired; and
the separation of the glyph atlas's packing from the upload of its texture,
so that the suite can pack atlases with no GL context. The suite is red by
design (LEXTER-DRAFT-cell-model-revision-D21): its reproduction tests fail
until Phase 1 and Phase 2 land their repairs.

## Problem

LEXTER-D106 asks that every finding the plan repairs first be reproduced by a
headless test, so that the repair is shown to work and stays working. Lexter
had no such suite. Its two test systems cover mouse reporting and the Origin
integration, and the screenshot test rig
([LEXTER-0010](Log.ScreenshotTestRig.md)) needs a display and cannot see a
stale GPU copy that a capture happens not to show. The critique reproduced its
findings at the REPL, with probe code outside the repository and an atlas
struct built by hand, because `build-atlas` queries the GPU's maximum texture
size and uploads a texture (`src/atlas.lisp:build-atlas@2d4d743`), and
`add-cursor-glyphs` uploads it again
(`src/atlas.lisp:add-cursor-glyphs@2d4d743`). Phase 1's repairs, and the width
fitting of LEXTER-D117, change the packing, so their tests must pack real
atlases.

## Design Decisions

The decisions of this phase are recorded in the plan, where the steward made
them:

- **LEXTER-DRAFT-cell-model-revision-D21** — the suite follows Square, as the
  system `lexter/tests` in `tests/`; reproduction tests assert the repaired
  behaviour and fail until the repair lands; findings about the code's
  arrangement get structural tests; fonts are made in the tests; and the
  existing test systems move into the suite later.
- **LEXTER-DRAFT-cell-model-revision-D22** — the atlas's packing is separated
  from its upload in Phase 0, with a column count the caller fixes.

Choices made while building, within those decisions:

- **No umbrella package.** Lexter's subsystems each have a package, and there
  is no `lexter` package for the test package to use. The test package uses
  only `cl`, and names every symbol by its package, so that a reader sees
  which subsystem each operation comes from.
- **The test font puts the space third.** The made-up font holds A, B, the
  space, and U+4E00, in that order, so that no test of blanks passes because
  the space happens to be packed at position 0.
- **A stand-in for the GPU's swatch upload.** The renderer's rule needs a GL
  context, so the swatch tests use a stand-in that copies the grid's table
  when its generation differs from the one recorded, as
  `src/renderer.lisp:upload-swatch-table@2d4d743` does. LEXTER-D106 allows it;
  Phase 2 replaces it with the renderer's own rule, made callable without GL.
- **Structural tests read the source as text.** The tests of LEXTER-O36 scan
  the source files for top-level definitions, and the test of LEXTER-O40
  inspects the loaded function's lambda list and docstring.

## Implementation

### The atlas split, in `src/atlas.lisp`

`build-atlas` was one function that collected the font chain's glyphs, chose a
column count from `GL_MAX_TEXTURE_SIZE`, packed, blitted, and uploaded. It is
now:

- `%collect-glyph-entries`, the font chain's glyphs, first font winning, with
  the check that the fonts share a cell size;
- `atlas-columns-for`, the column count for a chain and a maximum texture size,
  by the same rule as before;
- `pack-atlas`, which assigns positions and keeps pixels, taking its column
  count from its caller and touching no GL, and returns an atlas whose
  texture id is 0;
- `upload-atlas`, which blits the packed pixels and creates the texture, or
  refreshes it when the atlas has one, checking the maximum texture size;
- `build-atlas`, which chooses the column count, packs, and uploads, and
  accepts a fixed `:cols`.

`%rebuild-atlas-texture`, which `add-cursor-glyphs` calls, recomputes the
atlas's dimensions and uploads only when the atlas has a texture, so cursor
glyphs are added to a packed atlas without GL. `pack-atlas`, `upload-atlas`,
and `atlas-columns-for` are exported from `lexter/atlas`
(`src/packages.lisp`).

### The suite, in `tests/` and `lexter.asd`

`lexter.asd` defines `lexter/tests`, depending on `lexter`, `lexter/unix`,
`lexter/panes`, `babel`, `sb-introspect`, `fiveam`, and `hamcrest/fiveam`,
with its files loaded in order, and its `test-op` calling
`lexter-tests:run-all-tests`; the main system's `test-op` runs it.

Table: The files of the suite.

| File | Suite | Contents |
|---|---|---|
| `tests/package.lisp` | — | The package `lexter-tests`, importing FiveAM and cl-hamcrest explicitly and exporting the two runners |
| `tests/helpers.lisp` | — | The suites, the runners, the test font and atlas factories, the `with-clean-terminal` fixture, readers of first-edition state, the GPU stand-in, and the source scanner |
| `tests/test-atlas.lisp` | `atlas` | Packing without GL (8 tests, passing) and the reserved positions of LEXTER-O28 (2 tests) |
| `tests/test-handler.lisp` | `handler` | A narrow character (passing) and the double-width writes of LEXTER-O19 (3 tests) |
| `tests/test-model.lisp` | `model` | The row and range operations of LEXTER-O26 (6 tests), the blank of LEXTER-O28, and a layered cell's swatch, LEXTER-O27 |
| `tests/test-grid.lisp` | `grid` | The flush, render data, cursor, and resize of LEXTER-O19 and LEXTER-O26 (4 tests), the layered cells of LEXTER-O27 (3 tests), and `clear-grid`, LEXTER-O28 |
| `tests/test-swatches.lisp` | `swatches` | LEXTER-O20, LEXTER-O22, LEXTER-O23, and LEXTER-O24, one test each |
| `tests/test-structure.lisp` | `structure` | LEXTER-O36 (3 tests) and LEXTER-O40 |

Each reproduction test names its finding at the start of its docstring, and
states the invariant the repair establishes.

## Verification

- **The suite.** `sbcl --non-interactive --eval '(ql:quickload :lexter/tests)'
  --eval '(asdf:test-system :lexter)'` runs 38 tests and 93 checks: 29 checks
  pass and 64 fail. The 9 tests that should hold now pass: the 8 packing tests
  and the narrow character. The 29 reproduction tests fail, each as its
  finding's evidence in the critique predicts: for example, the render data
  holds 30 instances for a 10-by-3 grid with one double-width character, not
  29, and a flush after 2100 swatches signals an invalid index. The suite
  loads with no warnings, and runs with no display.
- **The split is a refactoring.** The old `build-atlas`, from commit
  `2d4d743` with GL stubbed, and `pack-atlas`, with the column count from
  `atlas-columns-for`, gave identical column counts, row counts, codepoint
  tables, wide sets, and pixels for Terminus, for Unifont 17.0.04 (57,086
  glyphs, 49,804 wide), for zpix, and for a chain of a 10-by-20 font and a
  Japanese 18-by-18 font, at maximum texture sizes of 16,384, 8192, and 1024.
- **Pixels unchanged.** A hidden terminal of the test rig, replaying one byte
  stream of plain, coloured, box-drawing, and CJK text, gave the same pixel
  checksum before and after the split: `#xF30DE014C5651825` with Terminus and
  `#xF1F04F20171FD8DF` with Unifont.
- **The other systems.** `lexter/mouse-tests` passes, 32 checks. `lexter/origin-tests`
  gives 23 passes and 28 failures, the same before and after this change.

## Files

Table: Files added or changed in this phase.

| File | Action | Description |
|---|---|---|
| `src/atlas.lisp` | Modified | Packing separated from upload: `pack-atlas`, `upload-atlas`, `atlas-columns-for`; `build-atlas` takes `:cols`; cursor glyphs added without GL to a packed atlas |
| `src/packages.lisp` | Modified | Exports of the new atlas functions |
| `lexter.asd` | Modified | The `lexter/tests` system; the main system's `test-op` |
| `tests/package.lisp` | **New** | The test package |
| `tests/helpers.lisp` | **New** | Suites, runners, factories, fixture, and readers |
| `tests/test-atlas.lisp` | **New** | Atlas tests |
| `tests/test-handler.lisp` | **New** | VT handler tests |
| `tests/test-model.lisp` | **New** | Screen model tests |
| `tests/test-grid.lisp` | **New** | Display grid tests |
| `tests/test-swatches.lisp` | **New** | Swatch tests |
| `tests/test-structure.lisp` | **New** | Structural tests |
| `AGENTS.md` | Modified | The Square block |
| `doc/Plan.CellModelRevision.md` | Modified | LEXTER-DRAFT-cell-model-revision-D21, -D22, -D23, the order of work, and the Roadmap |
| `doc/Arch.CellModel.md` | Modified | The "no glyph" glyph at generated position 6 |
| `doc/Plan.TerminalFixes1e.md` | Modified | The resolution of LEXTER-O41 |

## Outstanding Work

- **The terminal-fixes plan's tests.** The reproduction tests of
  LEXTER-0015's findings, in this suite, are the next step of the order of
  work.
- **Phase 1's own tests.** The width table, the fitting of glyphs to widths,
  the replacement and "no glyph" glyphs, and dropped zero-width characters
  (LEXTER-D117, LEXTER-DRAFT-cell-model-revision-D23) are not findings, and
  their tests are written first in Phase 1.
- **The palette half of LEXTER-O23.** Two screens' palette generations can be
  equal for different palettes; it is tested when Phase 2 records uploads by
  owner (LEXTER-D92).
- **The existing test systems** move into the suite later
  (LEXTER-DRAFT-cell-model-revision-D21).
- **Pinning.** The new code is referred to here by file; its symbols can be
  pinned to the commit that holds this phase once it exists.
- **The Origin tests' failures.** `lexter/origin-tests` already failed 28 of
  its checks before this phase; they are outside the cell-model plan.
