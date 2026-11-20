---
id:            LEXTER-DRAFT-dense-cell-model
title:         "The Dense Cell Model (Phase 3): Development Log"
genre:         Log
scope:         project
project:       Lexter
language:      en
status:        Draft
provenance:
  assistant:   opencode
  session:     "Phase 3, step 1: the manifests and their accessors (2026-11-20); step 2: the screen as text and styles (2026-11-20); step 3: records in the composed grid (2026-11-20); step 4: the API and surfaces (2026-11-20); step 5: the 3270 pane on a Lexter screen (2026-11-20); step 6: the renderer of records (2026-11-20)"
relates-to:
  - LEXTER-0017
  - LEXTER-0016
  - LEXTER-0025
  - LEXTER-DRAFT-handler-fixes
cites:
  - title:    "SpecOps Manifest Reference"
    locator:  "SpecOps repository (~/src/lisp/specops), doc/Ref.Manifest.md, SPECOPS-0007, release 0.2.3: defmanifest, defenum, masques, :case, marshal, unmarshal, patches, records at an index, selective reads, checks"
    external: true
  - title:    "SpecOps manifests over arrays of records"
    locator:  "SpecOps repository, test/test-manifest-arrays.lisp: the prototype manifests of Lexter's cell, after the architecture at 76741bc"
    external: true
---

# The Dense Cell Model (Phase 3): Development Log

This document records Phase 3 of the cell-model revision
([LEXTER-0017](Plan.CellModelRevision.md)), which replaces the first
edition's cells with the record of the cell-model architecture
([LEXTER-0016](Arch.CellModel.md)), as LEXTER-D102 decides. The phase is built
in eight steps, and this document gains a dated update as each lands:

1. **Groundwork:** the record, the text cell, and the swatch and palette
   texels declared as SpecOps manifests, with the accessors over them
   (LEXTER-D130, LEXTER-D127).
2. **The screen as text and styles** (LEXTER-D124, LEXTER-D119).
3. **Records built into the composed grid**, a Lisp array of bytes, with
   drawn rows, and the interim cursor drawn by transforming its cell
   (LEXTER-D129, LEXTER-D113).
4. **The API's surfaces** writing records.
5. **The 3270 pane** on a Lexter screen (LEXTER-D128).
6. **The renderer:** two `uvec4` attributes, the shader of Drawing a Pixel,
   uploads of dirty rows, and the palette slot allocator (LEXTER-D110,
   LEXTER-D92).
7. **The cell checksum**, and the fixtures re-authored on llvmpipe under
   Xvfb (LEXTER-D108, LEXTER-D112).
8. **This Log** completed.

This first part records step 1.

## Problem

Phase 3 writes every cell as a record, and LEXTER-D104 requires that one
descriptor define the record for Lisp and the shader, and that its accessors
be the only writers of its fields. LEXTER-D130 makes that descriptor a set of
SpecOps manifests, in 8-bit units and little-endian, and asks that Lexter's
other binary formats be declared the same way, the text cell and the swatch
and palette texels first, in Phase 3. Every later step writes through what
this step declares, so it comes first.

Phase 2 left the texels written by hand, at offsets of 4 bytes, in four
places: the swatch table's entries, the default palette, the screen's palette
entries, and the reset of palette entries by OSC 104.

## Design Decisions

The decisions are the plan's, LEXTER-D127 and LEXTER-D130, and the
architecture's tables of the record. Choices made while building:

- **Lexter's own manifests.** They follow the shape of SpecOps's prototypes
  of Lexter's cell (*SpecOps manifests over arrays of records*): one manifest
  for each format, one of the first eight bytes for the fields every format
  shares, and each of glyphs 1–5 a `:case` on its type bit, as a layer or as
  a mask. As LEXTER-D130 asks, they are written from the architecture as it
  stands, so they add the line size and the magnified half (LEXTER-D114).
- **The plain format only.** Phase 3 builds the plain format first, and
  writes no other. The shared view reads the first eight bytes of any
  format, a format byte that names none included, since SpecOps reads an
  unknown code of an enumeration as its integer. A record of another format
  read as plain fails the check of its constant format byte.
- **Names from the canonical terms.** Fields are named as the architecture's
  terms name them: `:palette-slot`, `:background-slot`, `:ink-slot`,
  `:glyph-count`, `:type-1` to `:type-5`, `:right-half`, `:line-size`, and
  `:magnified-half`. `:reach` is the reach field, so that a mask cuts one
  layer more than its value.
- **Reserved bits are constants.** Every reserved bit is a constant digit of
  its masque, so that a full read checks it, as LEXTER-D130 asks. In the
  shared view, bits 22–23 are a field, `:format-flags`, since a format may
  claim them from bit 23 down, as tiles do (LEXTER-D81).
- **The text cell's flags.** LEXTER-D117 stores a character's width in the
  text grid's wide bit, so the wide bit is the width, in bit 0. Bit 1 is the
  flag of a cell that holds more codepoints than its first (LEXTER-D127), and
  bits 2–15 are reserved.
- **The continuation marker** is `#xFFFFFFFF`, the largest content word. It
  lies beyond Unicode, and beyond the generated glyphs' names, 0x110000 to
  0x11003F, however many generated glyphs are added later (LEXTER-D119,
  LEXTER-D89).
- **The accessors.** Macros write, patch, and read a plain record, and the
  shared view, at a record's index, with the manifest's fields. A function
  reads or writes the glyph or ink slot of a glyph word whose number is known
  only when the code runs, and finds a record's topmost layer, which the
  interim cursor of step 3 needs. Others copy and clear runs of records, as
  composing rows does. Writing a field of a layer into a mask is refused by
  SpecOps before anything is written.
- **Checked reads only, for now.** LEXTER-D130 has the paths that draw read
  with `(:check nil)`. No path in Lisp draws from records yet. An unchecked
  read arrives with the first that does, the interim cursor of step 3 or the
  CPU renderer of Phase 5.
- **The invariants that span fields.** These are checked by two functions,
  which report each invariant a record, or a pair of halves, breaks:
  - glyph words or type bits in use beyond the glyph count;
  - a glyph count beyond six;
  - a mask that reaches more layers than lie before it;
  - a reserved bit set;
  - for a pair of halves, the wide and right-half bits, matching glyph counts
    and type bits, and the right half naming each wide glyph's second column
    (LEXTER-D126).

  Two more follow from the architecture's flags: a right-half bit without
  the wide bit, and a magnified half without a line size. Each qualifies a
  flag, and without it means nothing, so it is reported. Debugging builds
  assert these on the records they write (LEXTER-D130); the assertions
  arrive with the writers, in steps 3 and 4.
- **Which glyphs are wide.** Only the atlas knows which positions begin a
  wide glyph, so the check of halves takes a predicate for it rather than
  an atlas.
- **The texels through their manifests.** The swatch store's entries, the
  default palette, the screen's palette entries, and OSC 104's reset now
  write and read texels through the texel accessors, with no offsets of their
  own.
- **SpecOps's warnings.** SpecOps 0.2.3 binds variables it never reads when
  it writes a sub-manifest that holds a masque, as each glyph word is, and
  SBCL raises a style warning for each, 155 for the two `setf` accessors
  alone. The two record-writing macros muffle style warnings around their
  `marshal`, with a comment naming the cause. A report for SpecOps names the
  binding and its fix.
- **The version.** `lexter.asd` requires SpecOps 0.2.3, as
  `(:version "specops" "0.2.3")` (LEXTER-D130).

## Implementation

### The manifests, `src/manifests.lisp`

A new file and package, `lexter/manifests`, loaded after the package
definitions and before everything else of `lexter`.

- **Manifests.** `glyph-layer` and `glyph-mask`, the two forms of a glyph
  word; `src/manifests.lisp:plain-record@e62caa7`; `record-common`, the shared
  view; `text-cell`; and `swatch-texel` and `palette-texel`.
