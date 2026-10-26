---
id:            LEXTER-DRAFT-mouse-reporting
title:         "Mouse Reporting: Development Log"
genre:         Log
scope:         component
project:       Lexter
component:     vt
language:      en
status:        Draft
provenance:
  assistant:   opencode
relates-to:
  - LEXTER-DRAFT-input-redirect
  - LEXTER-DRAFT-multi-buffer
decisions:
  - LEXTER-DRAFT-mouse-reporting-D1
  - LEXTER-DRAFT-mouse-reporting-D2
  - LEXTER-DRAFT-mouse-reporting-D3
  - LEXTER-DRAFT-mouse-reporting-D4
  - LEXTER-DRAFT-mouse-reporting-D5
  - LEXTER-DRAFT-mouse-reporting-D6
  - LEXTER-DRAFT-mouse-reporting-D7
---

# Mouse Reporting: Development Log

This document chronicles the design and implementation of mouse input in
Lexter: a shared GLFW pointer-plumbing layer that delivers mouse events to
panes, and a terminal mouse-reporting layer that translates those events
into xterm escape sequences (DEC private modes 1000/1002/1003 + SGR 1006)
so applications running inside a terminal pane receive the mouse.

**Date:** 2026-06-23


## Problem

Lexter had no mouse support whatsoever -- no GLFW mouse/cursor/scroll
callbacks were registered, the pane protocol had only keyboard generics,
and the `*-hit-test` stubs in the chrome mixin
(`src/panes/chrome-mixin.lisp:scroll-bar-hit-test@1f07ee8`) were never
invoked. An
application running in a `uterm-pane` (vim, tmux, htop, a TUI file
manager) could not see the pointer at all.

Two distinct consumers needed the pointer, sharing one acquisition path:

1. **Terminal mouse reporting** -- translate pointer events into the xterm
   escape sequences a terminal application reads from its stdin. This is
   the focus of this work.
2. **Substrate event delivery** -- deliver pointer events to panes via
   generic functions so a separate UI/affordance layer (the author's APL
   compiler) and local features (focus, text selection) can consume them.
   Widgets and decorators are explicitly *not* Lexter's concern; only the
   event-delivery seam is.


## Design Decisions

Settled before implementation (see the planning discussion for the full
Q&A):

### LEXTER-DRAFT-mouse-reporting-D1 — Coordinates are pane-content-relative

**Status:** Proposed

**Context:** A terminal app expects `(1,1)` at its own top-left.

**Decision:** The compositor maps window pixels to a window cell, finds
the target pane, then subtracts the pane's grid offset (and any
header/chrome via `content-row`/`content-width`/`content-height`) before
delivering. Panes never see window coordinates.

**Alternatives:**
- None recorded.

### LEXTER-DRAFT-mouse-reporting-D2 — Drag capture

**Status:** Proposed

**Context:** A drag can leave the pane it started in. Without capture,
mode-1002 drags break at pane edges.

**Decision:** The pane under the cursor at button-press grabs the
pointer; all subsequent motion and the release go to that pane until
every button is released, even if the cursor leaves the pane. Capture
lives at the compositor (routing) level and composes with the pane-level
input-redirect.

**Alternatives:**
- None recorded.

### LEXTER-DRAFT-mouse-reporting-D3 — Cell-granularity motion

**Status:** Proposed

**Context:** GLFW fires cursor-pos per pixel; xterm reports per cell.

**Decision:** The compositor dedupes by window cell and only delivers
motion on a cell change.

**Alternatives:**
- None recorded.

### LEXTER-DRAFT-mouse-reporting-D4 — SGR (1006) first; X10 later

**Status:** Proposed

**Context:** Tracking level (1000/1002/1003) and encoding (X10 vs SGR
1006) are orthogonal axes.

**Decision:** SGR is what modern apps request, has no 223-cell
coordinate cap, and distinguishes press/release explicitly -- so it is
the primary path. A small X10 encoder is included (it is trivial and
makes mode 1000 work without 1006), but SGR is the tested-and-blessed
path.

**Alternatives:**
- X10 as the primary encoding. Rejected: it has a 223-cell coordinate
  cap and does not distinguish press from release explicitly.

### LEXTER-DRAFT-mouse-reporting-D5 — Direct host write-back

