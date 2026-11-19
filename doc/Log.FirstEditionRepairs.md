---
id:            LEXTER-DRAFT-first-edition-repairs
title:         "The First Edition Repaired (Phase 1): Development Log"
genre:         Log
scope:         project
project:       Lexter
language:      en
status:        Draft
provenance:
  assistant:   opencode
  session:     "Phase 1: the first edition repaired (2026-11-17)"
relates-to:
  - LEXTER-0017
  - LEXTER-0016
  - LEXTER-0014
  - LEXTER-0020
  - LEXTER-0021
  - LEXTER-0023
cites:
  - title:    "Unicode Character Database 17.0.0"
    locator:  "https://www.unicode.org/Public/17.0.0/ucd/: EastAsianWidth.txt, extracted/DerivedGeneralCategory.txt, emoji/emoji-data.txt"
    external: true
---

# The First Edition Repaired (Phase 1): Development Log

This document records Phase 1 of the cell-model revision
([LEXTER-0017](Plan.CellModelRevision.md)): the first edition's data model
repaired in place for the cell-model findings of the critique
([LEXTER-0014](Eval.Critique.DataStructures1e.md)), LEXTER-O19, LEXTER-O26,
LEXTER-O27, LEXTER-O28, LEXTER-O36, and LEXTER-O40, as LEXTER-D97 decides,
with the width table of LEXTER-D117 and LEXTER-D122,
the atlas's reserved positions of LEXTER-D89, and the cursor of LEXTER-D101.
Every reproduction test of those findings that Phase 0 wrote
([LEXTER-0020](Log.RegressionSuite.md)) now passes.

## Problem

Double-width characters never reached the GPU from a screen: the VT handler
wrote them narrow and advanced by one
(`src/vt-handler.lisp:%print-codepoint@6bac50d`), the flush broke the pairs
it was given, and the cursor rewrote its cell without them (LEXTER-O19). The
operations that move or clear cells left wide flags behind (LEXTER-O26).
Layered cells drifted apart between the model and the grid (LEXTER-O27).
Glyph 0 meant both a blank and the first glyph packed, and codepoint 32 was
written as a blank glyph (LEXTER-O28). Constants were defined twice
(LEXTER-O36), and `build-render-data` claimed incremental rebuilds it did not
make (LEXTER-O40). A codepoint no font covered was skipped without moving the
cursor, and widths came from the font that happened to be loaded.

## Design Decisions

The decisions are the plan's and the architecture's: LEXTER-D97, LEXTER-D98,
LEXTER-D101, LEXTER-D117, LEXTER-D122, and
LEXTER-D89. Choices made while building:

- **The data files by checksum.** At the steward's choice, the Unicode 17.0
  data files are not committed: the generator downloads them into
  `tools/ucd-cache/`, which git ignores, and checks them against SHA-256 sums
  written in it; the generated table, `src/width-data.lisp`, is committed with
  the version and the sums in its header.
- **Zero-width rules.** General categories Mn, Me, and Cf, and the Hangul
  medial vowels and final consonants, take no columns; the soft hyphen and the
  prepended concatenation marks, which are format characters drawn with a
  width, take one. The generator's header states the rules in order.
- **The policy travels with the atlas.** A width policy is fixed when an atlas
  is packed, since the fitting depends on it, and the VT handler reads the
  policy from its atlas, so that the widths it writes and the glyphs it finds
  always agree. The compositor and the standalone terminal take
  `:width-policy`.
- **Natural and fitted glyphs.** `atlas-glyph-index` takes an optional width.
  Without it, it gives the glyph of the first font that covers the codepoint,
  at its natural width, as LEXTER-D117 gives Lexter's own writers by default;
  with it, the glyph fitted to that width, which the VT handler asks for. The
  fitted glyphs are packed after the natural ones, only for the codepoints
  whose natural glyph has another width than the table's.
- **Small cells.** The replacement glyph is the "no glyph" box crossed by its
  diagonals; where the cell is too narrow for the diagonals to show inside the
  box, the box is filled, and where even the box is solid, the glyph is a
  checkerboard, so that the two are always told apart.
- **A wide uncovered character.** LEXTER-D122 draws
  the "no glyph" glyph in each cell of a wide character. The first edition
  draws a pair as one instance two cells wide from its left half's glyph, so
  the box shows in the left cell and the right cell is empty; the halves of
  Phase 3 draw it in both.
- **Wrapping a wide character.** With autowrap on, a pair that would begin in
  the last column blanks it and wraps first; with autowrap off, it is written
  in the last two columns. `put-char`, the model's cursor-relative writer,
  blanks the last column and writes the pair at the start of the next row,
  scrolling at the bottom.
- **The cursor by exchanging slots.** The grid gains `exchange-cell-slots`,
  which makes a simple cell a layered cell of one layer inking in slot 0 over
  slot 1, or exchanges the slots of a layered cell's layer 0; the cursor on a
  right half covers the pair's left half. No swatch is interned, and the
  pixels are those the reversed swatch drew.
