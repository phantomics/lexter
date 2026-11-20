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
  - CLVT-0001
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
  that reads it, and LEXTER-D76 rules out `::`. The update of 2026-11-20
  below replaces this accumulator with cl-vt's buffer, which cl-vt now
  exports.
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

- **Extended colours.**
  `src/vt-handler.lisp:%sgr-extended-colour@3ff5a2c` reads `38` and `48`,
  for SGR's foreground and background, as an index or a 24-bit colour. It
  returns NIL for one that is incomplete or out of range, and the
  parameters it took.
- **The greyscale ramp.** `src/vt-handler.lisp:rgb-to-256@3ff5a2c` stays
  within 16–255: the ramp is capped at its last entry.
- **Erase modes.** ED and EL ignore a mode outside 0–3 and 0–2.
- **DECSTBM** gives a margin of 0 its default, and ignores a region whose
  top is not above its bottom.
- **Tab stops.** `src/vt-handler.lisp:%default-tab-stops@3ff5a2c` makes
  the tab stops, at construction, at reset, and in
  `src/vt-handler.lisp:vt-handler-resize-all@3ff5a2c`, which now rebuilds
  them for the new width. A horizontal tab reads no further than the
  tab-stop vector.
- **UTF-8.** A decoded value above U+10FFFF, or a surrogate, becomes U+FFFD.
- **The OSC string** is an adjustable string, filled to
  `+max-osc-length+`, 4096.
- **Line movement.** Line feed, index, and next line call the model's
  `line-feed`, autowrap through
  `src/vt-handler.lisp:%wrap-to-next-line@3ff5a2c`. Reverse index calls
  `reverse-line-feed`. The handler no longer reads the region's margins
  with `::`.

### The model, `src/model.lisp`, and `src/packages.lisp`

- `src/model.lisp:line-feed@3ff5a2c` and
  `src/model.lisp:reverse-line-feed@3ff5a2c` are new and exported.
- `src/model.lisp:put-char@3ff5a2c` wraps through `line-feed`.
- `src/model.lisp:scroll-up@3ff5a2c` and
  `src/model.lisp:scroll-down@3ff5a2c` clamp their count to the region's
  height.
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
- **`structure` gains 1,** that terminal modes have one home
  (`tests/test-structure.lisp:terminal-modes-have-one-home@3ff5a2c`).
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

- **cl-vt doesn't end an OSC on BEL.** Done: cl-vt fixed it, and the
  update of 2026-11-20 below records Lexter's side.
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
- **Code references.** Done: the references above are pinned to `3ff5a2c`,
  the commit that holds the fixes. The update's are pinned once it is
  committed.

## Update 2026-11-20 — OSC strings from cl-vt

The steward fixed the cl-vt fault that the first Outstanding Work item
recorded, and cl-vt now exports its OSC accessors
([CLVT-0001](../../../lisp/cl-vt/doc/Log.OscStrings.md)). This
update records Lexter's side: a test of the BEL form, and the handler reading
the OSC string from cl-vt rather than collecting a copy of its own. It
answers LEXTER-O44 of the terminal-fixes plan: the fault is fixed in cl-vt,
and Lexter has no workaround.

### Problem

Two things in Lexter followed from cl-vt's faults:

- **BEL.** An OSC string ended by BEL was never dispatched, and the output
  after it was taken into the OSC string until the next ESC. cl-vt now ends
  the string on BEL as on ST (CLVT-D1).
- **Bytes above 0x7F.** cl-vt dropped them from OSC strings, so a title
  holding a character beyond ASCII lost it. cl-vt now collects them
  (CLVT-D2), and leaves their decoding to the consumer
  (CLVT-D3).

Lexter's own copy of the OSC string, built from `:osc-put` bytes as Latin-1
characters, would have shown a UTF-8 character as its bytes, one character
for each.

### Design Decisions

- **cl-vt's buffer, not a copy.** The handler reads the OSC string when it
  ends, with `cl-vt:vt-parser-osc-bytes` (CLVT-D4), and no
  longer collects `:osc-put` bytes. The parser already bounds its buffer, so
  a second bound in Lexter is redundant, and LEXTER-D76's rule against `::`
  is kept.
- **The limit is cl-vt's 512 bytes.** The handler kept 4096 characters
  before. The commands Lexter acts on are short: a window title, and OSC 4,
  10, 11, and 104 palette changes. A title is rarely near 512 bytes, and
  LEXTER-D68 asks only that the bound exist. A larger limit would be a
  change to cl-vt's `+max-osc-length+`.
