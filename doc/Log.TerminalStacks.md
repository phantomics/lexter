---
id:            LEXTER-DRAFT-terminal-stacks
title:         "Consolidating the Terminal Stacks: Development Log"
genre:         Log
scope:         project
project:       Lexter
language:      en
status:        Draft
provenance:
  assistant:   opencode
  session:     "Consolidating the terminal stacks (2026-11-17); review revisions (2026-11-19)"
relates-to:
  - LEXTER-0015
  - LEXTER-0017
  - LEXTER-0014
  - LEXTER-0005
  - LEXTER-0010
  - LEXTER-0020
  - LEXTER-DRAFT-pane-profiles
  - LEXTER-DRAFT-first-edition-repairs
  - LEXTER-DRAFT-swatch-ranges
decisions:
  - LEXTER-DRAFT-terminal-stacks-D1
---

# Consolidating the Terminal Stacks: Development Log

This document records the second step of the terminal-fixes plan
([LEXTER-0015](Plan.TerminalFixes1e.md)), the consolidation of LEXTER-D67:
the standalone terminal becomes a compositor holding one workspace with one
Unix terminal pane, behind the API that the test rig
([LEXTER-0010](Log.ScreenshotTestRig.md)) and the Origin integration use, and
the code it duplicated is removed. The compositor gains
the headless flag that LEXTER-O41 chose. The cell plan's Phase 1
([LEXTER-0017](Plan.CellModelRevision.md)) waits for this step, so that its
repairs land once.

## Problem

Lexter had two terminal stacks. The standalone terminal
(`src/unix-term.lisp:gui-tick@2d4d743`) and the pane compositor
(`src/panes/compositor.lisp:gui-tick@2d4d743`) each had their own main loop,
key encoding (`src/unix-term.lisp:*key-sequences*@2d4d743` beside
`src/panes/vt-pane.lisp:*key-sequences*@2d4d743`), cursor blink, resize
handling, palette upload, and `setup-default-swatches`
(`src/unix-term.lisp:setup-default-swatches@2d4d743`,
`src/panes/compositor.lisp:setup-default-swatches@2d4d743`). The review
cited in the plan found that every fix landed twice or landed once, and the
critique traced the duplicated `setup-default-swatches` and default palettes
([LEXTER-0014](Eval.Critique.DataStructures1e.md), LEXTER-O36); Phase 1
changes the flush, the cursor, and the swatches in both. The standalone
terminal's input handlers dereferenced a missing PTY in headless mode
(LEXTER-O35), and the Origin integration read its cached screen slot, which
held the primary screen while the alternate one was shown (LEXTER-O29).

## Design Decisions

The decision is LEXTER-D67, with LEXTER-O41's resolution, both in the plan.
Choices made while building, within LEXTER-D67:

- **A layout function on the compositor.** The compositor resized its grid
  but left the panes as they were, since a paned layout is the user's. The
  standalone terminal's one pane must follow the window, so the compositor
  takes a `layout-fn`, called after a resize with the new columns and rows;
  the terminal passes one that resizes its pane, which resizes both screens
  and the PTY.
- **The prefix key belongs to each compositor, and may be NIL.** The
  standalone terminal had no meta-mode, so F12 reached the program; the
  compositor took F12 as its prefix. The terminal's compositor has no prefix
  key, and the compositor now reads its own prefix key rather than the global
  `*prefix-key*`, which every compositor in an image overwrote when it was
  initialised. The global is still set, for code that reads it; moving the
  rest of the instance state out of globals is LEXTER-D77.
- **A capture repaints in full.** The standalone terminal's capture marked its
  screen dirty before flushing; the compositor's flushed only what was dirty.
  A new generic function of the pane protocol, `pane-mark-dirty`, marks a
  pane's content dirty, with methods for VT panes and function panes, and the
  compositor's capture marks every pane and the decorations before it
  flushes.
- **A reset keeps the window.** `terminal-reset` gives the pane a new screen
  and VT handler, and the compositor a new display grid with the default
  swatches (`compositor-reset-display`), as the standalone terminal did, so
  that the test rig's fixtures replay as before.
- **Accessors read the compositor and the pane.** The terminal is a struct of
  its compositor, its pane, and the command it was made for. The accessors the
  test rig and the Origin integration use are functions that read the
  compositor or the pane, and are exported, as LEXTER-D76 asks:
  `unix-terminal-cols`, `-rows`, `-pixel-scale`, `-title` (the last two
  settable), `-command`, `-window`, `-renderer`, `-vt-handler`, `-compositor`,
  and `-pane`. The cached screen slot is gone: `terminal-screen` asks the VT
  handler for the active screen, and `terminal-pty` returns the pane's PTY;
  both names were exported before but defined nowhere (LEXTER-O37).

As LEXTER-D67 foresaw, the standalone terminal gains what panes have: mouse
reporting and wheel scrolling of the scrollback, which the pane-profiles plan
provides ([LEXTER-DRAFT-pane-profiles](Plan.PaneProfiles.md)).