- **Enumerations.** `record-format`, the formats of LEXTER-D82, and
  `mask-operation`, the operations of LEXTER-D84.
- **Record arrays.** `src/manifests.lisp:make-record-array@e62caa7` makes an
  array of records of zeros.
  The macros `write-plain-record`, `patch-plain-record`, `read-plain-record`,
  `read-record-common`, and `patch-record-common` take an array, a record's
  index, and the manifest's fields. `record-format`, `copy-records`, and
  `clear-records` are functions.
- **Glyph words by number.** `src/manifests.lisp:record-glyph@e62caa7` and
  `record-ink-slot` are read
  and written with `setf`, through one branch for each glyph word;
  `record-layer-p` and `record-topmost-layer` read the glyph count and type
  bits.
- **Invariants.** `src/manifests.lisp:record-invariant-violations@e62caa7` and
  `src/manifests.lisp:half-pair-violations@e62caa7`.
- **Text cells.** `make-text-array`, the macros `write-text-cell`,
  `patch-text-cell`, and `read-text-cell`, and `text-cell-continuation-p`.
- **Texels.** `src/manifests.lisp:write-swatch-texel@e62caa7`,
  `read-swatch-texel`, `write-palette-texel`, and `read-palette-texel`,
  inline functions.

### The texels' writers

- `src/swatches.lisp`: a table's entries are written and read as swatch
  texels (`src/swatches.lisp:%add-entry@e62caa7`), and the default palette
  and the distance between two colours through palette texels.
- `src/model.lisp`: `src/model.lisp:set-palette-entry@e62caa7` and
  `get-palette-entry` write and read a palette texel.
- `src/vt-handler.lisp`: OSC 104 reads the default colour of an entry as a
  palette texel (`src/vt-handler.lisp:%osc-reset-color-104@e62caa7`).
- `src/packages.lisp` defines `lexter/manifests` and imports the texel
  accessors into `lexter/swatches` and `lexter/model`; `lexter.asd` requires
  SpecOps and loads the new file.

### Tests

A new suite, `manifests`, in `tests/test-manifests.lisp`, has 25 tests, with
a fixture, `tests/helpers.lisp:with-clean-records@e62caa7`, that binds fresh
arrays of records and text cells:

- **The worked records.** Each record of the architecture's Appendices in the
  plain format is written and compared byte for byte:
  - the record of zeros;
  - the underlined g;
  - the reversed g;
  - the red underline with a strikethrough;
  - the spelling checker's underline;
  - the scroll bar's band;
  - the mask reaching two layers;
  - the blinking g.

  The block cursor's record, an overlay instance, waits for Phase 4.
- **Halves and line sizes.** The two halves of a wide glyph, and a line size
  with its magnified half.
- **Patches and glyph words by number.** A patch leaves the rest of the
  array as it was; a glyph word is read and written by its number; a mask
  has no ink slot to write.
- **Formats and checks.** The shared view reads formats not built, a record
  of another format is not read as plain, and a reserved bit fails the check.
- **Invariants.** The worked records keep them, and a record or pair that
  breaks each is reported.
- **Copying and clearing** runs of records.
- **Text cells.** The layout, the continuation marker, and the reserved
  flags.
- **Texels.** The layout of each, and the default palette read through the
  palette texel.

## Verification

- **The suite.** `(asdf:test-system :lexter)` runs 148 tests and 359 checks:
  346 pass and 13 fail.
  - The `manifests` suite passes, 70 checks.
  - The 13 failing checks are the same as before, those of the
    terminal-fixes plan's LEXTER-D72, LEXTER-D73, and LEXTER-D74.
- **Pixels.** `tools/check-pixel-fixtures.lisp` reproduces every checksum of
  the Phase 2 fixtures, and the GPU's swatch and palette stores match, so the
  texels written through their manifests hold the bytes Phase 2 wrote by
  hand.
- **The other test systems.** `lexter/mouse-tests` passes, 32 checks;
  `lexter/origin-tests` gives its same 23 passes and 28 failures.
- **Loading.** `lexter`, `lexter/unix`, and `lexter/panes` load with the same
  four style warnings as before this work, in `src/pcf.lisp` and the
  compositor, and `lexter/tests` with the same four.
- **Speed.** On SBCL 2.3.4, in a typed loop over an array of 1,000 records,
  with values known only when the code runs:
  - a plain record of two glyph words is written in 13.6 ns;
  - a patch of the background slot and an ink slot takes 7.2 ns;
  - a read of the glyph count takes 2.4 ns;
  - a read of a glyph by its number takes 7.2 ns.

  None allocates, as SpecOps's own measures of its prototype found.

## Files

Table: Files changed by step 1.

| File | Action | Description |
|---|---|---|
| `src/manifests.lisp` | **New** | The manifests of the record, the text cell, and the texels, and their accessors |
| `tests/test-manifests.lisp` | **New** | The `manifests` suite |
| `src/packages.lisp` | Modified | The `lexter/manifests` package; its texel accessors imported where texels are written |
| `lexter.asd` | Modified | SpecOps 0.2.3 required; the new source and test files |
| `src/swatches.lisp` | Modified | Swatch and palette texels through their accessors |
| `src/model.lisp` | Modified | Palette entries through the palette texel |
| `src/vt-handler.lisp` | Modified | OSC 104's default colours through the palette texel |
| `tests/helpers.lisp` | Modified | The `manifests` suite and the `with-clean-records` fixture |

## Outstanding Work

- **SpecOps's warnings.** Done: SpecOps 0.2.4 declares the bindings
  ignorable, and Lexter requires it and no longer muffles warnings (the
  update of 2026-11-20 below).
- **Unchecked reads** for the paths that draw, with the first such path.
- **Assertions in debugging builds** of the invariants, with the writers of
  steps 3 and 4.
- **The terminal row.** Done in step 2 (the update below).
- **Code references.** Done: the references above are pinned to `e62caa7`,
  the commit that holds this step.

## Update 2026-11-20 — Step 2: the screen as text and styles

Step 2 makes a terminal's screen hold what the terminal wrote rather than
what it draws (LEXTER-D124):
- a text grid of text cells (LEXTER-D127);
- a terminal row beside each row (LEXTER-D119);
- the styles the cells were written in (LEXTER-D118, LEXTER-D125);
- a history of text and styles (LEXTER-D118).

Its rows are built into the display grid by one function, which builds the
history's rows too. Until step 3 brings the record, that function builds
the first edition's grid, so nothing on screen changes: every pixel fixture
keeps its checksum. Lexter also now requires SpecOps 0.2.4, whose writes of
sub-manifests raise no warnings, and the two record-writing macros no
longer muffle them.

### Problem

The first edition's screen held, for each cell, the atlas position of its
glyph, its swatch, and an attribute word, beside a hash table of layered
cells. The handler decided all three as it wrote: it looked the glyph up in
the atlas, applied bold-as-bright to the colours, and mapped 24-bit colour
to the palette. A row could therefore not be drawn again under another
font, setting, or palette slot, and history kept the drawn cells, not what
the host sent. LEXTER-D124 has the screen keep text and styles, with every
row built from them, and LEXTER-D125 has the presentation rules applied
when rows are built.

### Design Decisions

The decisions are the plan's: LEXTER-D118, LEXTER-D119, LEXTER-D124,
LEXTER-D125, and LEXTER-D127. The steward settled four more before this
step was built:

- **The screen's layered cells are removed.** No source file wrote them,
  and four tests of LEXTER-O27 did. Layers belong to the API's surfaces,
  which arrive in step 4 (LEXTER-D124). The tests are retired, and their
  invariants return as tests of surfaces.
- **A full style table gives the default style.** Style ids are 16 bits, so
  a terminal holds at most 65,536 styles. Styles are never freed in Phase 3,
  since LEXTER-D118 leaves freeing to the packing of history. Once the table
  is full it interns nothing, and new text takes style 0.
