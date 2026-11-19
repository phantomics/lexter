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
  - LEXTER-0010
---

# Regression Suite (Phase 0): Development Log

This document records Phase 0 of the cell-model revision
([LEXTER-0017](Plan.CellModelRevision.md)): a headless regression suite,
`lexter/tests`, written to the Square testing standard, with a test that
reproduces each cell-model finding of the critique
([LEXTER-0014](Eval.Critique.DataStructures1e.md)) before it is repaired; and
the separation of the glyph atlas's packing from the upload of its texture,
so that the suite can pack atlases with no GL context. The suite is red by
design (LEXTER-D120): its reproduction tests fail
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

- **LEXTER-D120** — the suite follows Square, as the
  system `lexter/tests` in `tests/`; reproduction tests assert the repaired
  behaviour and fail until the repair lands; findings about the code's
  arrangement get structural tests; fonts are made in the tests; and the
  existing test systems move into the suite later.
- **LEXTER-D121** — the atlas's packing is separated
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

- `src/atlas.lisp:%collect-glyph-entries@d6acd93`, the font chain's glyphs,
  first font winning, with the check that the fonts share a cell size;
- `src/atlas.lisp:atlas-columns-for@d6acd93`, the column count for a chain
  and a maximum texture size, by the same rule as before;
- `src/atlas.lisp:pack-atlas@d6acd93`, which assigns positions and keeps
  pixels, taking its column count from its caller and touching no GL, and
  returns an atlas whose texture id is 0;
- `src/atlas.lisp:upload-atlas@d6acd93`, which blits the packed pixels
  (`src/atlas.lisp:%atlas-texture-data@d6acd93`) and creates the texture, or
  refreshes it when the atlas has one, checking the maximum texture size;
- `src/atlas.lisp:build-atlas@d6acd93`, which chooses the column count, packs,
  and uploads, and accepts a fixed `:cols`.

`src/atlas.lisp:%rebuild-atlas-texture@d6acd93`, which
`src/atlas.lisp:add-cursor-glyphs@d6acd93` calls, recomputes the atlas's
dimensions and uploads only when the atlas has a texture, so cursor glyphs are
added to a packed atlas without GL. `pack-atlas`, `upload-atlas`, and
`atlas-columns-for` are exported from `lexter/atlas`
(`src/packages.lisp:lexter/atlas@d6acd93`).

### The suite, in `tests/` and `lexter.asd`

`lexter.asd` defines `lexter/tests` (`lexter.asd:lexter/tests@d6acd93`),
depending on `lexter`, `lexter/unix`, `lexter/panes`, `babel`,
`sb-introspect`, `fiveam`, and `hamcrest/fiveam`, with its files loaded in
order, and its `test-op` calling `lexter-tests:run-all-tests`
(`tests/helpers.lisp:run-all-tests@d6acd93`); the main system's `test-op`
runs it. The fixture is `tests/helpers.lisp:with-clean-terminal@d6acd93`, the
test font `tests/helpers.lisp:make-test-font@d6acd93`, and the GPU stand-in
`tests/helpers.lisp:gpu-upload@d6acd93`.

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

Table: Files added or changed in this phase: the code and tests in commit `d6acd93`, the documents in commit `d118a35`.

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
| `doc/Plan.CellModelRevision.md` | Modified | LEXTER-D120, -D22, -D23, the order of work, and the Roadmap |
| `doc/Arch.CellModel.md` | Modified | The "no glyph" glyph at generated position 6 |
| `doc/Plan.TerminalFixes1e.md` | Modified | The resolution of LEXTER-O41 |

## Outstanding Work

- **Phase 1's own tests.** The width table, the fitting of glyphs to widths,
  the replacement and "no glyph" glyphs, and dropped zero-width characters
  (LEXTER-D117, LEXTER-D122) are not findings, and
  their tests are written first in Phase 1.
- **The palette half of LEXTER-O23.** Two screens' palette generations can be
  equal for different palettes; it is tested when Phase 2 records uploads by
  owner (LEXTER-D92).
- **The existing test systems** move into the suite later
  (LEXTER-D120).
- **The Origin tests' failures.** `lexter/origin-tests` already failed 28 of
  its checks before this phase; they are outside the cell-model plan.

## Update 2026-11-17 — The terminal-fixes plan's tests

The second step of the order of work
([LEXTER-0017](Plan.CellModelRevision.md), Roadmap) adds to this suite a
reproduction test for each finding of the terminal-fixes plan
([LEXTER-0015](Plan.TerminalFixes1e.md)) that its Roadmap tests first, as
LEXTER-D80 asks: LEXTER-O21, LEXTER-O25, LEXTER-O29, LEXTER-O31,
LEXTER-O33, LEXTER-O34, and LEXTER-O35.

### Problem

LEXTER-D80 asks that each finding of the terminal-fixes plan be reproduced by
a headless test before it is repaired, in this suite. `lexter/tn3270` did not
load, so its tests could not be written until a build fault was repaired.

### Design Decisions

- **Loopback, not a recording.** LEXTER-D80 asks that the TN3270E fix be
  tested against a recorded negotiation. No TN3270E server was at hand, so
  the tests connect the real client, over a loopback socket in the same
  image, to a peer that sends the server's side of the negotiation as RFC
  2355 lays it out. The telnet tests do the same with a real telnet pane, in
  place of the in-memory stream LEXTER-D80 names, so that they test what the
  pane sends rather than the client's string writer, which LEXTER-D73 moves
  into the pane. The plan records this as LEXTER-DRAFT-terminal-fixes-1e-D16.
