---
id:            LEXTER-DRAFT-handler-fixes
title:         "Host Input, the Scrolling Region, and Terminal Modes: Development Log"
genre:         Log
scope:         project
project:       Lexter
language:      en
status:        Draft
provenance:
  assistant:   opencode
  session:     "Step 0 before Phase 3: the handler's terminal fixes (2026-11-20)"
relates-to:
  - LEXTER-0015
  - LEXTER-0017
  - LEXTER-0014
  - LEXTER-0020
  - LEXTER-0016
cites:
  - title:    "XTerm Control Sequences"
    locator:  "Moy, Gildea, Dickey; https://invisible-island.net/xterm/ctlseqs/ctlseqs.txt, updated for patch #411 (2026-08-23): SGR's indexed and direct colour, ED, EL, TBC, DECSTBM, and Operating System Commands"
    external: true
---

# Host Input, the Scrolling Region, and Terminal Modes: Development Log

This document records three fixes of the terminal-fixes plan
([LEXTER-0015](Plan.TerminalFixes1e.md)), built before the cell-model
revision's Phase 3 ([LEXTER-0017](Plan.CellModelRevision.md)) because they
live in the model and handler code that Phase 3 rewrites. They are:

- LEXTER-D68, host input checked at the boundary;
- LEXTER-D69, autowrap and line feed sharing one path;
- LEXTER-D78, terminal modes kept by the handler alone.

The reproduction tests of LEXTER-O21 and LEXTER-O33, which Phase 0 wrote
([LEXTER-0020](Log.RegressionSuite.md)), now pass, together with tests of
the further cases the audit found. Phase 3 then ports correct behaviour to
the new model, with these tests to show that nothing regressed.

## Problem

The critique ([LEXTER-0014](Eval.Critique.DataStructures1e.md)) found that
host input could put the VT handler's state outside its declared types
(LEXTER-O21):

- `rgb-to-256` returned 256 for the grey (248, 248, 248);
- SGR `38;5;n` stored any n in a slot of 8 bits;
- the tab stops kept their old length when the screen was widened.

Each signalled an error inside `process-output`, abandoning the rest of the
host's buffer. Autowrap tested the screen's last row rather than the
scrolling region's bottom margin, so text that wrapped inside a region moved
the cursor out of it (LEXTER-O33). The screen carried a `mode-flags` slot and
two stubs, `set-mode` and `get-mode`, beside the handler's real modes.

## Design Decisions

The decisions are the plan's: LEXTER-D68, LEXTER-D69, and LEXTER-D78. As
LEXTER-D68 asks, xterm's documentation was read first, for the values it
defines (*XTerm Control Sequences*):

- RGB values range from 0 to 255;
- an indexed colour is an index into the palette;
- ED's modes are 0 to 3, and EL's 0 to 2;
- TBC notes that the VT100, DEC's later terminals, and xterm ignore codes
  the VT100 doesn't define;
- DECSTBM's default is the full size of the window.

It says nothing of most values out of range. Where it is silent, the value
is ignored, which is LEXTER-D68's rule. Choices made while building:

- **The audit's further cases.** LEXTER-D68 extends its rule to every
  parameter the handler stores. The audit found six beyond the critique's,
  each now with a reproduction test:
  - a 24-bit colour with a component above 255;
  - an erase in display or in line with a mode xterm doesn't define, which
    reached an `ecase` and signalled an error;
  - a scrolling region whose bottom margin was given as 0, which set the
    bottom margin to −1, so that the next scroll indexed row −1;
  - a scrolling region whose top margin is not above its bottom;
  - SU and SD with a huge count, which scrolled once for each line asked
    for, so that `CSI 999999999 S` hung the terminal;
  - an operating-system command of unbounded length, appended one
    `concatenate` at a time.
- **An out-of-range colour is ignored.** A whole extended colour is ignored
  when its index or any component is out of range, and the current colour
  stays as it was, as LEXTER-D68 decides for indexed colours.
