# Input Redirect and Chrome Mixins: Development Log

This document chronicles the design of Lexter's input redirect system
and the chrome mixin that accompanies it -- the two mechanisms that
together make modal dialogs possible in the pane compositor. The
notable feature of this work is what it *avoided*: the original plan
was a workspace-level overlay stack, and the redirect system was
adopted as a lighter, more elegant alternative that reuses the
machinery already present rather than building a parallel one.

**Date:** 2026-06-06


## Problem

The pane compositor lets a workspace hold several panes, each occupying
a rectangle of the display grid, each able to take keyboard focus. The
motivating use case for modal behavior was concrete: when a user is
disconnected from a host in a TN3270 pane, a dialog should pop up
*over that pane* inviting them to enter a new host to connect to. While
that dialog is up, it should capture keyboard input -- the user is
answering the dialog, not typing at the (now dead) 3270 session.

Generalizing, a "modal dialog" needs three things:

1. **Input capture.** While the dialog is active, keystrokes go to the
   dialog, not to the pane underneath.
2. **Visuals on top.** The dialog box -- border, prompt, input field --
   draws over the pane's content.
3. **A clean lifecycle.** The dialog appears, collects a result, and
   disappears, returning the pane to normal operation.

The compositor at the time had none of these. Panes flushed to the grid
in list order (`flush-workspace`, `workspace.lisp:101`); the focused
pane received all non-meta keystrokes (`handle-compositor-key`,
`compositor.lisp:67`); and there was no notion of one pane temporarily
standing in front of another.


## The Original Plan: An Overlay Stack

The first design (recorded in `session-ses_2263-Lexter6.md:862`
onward, "Option A") added modality as a *workspace-level* concept: an
overlay stack parallel to the pane list.

```
workspace
  panes:    [tn3270-pane, status-bar]   ;; base layout
  overlays: [reconnect-dialog]          ;; drawn last, gets all input
```

The plan called for:

- an `overlays` slot on `workspace`,
- `push-overlay` / `pop-overlay` to manage the stack and capture/restore
  focus,
- `flush-workspace` extended to flush base panes first and overlays on
  top,
- key routing extended to send input to the top overlay if one exists,
  otherwise to the focused base pane,
- a new `dialog-pane` class with built-in border, text layout, and an
  input field.

This works, and it is a familiar pattern. But weighed honestly it is a
lot of new structure for the goal. It introduces a *second* pane
collection with its own ordering, a *second* focus model layered over
the existing one, new lifecycle verbs, explicit z-ordering semantics,
and a new widget class -- all so that one pane can temporarily answer
for another. Every code path that already iterated `workspace-panes`
(flush, dirty-check, focus, I/O) would have to learn about overlays or
risk treating them inconsistently. The overlay stack is a parallel
hierarchy bolted alongside the one we have.


## The Alternative: Redirect Input, Don't Restructure Panes

The recommended alternative reframes what a modal dialog *is*. A modal
is not a new pane stacked on top of an existing one. It is a temporary
**takeover of an existing pane's input**. The pane that raises the
dialog (the 3270 pane) does not yield to a sibling; it redirects its
own input stream to a handler for the duration, and the dialog's visuals
are painted over its own region.

This collapses all three requirements onto machinery that already
exists or is trivially small:

- **Input capture** becomes a single slot on the pane that, when set,
  funnels the pane's input to a function. No second focus model: the
  pane is still the focused pane; it has simply changed what it does
  with input.
- **Visuals on top** become a job for the chrome decorator, which
  already draws over pane content and can inspect the pane's redirect
  state to decide whether to draw a dialog.
- **Lifecycle** becomes "set the slot, clear the slot." No stack, no
  push/pop, no focus save/restore.

Nothing in `flush-workspace`, the focus logic, or the compositor's key
router has to change. The redirect is invisible to all of them.


## Design Decisions

### 1. Modality is per-pane state, expressed as one slot

**Question:** Where does "this is modal right now" live?

**Decision:** On the base `pane` class, as a single `input-redirect`
slot (`protocol.lisp:41`) defaulting to NIL. NIL means normal routing;
a function means input is intercepted. Any pane type inherits the
capability for free; nothing needs a special "dialog" subclass to be
modal.

```lisp
(input-redirect :accessor pane-input-redirect
                :initform nil
                :documentation "Function to redirect input to, or NIL ...")
```

### 2. Interception lives in method combination, not the router

**Question:** How does input actually get diverted without touching the
compositor's routing code?

**Decision:** `:around` methods on `pane-handle-key` and
`pane-handle-char` (`protocol.lisp:210-224`) check the redirect slot
and, if set, call the redirect function *instead of* `call-next-method`:

```lisp
(defmethod pane-handle-key :around ((pane pane) key scancode action mods)
  (let ((redirect (pane-input-redirect pane)))
    (if (and redirect (not *redirect-suppressed*))
        (funcall redirect pane :key key scancode action mods)
        (call-next-method))))
```