- **OSC 133 is not parsed yet.** The terminal row's prompt kind is kept
  through scrolling and history, and is always 0 for now. The line size
  stays 0 until DEC double-size lines are built (LEXTER-D114).
- **The soft wrap follows xterm.** Autowrap sets it, and so does a wide
  character that wraps early because it cannot begin in the last column.
  Several things clear it:
  - an erase that reaches the row's last column, since the row's text no
    longer runs on;
  - a delete of characters, which shifts blanks into the last column;
  - a character written in the last column with autowrap off;
  - a row cleared whole, by scrolling or by inserting or deleting lines.

  Cursor movement leaves it alone, as in xterm.

Choices made while building:

- **A colour is an integer.** Its top two bits say whether it is the
  default, a palette index, or a 24-bit value, so that SGR 39 and 49 are
  told apart from palette colours 7 and 0. Bold-as-bright depends on that
  difference, since it leaves the default foreground alone (LEXTER-D125).
- **A style is a structure, interned by its slots** in an `equalp` table. It
  holds three colours and the flags of bold, underline and the line style,
  strikethrough, overline, reverse video, blink, and invisible. The handler
  now records SGR 9, 29, 53, 55, 58, and 59, so that the style holds what the
  host sent, though none of them is drawn yet.
- **The handler interns lazily.** Each SGR makes a fresh copy of the current
  style, and the copy is interned when the first character is written in
  it. An interned style is never changed.
- **The settings belong to the style table.** The table is shared by a
  terminal's screens, so bold-as-bright moves there from the handler. The
  table also caches each style's swatch under the settings. Changing the
  setting clears the cache, and the handler marks both screens dirty.
- **The interim build.** `flush-to-display` gives each cell of a dirty row:
  - its glyph, from the atlas by its codepoint and width;
  - its swatch, from its style under the presentation rules.

  The swatch's four slots are the background, the foreground twice, and 0,
  exactly as the handler interned them. Reverse video, underline, and
  invisible text are still not drawn, as in the first edition; the record
  draws them in step 3. The flush now takes the atlas, which the VT pane
  passes from its handler.
- **An empty cell's content is 0.** C0 controls are never printed, so 0
  means no character. The build draws an empty cell in the atlas's empty
  glyph at position 0 (LEXTER-O28), and a screen has no blank glyph of its
  own.
- **An erased cell keeps its colours.** It is erased to a style of its
  foreground and background alone, cached for each style, as the first
  edition's erase kept a cell's swatch and cleared its attributes. A first
  version kept only the background. It changed the "colours" fixture's
  checksum, because the block cursor exchanges a blank cell's slots and so
  showed its foreground, and it was not kept. Erasing in the current
  background, as xterm does, would be a change of behaviour of its own.
- **Both halves of a wide character set the wide bit,** and the right half
  holds the continuation marker, so that each cell describes itself
  (LEXTER-D119).
- **Joined codepoints are kept by row,** in an alist of columns for each
  row. They move with their cells under inserting, deleting, scrolling, and
  resizing, and go with the row into history. A character of width 0 joins
  the cell before the cursor. At the start of a row, it joins the last cell
  of the row before if that row is soft-wrapped; otherwise it is dropped.
- **A history row** keeps its text cells without continuations, its joined
  codepoints by their place in the row, and its terminal row. The build
  passes over continuations, so a screen row and a history row are built
  by the same loop.
- **24-bit colour.** `rgb-to-256` moves from the handler to the model, which
  maps a style's 24-bit colour as rows are built.

### Implementation

- **`src/styles.lisp`**, new: colours, `style`, the style table with its
  swatch cache and the cache of erased styles,
  `src/styles.lisp:style-swatch@0d4b524`, which applies the presentation
  rules, and `rgb-to-256`.
- **`src/model.lisp`**, rewritten from the cell representation down:
  - the screen holds `text`, `clusters`, `terminal-rows`, and `styles`;
  - `write-char-at`, `put-char`, `write-string-at`, and
    `src/model.lisp:join-character@0d4b524` write codepoints;
  - the erase, insert, delete, line, scroll, and resize operations move and
    clear text cells, joined codepoints, and terminal rows together;
  - `src/model.lisp:history-row@0d4b524` is the form of history;
  - `src/model.lisp:%build-row@0d4b524` is the one function that builds a
    terminal row, and `src/model.lisp:flush-to-display@0d4b524` calls it
    for the screen and for the history.
- **`src/manifests.lisp`:** the `src/manifests.lisp:terminal-row@0d4b524`
  manifest and its accessors,
  and `copy-text-cells` and `clear-text-cells`.
- **`src/vt-handler.lisp`:**
  - the current, saved, and alternate-saved styles replace the colour and
    attribute slots;
  - `src/vt-handler.lisp:handle-sgr@0d4b524` builds a new style;
  - `%print-codepoint` joins characters of width 0;
  - `src/vt-handler.lisp:%write-printed-char@0d4b524` writes the style's
    id and sets or clears the soft wrap;
  - `src/vt-handler.lisp:vt-handler-bold-as-bright@0d4b524` reads and sets the
    style table's setting.
- **`src/panes/vt-pane.lisp`:** the flush passes the handler's atlas, and
  the screen's blank glyph is gone.
- **`lexter.asd`:** SpecOps 0.2.4, and the new source file. In
  `src/manifests.lisp`, the two record-writing macros no longer muffle style
  warnings.

### Tests

- **Migrated.** Tests that read atlas positions from the screen now read
  codepoints, and the helper `screen-glyph` is replaced by `screen-char`. The
  "no glyph" test, the blank test of LEXTER-O28, and the light grey of
  LEXTER-O21 now check the grid after a flush, where the glyph and colours
  are decided. The swatch suite's tests write cells in styles of the colours
  they need, and check the swatch the build gives: the same swatches, from
  the same table.
- **Rewritten.** The zero-width test now asserts that the character joins
  the cell before it (LEXTER-D119), with two new tests: one across a soft
  wrap, and one with nothing to join.
- **Retired.** The four tests of LEXTER-O27's layered cells in screens.
- **New in `handler`, 9 tests:**
  - SGR kept as sent;
  - default colours told apart from palette colours;
  - DECSC and DECRC with the style;
  - the alternate screen sharing the style table;
  - five tests of the soft wrap.
- **New in `model`, 11 tests:**
  - a wide character's two cells;
  - writing over a right half;
  - joined codepoints moving and clearing;
  - an erased cell's style;
  - interning, and a full style table;
  - bold-as-bright at the build, a changed setting, and 24-bit colour
    mapped at the build;
  - history's text and its build.
- **New in `structure`:** a terminal's screen holds text and styles only.

### Verification

- **The suite.** `(asdf:test-system :lexter)` runs 167 tests and 441 checks:
  428 pass and 13 fail. The failures are the same as before, those of
  LEXTER-D72, LEXTER-D73, and LEXTER-D74.
- **Pixels.** `tools/check-pixel-fixtures.lisp` reproduces every checksum of
  the Phase 2 fixtures, in both orders and both fonts, and the GPU's stores
  match.
- **The other test systems.** `lexter/mouse-tests` passes, 32 checks;
  `lexter/origin-tests` gives its same 23 passes and 28 failures.
- **Loading.** Every system loads with the same style warnings as before,
  and the record writers raise none under SpecOps 0.2.4.

### Files

Table: Files changed by step 2.