- **A margin of 0 takes its default.** For DECSTBM, a margin given as 0
  takes its default, the window's edge. A region whose top margin is not
  above its bottom is ignored, and the cursor doesn't move, as the VT100
  requires the top margin to be less than the bottom.
- **Scrolling by more than the region.** SU and SD by more lines than the
  region holds scroll it as its height does. The clamp is in the model's
  `scroll-up` and `scroll-down`, so it serves every caller.
- **UTF-8 beyond Unicode.** A UTF-8 sequence that decodes above U+10FFFF,
  which lead bytes F5–F7 allowed, or to a surrogate, is drawn as U+FFFD. The
  architecture states that no host can reach a value above U+10FFFF, where
  Lexter names its generated glyphs (LEXTER-D89 in
  [LEXTER-0016](Arch.CellModel.md)); the decoder now makes that true, ahead
  of Phase 3's text cells, whose content word reserves those values.
- **The OSC string is bounded.** The handler keeps at most 4096 characters
  of an operating-system command and drops the rest. Its accumulator is an
  adjustable string, so that collecting is no longer quadratic. cl-vt keeps
  a bounded copy of its own, of 512 bytes, but doesn't export the function
  that reads it, and LEXTER-D76 rules out `::`.
- **One home for the region's rule, in the model.** LEXTER-D69's one
  function is the model's `line-feed`. `put-char`, the model's own
  cursor-relative writer, kept a third copy of the rule, and it had the same
  fault as autowrap. Line feed, index, next line, autowrap, and `put-char`'s
  wrap of a wide character all go through `line-feed`.
- **Its mirror, `reverse-line-feed`.** The fault had a mirror image. A line
  feed below the region, and a reverse index above it, scrolled the region,
  where xterm moves the cursor only. Reverse index now goes through
  `reverse-line-feed`, which applies the region's rule from the top margin.
  Both cases have reproduction tests, filed under LEXTER-O33.
- **LEXTER-D78's test is structural:** the screen has no `mode-flags` slot,
  and `lexter/model` exports neither stub.

## Implementation

### The handler, `src/vt-handler.lisp`

- **Extended colours.** `%sgr-extended-colour` reads `38` and `48`, for SGR's
  foreground and background, as an index or a 24-bit colour. It returns NIL
  for one that is incomplete or out of range, and the parameters it took.
- **The greyscale ramp.** `rgb-to-256` stays within 16–255: the ramp is
  capped at its last entry.
- **Erase modes.** ED and EL ignore a mode outside 0–3 and 0–2.
- **DECSTBM** gives a margin of 0 its default, and ignores a region whose
  top is not above its bottom.
- **Tab stops.** `%default-tab-stops` makes the tab stops, at construction,
  at reset, and in `vt-handler-resize-all`, which now rebuilds them for the
  new width. A horizontal tab reads no further than the tab-stop vector.
- **UTF-8.** A decoded value above U+10FFFF, or a surrogate, becomes U+FFFD.
- **The OSC string** is an adjustable string, filled to
  `+max-osc-length+`, 4096.
- **Line movement.** Line feed, index, and next line call the model's
  `line-feed`, autowrap through `%wrap-to-next-line`. Reverse index calls
  `reverse-line-feed`. The handler no longer reads the region's margins
  with `::`.

### The model, `src/model.lisp`, and `src/packages.lisp`

- `line-feed` and `reverse-line-feed` are new and exported.
- `put-char` wraps through `line-feed`.
- `scroll-up` and `scroll-down` clamp their count to the region's height.
- The `mode-flags` slot, `set-mode`, `get-mode`, and their exports are
  removed.

### Tests