- **Decoded as printed text is.** The bytes are decoded by the encoding the
  handler prints with: UTF-8, or the CP437 table in CP437 mode. One decoder
  step, `%utf8-step`, serves both printed text and OSC strings, so that they
  treat malformed input alike, U+FFFD for values beyond Unicode included
  (LEXTER-D68).
- **A character cut at the limit is dropped.** A UTF-8 character that the
  512-byte limit cuts short is dropped rather than shown as U+FFFD, since
  its bytes are missing because of the limit and not because the host sent
  them wrongly.

### Implementation

In `src/vt-handler.lisp`:

- **The accumulator is removed:** the handler's `osc-string` slot and
  `+max-osc-length+`. `src/vt-handler.lisp:dispatch-action@158933b` passes
  `:osc-start` and `:osc-put` by, and on `:osc-end` calls `handle-osc` with
  the decoded string.
- **`src/vt-handler.lisp:%utf8-step@158933b`** takes one byte into a UTF-8
  decoder whose state it is given, and returns the codepoint the byte
  completes, if any, with the new state.
  `src/vt-handler.lisp:handle-print@158933b` keeps its state in the handler
  as before.
- **`src/vt-handler.lisp:%osc-text@158933b`** decodes an OSC string's bytes,
  through the CP437 table or with `%utf8-step` and a state of its own.
- **`src/vt-handler.lisp:handle-osc@158933b`** takes the decoded string as an
  argument.

In `tests/test-handler.lisp`, three tests are new and one is changed:

- **`tests/test-handler.lisp:osc-ended-by-bel-is-applied@158933b`**
  (LEXTER-O44): after `ESC ] 0 ; two BEL AB`, the title is `two`, and `A`
  and `B` are drawn.
- **`tests/test-handler.lisp:osc-string-is-decoded-as-printed-text-is@158933b`:**
  a title holding U+00E9 reads as the host sent it.
- **`tests/test-handler.lisp:osc-string-cut-within-a-character-drops-it@158933b`:**
  a title of one `x` and 600 copies of U+00E9 keeps the 254 that fit in 512
  bytes after `0;x`, and drops the one whose second byte is cut.
- **`tests/test-handler.lisp:long-osc-string-is-bounded@158933b`** now
  asserts the 512-byte limit.

The two decoding tests failed on the handler before the change, with cl-vt's
fix in place; the BEL test passes on either, since the fix is cl-vt's.

### Verification

- **The suite.** `(asdf:test-system :lexter)` runs 123 tests and 289 checks:
  276 pass, and the same 13 fail, which belong to LEXTER-D72, LEXTER-D73, and
  LEXTER-D74.
- **cl-vt.** Its suite passes, 5610 checks.
- **Pixels.** Every checksum of the Phase 2 fixtures is unchanged, the
  "palette" fixture's included. Its OSC 4 commands are ended by BEL, but
  each BEL is followed at once by an ESC, which ended the OSC string before
  the fix as well. The fixture never showed the fault, and the first
  Outstanding Work item was wrong to say its checksum recorded it.
- **The other test systems** give the same results: `lexter/mouse-tests`
  passes 32 checks, and `lexter/origin-tests` gives 23 passes and 28
  failures. The systems load with no new warnings.

### Files

Table: Files changed by the OSC update.

| File | Action | Description |
|---|---|---|
| `src/vt-handler.lisp` | Modified | The OSC accumulator removed; the string read from cl-vt and decoded; `%utf8-step` shared with printed text |
| `tests/test-handler.lisp` | Modified | The BEL form, decoding, and the cut character; the bound at 512 bytes |
| `compass.sexp` | Modified | CLVT federated |
| `AGENTS.md` | Modified | CLVT in the list of federated repositories |

### Outstanding Work

- **A stale build of cl-vt.** ASDF compares file dates to the second. cl-vt's
  last change to `tables.lisp` was saved in the same second as the cached
  build of it, so Lexter loaded the old tables, without the high bytes,
  until cl-vt was rebuilt with `(asdf:load-system :cl-vt :force t)`. A
  machine that built cl-vt during the change may need the same.
- **Code references.** Done: the update's references are pinned to
  `158933b`, the commit that holds it.