| File | Action | Description |
|---|---|---|
| `src/styles.lisp` | **New** | Colours, styles, the style table, and the presentation rules |
| `src/model.lisp` | Modified | The screen as text, joined codepoints, terminal rows, and styles; history rows; the one build |
| `src/manifests.lisp` | Modified | The terminal row; copying and clearing text cells; no muffled warnings |
| `src/packages.lisp` | Modified | The model's new exports and imports |
| `src/vt-handler.lisp` | Modified | Styles for SGR state; codepoints, joining, and soft wraps written |
| `src/panes/vt-pane.lisp` | Modified | The atlas passed to the flush |
| `lexter.asd` | Modified | SpecOps 0.2.4; `src/styles.lisp` |
| `tests/helpers.lisp` | Modified | Helpers that read and write screens through the model's API |
| `tests/test-handler.lisp` | Modified | Migrated; zero-width joining; styles and soft wraps |
| `tests/test-model.lisp` | Modified | Migrated; the text grid, styles, and history |
| `tests/test-grid.lisp` | Modified | The tests of layered cells in screens retired |
| `tests/test-swatches.lisp` | Modified | Swatches from styles |
| `tests/test-scrollback.lisp` | Modified | The empty glyph as history's padding |
| `tests/test-workspaces.lisp` | Modified | Codepoints written |
| `tests/test-structure.lisp` | Modified | Screens hold text and styles only |

### Outstanding Work

- **Drawing what styles hold.** Reverse video, underline, invisible text,
  and blink are drawn from styles once the record is built, in step 3.
- **Freeing styles,** with the packing of history (LEXTER-D118).
- **Erasing in the current background,** as xterm does, if the steward
  wants that change.
- **OSC 133 and DEC double-size lines,** which would write the terminal
  row's prompt kind and line size.
- **The first edition's specification.**
  [LEXTER-DRAFT-data-structures-1e](Spec.DataStructures1e.md) still
  describes the screen's cells as they were. It is superseded by the second
  edition's specification at the end of the plan, rather than amended now.
- **Code references.** Done: the update's references are pinned to
  `0d4b524`, the commit that holds it.

## Update 2026-11-20 — Step 3: records in the composed grid

Step 3 makes the composed grid an array of records (LEXTER-D129), with a
change stamp for each row (LEXTER-D113), and builds a terminal's rows into
it as records. The build applies the presentation rules: reverse video
through the background slot, invisible text as no glyphs, the underline as a
mask in the text's colour, and the blink flag. The interim cursor transforms
its cell. The renderer that draws records is step 6. Until then, the grid's
records are turned into the first edition's instances. That is enough for
reverse video and the underline to be drawn now, which the first edition
never drew.

### Problem

The grid held the first edition's cells:
- a glyph and swatch for each cell, with wide and continuation flags;
- a hash table of layered cells;
- a dirty bit for each row, which nothing read (LEXTER-O40).

Reverse video, invisible text, and the underline were kept in the
handler's attributes but never drawn. LEXTER-D129 has the grid hold
records, read and written only through their accessors, and LEXTER-D113
has each row carry a change stamp in place of the dirty bit.

### Design Decisions

The decisions are the plan's and the architecture's: LEXTER-D129,
LEXTER-D113, LEXTER-D86, LEXTER-D88, LEXTER-D89, LEXTER-D94, LEXTER-D101,
and LEXTER-D126. The steward settled four more before this step was built:

- **Records drawn through the first edition's renderer until step 6.**
  `build-render-data` turns the records into the first edition's
  instances:
  - a cell of one glyph layer in ink slot 1 over background slot 0 is a
    simple instance, drawn as before;
  - any other plain cell is layered instances, its first layer opaque over
    its background slot;
  - a union mask that cuts one layer is drawn as a layer in that layer's
    ink, which colours the same pixels;
  - other masks and blink are not drawn until step 6.
- **The first edition's writers, over records.** The function pane, the
  workspace's decorations, the 3270 pane, and the demo keep writing
  through `set-simple-cell`, `set-cell-layer`, and their companions, which
  now write records. A transparent side maps as LEXTER-D86 has it: `:bg` is
  a selector of 0, `:fg` a selector of 1, and `:none` on layer 0 gives the
  cell its background slot. Steps 4 and 5 move these writers to records.
- **Stamps on the grid now, on screens later.** The grid's rows carry
  change stamps. A screen keeps its dirty bits while the flush is their
  only reader.
- **The underline from the font's ascent.** The single underline, atlas
  position 9, is drawn from the font's ascent: one row below the baseline,
  max(1, cell height ÷ 16) thick, kept inside the cell. The PCF loader does
  not read the XLFD properties that LEXTER-D89 would place it by.

Choices made while building:

- **What the build writes.** Each cell is a plain record:
  - its glyph as layer 0 in ink slot 1, over background slot 0;
  - its style's swatch, and the terminal's palette slot, which the VT pane
    passes to the flush;
  - for reverse video, background slot 1 and ink slot 0, in the same swatch
    as without it, so that no reversed swatch is interned (LEXTER-D86,
    LEXTER-O24);
  - for invisible text, a glyph count of 0;
  - for an underline, the line glyph of the style's line style as a union
    mask reaching one layer (LEXTER-D88);
  - for blink, the blink flag.

  An empty cell is a record with no glyphs, rather than the empty glyph.
- **The halves of a wide character.** Both halves are wide, and the second
  sets the right-half bit. The right half names the glyph's position plus 1
  when the glyph is a wide entry of the atlas, and otherwise the same
  narrow glyph, such as the "no glyph" glyph (LEXTER-D126). The underline
  mask is narrow, and each half carries it.
- **The interim cursor.** The cursor's cell has its background slot
  exchanged with its topmost layer's ink slot, past any mask, as an overlay
  will copy the cell in Phase 4 (LEXTER-D93). It changes both halves of a
  wide character, so that they still match. A cell with no layer takes
  slot 1 as its background. On a cell of one layer this draws the same
  pixels as the first edition's exchange.
- **One counter for stamps.** `next-change-stamp` takes the next value of
  one counter, which every write of a record to a grid takes. Making,
  resizing, or touching a whole grid gives every row a new stamp. The
  renderer still builds every row each frame; uploads by stamp, and the
  clock masks that renderers derive, come with step 6.
- **An adapter that costs little.** A first version of the adapter read
  every record's layers into a list. It took 1.8 ms and allocated 750 KB a
  frame for a grid of 200 by 60. Text cells now take a path that reads
  their few fields at once, at 0.40 ms with nothing allocated; the first
  edition's builder took 0.08 ms.
- **Accessors for the grid.** Rather than reach the manifests' internals,
  the grid uses new exported accessors: a glyph word's selector
  (`record-selector`), a mask's operation and reach (`record-mask`), and a
  record's glyph count and type bits (`record-type-bits`).

### Implementation

- **`src/grid.lisp`**, rewritten:
  - the grid holds `records` and `stamps`;
  - `src/grid.lisp:write-text-record@3371b1b` writes a cell of text,
    `clear-cell` a record of zeros, and
    `src/grid.lisp:exchange-cell-slots@3371b1b` draws the interim cursor;
  - `cell-glyph`, `cell-swatch`, `wide-left-p`, and `continuation-p` read
    the records;
  - the first edition's writers write records;
  - `src/grid.lisp:build-render-data@3371b1b` builds the first edition's
    instances from the records;
  - `resize-grid` copies records;
  - `src/grid.lisp:row-stamp@3371b1b`, `touch-row`, and `touch-all-rows`
    replace the dirty bits.
- **`src/model.lisp`:** `src/model.lisp:%build-row@3371b1b` writes text
  records with the presentation rules, and `flush-to-display` takes the
  palette slot.
- **`src/atlas.lisp`:** the single underline at position 9, made by
  `src/atlas.lisp:%make-underline@3371b1b`, named `+underline-glyph+`, and
  `src/atlas.lisp:line-glyph-position@3371b1b`.
- **`src/manifests.lisp`:** `src/manifests.lisp:record-selector@3371b1b`,
  `record-mask`, and `record-type-bits`.
- **`src/packages.lisp`:** `lexter/manifests` is defined before
  `lexter/grid`, which imports its accessors; the grid's dirty-bit
  functions are gone.
- **Panes:** the VT pane passes its palette slot to the flush, and the
  compositor and `clear-grid` touch every row where they marked every row
  dirty.