- **Slow tests.** The two tests that fork `/bin/true` on a PTY are in the
  suite `pty-slow`, which `run-all-tests` omits when given `:skip-slow`
  (`tests/helpers.lisp:run-all-tests@7de1459`).

### Implementation

#### A build fault repaired first

`lexter/tn3270` did not load. Commit `71e86d7` renamed its EBCDIC dependency
in `lexter.asd` from `specops/format.ebcdic` to `specops.map.ebcdic`, the
name of the package in the SpecOps repository, but the three references to
the package in the source kept the old name
(`src/tn3270/parser.lisp:ebcdic-to-char@71e86d7`,
`src/tn3270/client.lisp:char-to-ebcdic@71e86d7`), so the parser failed to
read. They now name `specops.map.ebcdic`, and `lexter/tn3270`,
`lexter/tn3270-pane`, and `lexter/origin-tests` load again.

#### Tests by finding

Table: The terminal-fixes plan's reproduction tests, by finding.

| Finding | Suite | Tests |
|---|---|---|
| LEXTER-O21 | `handler` | `rgb-to-256` stays in the palette; a 24-bit light grey does not stop the parse; an indexed colour above 255 is ignored; a tab after widening reaches the new stops |
| LEXTER-O33 | `handler` | Autowrap on the region's bottom row scrolls the region |
| LEXTER-O29 | `handler`, `structure` | The alternate screen keeps a palette entry redefined before it; the Origin integration does not read `unix-terminal-screen` |
| LEXTER-O25 | `tn3270` | SEND DEVICE-TYPE is answered with DEVICE-TYPE REQUEST; DEVICE-TYPE IS is followed by FUNCTIONS REQUEST |
| LEXTER-O31 | `tn3270` | A 132-by-27 screen has 3564 cells in every per-cell array; a data byte 255 sent as FF FF before 239 does not end a record |
| LEXTER-O34 | `telnet` | A UTF-8 pane sends `é` as C3 A9; a CP437 pane sends the no-break space as FF FF; a second WILL ECHO gets no reply |
| LEXTER-O35 | `pty`, `pty-slow` | A key and a character on a terminal with no PTY are ignored; closing a PTY after its child's end of file closes the descriptor and reaps the child |

- **Where the pieces are.** The loopback helpers are
  `tests/helpers.lisp:with-loopback-listener@7de1459` and
  `tests/helpers.lisp:exchange@7de1459`; the sessions are
  `tests/test-tn3270.lisp:with-tn3270-session@7de1459` and
  `tests/test-telnet.lisp:with-telnet-pane@7de1459`; the PTY fixture is
  `tests/test-pty.lisp:with-finished-child@7de1459`. The EBCDIC repair is in
  `src/tn3270/parser.lisp:ebcdic-to-char@7de1459` and
  `src/tn3270/client.lisp:char-to-ebcdic@7de1459`.
- **Exports.** The test of LEXTER-O31 found that `lexter/tn3270` exports
  `screen-attributes`, which nothing defines; the screen's per-cell arrays are
  `buffer`, `field-attrs`, `colors`, and `highlights`. It is one of the
  export faults of LEXTER-O37.

### Verification

- `(asdf:test-system :lexter)` runs 56 tests and 120 checks: 31 checks pass
  and 89 fail. The 9 tests that held before still pass, and every one of the
  18 new tests fails as its finding predicts: the client answers DO TN3270E
  and then nothing; the UTF-8 pane sends `é` as 69 and the CP437 pane the
  no-break space as 20; the second WILL ECHO is answered again; the key and
  character handlers signal a type error on the missing PTY; and the
  descriptor stays open and the child unreaped after `pty-close`.
- `(lexter-tests:run-all-tests :skip-slow t)` runs 118 checks in about three
  seconds, omitting `pty-slow`.
- `lexter/mouse-tests` still passes, 32 checks, and `lexter/origin-tests`
  gives the same 23 passes and 28 failures as before.

### Files

Table: Files added or changed in this update, in commit `7de1459`.

| File | Action | Description |
|---|---|---|
| `src/tn3270/parser.lisp` | Modified | The EBCDIC package's name |
| `src/tn3270/client.lisp` | Modified | The EBCDIC package's name |
| `lexter.asd` | Modified | `lexter/tests` depends on `lexter/tn3270`, `lexter/telnet-pane`, `usocket`, and `sb-posix`, and loads the new files |
| `tests/helpers.lisp` | Modified | The suites `tn3270`, `telnet`, `pty`, and `pty-slow`; `:skip-slow`; polling; loopback sockets |
| `tests/test-handler.lisp` | Modified | LEXTER-O21, LEXTER-O33, and LEXTER-O29 |
| `tests/test-structure.lisp` | Modified | LEXTER-O29's reads in the Origin integration |
| `tests/test-tn3270.lisp` | **New** | TN3270 tests |
| `tests/test-telnet.lisp` | **New** | Telnet tests |
| `tests/test-pty.lisp` | **New** | PTY tests |
| `AGENTS.md` | Modified | The `:skip-slow` run command |

### Outstanding Work

- **A recorded negotiation.** A recording from a real TN3270E server can
  replace the scripted peer when one is made
  (LEXTER-DRAFT-terminal-fixes-1e-D16).
- **The export of `screen-attributes`** is repaired with the other export
  faults of LEXTER-O37.
