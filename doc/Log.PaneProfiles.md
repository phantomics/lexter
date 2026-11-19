---
id:            LEXTER-DRAFT-pane-profiles-log
title:         "Pane Profiles and Scrollback Viewing: Development Log"
genre:         Log
scope:         component
project:       Lexter
component:     panes
language:      en
status:        Draft
provenance:
  assistant:   opencode
  session:     "Pane profiles and the history drawing (2026-11-17)"
relates-to:
  - LEXTER-DRAFT-pane-profiles
  - LEXTER-0017
  - LEXTER-0014
  - LEXTER-0021
  - LEXTER-0020
---

# Pane Profiles and Scrollback Viewing: Development Log

This document records the first two steps of the pane-profiles plan
([LEXTER-DRAFT-pane-profiles](Plan.PaneProfiles.md)): pane profiles, typed
settings inherited through parent profiles and then through containment; and
the drawing of a pane's history, so that the mouse wheel scrolls back through
it, with the scroll-bar thumb turned the right way up. Together they repair
LEXTER-O30 of the critique
([LEXTER-0014](Eval.Critique.DataStructures1e.md)). The cell-model plan places
the history drawing before its Phase 1
([LEXTER-0017](Plan.CellModelRevision.md), Roadmap), so that Phase 1 repairs
the flush as the history drawing leaves it. The plan's other steps, snapping
and terminal events, follow later.

## Problem

The wheel arrived at a terminal pane on the primary screen and changed the
screen's scrollback viewport
(`src/panes/vt-pane.lisp:%vt-pane-scroll-local@ee026f2`), but nothing drew the
history: `src/model.lisp:flush-to-display@ee026f2` always copied the live
screen. Nothing asked for a redraw either, and the scroll-bar thumb
(`src/panes/chrome-mixin.lisp:scroll-bar-thumb-geometry@ee026f2`) stood at the
top of the bar for the live screen. The wheel's lines per notch, the plan's
first setting, needed a home that is not a global which instances write.

## Design Decisions

The decisions are the plan's: LEXTER-DRAFT-pane-profiles-D1 to -D5 and -D7.
The steward settled two of its open questions for this work: a workspace finds
its compositor through a `workspace-compositor` slot
(LEXTER-DRAFT-pane-profiles-O2), and the tests live in the Square suite
(LEXTER-DRAFT-pane-profiles-O4). Choices made while building:

- **The compositor link is set at construction.** The lean of
  LEXTER-DRAFT-pane-profiles-O2 set the slot in
  `gui-initialize`; it is set in `make-paned-compositor` instead, where the
  compositor first receives its workspaces, so that settings resolve before a
  window exists.
- **Readers at every level.** For each setting, `define-pane-profile` defines
  a generic reader on panes, which resolves the setting, and plain readers on
  workspaces, compositors, and profiles, which return the value set at that
  level or in its parents, with a second value saying whether one was found;
  each has a `setf` writer that checks the declared type and writes that
  level's own profile. `unset-setting` makes a setting inherit again.
- **The setting names are exported** (`wheel-scroll-lines`, `snap-on-input`,
  `snap-on-output`), since `unset-setting` names a setting by its symbol.
- **Sharing by initarg.** Panes and workspaces take `:profile-parent`, which
  becomes the parent of their private profile. Settings are not initargs of
  the panes; they are set with the writers.
- **The arrow keys take the factor too.** LEXTER-DRAFT-pane-profiles-D7 makes
  the lines per notch apply to the history and to the arrow keys sent in the
  alternate screen; both are built, and a report to an application stays one
  event per notch.

## Implementation

### `src/panes/profile.lisp` (new)

The registry of settings, each with its type and default; the lookup through
a profile's chain of parents, passing over profiles whose class lacks the
setting; `src/panes/profile.lisp:resolve-pane-setting@6bac50d`, which tries the pane's chain, then the
workspace's, then the compositor's, and then the default; the generic
`own-profile`; `src/panes/profile.lisp:unset-setting@6bac50d`; the macro
`src/panes/profile.lisp:define-pane-profile@6bac50d`; and Lexter's
`pane-profile`, with `wheel-scroll-lines` (an integer of at least 1, default
3), `snap-on-input` (default true), and `snap-on-output` (default false).

### `src/panes/protocol.lisp`, `workspace.lisp`, `compositor.lisp`

The pane class gains a private profile, read by `pane-profile`; the workspace
gains one, read by `workspace-profile`, and the `workspace-compositor` slot;
the compositor struct gains one, read by `compositor-profile`. Each has an
`own-profile` method. `src/panes/compositor.lisp:make-paned-compositor@6bac50d`
sets each workspace's compositor.

### `src/model.lisp`

