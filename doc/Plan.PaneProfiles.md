---
id:            LEXTER-DRAFT-pane-profiles
title:         "Pane Profiles and Scrollback Viewing: Development Plan"
genre:         Plan
scope:         component
project:       Lexter
component:     panes
language:      en
status:        Draft
provenance:
  assistant:   opencode
relates-to:
  - LEXTER-DRAFT-mouse-reporting
  - LEXTER-DRAFT-input-redirect
  - LEXTER-DRAFT-multi-buffer
  - LEXTER-DRAFT-screenshot-test-rig
cites:
  - title:    "Session transcript ses_febe-LexterCritique"
    locator:  "session-ses_febe-LexterCritique.md, the closing review"
    external: true
decisions:
  - LEXTER-DRAFT-pane-profiles-D1
  - LEXTER-DRAFT-pane-profiles-D2
  - LEXTER-DRAFT-pane-profiles-D3
  - LEXTER-DRAFT-pane-profiles-D4
  - LEXTER-DRAFT-pane-profiles-D5
  - LEXTER-DRAFT-pane-profiles-D6
  - LEXTER-DRAFT-pane-profiles-D7
  - LEXTER-DRAFT-pane-profiles-D8
  - LEXTER-DRAFT-pane-profiles-D9
open-questions:
  - LEXTER-DRAFT-pane-profiles-O1
  - LEXTER-DRAFT-pane-profiles-O2
  - LEXTER-DRAFT-pane-profiles-O3
  - LEXTER-DRAFT-pane-profiles-O4
---

# Pane Profiles and Scrollback Viewing: Development Plan