- **`handler` gains 9 tests,** each a reproduction of a fault the audit
  found:
  - the out-of-range 24-bit colour;
  - the undefined erase modes;
  - DECSTBM's bottom margin of 0;
  - the inverted region;
  - SU and SD by a huge count;
  - UTF-8 beyond Unicode and surrogates;
  - the bounded OSC string;
  - a line feed below the region;
  - a reverse index above it.
- **`structure` gains 1,** that terminal modes have one home.
- **Checked before the repair.** Each new test failed on the code before the
  repair. The line-feed and reverse-index tests were also run against that
  code alone, with the repair removed.
- **SU and SD without hanging.** The test of SU and SD asks for 100,000
  lines and checks that history gains no more than the region's 3 lines.
  That shows the fault without the hang a larger count would cause.

## Verification

- **The suite.** `(asdf:test-system :lexter)` runs 120 tests and 283 checks:
  270 pass and 13 fail.
  - The reproduction tests of LEXTER-O21 and LEXTER-O33, and every test
    added here, pass.
  - The 13 failing checks belong to the terminal-fixes plan's remaining
    decisions: LEXTER-D72 (LEXTER-O25, LEXTER-O31), LEXTER-D73
    (LEXTER-O34), and LEXTER-D74 (LEXTER-O35).
- **Pixels.** `tools/check-pixel-fixtures.lisp` reproduces every checksum of
  the Phase 2 fixtures, in either order and in both fonts.
- **The other test systems.** `lexter/mouse-tests` passes, 32 checks;
  `lexter/origin-tests` gives its same 23 passes and 28 failures.
- **Loading.** The systems load with no warnings. The one style warning, an
  unused variable in `src/pcf.lisp`, predates this work.

## Files

Table: Files changed by the three fixes.

| File | Action | Description |
|---|---|---|
| `src/vt-handler.lisp` | Modified | Extended colours, the ramp, erase modes, DECSTBM, tab stops, UTF-8, the OSC string, and line movement through the model |
| `src/model.lisp` | Modified | `line-feed` and `reverse-line-feed`; `put-char`'s wrap; the scroll clamp; the mode stubs removed |
| `src/packages.lisp` | Modified | The two new functions exported; the mode stubs' exports removed |
| `tests/test-handler.lisp` | Modified | The audit's further cases, and the region's mirror cases |
| `tests/test-structure.lisp` | Modified | Terminal modes in one home |

## Outstanding Work

- **cl-vt doesn't end an OSC on BEL.**
  - The audit found that cl-vt's parser ends an OSC string only on ST.
    xterm documents BEL as well, and shells set the title with it.
  - After `ESC ] 0 ; title BEL`, Lexter sets no title and swallows the
    output that follows until the next ESC. Phase 2's "palette" fixture,
    whose OSC 4 is ended by BEL, records the fault in its checksum.
  - Lexter can't work around it, since cl-vt emits no action for that BEL.
    The steward is fixing cl-vt, from a report that names the change and its
    tests.
  - A reproduction test in this suite, and the fixture's new checksum,
    follow that change.
- **Counts of 0.** An explicit count of 0, as in `CSI 0 A`, moves the cursor
  by 0 rather than 1. xterm treats it as 1, but its documentation states only
  each control's default, so this was left alone under LEXTER-D68's
  documented-behaviour rule.
- **IL and DL outside the region.** Insert and delete line still act when the
  cursor is outside the scrolling region, where xterm ignores them. It
  signals no error, and is outside LEXTER-D68 and LEXTER-D69.
- **Floating-point traps under llvmpipe.** Found while checking the
  environment for Phase 3. Mesa's LLVM-compiled code raises floating-point
  exceptions, which SBCL traps by default, so GLFW's window creation signals
  an error on llvmpipe. The test rig must mask the traps around its GL calls
  when it draws on llvmpipe (Phase 3, LEXTER-D112). With them masked, the
  integer texture-buffer check passes under Xvfb on Mesa 20.3.5.
- **Code references.** The references above name files and functions without
  a revision; they are pinned to the commit that holds the fixes once it is
  made.