**Status:** Proposed

**Context:** A mouse report must reach the backend; the trigger is
already a GLFW event inside the pane.

**Decision:** Mouse bytes are written straight to the backend via
`vt-pane-write-bytes`.

**Alternatives:**
- Routing the report through the handler's callback channel, as the DSR
  cursor report does. Noted as a future unification but not needed now.

### LEXTER-DRAFT-mouse-reporting-D6 — Substrate fall-through

**Status:** Proposed

**Context:** Pointer events are wanted by more than terminal mouse
reporting: the compositor and the APL layer use them for focus and
selection (see Problem).

**Decision:** When a terminal pane has no mouse mode active, its mouse
handlers return NIL, leaving the event available to the compositor / APL
layer for focus and selection. Mouse reporting is one *opt-in* consumer,
not a sink.

**Alternatives:**
- None recorded.

### LEXTER-DRAFT-mouse-reporting-D7 — Redirect captures the pointer too

**Status:** Proposed

**Context:** The existing `input-redirect` modal mechanism
([LEXTER-DRAFT-input-redirect](Log.InputRedirect.md)) diverted only key
and character input.

**Decision:** The mechanism is extended to divert `:mouse-button`,
`:mouse-motion`, and `:scroll` messages (wheel included), not just keys.

**Alternatives:**
- None recorded.


## Implementation

### Mouse state + encoding (`src/vt-handler.lisp`)

Two slots were added to `vt-handler`, mirroring `autowrap`/`encoding`:

- `mouse-tracking`: `nil | :normal(1000) | :button(1002) | :any(1003)`
- `mouse-encoding`: `:x10 | :sgr(1006)`

DECSET/DECRST gained clauses for 1000/1002/1003 (tracking level) and 1006
(encoding). The three tracking modes collapse to one slot, so resetting any
of them turns reporting off (apps reset symmetrically). `RIS` (`ESC c`)
clears both slots so a crashed app cannot leave the terminal grabbing the
pointer.

Encoding is split into pure, unit-testable functions:

- `encode-mouse-sgr (cb col row press-p)`
  (`src/vt-handler.lisp:encode-mouse-sgr@4d6a89d`) -> `CSI < cb ; col+1 ; row+1 M/m`.
- `encode-mouse-x10 (cb col row)` (`src/vt-handler.lisp:encode-mouse-x10@4d6a89d`)
  -> `CSI M (32+cb)(33+col)(33+row)`, or NIL
  beyond the 223-cell limit.
- `mouse-report-bytes (handler col row button action mods &key motion)`
  (`src/vt-handler.lisp:mouse-report-bytes@4d6a89d`) consults the active mode, gates motion by tracking level (`:normal`
  ignores motion; `:button` requires a held button; `:any` reports all),
  composes the modifier (shift 4, alt 8, control 16) and motion (32) bits,
  and dispatches to the encoder. Returns the byte vector or NIL.

xterm button codes used throughout: 0 left, 1 middle, 2 right, 3 "no
button" (bare motion), 64/65 wheel up/down, 66/67 wheel left/right.

### Pane protocol (`src/panes/protocol.lisp`)

Three generics with no-op defaults: `pane-handle-mouse-button (pane col row
button action mods)` (`src/panes/protocol.lisp:pane-handle-mouse-button@4d6a89d`), `pane-handle-mouse-motion (pane col row buttons
mods)` (`src/panes/protocol.lisp:pane-handle-mouse-motion@4d6a89d`),
`pane-handle-scroll (pane col row dx dy mods)`
(`src/panes/protocol.lisp:pane-handle-scroll@4d6a89d`). Each has an
`:around` method diverting to an active `input-redirect`, plus a
`pane-forward-*` helper (binding `*redirect-suppressed*`) for redirect
functions that want to pass an event through.

### VT pane (`src/panes/vt-pane.lisp`)

`pane-handle-mouse-button`/`-motion` report to the backend only when a
mouse mode is active, else return NIL (substrate fall-through).
`pane-handle-scroll` (`src/panes/vt-pane.lisp@4d6a89d`) implements the wheel
precedence table:

1. mouse mode active -> wheel as buttons 64-67;
2. no mode, alternate screen -> translate to arrow keys (one per notch);
3. no mode, primary screen -> drive local scrollback via
   `set-scrollback-viewport`.