- **One default palette.** The compositor's `make-xterm-palette` now returns
  the model's `make-default-palette`, whose colour 7 is (170, 170, 170), the
  palette every pane already showed after its first frame.
- **`add-cursor-glyphs` remains,** doing nothing, since the cursor glyphs are
  generated when an atlas is packed.

## Implementation

### The width table

- `tools/gen-width-table.lisp` (new) downloads and checks the three data
  files of Unicode 17.0 and writes `src/width-data.lisp` (new), 673 ranges of
  code points whose width is not 1, by class: 0, 2, or ambiguous.
- `src/width.lisp` (new) and the package `lexter/width`:
  `src/width.lisp:width-policy@3627e50`, with
  the width of ambiguous characters and overrides of single code points or
  ranges; `*default-width-policy*`; `unicode-width-class`; and
  `src/width.lisp:char-width@3627e50`,
  which bisects the table. It needs no GL and no font.

### The atlas, `src/atlas.lisp`

`src/atlas.lisp:pack-atlas@3627e50` reserves positions 0–63 and packs font glyphs
from position 64.
It generates the empty glyph, the full block, underline, bar, and outlined
block cursors, the replacement glyph, and the "no glyph" glyph at positions 0
to 6, named from 0x110000 in the codepoint table, in place of the private-use
codepoints the cursor glyphs had. It plans the fitting of glyphs to the width
policy (`src/atlas.lisp:%plan-atlas@3627e50`, `src/atlas.lisp:%fit-glyph@3627e50`): a
glyph of the right width from the
chain, or a narrow glyph centred at column cell-width / 2 (`%pad-glyph`), or a
wide glyph cropped to the window centred on its ink (`%crop-glyph`), or the
replacement glyph. The atlas records its width policy and a table of fitted
glyphs; `build-atlas` and `atlas-columns-for` take the policy.

### The VT handler, `src/vt-handler.lisp`

`src/vt-handler.lisp:%print-codepoint@3627e50` decides each character's width from
the table through the
atlas's policy: a character of width 0 is dropped; a pair that would begin in
the last column wraps first; and `src/vt-handler.lisp:%write-printed-char@3627e50`
writes the character
with the glyph fitted to its width, or the "no glyph" glyph, as a pair when it
is wide, and advances by its width. The screen's blank is the empty glyph.

### The model, `src/model.lisp`

- Every range operation repairs a pair it cuts at its edges
  (`src/model.lisp:%repair-pair-edges@3627e50`): the erases, through `%erase-range`; `insert-chars`
  and `delete-chars`, which move cells whole (`%move-cell`), layered entries
  included; and `resize-screen`, at a narrower right edge. `%copy-row` and
  `%clear-row` carry the wide flags. `%erase-cell` clears the wide flag.
- `write-char-at` never begins a pair in the last column, and on a layered
  cell takes the swatch and attributes as a simple cell does; `cell-swatch`
  reads a layered cell's swatch.
- The flush checks each row it copies for a left half without its right half
  (`src/model.lisp:%check-row-pairs@3627e50`, called from
  `src/model.lisp:flush-to-display@3627e50`), writes each pair once from its left half, clips a pair
  at the grid's right edge, rebuilds a layered cell whole so that a cleared
  layer is cleared in the grid, and draws the cursor with
  `src/grid.lisp:exchange-cell-slots@3627e50`.
- The blank is the empty glyph: a fresh screen, `delete-char`, and an absent
  layer's glyph. `+max-layers+` and `+swatch-slots+` are imported from the
  grid; the screen's struct default for `cursor-blink` matches its
  constructor's.

### The grid, `src/grid.lisp`

`resize-grid` copies the wide and continuation flags; the cell layer's slots
are named `ink-slot` and `bg-slot`, as the model's are, and `set-cell-layer`
takes `:bg-slot`; `exchange-cell-slots` and `continuation-p` are added;
`build-render-data` loses its ignored `force-full` and its claim of
incremental rebuilds; the struct default for `swatch-count` matches the
constructor's.

### Elsewhere

- `src/renderer.lisp`: its copy of `+layered-stride+` is removed; it uses the
  grid's.
- `src/panes/vt-pane.lisp`, `workspace.lisp`, `function-pane.lisp`,
  `compositor.lisp`: blanks and cleared grids use the empty glyph; the
  compositor takes `:width-policy` and builds its atlas with it, and its
  default palette is the model's.
- `src/unix-term.lisp`: `make-terminal` and `run-terminal` take
  `:width-policy`.
- `src/demo.lisp`: `:bg-slot` for `set-cell-layer`.

### Tests

