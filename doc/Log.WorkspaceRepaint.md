---
id:            LEXTER-0026
title:         "The Workspace-Switch Repaint: Development Log"
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
  session:     "The gate's questions settled, and the workspace-switch repaint (2026-11-18); review revisions (2026-11-19)"
relates-to:
  - LEXTER-0015
  - LEXTER-0017
  - LEXTER-0014
  - LEXTER-0020
  - LEXTER-0010
  - LEXTER-0025
---

# The Workspace-Switch Repaint: Development Log

This document records the terminal-fixes plan's repair of LEXTER-O32
([LEXTER-0015](Plan.TerminalFixes1e.md)), as LEXTER-D71 decides: a switch of
workspace marks every pane of the new workspace and its decorations dirty, so
that the next frame repaints it whole. The cell plan's Phase 3
([LEXTER-0017](Plan.CellModelRevision.md)) waits for this repair, since its
uploads follow the rows that change.

## Problem

`switch-workspace` cleared the display grid but marked nothing dirty. A
workspace switched to stayed blank, except for the row under each cursor,
which every flush copies again, until its panes produced output; and its
decorations, drawn only when the workspace marks them dirty, did not return
until the window was resized (LEXTER-O32).

## Design Decisions

The decision is LEXTER-D71, which treats a switch as LEXTER-D33 treats the
alternate-screen swap. Choices made while building its tests:

- **A suite of its own.** The tests are a new child suite, `workspaces`
  (`tests/helpers.lisp:workspaces@e7d68ad`), rather than a part of an existing
  one, since none of the suites covers the compositor's workspaces.
- **A compositor never initialized.** The tests make a compositor with
  `make-paned-compositor` and set its display grid directly, without
  `gui-initialize`, so that they need no window and no GL.

## Implementation

### `src/panes/compositor.lisp`

`src/panes/compositor.lisp:switch-workspace@e7d68ad` clears the grid as it
did, then calls `pane-mark-dirty` on every pane of the workspace switched to,
which every pane type defines, and `mark-decorations-dirty` on the workspace.

### Tests

A new suite, `workspaces`, has 2 tests of a compositor that is never
initialized, with two workspaces of one terminal pane each, made on a test
atlas with no PTY (`tests/test-workspaces.lisp:with-two-workspaces@e7d68ad`):
a workspace switched away from and back to shows again a character its pane
wrote below the cursor's row, and draws again a list decoration beside its
pane. Both failed before the repair and pass after it. The character is
written below the cursor's row because every flush copies that row again,
which would hide the fault.

## Verification

- **The suite.** `(asdf:test-system :lexter)` runs 110 tests and 253 checks:
  232 pass and 21 fail, the same 21 that belong to the rest of the
  terminal-fixes plan (LEXTER-O21, LEXTER-O25, LEXTER-O31, LEXTER-O33,
  LEXTER-O34, LEXTER-O35).
- **Pixels.** The test rig's captures
  ([LEXTER-0010](Log.ScreenshotTestRig.md)) mark every pane and the
  decorations dirty before they render, so the fixtures do not pass through a
  switch and their checksums are unaffected. With the repair in place,
  `tools/check-pixel-fixtures.lisp`, run during the review of
  [LEXTER-0025](Log.SwatchRanges.md), reproduced all ten checksums of the
  Phase 2 fixtures, in either order and in both fonts, and found every swatch
  equal on the GPU.

## Files

Table: Files added or changed for the workspace-switch repaint, in commit `e7d68ad`.

| File | Action | Description |
|---|---|---|
| `src/panes/compositor.lisp` | Modified | `switch-workspace` marks the new workspace dirty |
| `tests/test-workspaces.lisp` | **New** | The `workspaces` suite |
| `tests/helpers.lisp` | Modified | The `workspaces` suite in the hierarchy and the fast run |
| `lexter.asd` | Modified | The new test file |

## Outstanding Work

- **The rest of the terminal-fixes plan.** Its other findings remain, and
  their reproduction tests fail, the 21 checks under Verification: LEXTER-O21,
  LEXTER-O25, LEXTER-O31, LEXTER-O33, LEXTER-O34, and LEXTER-O35.