- **`tools/check-pixel-fixtures.lisp`:** the new checksums of "colours" and
  "palette".

### Tests

- **The helpers** that read the grid read its records, and a new one,
  `grid-record`, reads a whole record. Every existing test passes
  unchanged.
- **New in `grid`, 14 tests:**
  - a character built as one layer;
  - reverse video through the background slot;
  - invisible text with no glyphs;
  - the underline as a mask;
  - the blink flag;
  - the two halves of a wide character;
  - every built record keeping the invariants;
  - the cursor's exchange, and on a wide character;
  - stamps on writing, and on resizing;
  - the first edition's transparent sides as selectors;
  - reverse video and the underline reaching the first edition's
    instances;
  - the grid holding records only.
- **New in `atlas`:** the single underline at position 9.

### Verification

- **The suite.** `(asdf:test-system :lexter)` runs 182 tests and 534 checks:
  521 pass and 13 fail. The failures are the same as before, those of
  LEXTER-D72, LEXTER-D73, and LEXTER-D74.
- **The instances, compared.** The first edition's instances were built
  from each fixture before and after this step, in a headless terminal of
  40 by 8. They differ only where expected:
  - the cells of "reverse" in "colours" and of "rev" in "palette" are now
    layered instances in exchanged slots;
  - on the cursor over an empty cell, ink 1 over background 1 replaces ink
    0 over background 1, which with the empty glyph draws the same pixels.
- **Pixels.** On the NVIDIA driver, in both fonts and both orders, "cjk",
  "alt", and "many" keep their checksums. "colours" and "palette" take new
  ones, which show their reverse video drawn. The GPU's stores match
  everywhere. The new checksums are recorded in
  `tools/check-pixel-fixtures.lisp`, with the reason.
- **The other test systems.** `lexter/mouse-tests` passes, 32 checks;
  `lexter/origin-tests` gives its same 23 passes and 28 failures.
- **Loading.** Every system loads with the same style warnings as before.

### Files

Table: Files changed by step 3.

| File | Action | Description |
|---|---|---|
| `src/grid.lisp` | Modified | Records and stamps; the first edition's writers and instances over records |
| `src/model.lisp` | Modified | Rows built as text records with the presentation rules |
| `src/atlas.lisp` | Modified | The single underline at position 9 |
| `src/manifests.lisp` | Modified | Accessors of selectors, masks, and type bits |
| `src/packages.lisp` | Modified | The grid's imports and exports |
| `src/panes/vt-pane.lisp` | Modified | The palette slot passed to the flush |
| `src/panes/compositor.lisp` | Modified | Every row touched on resizing |
| `src/panes/workspace.lisp` | Modified | Every row touched on clearing |
| `tools/check-pixel-fixtures.lisp` | Modified | New checksums of "colours" and "palette" |
| `tests/helpers.lisp` | Modified | Readers of records |
| `tests/test-grid.lisp` | Modified | Records, the cursor, stamps, and the adapter |
| `tests/test-atlas.lisp` | Modified | The underline glyph |

### Outstanding Work

- **Stamps on screens** (LEXTER-D113), when partial redraw or a second
  reader needs them.
- **Uploads by stamp, clock masks, and blink.** Done in step 6, which also
  removes the adapter and the first edition's instances.
- **The underline from XLFD properties,** when the PCF loader reads them.
- **Assertions in debugging builds** of the invariants. Done in step 4
  (the update below).
- **An opaque layer above the first.** Done: `set-cell-layer` is removed in
  step 4, its one caller, the demo, moved to the API.
- **Code references.** Done: the update's references are pinned to
  `3371b1b`, the commit that holds it.

## Update 2026-11-20 — Step 4: the API and surfaces

Step 4 gives Lexter's own writers an API that writes records. Those writers
are chrome, decorators, function panes, and Common Lisp applications.

- **The calls** take characters, or atlas positions, and write records of
  the plain format. On a surface they write the text cells beside them
  (LEXTER-D124).
- **Wide glyphs** are written as two halves, so that no caller writes
  halves by hand (LEXTER-D126).
- **A surface** keeps records, text, and change stamps, and is copied into
  the composed grid at its place (LEXTER-D107).
- **The writers move.** The function pane, the workspace's decorations,
  `clear-grid`, and the demo now write through the API.
- **The old API goes.** The first edition's layered API is removed.
  `set-simple-cell` and the cursor exchange stay for the 3270 pane, which
  step 5 rewrites.

### Problem

Lexter's own writers reached the composed grid through the first edition's
API, by atlas position, and kept nothing of what they wrote. A function
pane drew straight into the grid. Its helper, `write-pane-string`, passed
each character's code as an atlas position, though fonts' glyphs begin at
position 64 (LEXTER-D89); nothing called it, so the fault had no effect.
LEXTER-D124 has these writers keep their records and the text beside them,
and LEXTER-D126 has the API split a wide character into its halves.

### Design Decisions

The decisions are the plan's: LEXTER-D107, LEXTER-D117, LEXTER-D124,
LEXTER-D126, and LEXTER-D130. The steward settled five more before this
step was built:

- **A surface is records, text, and stamps.** It is a rectangle of records,
  with text cells beside them and a change stamp for each row, written only
  through the API. A function pane owns one, which its render function
  writes and its flush copies into the composed grid.
- **Decorators write the composed grid through the API.** The grid keeps
  no text, so chrome is not copyable text. A surface for chrome can follow
  if chrome needs text.
- **A surface's text cells carry style 0.** The record alone says how a cell
  looks, and the text serves selection, copying, search, and screen
  readers.
- **Debugging builds check records through a variable.** `*check-records*`
  is true when Lexter is compiled with the `:lexter-debug` feature, and the
  API checks every record it writes while it is true. Tests bind it.
- **The layered API is removed now.** `set-cell-layer`, `set-cell-swatch`,
  `clear-cell-layers`, and `cell-layered-p` go. `set-simple-cell` and the
  cursor exchange stay for the 3270 pane until step 5.

Choices made while building:

- **A surface is a grid.** The surface structure includes the display grid's,
  so the grid's readers, stamps, and copies serve both. The grid gains an
  atlas, which the API looks codepoints up in, and a palette slot, which
  the API's records draw in. The compositor gives its grid its atlas.
- **Widths.** A character is drawn at its glyph's natural width unless the
  caller asks for one (LEXTER-D117). A character that no font covers is the
  "no glyph" glyph (LEXTER-D122).
- **Halves.** In the right half of a cell, each glyph word that names a wide
  atlas entry names its second column, and a narrow glyph names itself, so
  that each half draws the narrow glyph whole (LEXTER-D126). Writing over
  either half of a pair empties the other half, in its record and its text.
- **One call for cells of several glyphs.** `put-cell` takes glyph words in
  order, each layer followed by the masks that cut it (LEXTER-D85). Each
  word names its glyph by a character or an atlas position, with its
  selector and ink slot, or its operation and reach. The cell's text is the
  character of its last layer named by one, unless the caller gives it.
- **Copying a surface.** `compose-surface` copies the records of every row
  as they are, stamping each row of the grid it writes. A wide glyph whose
  right half falls outside the copy loses its pair. A function pane writes
  and copies its surface only when it is dirty; switching workspaces marks
  every pane dirty (LEXTER-D71).
- **The demo.** The demo's scene is written through the API. Rendered on the
  GPU before and after, it is the same pixel for pixel but in its first row.
  The old scene wrote "Hello from lexter!" and then filled the grid with
  spaces over it; the scene now fills first.

### Implementation

- **`src/surface.lisp`**, new, the package `lexter/surface`:
  - `src/surface.lisp:put-char@2c398a9`, `put-string`, `put-glyph`, and
    `src/surface.lisp:put-cell@2c398a9` write cells;
  - `fill-cells` and `clear-cells` fill and clear them;
  - `char-glyph` looks a character's glyph up in the atlas;
  - `surface-char` and `surface-string` read a surface's text;
  - `src/surface.lisp:compose-surface@2c398a9` copies a surface into the
    composed grid.