This is the crux of why the approach is light. The compositor's
`handle-compositor-key` / `handle-compositor-char`
(`compositor.lisp:67`, `compositor.lisp:120`) still do nothing but
`(pane-handle-key (focused-pane ws) ...)`. They are completely unaware
that redirection exists. Modality is a property of the method dispatch
on the pane, not a branch in the router. Add the `:around` methods once
and every pane, present and future, becomes modal-capable without the
routing layer knowing.

### 3. A single redirect function with a discriminated signature

**Question:** Key events and character events are distinct. Two
redirect slots, or one?

**Decision:** One slot, one function, discriminated by a leading
keyword:

```
(funcall redirect pane :key  key scancode action mods)
(funcall redirect pane :char codepoint)
```

A dialog handler is a single closure that `case`s on `:key` vs `:char`.
This keeps the modal's logic in one place and matches how the two
GLFW callbacks (key and char) are two faces of one input stream.

### 4. Selective passthrough via dynamic suppression

**Question:** A redirect function sometimes wants to hand an event *back*
to the pane's normal handler -- e.g. a semi-modal overlay that captures
its hotkeys but lets ordinary typing reach the terminal underneath. How
does it forward an event without the `:around` method catching it again
and recursing forever?

**Decision:** A dynamic variable `*redirect-suppressed*`
(`protocol.lisp:205`) plus two helpers, `pane-forward-key` and
`pane-forward-char` (`protocol.lisp:230-242`). The helpers bind
`*redirect-suppressed*` to T around a re-dispatch, and the `:around`
methods honor that binding by falling through to `call-next-method`:

```lisp
(defun pane-forward-key (pane key scancode action mods)
  (let ((*redirect-suppressed* t))
    (pane-handle-key pane key scancode action mods)))
```

This gives a redirect function a clean way to say "I've looked at this
event; now treat it as if no redirect were installed," without
clearing and reinstalling the slot. The recursion guard is dynamically
scoped, so it is automatically unwound after the forwarded call.

### 5. Focus trapping falls out for free

**Question:** The overlay plan needed explicit focus capture and
restore. What replaces it?

**Decision:** Nothing -- it is not needed. Because the redirect lives on
the focused pane and intercepts at dispatch time, the pane simply
cannot act on input normally while a redirect is installed. The dialog
*is* the focused pane's input. There is no other pane to trap focus away
from, and clearing the slot restores normal behavior instantly. The
"save focus / restore focus" bookkeeping of the overlay stack has no
analogue because there was never a focus transfer.

### 6. Dialog visuals are a chrome concern, drawn by the decorator

**Question:** If the dialog isn't a separate pane, who draws its box?

**Decision:** The chrome mixin's decorator. The `chrome-pane` mixin
(`chrome-mixin.lisp`) already reserves regions of a pane and delegates
their drawing to a single workspace-level `decorator` function. That
decorator inspects pane state -- explicitly including `input-redirect`
(noted at `chrome-mixin.lisp:9-11`) -- to decide what to draw. When a
redirect is active, the decorator paints the modal dialog's frame and
prompt over the pane's content. Input behavior (redirect) and dialog
appearance (chrome decorator) are orthogonal systems that compose:
one owns the keystrokes, the other owns the pixels.


## The Chrome Mixin

The chrome mixin was built in the same effort because dialogs need a
place to draw and because the compositor wanted scroll bars, headers,
and footers anyway. Rather than three separate features it is one
mixin that reserves edges of a pane and routes their drawing through a
single themeable function.

### Reserved regions and content geometry

`chrome-pane` (`chrome-mixin.lisp:19`) adds slots for a scroll-bar
column, header rows, and footer rows. The content-geometry generics
shrink to exclude whatever chrome is present:

- `content-width` = `pane-width` minus the scroll-bar column
  (`chrome-mixin.lisp:58`)
- `content-height` = `pane-height` minus header and footer
  (`chrome-mixin.lisp:63`)
- `content-row` = `pane-row` plus header height (`chrome-mixin.lisp:69`)

A pane's screen model is built to `content-width` x `content-height`,
so the screen never overwrites the reserved edges. This is the
"screen model need not match the allocated rectangle" insight from the
scroll-bar design discussion (`session-ses_2263-Lexter6.md:965`): an
80-column pane with a scroll bar runs a 79-column screen.

### Flush delegates chrome to the decorator

A `pane-flush :around` method (`chrome-mixin.lisp:103`) flushes the
pane's content via `call-next-method`, then calls the workspace
decorator once per active chrome element, passing a mode keyword
(`:header`, `:footer`, `:scroll-bar`) and the geometry/data for that
element. The decorator is also invoked with `:borders` at the
workspace level (`workspace.lisp:126`). One function, dispatched on a
mode keyword, draws every piece of chrome in the system -- borders,
headers, footers, scroll bars, and (when a redirect is active) modal
dialogs. This is the single-point-of-control the scroll-bar discussion
recommended (Option B mixin, with workspace access).