Where the standalone terminal now lives is recorded as a decision of its own:

### LEXTER-DRAFT-terminal-stacks-D1 — The standalone terminal moves into `lexter/panes`

**Status:** Proposed

**Context:** The standalone terminal was part of `lexter/unix`, with the PTY
and the VT handler, and `lexter/panes` depended on `lexter/unix`. Once the
terminal is built on the compositor (LEXTER-D67), it depends on
`lexter/panes`, so it cannot stay in a system that `lexter/panes` depends on.
Its callers, the test rig and the Origin integration, load it by system.

**Decision:** `lexter/unix` keeps the PTY and the VT handler.
`src/unix-term.lisp` loads at the end of `lexter/panes`, with its package,
`lexter/unix-term`, in a file of its own, `src/packages-unix-term.lisp`; and
`lexter/test` and `lexter/origin` depend on `lexter/panes`. Code that loaded
`lexter/unix` to make a standalone terminal loads `lexter/panes` instead; the
package and its functions keep their names.

**Alternatives:**
- The pane system moved into `lexter/unix`. Rejected: the backend system would
  carry the compositor, the workspace, and every pane type, which the telnet
  and 3270 panes build on without a PTY.
- A system of its own for the standalone terminal, depending on
  `lexter/panes`. Not chosen: one more system for its callers to load, for
  some 260 lines that every caller loads with the panes already.

## Implementation

### `src/panes/compositor.lisp`

- The compositor struct gains `headless` and `layout-fn`
  (`src/panes/compositor.lisp:compositor@ee026f2`); the constructor
  `src/panes/compositor.lisp:make-paned-compositor@ee026f2` takes `:headless` and
  `:layout-fn`.
- The liveness test in `src/panes/compositor.lisp:gui-tick@ee026f2` stops the compositor when no pane is alive
  only if it is not headless (LEXTER-O41).
- `src/panes/compositor.lisp:handle-compositor-key@ee026f2` uses the compositor's own prefix key, and has no
  meta-mode when it is NIL.
- `src/panes/compositor.lisp:handle-compositor-resize@ee026f2` calls the layout function after resizing the
  grid.
- `src/panes/compositor.lisp:compositor-capture@ee026f2` binds the cursor's blink phase to the compositor's,
  marks every pane and the decorations dirty, and then flushes.
- `src/panes/compositor.lisp:compositor-reset-display@ee026f2` replaces the display grid with a fresh one of the
  compositor's size, with the default swatches.

### `src/panes/protocol.lisp`, `vt-pane.lisp`, `function-pane.lisp`, `packages.lisp`

`pane-mark-dirty` is added to the protocol
(`src/panes/protocol.lisp:pane-mark-dirty@ee026f2`), with a default that does nothing;
a VT pane marks its active screen dirty, and a function pane sets its dirty
flag. `lexter/panes` exports it, `compositor-reset-display`, and the
compositor accessors the standalone terminal reads.

### `src/unix-term.lisp` and `src/packages-unix-term.lisp`

The standalone terminal is rewritten as a layer over the compositor, 259
lines in place of 658. `make-terminal` builds a `uterm-pane`, given the
command unless the terminal has no PTY; a workspace holding it; and a
compositor with no prefix key, headless when there is no PTY, whose layout
function resizes the pane (`src/unix-term.lisp:make-terminal@ee026f2`). The
terminal is `src/unix-term.lisp:unix-terminal@ee026f2`; the screen and PTY are read
by `src/unix-term.lisp:terminal-screen@ee026f2` and
`src/unix-term.lisp:terminal-pty@ee026f2`, and a reset is
`src/unix-term.lisp:terminal-reset@ee026f2`. The `gui-*` methods delegate to the compositor;
`terminal-capture` calls `compositor-capture`; recording uses the pane's VT
handler; `terminal-config-plist` reads the compositor. The `gui-*` protocol is
the one [LEXTER-0005](Log.GUILifecycle.md) defines. Removed with the
duplication: the terminal's own main loop, key table and encoder, character
encoder, VT callback, PTY polling, cursor blink, resize handling, GLFW
callbacks, and `setup-default-swatches`.

### `src/origin-impulse.lisp`

The window fields, the configuration of the title and pixel scale, and the
export and import of handoff state
(`src/origin-impulse.lisp:%window-fields@ee026f2`) use `terminal-screen`, `terminal-pty`, and
the exported accessors, in place of the cached screen slot and internal
symbols (LEXTER-D70, LEXTER-D76).

### `lexter.asd`, `src/packages-unix.lisp`

`lexter/unix` loses `src/unix-term.lisp`, and `src/packages-unix.lisp` the
`lexter/unix-term` package; `lexter/panes` loads both at its end; `lexter/test`
and `lexter/origin` depend on `lexter/panes`.