- **`src/grid.lisp`:** the `surface` structure, which includes the display
  grid's, with `src/grid.lisp:make-surface@2c398a9` and `resize-surface`;
  the grid's `atlas` and `palette-slot`; `cell-index`; and the layered API
  removed.
- **`src/manifests.lisp`:** `*check-records*` and
  `src/manifests.lisp:check-record@2c398a9`.
- **`src/panes/function-pane.lisp`:** the pane keeps its atlas and a surface
  of its size
  (`src/panes/function-pane.lisp:function-pane-ensure-surface@2c398a9`). Its
  render function is called with the pane and the surface, in the pane's own
  coordinates, and its flush copies the surface into the grid.
  `write-pane-string` and `clear-pane-region` write the surface.
- **`src/panes/workspace.lisp`:** the decoration list is written with
  `put-glyph`, and `src/panes/workspace.lisp:clear-grid@2c398a9` with
  `fill-cells`.
- **`src/panes/compositor.lisp`:** the composed grid is made with the atlas.
- **`src/demo.lisp`:** the scenes are written through the API.
- **`src/packages.lisp`** and **`lexter.asd`:** the new package and file.

### Tests

A new suite, `surfaces`, in `tests/test-surfaces.lisp`, has 17 tests, with a
fixture, `with-clean-surface`:

- **Characters:**
  - a character written with its text;
  - a character's natural width, and its halves;
  - an uncovered character;
  - a string advancing by widths;
  - an underline.
- **Cells:**
  - layers and masks written in order;
  - a narrow glyph over a wide one, split half to half;
  - writing over half a pair;
  - a filled cell.
- **Composing:**
  - a surface copied into the grid at its place, with stamps;
  - a pair cut by the grid's edge;
  - the two invariants of LEXTER-O27, a cleared layer and a new swatch, as
    tests of surfaces.
- **Checks:** a record that breaks an invariant refused while checking, and
  written without.
- **Writers:**
  - a function pane writing and copying its surface;
  - a pane's string written by codepoint;
  - the grid keeping no layered API.

The test of the first edition's transparent sides is removed with
`set-cell-layer`. The scrollback test that a cursor is not drawn now checks
the cell's background slot, where it checked that the cell was layered.

### Verification

- **The suite.** `(asdf:test-system :lexter)` runs 198 tests and 588 checks:
  575 pass and 13 fail. The failures are the same as before, those of
  LEXTER-D72, LEXTER-D73, and LEXTER-D74.
- **Pixels.** `tools/check-pixel-fixtures.lisp` reproduces every checksum,
  in both fonts and both orders, and the GPU's stores match.
- **The demo** runs on the display without error, and its scene, rendered
  offscreen on the GPU, is the same as at `3371b1b` but in its first row,
  as above.
- **The other test systems.** `lexter/mouse-tests` passes, 32 checks;
  `lexter/origin-tests` gives its same 23 passes and 28 failures.
- **Loading.** Every system loads with the same style warnings as before.

### Files

Table: Files changed by step 4.

| File | Action | Description |
|---|---|---|
| `src/surface.lisp` | **New** | The API, and surfaces composed into the grid |
| `tests/test-surfaces.lisp` | **New** | The `surfaces` suite |
| `src/grid.lisp` | Modified | Surfaces; the grid's atlas and palette slot; the layered API removed |
| `src/manifests.lisp` | Modified | The checks of debugging builds |
| `src/panes/function-pane.lisp` | Modified | A surface, written by the render function and copied |
| `src/panes/workspace.lisp` | Modified | Decorations and clears through the API |
| `src/panes/compositor.lisp` | Modified | The grid made with its atlas |
| `src/panes/packages.lisp` | Modified | The function pane's surface exported |
| `src/demo.lisp` | Modified | The scenes through the API |
| `src/packages.lisp` | Modified | `lexter/surface`; the grid's exports |
| `lexter.asd` | Modified | The new source and test files |
| `tests/helpers.lisp` | Modified | The `surfaces` suite and its fixture |
| `tests/test-grid.lisp` | Modified | The test of transparent sides removed |
| `tests/test-scrollback.lisp` | Modified | No cursor, by the background slot |

### Outstanding Work

- **A function pane's render function** now takes the pane's surface, in the
  pane's coordinates, where it took the composed grid. Lexter has no other
  callers; code outside it that wrote function panes must follow.
- **Copying by stamp.** `compose-surface` copies every row it is given. A
  surface's stamps would let it copy only the rows changed since the copy
  before, if the copies are measured to cost.
- **Chrome as text,** if selection or screen readers come to need it.
- **The 3270 pane's writer.** Done in step 5 (the update below).
- **Code references.** Done: the update's references are pinned to
  `2c398a9`, the commit that holds it.

## Update 2026-11-20 — Step 5: the 3270 pane on a Lexter screen

Step 5 puts the 3270 pane on a Lexter screen, as LEXTER-D128 decides. The
3270 screen's characters are held once, in a Lexter screen of its geometry,
written through the model's operations. Its field state lies beside the
Lexter screen, and its pane builds the screen into the composed grid as every
terminal pane does (LEXTER-D124). The pane's own path to the grid is gone,
and with it `set-simple-cell`, the last of the first edition's writers.

### Problem

The 3270 pane drew a screen of its own:
- buffers of codepoints, field attributes, extended colours, and
  highlights;
- written to the grid cell by cell, in swatches of its own;
- with the cursor drawn by exchanging slots.

It never touched the model, and it ignored a field's intensity, so a
password typed into a non-display field was shown. Its screen's arrays were
made 80 by 24 whatever its geometry, the fault of LEXTER-O31 that the
terminal-fixes plan's LEXTER-D72 repairs.

### Design Decisions

The decision is LEXTER-D128. The steward settled two more before this step
was built:

- **Intensity styles a field's cells.** A non-display field's cells are
  written invisible, with their text kept, and an intensified field's are
  written bold.
- **Background colours wait.** The extended attribute for background colour
  stays ignored.

Choices made while building:

- **One copy.** A `tn3270-screen` holds a Lexter screen of its geometry,
  mode `:3270`, with no history and a blinking cursor. Beside it, it keeps
  the field attribute at each address and each cell's extended colour and
  highlight. Characters are read from the Lexter screen, by the client's
  Read Modified reply among others. `lexter/tn3270` now depends on `lexter`.
- **The cursor** is the Lexter screen's cursor: the user's cursor, which IC
  and local keys move. The host's paint pointer, the buffer address, stays
  apart in the 3270 screen.
- **Blank cells are spaces,** as the old buffer held them, so that Read
  Modified replies send what they sent before. A field attribute's
  position is a blank cell, in the plain style.
- **Restyling.** A cell's style is made from its field's intensity and its
  own extended colour and highlight. The colour maps to the palette as the
  pane mapped it, and reverse, underscore, and blink are the style's
  attributes. Every cell is restyled after each record of the data stream
  and each keystroke, in one pass that follows the field attributes in
  order, wrapping round. Only cells whose style changes mark their rows
  dirty. Styles are kept by intensity, colour, and highlight, so each is
  interned once.
- **Widths.** Every buffer address is one narrow cell, as the data stream
  decides (LEXTER-D117).
- **The pane** flushes the Lexter screen with the atlas and the default pane
  palette slot. When its workspace is switched to, it marks every row dirty
  (LEXTER-D71).
- **What changes on screen.** Reverse video is drawn through the background
  slot, the same pixels as the pane's reversed swatch, and the extended
  underscore is now drawn. Blink is carried as the blink flag, which the
  renderer draws in step 6. A character that no font covers is now the "no
  glyph" glyph, where the pane drew a space (LEXTER-D122).
