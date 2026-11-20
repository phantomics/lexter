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
  session:     "Phase 3, step 1: the manifests and their accessors (2026-11-20)"
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
  word; `plain-record`; `record-common`, the shared view; `text-cell`; and
  `swatch-texel` and `palette-texel`.
- **Enumerations.** `record-format`, the formats of LEXTER-D82, and
  `mask-operation`, the operations of LEXTER-D84.
- **Record arrays.** `make-record-array` makes an array of records of zeros.
  The macros `write-plain-record`, `patch-plain-record`, `read-plain-record`,
  `read-record-common`, and `patch-record-common` take an array, a record's
  index, and the manifest's fields. `record-format`, `copy-records`, and
  `clear-records` are functions.
- **Glyph words by number.** `record-glyph` and `record-ink-slot` are read
  and written with `setf`, through one branch for each glyph word;
  `record-layer-p` and `record-topmost-layer` read the glyph count and type
  bits.
- **Invariants.** `record-invariant-violations` and `half-pair-violations`.
- **Text cells.** `make-text-array`, the macros `write-text-cell`,
  `patch-text-cell`, and `read-text-cell`, and `text-cell-continuation-p`.
- **Texels.** `write-swatch-texel`, `read-swatch-texel`,
  `write-palette-texel`, and `read-palette-texel`, inline functions.

### The texels' writers

- `src/swatches.lisp`: a table's entries are written and read as swatch
  texels, and the default palette and the distance between two colours
  through palette texels.
- `src/model.lisp`: `set-palette-entry` and `get-palette-entry` write and
  read a palette texel.
- `src/vt-handler.lisp`: OSC 104 reads the default colour of an entry as a
  palette texel.
- `src/packages.lisp` defines `lexter/manifests` and imports the texel
  accessors into `lexter/swatches` and `lexter/model`; `lexter.asd` requires
  SpecOps and loads the new file.

### Tests

A new suite, `manifests`, in `tests/test-manifests.lisp`, has 25 tests, with
a fixture, `with-clean-records`, that binds fresh arrays of records and text
cells:

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

- **SpecOps's warnings.** The report for SpecOps names the binding in
  `marshal`'s expansion of a sub-manifest and its fix. Once it is fixed and
  Lexter's required version raised, the two macros stop muffling style
  warnings.
- **Unchecked reads** for the paths that draw, with the first such path.
- **Assertions in debugging builds** of the invariants, with the writers of
  steps 3 and 4.
- **The terminal row**, the soft wrap, prompt kind, and line size of each row
  (LEXTER-D119), with the screen in step 2.
- **Code references.** The references above name files and functions without
  a revision; they are pinned to the commit that holds this step once it is
  made.