### Tests

- `tests/test-pty.lisp`: the input tests of LEXTER-O35 route a key and a
  character through the headless terminal's compositor, as a GLFW callback
  does, where they called the standalone terminal's handlers, which are gone.
- `tests/origin-impulse-tests.lisp`: the handoff tests set a screen into the
  cached slot; they now give the terminal's pane its screen and VT handler,
  with no atlas and so no GL, and read it through `terminal-screen`.

## Verification

- **The regression suite** ([LEXTER-0020](Log.RegressionSuite.md)).
  `(asdf:test-system :lexter)` runs 120 checks: 35
  pass and 85 fail, where 31 passed before. Four reproduction tests turn
  green, all owed to this step: the default swatches have one home
  (LEXTER-O36, in part), the Origin integration reads screens through the
  handler (LEXTER-O29, in part), and a key and a character on a terminal with
  no PTY are ignored (LEXTER-O35, in part). No test that passed fails.
- **Pixels unchanged.** In a hidden test-rig terminal, three byte streams
  replayed in a row with a reset between them, one of plain, coloured,
  box-drawing, and CJK text, one of colours, reverse video, cursor movement,
  and a palette change by OSC 4, and the first again, gave the same six pixel
  checksums before and after the consolidation, with Terminus and with Unifont:
  `#xF30DE014C5651825`, `#x6FF2D60CB4D1E068`, `#xF30DE014C5651825`, and
  `#xF1F04F20171FD8DF`, `#xDE030FA5077B08ED`, `#xF1F04F20171FD8DF`.
- **A live terminal.** A hidden terminal of 40 by 6 ran
  `/bin/sh -c "printf live-ok; stty size; sleep 1.5"` on a PTY and was resized
  to 50 by 8 while its child slept: its first row read `live-ok8 50`, so the
  PTY had its new size; the terminal, its pane, and its screen were 50 by 8;
  and the terminal stopped of itself when the child exited.
- **The other test systems.** `lexter/mouse-tests` passes, 32 checks.
  `lexter/origin-tests` gives the same 23 passes and 28 failures as before;
  the failures are older than this work, since `define-terminal` now tags an
  orbital `:generic` rather than `:lexter-host`, and the tests of typed status
  fail before they reach the terminal.
- **Loading.** `lexter/tests`, `lexter/test`, `lexter/origin-tests`,
  `lexter/tn3270-pane`, and `lexter/telnet-pane` load with no warnings.

## Files

Table: Files added or changed by the consolidation, in commit `ee026f2`.

| File | Action | Description |
|---|---|---|
| `src/unix-term.lisp` | Modified | Rewritten as a layer over a compositor with one pane |
| `src/packages-unix-term.lisp` | **New** | The `lexter/unix-term` package, with the accessors exported |
| `src/packages-unix.lisp` | Modified | The `lexter/unix-term` package moved out |
| `src/panes/compositor.lisp` | Modified | The headless flag, the layout function, the prefix key per compositor, a capture that repaints in full, and `compositor-reset-display` |
| `src/panes/protocol.lisp` | Modified | `pane-mark-dirty` |
| `src/panes/vt-pane.lisp` | Modified | `pane-mark-dirty` for VT panes |
| `src/panes/function-pane.lisp` | Modified | `pane-mark-dirty` for function panes |
| `src/panes/packages.lisp` | Modified | Exports of `pane-mark-dirty`, `compositor-reset-display`, and the compositor accessors |
| `src/origin-impulse.lisp` | Modified | Screens through the handler; exported accessors |
| `lexter.asd` | Modified | The standalone terminal in `lexter/panes`; `lexter/test` and `lexter/origin` depend on it |
| `tests/test-pty.lisp` | Modified | Input routed through the compositor |
| `tests/origin-impulse-tests.lisp` | Modified | The handoff tests' screen made through the pane |

## Outstanding Work

- **The palette half of LEXTER-O29.** The alternate screen still starts from
  the default palette; it is repaired with the VT handler's fixes
  (LEXTER-D70). Since done
  ([LEXTER-DRAFT-swatch-ranges](Log.SwatchRanges.md)).
- **The rest of LEXTER-O35.** Closing a PTY after its child's end of file
  still leaves the descriptor open and the child unreaped (LEXTER-D74).
- **The default palette.** The compositor loads `make-xterm-palette` at
  initialisation, whose colour 7 differs from the model's default; the pane's
  palette replaces it at the first frame, but the two definitions remain until
  LEXTER-O36's repair in Phase 1. Since done
  ([LEXTER-DRAFT-first-edition-repairs](Log.FirstEditionRepairs.md)).
- **Globals.** `*prefix-key*` and `*cursor-blink-on*` are still set globally;
  LEXTER-D77 moves them into the compositor.
- **The Origin tests' failures** are outside the cell-model and terminal-fixes
  plans, and await a look at the Origin and Impulse libraries' current API.