(Application-cursor-keys mode (DECCKM) for the alt-screen arrow translation
is a noted future refinement; normal-mode arrows are sent for now.)

### Compositor (`src/panes/compositor.lisp`)

New mouse state: last cursor pixel position (the GLFW button callback
carries no coordinates), the capture pane, the held-button set, and the
last motion cell. Helpers: `compositor-pixel->cell`
(`src/panes/compositor.lisp:compositor-pixel->cell@4d6a89d`; pixel -> clamped
window cell, honoring `pixel-scale`), `compositor-pane-at`
(`src/panes/compositor.lisp:compositor-pane-at@4d6a89d`; spatial hit test over
pane rectangles), `pane-content-cell`
(`src/panes/compositor.lisp:pane-content-cell@4d6a89d`; window cell -> pane
content cell + inside-p), and `%glfw-button->xterm`
(`src/panes/compositor.lisp:%glfw-button->xterm@4d6a89d`; robust to cl-glfw3
decoding `:left`/`:right`/`:3`, and to GLFW's button order differing from
xterm's). Three GLFW callbacks (`mouse-button`, `cursor-pos`, `scroll`) are
registered alongside the existing key/char callbacks; button-press focuses
a focusable pane and starts capture; release ends capture when no buttons
remain.

### Tests (`tests/mouse-tests.lisp`, system `lexter/mouse-tests`)

In `tests/mouse-tests.lisp@4d6a89d`, 32 pure assertions (no GL/display): the SGR and X10 encoders, the
`mouse-report-bytes` gating matrix (off / normal / button-drag / any-bare /
modifiers / wheel / X10 release), the GLFW->xterm button mapping, and the
compositor's `pixel->cell` (including scale and clamp) and
`pane-content-cell` routing math. Run via `asdf:test-system
:lexter/mouse-tests`.


## Verification

`lexter/panes` and `lexter/test` compile and load clean from scratch
(cache cleared). All 32 mouse unit tests pass via both a direct call and
`asdf:test-op`. The end-to-end path (real GLFW events -> escape sequences
-> an app) could not be exercised headlessly (no display) and is consistent
with the deferred event-injection decision.



## Files

*Migration note (2026-10-25):* the Files section was a bulleted list,
after Future work; it is rewritten as a table, with the same files and
descriptions, and placed before Outstanding Work.

Table: Files added or changed in commit `4d6a89d`.

| File | Action | Description |
|------|--------|-------------|
| `src/vt-handler.lisp` | Modified | Mouse-tracking/encoding slots, DECSET/DECRST 1000/1002/1003/1006, `encode-mouse-sgr`/`encode-mouse-x10`/`mouse-report-bytes`, RIS reset |
| `src/packages-unix.lisp` | Modified | Mouse API exports |
| `src/panes/protocol.lisp` | Modified | Mouse generics, redirect `:around`, forward helpers, slot doc |
| `src/panes/vt-pane.lisp` | Modified | Terminal mouse-report methods + wheel precedence |
| `src/panes/compositor.lisp` | Modified | Mouse state, routing helpers, capture, GLFW callbacks |
| `src/panes/packages.lisp` | Modified | New generic + forward exports |
| `tests/mouse-tests.lisp` | **New** | `lexter/mouse-tests` system |
| `lexter.asd` | Modified | `lexter/mouse-tests` system |


## Outstanding Work

*Migration note (2026-10-25):* this section was headed "Future work". The
paragraph headed "Deferred" closed the Log's Design Decisions; it is kept
here, as the first item.

- **Deferred:** the xterm Shift-bypass convention (Shift forces local
  handling even when the app grabbed the mouse); the legacy single-terminal
  (`unix-term`) path (compositor-only for now); and event-injection
  end-to-end testing (until a synthetic-input harness exists).
- X10 is implemented but SGR is the blessed path; widen testing if a legacy
  app needs X10.
- Shift-bypass for local selection over an app's mouse grab.
- DECCKM-aware arrow translation for wheel in the alternate screen.
- Mouse on the legacy single-terminal `unix-term` path.
- Route mouse reports through the handler callback channel to unify with the
  DSR write-back path.
- Event-injection harness for end-to-end tests (pairs with the screenshot
  rig's deferred input recording).