- **LEXTER-O31's geometry.** Every per-cell array is now made from the
  screen's geometry, so the reproduction test of a 132-by-27 screen passes.
  It belongs to LEXTER-D72, whose record framing, the other half of
  LEXTER-O31, and negotiation (LEXTER-O25) still fail.

### Implementation

- **`src/tn3270/screen.lisp`**, rewritten:
  - the screen, `src/tn3270/screen.lisp:tn3270-screen@76ea0b6`, holds `model`,
    a Lexter screen, beside `field-attrs`, `colors`, and `highlights`;
  - every write goes through the model;
  - `src/tn3270/screen.lisp:screen-restyle@76ea0b6` gives every cell its
    style;
  - `screen-cursor-address`, `screen-dirty`, and `screen-get-char` read the
    Lexter screen;
  - `screen-erase-char` and `screen-set-field-attr` are new;
  - the colour map moved here from the pane.
- **`src/tn3270/parser.lisp`:** EUA, Erase All Unprotected, and MF write
  through the screen's functions, and each stream ends with a restyle
  (`src/tn3270/parser.lisp:process-3270-stream@76ea0b6`).
- **`src/tn3270/client.lisp`:** Read Modified reads each field's characters
  from the Lexter screen
  (`src/tn3270/client.lisp:write-modified-fields@76ea0b6`).
- **`src/tn3270-pane/tn3270-pane.lisp`:** the flush builds the pane's
  Lexter screen, which
  `src/tn3270-pane/tn3270-pane.lisp:tn3270-pane-screen@76ea0b6` finds,
  through `flush-to-display`; the pane marks its screen dirty when asked;
  and its keys write through the screen's functions.
- **`src/model.lisp`:** `make-screen` takes `:scrollback-enabled` and
  `:cursor-blink`, which the VT handler's alternate screen now uses in place
  of `::`, and `src/model.lisp:set-cell-style@76ea0b6` restyles a cell.
- **`src/grid.lisp`:** `set-simple-cell` is removed.
- **`lexter.asd`:** `lexter/tn3270` depends on `lexter`, and `lexter/tests`
  on `lexter/tn3270-pane`.

### Tests

- **Migrated.** LEXTER-O31's geometry test now checks the Lexter screen and
  the arrays beside it, and passes. The grid's test of a resized pair writes
  its pair through the API.
- **New in `tn3270`, 8 tests:**
  - the data stream writing the Lexter screen;
  - a field attribute in a blank cell;
  - a field's intensity styling its cells;
  - a changed field attribute restyling its field;
  - extended attributes as the style;
  - the pane built as a terminal is, with its cursor;
  - Read Modified sending what was typed;
  - the pane writing the grid only through the model.

### Verification

- **The suite.** `(asdf:test-system :lexter)` runs 206 tests and 617 checks:
  609 pass and 8 fail. The failures are those of LEXTER-D72's negotiation
  and framing, LEXTER-D73, and LEXTER-D74; the 5 checks of LEXTER-O31's
  geometry now pass.
- **Pixels.** `tools/check-pixel-fixtures.lisp` reproduces every checksum,
  in both fonts and both orders, and the GPU's stores match.
- **The other test systems.** `lexter/mouse-tests` passes, 32 checks;
  `lexter/origin-tests` gives its same 23 passes and 28 failures.
- **Loading.** Every system loads with the same style warnings as before.

### Files

Table: Files changed by step 5.

| File | Action | Description |
|---|---|---|
| `src/tn3270/screen.lisp` | Modified | The screen as a Lexter screen with its field state beside it |
| `src/tn3270/parser.lisp` | Modified | Writes through the screen; a restyle after each stream |
| `src/tn3270/client.lisp` | Modified | Read Modified from the Lexter screen |
| `src/tn3270/packages.lisp` | Modified | The screen's new exports |
| `src/tn3270-pane/tn3270-pane.lisp` | Modified | Built through the model; its own path to the grid removed |
| `src/model.lisp` | Modified | `:scrollback-enabled`, `:cursor-blink`, and `set-cell-style` |
| `src/vt-handler.lisp` | Modified | The alternate screen made without history through `make-screen` |
| `src/grid.lisp` | Modified | `set-simple-cell` removed |
| `src/packages.lisp` | Modified | The model's and the grid's exports |
| `lexter.asd` | Modified | `lexter/tn3270` on `lexter`; the tests on the 3270 pane |
| `tests/test-tn3270.lisp` | Modified | The geometry test migrated; the 3270 screen on the model |
| `tests/test-grid.lisp` | Modified | A resized pair written through the API |

### Outstanding Work

- **LEXTER-D72's status.** LEXTER-O31's geometry is repaired by this step;
  its record framing, and LEXTER-O25's negotiation, remain. Updating the
  terminal-fixes plan is the steward's.
- **Background colours** (XA X'45'), and the character set attribute.
- **Erase/Write Alternate** still clears without switching to the alternate
  geometry, and double-byte characters are not yet two cells (LEXTER-D117).
- **The pane's palette slot.** Done in step 6: the 3270 pane draws in slot
  0, the default palette (the update below).
- **Code references.** Done: the update's references are pinned to
  `76ea0b6`, the commit that holds it.

## Update 2026-11-20 — Step 6: the renderer of records

Step 6 draws the composed grid from its records:
- **One draw.** The grid is drawn in one instanced call: each instance is one
  cell, its record the instance's two `uvec4` attributes, and the grid's
  array of records is the upload buffer (LEXTER-D107, LEXTER-D129).
- **The shader** follows Drawing a Pixel. It is written by hand and checked
  against the manifests, pixel for pixel, on the NVIDIA driver and on
  llvmpipe (LEXTER-D130).
- **Uploads by stamp.** Only the rows whose change stamps are newer than
  those the renderer took are uploaded, and each row's clock mask is derived
  from its records as it is taken (LEXTER-D113).
- **Palette slots** come from one allocator, and each cell draws in the slot
  its header word names (LEXTER-D92).

The first edition's instances, its simple and layered shaders, the adapter
of step 3, and the palette slot that every cell shared are gone.

### Problem

Until this step, the records were turned into the first edition's
instances each frame and drawn by its two paths: a simple path, and a
layered one of up to three blended draws. That conversion drew no mask but
a union cutting one layer, no blink, and no line size. It rebuilt every
instance every frame, and drew every cell in one palette slot, the focused
pane's. Terminals took palette slots by hand, or all took slot 1.

### Design Decisions

The decisions are the plan's and the architecture's: LEXTER-D92,
LEXTER-D94, LEXTER-D107, LEXTER-D110, LEXTER-D113, LEXTER-D114, and
LEXTER-D130. The steward settled three more before this step was built:

- **A full store gives slot 0.** When every palette slot is taken, a
  terminal draws in slot 0, the default palette, and its palette changes are
  not shown until a slot frees. This is an interim rule; what a full store
  does is the open LEXTER-O50.
- **Panes with no palette draw in slot 0.** Function panes, chrome, and the
  3270 pane never change their palette, so they draw in slot 0 and take no
  slot.
- **The shader is checked against a reference, pixel by pixel.** A Lisp
  reference of Drawing a Pixel decides every pixel of a grid of records, and
  the test rig compares it with the GPU's frame exactly.

Choices made while building:

- **The instance.** Each instance is one record: words 0–3 at location 1
  and words 4–7 at location 2, read as unsigned integers. The vertex shader
  places the cell by its instance number in the grid's columns, and passes
  the record flat. The fragment shader takes the pixel's place in the cell
  in the atlas's pixels, so that pixel scale is a matter of the quad's size
  alone.
- **The shader.** It reads glyphs with `texelFetch`, from the atlas column
  each glyph word names. It applies the glyph count, the type bits, each
  mask's operation and reach, each glyph's selector, the blink phase, and
  the line size with its magnified half, which no writer sets yet
  (LEXTER-D114). It then takes the topmost covered layer's ink slot, or the
  background slot, through the swatch and the cell's palette slot. A
  palette slot beyond the store draws in slot 0. A record of another
  format, none of which is built yet, is drawn in its background slot
  (LEXTER-D82).