`flush-to-display` reads the screen's viewport. At 0 it copies the dirty rows
and draws the cursor as before. Above 0, row D of the pane shows history line
V − 1 − D while that is 0 or more, and otherwise the screen's row D − V; every
row is repainted, and no cursor is drawn (`src/model.lisp:flush-to-display@6bac50d`).
The copy of one live cell becomes `src/model.lisp:%flush-cell@6bac50d`, shared by
both cases, and `src/model.lisp:%flush-history-row@6bac50d` writes a history
line as simple cells, padding a line narrower than the screen with blanks.

### `src/panes/vt-pane.lisp`, `chrome-mixin.lisp`

`src/panes/vt-pane.lisp:%vt-pane-scroll-local@6bac50d` multiplies the notches by `pane-wheel-scroll-lines`,
sets the viewport within the history, and marks the screen dirty when the view
moves; the alternate screen's arrow keys are multiplied by the same setting.
The thumb's row
(`src/panes/chrome-mixin.lisp:scroll-bar-thumb-geometry@6bac50d`) is
`(bar-height − thumb-height) × (1 − offset / max-offset)`,
at the bottom of the bar for the live screen.

### Tests

Two suites of `lexter/tests`. `profiles` (8 tests): the workspace's link to
its compositor, defaults, the order pane, workspace, compositor, the parent
chain before containment, a shared parent, a profile subclass with a setting
of its own (`test-pane-profile`), unsetting, and type checks. `scrollback`
(9 tests): the live view, a view one and two lines back, the return to the
live view, no cursor while scrolled back, a short history line padded, the
wheel by the lines setting, the redraw it asks for, and the thumb at both
ends. The history tests' font puts the space at atlas position 0, which the
first edition's flush draws as the blank (LEXTER-O28), so that no letter is
taken for a blank.

## Verification

- **The suite.** `(asdf:test-system :lexter)` runs 72 tests and 155 checks: 70
  checks pass and 85 fail, the same 85 as before. All 17 new tests pass.
- **The tests see the fault.** With the flush and the thumb of commit
  `ee026f2` restored, five of the nine scrollback tests fail: the views one and
  two lines back, the missing cursor, the padded line, and both thumbs.
- **Pixels unchanged on the live view.** The test rig's three replayed
  fixtures, in Terminus and Unifont, give the same six checksums as before.
- **The other test systems.** `lexter/mouse-tests` passes, 32 checks;
  `lexter/origin-tests` gives its same 23 passes and 28 failures.

## Files

Table: Files added or changed in the first two steps, in commit `6bac50d`.

| File | Action | Description |
|---|---|---|
| `src/panes/profile.lisp` | **New** | Pane profiles: the macro, the lookup, and Lexter's settings |
| `src/panes/protocol.lisp` | Modified | The pane's private profile |
| `src/panes/workspace.lisp` | Modified | The workspace's profile and its link to the compositor |
| `src/panes/compositor.lisp` | Modified | The compositor's profile; the link set at construction |
| `src/panes/packages.lisp` | Modified | Exports of the profile API and the settings |
| `src/model.lisp` | Modified | The flush of a scrolled-back view |
| `src/panes/vt-pane.lisp` | Modified | The wheel by the lines setting; the redraw |
| `src/panes/chrome-mixin.lisp` | Modified | The thumb turned the right way up |
| `lexter.asd` | Modified | `profile.lisp` loaded; the new test files |
| `tests/helpers.lisp` | Modified | The suites `profiles` and `scrollback` |
| `tests/test-profiles.lisp` | **New** | Profile tests |
| `tests/test-scrollback.lisp` | **New** | History, wheel, and thumb tests |
| `doc/Plan.PaneProfiles.md` | Modified | The resolutions of LEXTER-DRAFT-pane-profiles-O2 and -O4 |

## Outstanding Work

- **The plan's remaining steps.** Snapping on input and output
  (LEXTER-DRAFT-pane-profiles-D6), unseen output
  (LEXTER-DRAFT-pane-profiles-D8, with -O1), and terminal events
  (LEXTER-DRAFT-pane-profiles-D9).
- **The plan's non-goals**, carried here as the plan asks: the view drifts as
  output arrives while scrolled back; the globals `*prefix-key*` and
  `*cursor-blink-on*` remain (LEXTER-D77); the redirect protocol's payload is
  unchanged; history cells carry their screen's swatch indices, and so share
  the swatch faults that Phase 2 repairs; and the history is lossy, keeping no
  wide glyphs or layers, until the second edition keeps it as text and styles
  (LEXTER-D118).
- **The decision records' statuses.** The plan's decision records are marked
  Implemented, though before this work none was built:
  LEXTER-DRAFT-pane-profiles-D1 to LEXTER-DRAFT-pane-profiles-D5 and
  LEXTER-DRAFT-pane-profiles-D7 are built now, and
  LEXTER-DRAFT-pane-profiles-D6, LEXTER-DRAFT-pane-profiles-D8, and
  LEXTER-DRAFT-pane-profiles-D9 are not. Their statuses are for the steward to
  set.