This plan makes the mouse wheel scroll a terminal pane's history, and adds
the per-pane configuration that this and later features need. Configuration
lives in *pane profiles*: typed CLOS objects whose unset settings are
inherited, first through a chain of parent profiles and then from the
containing workspace and compositor. The plan also lets the layer that draws
pane decorations (the steward's APL layer) learn that output has arrived
below a scrolled-back view, through pollable pane state and a generic
function. It builds on the wheel delivery of
[LEXTER-DRAFT-mouse-reporting](Log.MouseReporting.md), and its design answers
the review recorded in the critique session cited below. Implementation is
for a later session.

## Problem

With mouse reporting in place, the wheel does nothing in a terminal pane on
the primary screen. The event arrives: `pane-handle-scroll` passes it to
`src/panes/vt-pane.lisp:%vt-pane-scroll-local@a9efdfc`, which changes the
screen's scrollback viewport. Two things are missing.

- **Nothing draws the history.**
  `src/model.lisp:flush-to-display@a9efdfc` always copies the live screen
  into the display grid. The viewport offset is read in one place,
  `src/panes/vt-pane.lisp:scroll-state@a9efdfc`, which only positions the
  scroll-bar thumb. The history itself is stored correctly:
  `src/model.lisp:%save-to-scrollback@a9efdfc` pushes each line that scrolls
  off the top into a ring, and `scrollback-line` reads it back.
- **Nothing asks for a redraw.** `%vt-pane-scroll-local` does not mark the
  screen dirty, and the compositor flushes only panes whose `pane-dirty-p` is
  true.

Making the wheel work raises three further needs. The number of lines per
wheel notch should be configurable, for every pane or for one. Typing should
return the view to the live screen while output should not, so that a long
build can be read while it runs. And the APL layer should be told when output
lands below a scrolled-back view, so that it can show it, for example by
flashing the pane's lower border.

The review in the critique session bears on how these are built. It found
three patterns that the obvious designs would repeat:

- **Instance values copied into globals.** The compositor has a `prefix-key`
  slot, but its `gui-initialize` copies it into the global `*prefix-key*`,
  and each tick copies its blink state into the global `*cursor-blink-on*`
  (`src/panes/vt-pane.lisp:*cursor-blink-on*@a9efdfc`). Two compositors
  overwrite each other. A global default for wheel lines would be a third
  case.
- **Keyword dispatch through `funcall`.** The input-redirect protocol passes
  a keyword and a lambda list to one function, so each new event kind changes
  every redirect function. The mouse work added three kinds. A callback for
  terminal events would be a second protocol of the same kind.
- **A growing `screen` struct.** `screen` holds the model, palette,
  scrollback, saved cursors, scroll region, and dirty flags. View state and
  configuration should not be added to it.

## Goals

- The wheel scrolls a pane's history on the primary screen, and the history
  is drawn.
- Lines per notch, snap-on-input, and snap-on-output are settings that can be
  set for all panes, for a workspace, for a shared group of panes, or for one
  pane, and changed at run time.
- Settings are typed, each has one generic reader, and the APL layer can add
  its own settings without a change to Lexter.
- No setting is held in a global that instances write.
- The APL layer can poll whether output is unseen, and can observe terminal
  events by defining methods.
- Profile resolution, scrollback drawing, and snapping are covered by tests
  that need no display.

## Settled Decisions

### LEXTER-DRAFT-pane-profiles-D1 — Settings live in pane-profile objects

**Status:** Proposed

**Context:** Wheel lines is the first per-pane setting, and more will follow.
The wheel handler runs inside a GLFW callback, outside any scope a caller
controls, so a dynamic binding made with `let` cannot reach it. The critique
faults globals that instances write.

**Decision:** Settings are slots of a `pane-profile` class. Each pane,
workspace, and compositor has a profile. A slot that is unbound means "not
set here; inherit".

**Alternatives:**
- A global default such as `*default-wheel-scroll-lines*` with a per-pane
  slot that overrides it. Rejected: it repeats the pattern of
  `*prefix-key*`, and offers no level between one pane and all panes.
- An untyped table of settings on each pane. Rejected: it has no types and no
  readers to specialise, the weakness the critique finds in the redirect's
  keyword dispatch.
- Slots directly on the pane classes. Rejected: settings could not be shared
  between panes or set for a workspace.

### LEXTER-DRAFT-pane-profiles-D2 — Resolution walks parent links, then containment

**Status:** Proposed

**Context:** Profiles are inherited in two ways. A profile may be derived
from another so that panes can share settings. A pane also sits in a
workspace, which sits in a compositor. An earlier draft of this design had
`gui-initialize` set each pane profile's parent to the compositor's profile.
That breaks when one profile is shared by panes in different workspaces,
since it can have only one parent.

**Decision:** A setting is looked up in the pane's profile and its chain of
`parent` profiles; then in the workspace's profile and its parents; then in
the compositor's profile and its parents; and finally in the default the
setting declares. Parent links express sharing and derivation; containment is
found through the pane's existing workspace back-reference
(`src/panes/workspace.lisp:initialize-instance@a9efdfc`) and a new reference
from workspace to compositor (LEXTER-DRAFT-pane-profiles-O2). A profile
lacking the slot is skipped, which lets a subclass of `pane-profile` add
settings that base profiles do not have.

**Alternatives:**
- Set parents to the containing profile at initialisation. Rejected for the
  reason above.
- Copy resolved values into each pane at initialisation. Rejected: a change
  made at run time would not reach panes already built.
- Containment only, with no parent links. Rejected: panes in different
  workspaces could not share a profile.

### LEXTER-DRAFT-pane-profiles-D3 — Each object owns a private profile; writers write it

**Status:** Proposed

**Context:** If a pane were given a shared profile directly, a write made
through that pane would change every pane sharing it.

**Decision:** Every pane, workspace, and compositor is created with a profile
of its own, empty unless initargs set it. Sharing is done by setting that
profile's `parent` to a shared one. A writer called on a pane, workspace, or
compositor sets the value in its own profile. Making the slot unbound again
restores inheritance.

**Alternatives:**
- Let the caller supply the profile object itself. Rejected: writes through
  one pane would change all its sharers, which is easy to do by accident.
- Copy on write. Rejected: more machinery for no gain over a private profile
  with a parent.

### LEXTER-DRAFT-pane-profiles-D4 — One generic reader per setting, defined by one macro

**Status:** Proposed

**Context:** The steward chose a generic function per setting over a single
keyword accessor such as `(pane-option pane :wheel-scroll-lines)`, so that a
pane class can override a setting with code. If the slots were written in a
`defclass` and the readers and defaults elsewhere, the names would have to be
kept in step by hand; the critique faults that kind of coupling in the
duplicated layered stride constant.

**Decision:** A macro, `define-pane-profile`, defines a profile class and,
for each setting in it, the slot (without an initform), the declared type and
default, a generic reader on panes such as `pane-wheel-scroll-lines` with a
default method that resolves the setting (LEXTER-DRAFT-pane-profiles-D2), and
a `setf` writer that checks the type and writes the private profile
(LEXTER-DRAFT-pane-profiles-D3). Lexter's own settings are defined with it,
and the APL layer defines a subclass the same way.

**Alternatives:**
- A single keyword accessor. Rejected by the steward.
- A hand-written `defclass` plus separate `defgeneric` forms. Rejected: the
  slot names and reader names would have to be kept in step by hand.

### LEXTER-DRAFT-pane-profiles-D5 — The history is drawn by flush-to-display

**Status:** Proposed

**Context:** The display grid is filled from the screen in
`flush-to-display`, the one loop that copies cells. Drawing the history
elsewhere would make a second copy of that loop, which the critique faults in
Lexter's parallel stacks.

**Decision:** `flush-to-display` reads the screen's viewport offset. At 0 it
behaves as now. Above 0 it repaints every row of the pane from a combination
of history and live rows, and does not draw the cursor.

**Alternatives:**
- Draw the history in `pane-flush` for `vt-pane`. Rejected: a second cell
  loop.
- Copy history lines into the live screen while scrolled back. Rejected: it
  would corrupt the model, which goes on receiving output.

### LEXTER-DRAFT-pane-profiles-D6 — Typing returns the view to live; output does not

**Status:** Proposed

**Context:** The steward wants typing to return to the live screen and output
not to, so that output can be read while it continues. xterm makes both
choices settings (its `scrollKey` and `scrollTtyOutput` resources).

**Decision:** Two settings, `snap-on-input` (default true) and
`snap-on-output` (default false). With `snap-on-input`, a key or character
that `vt-pane` writes to the backend sets the viewport to 0. Mouse reports do
not snap. With `snap-on-output`, output processed while scrolled back sets it
to 0.

**Alternatives:**
- Fixed behaviour with no settings. Rejected: the profile makes the settings
  nearly free, and xterm shows they are wanted.

### LEXTER-DRAFT-pane-profiles-D7 — The wheel factor applies to local scrolling only

**Status:** Proposed

**Context:** The wheel takes one of three paths
(LEXTER-DRAFT-mouse-reporting-D6): a report to the application when it has
asked for the mouse, arrow keys in the alternate screen, and the local
history on the primary screen.

**Decision:** `wheel-scroll-lines` (default 3) multiplies the notch count for
the history and for the arrow keys. A report to the application stays one
event per notch, as xterm sends it.

**Alternatives:**
- Apply the factor to reports as well. Rejected: applications expect one
  wheel event per notch and scale it themselves.

### LEXTER-DRAFT-pane-profiles-D8 — Unseen output is pane state, polled by the decorator

**Status:** Proposed

**Context:** A flashing border is a state that lasts while output is unseen,
and the decorator that draws it already runs on every flush. The critique
warns against adding view state to `screen`.

**Decision:** `vt-pane` gets a slot recording unseen output, set when output
is processed while the viewport is above 0 and cleared when the viewport
returns to 0. A reader exposes it to the decorator. Whether it is a flag or a
line count is LEXTER-DRAFT-pane-profiles-O1.

**Alternatives:**
- A slot on `screen`. Rejected for the reason above.
- An event only. Rejected: the decorator would have to keep the state
  itself.

### LEXTER-DRAFT-pane-profiles-D9 — Terminal events reach the APL layer through a generic function

**Status:** Proposed

**Context:** The APL layer needs discrete events (output, unseen output, the
bell, a title change, a viewport change) as well as the state of
LEXTER-DRAFT-pane-profiles-D8. A registered `funcall` callback was proposed;
the critique faults that style in the redirect protocol.

**Decision:** A generic function `pane-terminal-event (pane kind data)` with
a default method that does nothing. `vt-pane` calls it for `:output` (once
per call of `pane-process-output` that processed bytes, not once per read),
`:unseen-output`, `:bell`, `:title` (with the title string), and `:viewport`
(with the new offset). The VT handler's callback, built by
`src/panes/vt-pane.lisp:make-vt-pane-callback@a9efdfc`, does its own work
for the bell and the title and then calls the generic function. The APL layer
observes events with methods on its pane classes or mixins.

**Alternatives:**
- A `pane-event-callback` slot holding a function. Rejected by the steward:
  keyword dispatch through `funcall`.
- One generic function per event kind. Rejected: five functions for one
  idea, and a new kind would add another.

## Pane Profiles

A profile class is defined in one form. Lexter's base class holds the
settings this plan needs:

```lisp
(define-pane-profile pane-profile ()
  ((wheel-scroll-lines :type (integer 1) :default 3
                       :documentation "Lines scrolled per wheel notch.")
   (snap-on-input      :type boolean :default t
                       :documentation "Typing returns the view to the live screen.")
   (snap-on-output     :type boolean :default nil
                       :documentation "Output returns the view to the live screen.")))
```

This defines the class with a `parent` slot and the three setting slots; the
readers `pane-wheel-scroll-lines`, `pane-snap-on-input`, and
`pane-snap-on-output`; their `setf` writers; and the defaults. The readers
are specialised on panes; readers on profiles, workspaces, and compositors
give the value set at that level, if any.

The APL layer adds its own settings with a subclass:

```lisp
(define-pane-profile apl-pane-profile (pane-profile)
  ((border-flash-color :type (unsigned-byte 8) :default 11)))
```

Profiles that lack a slot are skipped during lookup, so a pane with an
`apl-pane-profile` finds `border-flash-color` in its own profile or its
parents, and otherwise the default, even inside a workspace whose profile is
a plain `pane-profile`.

Typical uses:

```lisp
;; All panes of a compositor:
(setf (compositor-wheel-scroll-lines comp) 5)
;; Panes sharing a profile:
(let ((logs (make-instance 'pane-profile :snap-on-output t)))
  (setf (profile-parent (pane-profile pane-a)) logs
        (profile-parent (pane-profile pane-b)) logs))
;; One pane:
(setf (pane-wheel-scroll-lines pane-a) 1)
```

Lookup is a few `slot-boundp` tests per call, made once per wheel event or
keystroke.

## Scrollback Viewing

With viewport offset V above 0 and R rows, row d of the pane (0 at the top)
shows history line `n = V - 1 - d` when n is 0 or more, and live row `d - V`
otherwise. History cells are stored as glyph, swatch, and attributes; they
are written with `set-simple-cell`, which also clears overlay layers, and a
glyph of 0 is drawn as the blank glyph. A history line shorter than the pane,
left by a resize, is padded with blanks.

Per-row dirty flags do not describe a shifted view, so while V is above 0
each flush repaints every row of the pane. Every change of V marks the
screen dirty with `src/model.lisp:mark-screen-dirty@a9efdfc`, which also
repaints the live screen on the return to 0. The cursor is not drawn while V
is above 0. That also avoids, in this mode, the reversed swatch that drawing
the cursor writes into the model, a side effect the critique records.

`%vt-pane-scroll-local` multiplies the notch count by
`pane-wheel-scroll-lines`, sets the viewport, which is already clamped to the
history, marks the screen dirty, and raises a `:viewport` event.

## Snapping and Unseen Output

`pane-handle-key` and `pane-handle-char` on `vt-pane` set the viewport to 0
after writing to the backend, when `pane-snap-on-input` is true.
`pane-process-output` checks the viewport after processing output: if it is
above 0 it either snaps, when `pane-snap-on-output` is true, or records
unseen output and raises `:unseen-output`. The record is cleared, and
`:viewport` raised, whenever the viewport returns to 0.

Table: Terminal events raised through pane-terminal-event.

| Kind | Data | Raised when |
|---|---|---|
| `:output` | none | `pane-process-output` processed bytes |
| `:unseen-output` | none, or a count (LEXTER-DRAFT-pane-profiles-O1) | output was processed while scrolled back |
| `:bell` | none | the VT handler reports a bell |
| `:title` | the title string | the VT handler reports a title change |
| `:viewport` | the new offset | the viewport changed |

## Tradeoffs and Non-Goals

- **The view drifts during output.** While scrolled back, each new line moves
  the history the view shows by one, since the offset is fixed and the bottom
  moves. Terminals usually increase the offset as lines arrive, so that the
  view stays put. Deferred by the steward.
- **The two globals stay.** `*prefix-key*` and `*cursor-blink-on*` keep
  their current form; moving `prefix-key` into the compositor's profile and
  binding the blink state around the flush instead of setting it are left for
  later, at the steward's direction.
- **The redirect protocol is unchanged.** Its keyword dispatch, which the
  mouse work extended (LEXTER-DRAFT-mouse-reporting-D7), could become event
  objects with generic dispatch. That is a separate refactor.
- **History colours share the swatch problem.** History cells carry swatch
  indices from their screen's table. The critique's main finding, that panes
  sharing one display grid overwrite each other's swatch tables, affects
  history cells as it does live ones; this plan does not change that.
- **History is lossy.** Scrollback does not record wide glyphs or overlay
  layers, so wide glyphs are drawn narrow in the history. It stores a list
  per cell, which the critique notes as a cost. The format is not changed
  here.
- **The single-terminal path is excluded.** `unix-term` has no panes and no
  mouse handling; it gains neither profiles nor wheel scrolling.

## Open Questions

### LEXTER-DRAFT-pane-profiles-O1 — Should unseen output be a flag or a line count?

A flag says that output has arrived since the view left the live screen,
which is enough to flash a border. A count says how many lines, which lets
the indicator show a number or scale. A count looks cheap: record the
screen's total scrollback count when the viewport leaves 0, and subtract it
from the current count. The current lean is the count, if that holds when
the ring wraps.

### LEXTER-DRAFT-pane-profiles-O2 — How does a workspace find its compositor?

Lookup needs the chain pane, workspace, compositor. Panes already refer to
their workspace. The lean is a `workspace-compositor` slot, set where the
compositor's `gui-initialize` already visits every workspace
(`src/panes/compositor.lisp:gui-initialize@a9efdfc`). The alternative is a
special variable bound by the compositor around event dispatch and the tick,
a dynamic binding in a scope the compositor controls. It would leave readers
called from elsewhere, such as the REPL, without the compositor level.

### LEXTER-DRAFT-pane-profiles-O3 — Which other settings move into profiles?

Candidates are xterm's `alternateScroll` (DECSET 1007), which would make the
wheel-to-arrows translation optional; the scrollback size; the blink
interval; and the encoding and bold-as-bright options now passed as
initargs. The compositor's prefix key is a further candidate once the
steward takes up the globals.

### LEXTER-DRAFT-pane-profiles-O4 — Where do the tests live?

The tests can extend `lexter/mouse-tests`, which uses a small check macro of
its own, or start a suite that follows the Square testing standard, with
FiveAM and cl-hamcrest, as `lexter/origin-tests` does. All of them need a
`vt-pane` subclass with an in-memory backend, and none needs a display, since
the display grid is plain arrays.

## Prior Art

Table: Prior systems and what this plan draws from each.

| System | What to draw from |
|---|---|
| Garnet's KR object system | Slot values inherited through prototype links, with local values overriding |
| Emacs buffer-local variables | A default value with local overrides, looked up on read, so changes take effect at once |
| CSS inherited properties | Values inherited through the containment tree when not set on an element |
| iTerm2 and GNOME Terminal profiles | Named, shared groups of terminal settings assigned to sessions |
| xterm `scrollKey`, `scrollTtyOutput`, `alternateScroll` | Snapping to the live screen on input and on output, and wheel-to-arrows in the alternate screen, as settings |

## Roadmap

1. **Profiles.** `define-pane-profile`, the resolver, private profiles on
   panes, workspaces, and compositors, the workspace-to-compositor reference
   (LEXTER-DRAFT-pane-profiles-O2), and the three settings. Tests for lookup
   order, parent sharing, skipping profiles without a slot, unbinding, and
   type checks.
2. **Drawing the history.** Viewport-aware `flush-to-display`, and
   `%vt-pane-scroll-local` using the wheel setting and marking the screen
   dirty. Tests that flush a screen with history into a display grid at
   several offsets and check the cells and the absent cursor.
3. **Snapping.** Snap-on-input in the key and character handlers, and
   snap-on-output in `pane-process-output`. Tests with an in-memory backend.
4. **Events and unseen output.** `pane-terminal-event`, the unseen-output
   slot and reader (LEXTER-DRAFT-pane-profiles-O1), and the bell and title
   routed through the generic function. Tests with a recording method.
5. **Log.** A development Log recording the work, with its Outstanding Work
   carrying the non-goals above.