- **Uploads.** `plan-record-uploads` decides, without GL, which runs of rows
  a renderer must upload. It uploads the whole grid when the grid is not the
  one last drawn or its size has changed, and otherwise the rows whose
  stamps are newer than those it took. Each renderer keeps its own record of
  what it took, so readers never clear each other's work. It derives each
  row's clock mask as it takes the row, so far only the blink bit; writers
  never write the mask.
- **The blink phase** is the compositor's cursor clock (LEXTER-D94), given
  to each frame; the capture of the test rig draws in the on phase.
- **The allocator** lives with the swatch store, in `lexter/swatches`, and
  the compositor keeps one the size of its renderer's palette store. A
  terminal pane takes a slot when its screen is made and gives it back with
  its swatch range. A pane that names a slot draws in it and takes none.
  The compositor uploads, by owner, the palette of every pane of the
  workspace drawn, not only the focused pane's.
- **The store's size has one home.** `+default-palette-slots+` moves from
  the renderer to `lexter/swatches`, beside the allocator, and the renderer
  imports it.

### The shader, checked

`check-record-drawing`, in the test rig, draws a grid of 16 by 3 records in
a hidden window and compares every pixel, in both blink phases, with
`reference-pixel-slot` through the swatch and palette stores. The reference
reads each record through its manifests, not by the shader's arithmetic on
its words. The grid holds:
- the worked records of the architecture's Appendices in the plain format;
- each of the four mask operations, a reach of two layers, and both
  selectors;
- a blinking cell;
- a wide glyph's two halves with a narrow glyph over both;
- the bottom of a double-height line;
- an empty solid cell, and a format the renderer does not draw;
- cells in palette slot 1, with a palette of its own, and in a slot beyond
  the store;
- text through the API, and the interim cursor.

In Unifont, it compares 12,288 pixels at pixel scale 1 and 49,152 at scale
2. All agree on the NVIDIA driver, and on llvmpipe, Mesa 20.3.5 under Xvfb,
with floating-point traps masked. A reference made to ignore the blink phase
is caught at the blinking cell, so the comparison is not vacuous. The
reference is the seed of the CPU renderer of Phase 5 (LEXTER-D111).

### Implementation

- **`src/shaders.lisp`**, rewritten: `+cell-vert+` and `+cell-frag+` replace
  the simple and layered shaders.
- **`src/renderer.lisp`:**
  - one program, and a vertex array of the record's two halves;
  - `render-frame` takes the blink phase, uploads the records by plan, and
    draws once;
  - `upload-palette` takes the slot it uploads to;
  - `set-active-palette-slot` and the default pane slot are removed.
- **`src/grid.lisp`:**
  - `record-upload-state` and `plan-record-uploads`;
  - the grid's `clock-masks`, and `+clock-blink+`;
  - the adapter, the instance buffers, and their constants removed.
- **`src/swatches.lisp`:** `make-palette-slots`, `allocate-palette-slot`,
  `release-palette-slot`, and `palette-slot-owner`, with
  `+default-palette-slots+`.
- **`src/panes/vt-pane.lisp`:** the allocated slot, taken with the screen
  and given back with the swatch table; `vt-pane-drawn-palette-slot`, which
  the flush and `pane-palette` report.
- **`src/panes/compositor.lisp`:** the compositor's `palette-slots` and
  `palette-slots-of`; `%upload-pane-palettes` for every pane drawn; and the
  blink phase given to each frame.
- **`src/tn3270-pane/tn3270-pane.lisp`:** the pane draws in slot 0.
- **`src/unix-term.lisp`** and **`src/test-rig.lisp`:** the terminal's drawn
  slot, for the reset's upload and the check of the GPU's stores; the
  shader's check and its reference.
- **`tools/check-pixel-fixtures.lisp`:** the new checksum of "cjk" in
  Terminus.

### Tests

- **Retired:** the grid's two tests of the first edition's instances, and
  the structural test of LEXTER-O40 that read `build-render-data`.
- **New in `grid`, 4 tests:**
  - a new or resized grid taken whole;
  - only the rows written uploaded again, a test of LEXTER-O40;
  - two renderers each keeping their own stamps;
  - a row's clock mask derived from its records.
- **New in `swatches`, 5 tests:**
  - slots handed out from 1;
  - a full store giving slot 0;
  - a terminal taking and returning its slot;
  - a pane that names a slot taking none;
  - a terminal's records naming its slot.
- **New in `structure`:** the first edition's renderer gone.

### Verification

- **The suite.** `(asdf:test-system :lexter)` runs 213 tests and 645 checks:
  637 pass and 8 fail. The failures are the same as before, those of
  LEXTER-D72's negotiation and framing, LEXTER-D73, and LEXTER-D74.
- **The shader,** checked as above on both drivers and at both scales.
- **Pixels.** On the NVIDIA driver every fixture keeps its checksum in
  Unifont, so the new renderer draws what the old one drew, wide glyphs
  included. In Terminus, "cjk" changes, and only it. Terminus covers no
  ideographs, and the old renderer stretched the narrow "no glyph" glyph
  over each one's two cells, drawing the box in the left and the empty
  reserved column 7 in the right. Each half now names the "no glyph" glyph
  itself, so the box is drawn in both cells, as LEXTER-D122 and LEXTER-D126
  have it. The new checksum is recorded with the reason, and the GPU's
  stores match everywhere.
- **The demo and the live terminal** run on the display without error, the
  terminal through its frame loop with an OSC 4 palette change and blinking
  text.
- **The other test systems.** `lexter/mouse-tests` passes, 32 checks;
  `lexter/origin-tests` gives its same 23 passes and 28 failures.
- **Loading.** Every system loads with the same style warnings as before.

### Files

Table: Files changed by step 6.

| File | Action | Description |
|---|---|---|
| `src/shaders.lisp` | Modified | The shader of Drawing a Pixel, in place of the simple and layered shaders |
| `src/renderer.lisp` | Modified | One draw of the records, uploaded by stamp; palettes by slot |
| `src/grid.lisp` | Modified | The plan of uploads and clock masks; the adapter removed |
| `src/swatches.lisp` | Modified | The palette slot allocator and the store's size |
| `src/panes/vt-pane.lisp` | Modified | A palette slot taken and given back, and drawn in |
| `src/panes/compositor.lisp` | Modified | The allocator; every pane's palette uploaded; the blink phase |
| `src/panes/packages.lisp` | Modified | The panes' new exports |
| `src/tn3270-pane/tn3270-pane.lisp` | Modified | Slot 0 |
| `src/unix-term.lisp` | Modified | The drawn slot uploaded on reset |
| `src/test-rig.lisp` | Modified | The shader's check and its reference; the drawn slot |
| `src/packages.lisp` | Modified | The renderer's, grid's, shaders', and swatches' exports |
| `tools/check-pixel-fixtures.lisp` | Modified | The new checksum of "cjk" in Terminus |
| `tests/test-grid.lisp` | Modified | Uploads and clocks, in place of the first edition's instances |
| `tests/test-swatches.lisp` | Modified | Palette slots |
| `tests/test-structure.lisp` | Modified | The first edition's renderer gone |

### Outstanding Work

- **LEXTER-O50,** what a full palette store does; slot 0 is the interim
  rule.
- **Damage.** Clock masks are derived, but every frame still draws every
  row; drawing by damage is partial redraw, Phase 6 of the plan.
- **The cell checksum and the fixtures re-authored** on llvmpipe, step 7.
  The check of the shader already runs there.
- **Formats beyond the plain format** in the shader, with Later Formats.
- **Code references.** The update's references name files and functions
  without a revision; they are pinned once it is committed.