The new suite `width` (8 tests) covers the table: Unicode 17.0, wide
ideographs and emoji, unassigned ideographs, zero-width characters, narrow
characters, ambiguous characters under two policies, overrides, and bad
overrides. The suite `atlas` gains 7 tests: the generated glyphs' positions,
a narrow glyph centred, a wide glyph cropped, the replacement glyph, a glyph
from the chain, the natural glyph without a width, and fitting by the policy.
The suite `handler` gains 4: a zero-width character dropped, an uncovered
character drawn with the "no glyph" glyph at its width, width from the table
rather than the font, and an ambiguous character following the policy. One
scrollback test now expects the blank, not the space, in a padded history
line.

## Verification

- **The suite.** `(asdf:test-system :lexter)` runs 92 tests and 201 checks:
  176 checks pass and 25 fail. Every reproduction test of LEXTER-O19,
  LEXTER-O26, LEXTER-O27, LEXTER-O28, LEXTER-O36, and LEXTER-O40 passes, and
  so does LEXTER-O20's, since its trigger was the cursor's writes to the grid's
  swatch table, which LEXTER-D101 removes. The 18 tests that fail belong to
  Phase 2 (LEXTER-O22, LEXTER-O23, LEXTER-O24) and to the terminal-fixes plan
  (LEXTER-O21, LEXTER-O25, LEXTER-O29, LEXTER-O31, LEXTER-O33, LEXTER-O34,
  LEXTER-O35). All 19 new tests pass.
- **Pixels.** In the test rig's hidden terminal, the fixture of colours,
  reverse video, cursor movement, and a palette change gives the same checksum
  as before Phase 1, in Terminus and in Unifont: the moved atlas positions, the
  empty blank, and the cursor by exchanged slots draw the same pixels. The
  fixture with CJK text changes, as it should: in Unifont the ideographs are
  now drawn two cells wide, and in Terminus, which has no glyph for them, they
  take two cells with the "no glyph" glyph, so the text after them stays in
  its columns. Captures of both were inspected.
- **A live terminal.** A terminal running `/bin/sh` on a PTY, resized while it
  runs, reports its new size to the child, and stops when the child exits.
- **The other test systems.** `lexter/mouse-tests` passes, 32 checks;
  `lexter/origin-tests` gives its same 23 passes and 28 failures.
- **Loading.** Every system loads with no warnings.

## Files

Table: Files added or changed in Phase 1, in commit `3627e50`.

| File | Action | Description |
|---|---|---|
| `tools/gen-width-table.lisp` | **New** | The generator of the width table |
| `src/width-data.lisp` | **New** | The width table of Unicode 17.0, generated |
| `src/width.lisp` | **New** | Width policies and `char-width` |
| `.gitignore` | Modified | The cache of Unicode data files |
| `src/packages.lisp` | Modified | The `lexter/width` package; the atlas's and grid's exports; the model's imports |
| `src/atlas.lisp` | Modified | Reserved positions, generated glyphs, and fitting to widths |
| `src/vt-handler.lisp` | Modified | Widths from the table; pairs; uncovered and zero-width characters; the empty blank |
| `src/model.lisp` | Modified | Pairs kept and repaired; layered cells; the flush; the cursor; the empty blank; constants |
| `src/grid.lisp` | Modified | Flags kept on resize; slot names; `exchange-cell-slots`; `build-render-data` |
| `src/renderer.lisp` | Modified | The duplicate constant removed |
| `src/panes/compositor.lisp` | Modified | The width policy; the empty blank; the default palette |
| `src/panes/vt-pane.lisp`, `workspace.lisp`, `function-pane.lisp` | Modified | The empty blank |
| `src/unix-term.lisp` | Modified | The width policy |
| `src/demo.lisp` | Modified | The renamed keyword |
| `lexter.asd` | Modified | The width files; the `width` test suite |
| `tests/helpers.lisp` | Modified | The `width` suite; atlases packed with a width policy |
| `tests/test-width.lisp` | **New** | Width table tests |
| `tests/test-atlas.lisp` | Modified | Generated glyphs and fitting |
| `tests/test-handler.lisp` | Modified | Widths in the handler |
| `tests/test-scrollback.lisp` | Modified | The blank in a padded history line |

## Outstanding Work

- **Phase 2.** The swatch ranges, which the reproduction tests of
  LEXTER-O22, LEXTER-O23, and LEXTER-O24 wait for, after LEXTER-O58 and
  LEXTER-O59 are settled. Since done
  ([LEXTER-DRAFT-swatch-ranges](Log.SwatchRanges.md)).
- **Autowrap and the scrolling region.** A pair that wraps uses the same
  wrapping as a narrow character, which still ignores the region
  (LEXTER-O33); the terminal-fixes plan's LEXTER-D69 repairs both together.
- **The 3270 pane** still falls back to the glyph of the space for a character
  it cannot find, and keeps its own path to the grid (LEXTER-O66).
- **Wide uncovered characters** show the "no glyph" glyph in their left cell
  only, until the halves of Phase 3.
- **Grapheme clusters.** Zero-width characters are dropped; the text grid of
  Phase 3 keeps them, and how they are drawn is LEXTER-O63.