### Workspace back-reference

For a pane to reach its decorator it needs its workspace. The base pane
carries a `workspace` back-reference (`protocol.lisp:38`), set in the
workspace's `initialize-instance :after` (`workspace.lisp:44`). This
directly answers the design question raised in the session
(`session-ses_2263-Lexter6.md:1044`): methods specialized on a pane can
reach the workspace, so chrome drawing can be informed by
workspace-level state.

### Scroll-bar geometry and future mouse support

`scroll-bar-thumb-geometry` (`chrome-mixin.lisp:81`) computes thumb
position and height from the pane's `scroll-state`
(total-lines / viewport-offset / visible-rows), with a one-cell minimum
thumb. `scroll-bar-hit-test` (`chrome-mixin.lisp:158`) maps a grid
coordinate to `:thumb`, `:track`, or NIL. Nothing consumes the hit-test
yet; it exists so that the mouse-input work to come can make scroll bars
(and, by the same token, dialog controls) interactive without reworking
the geometry.


## How a Modal Dialog Works End to End

```
3270 session drops
  |
  v
pane sets its own (pane-input-redirect pane) -> dialog closure
  |
  v
user presses a key
  |
  v
compositor routes it to the focused pane unchanged
  |
  v
pane-handle-key :around sees the redirect, calls the closure
  |                         (instead of the pane's normal handler)
  v
dialog closure updates its buffer; may pane-forward-* to passthrough
  |
  v
next frame: pane-flush :around draws pane content, then the decorator,
  seeing input-redirect set, paints the dialog box on top
  |
  v
user submits -> closure runs the action, then clears input-redirect
  |
  v
pane returns to normal input and the decorator stops drawing the dialog
```

No overlay list, no z-order, no focus stack, no dialog-pane class --
two slots (`input-redirect` to capture, the decorator's inspection of
it to draw) and one dynamic variable for passthrough.


## Design Properties

- **Additive and transparent.** The compositor's input router and the
  workspace's flush/focus logic are untouched. Redirection is entirely
  in pane method combination; chrome drawing is entirely in the
  decorator. Existing panes that use neither behave exactly as before.
- **No parallel hierarchy.** There is one pane list, one focus model,
  one flush order. Modality reuses them rather than shadowing them.
- **Orthogonal composition.** Input redirect (behavior) and chrome
  decorator (appearance) are independent and combine cleanly; either is
  useful without the other.
- **Uniform chrome.** Borders, headers, footers, scroll bars, and
  dialog visuals all flow through one mode-dispatched decorator
  function, so they share styling and a single drawing path.
- **Forward-compatible with mouse.** Hit-testing hooks are in place for
  scroll bars and, by extension, for clickable dialog controls.


## Files

| File | Action | Description |
|------|--------|-------------|
| `src/panes/protocol.lisp` | Modified | Added `input-redirect` slot and `workspace` back-reference to `pane`; `:around` methods on `pane-handle-key` / `pane-handle-char`; `*redirect-suppressed*` and `pane-forward-key` / `pane-forward-char` |
| `src/panes/chrome-mixin.lisp` | New | `chrome-pane` mixin: reserved scroll-bar/header/footer regions, content geometry generics, `pane-flush :around` decorator delegation, scroll-bar geometry and hit-testing |
| `src/panes/workspace.lisp` | Modified | Added `decorator` slot; `render-decorations` calls it with `:borders`; `initialize-instance :after` sets pane back-references |
| `src/panes/packages.lisp` | Modified | Exported redirect and chrome symbols |


## Outstanding Work

- **A dialog widget.** The infrastructure makes modal dialogs possible;
  a reusable dialog -- a closure factory that builds the redirect handler
  (line editing, submit/cancel) paired with a decorator branch that
  draws the box and input field -- is the natural next piece. The 3270
  reconnect dialog is its first intended consumer.
- **Mouse interactivity.** `scroll-bar-hit-test` is unused pending the
  mouse-input system. The same hit-testing approach will let dialogs
  expose clickable buttons and let scroll-bar thumbs be dragged.
- **Stacked modals.** A redirect handler can itself install a nested
  redirect, but there is no convenience for "dialog over dialog" with
  automatic unwinding. If nested modals become common, a small saved-
  redirect helper (set new, restore previous on dismiss) would formalize
  the pattern without resurrecting the overlay stack.
- **Dimming the backdrop.** The decorator could draw a dim pass over the
  pane region behind an active dialog, using the layered cell system, to
  visually emphasize modality. This is cosmetic and not yet implemented.
