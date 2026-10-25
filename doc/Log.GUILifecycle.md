# GUI Lifecycle (Iteration API): Development Log

This document chronicles the refactor of Lexter's two GUI entry points --
`run-terminal` (a single Unix terminal) and `run-paned-terminal` (the pane
compositor) -- from self-contained blocking loops into a steppable
**iteration API**: a persistent object with an `initialize` / `tick` /
`destroy` lifecycle, driven by a main-thread dispatcher that polls GLFW once
and ticks every live window. Lexter stays single-threaded. The notable
property of this work is what it does *not* require: no internal threading,
no separation of backend from renderer, and no change to the standalone entry
points' public signatures.

**Date:** 2026-06-06


## Problem

Every interactive entry point in Lexter was a self-contained blocking
function. `run-terminal` (`src/unix-term.lisp`) and `run-paned-terminal`
(`src/panes/compositor.lisp`) each did the same three things in one body:

1. create a GLFW window and OpenGL context,
2. build all state -- atlas, screen/workspaces, renderer, PTY -- as **locals**,
3. enter a `loop` that owned the entire lifecycle: poll events, process I/O,
   render, swap buffers, sleep, repeat until the window closed.

This shape works for a program that *is* a terminal. It does not work for a
program that wants to *host* a terminal among other things. The motivation was
integration with the Origin process manager, whose model places a supervisor
and all non-GUI processes on background threads. But GLFW has a thread-affinity
requirement: window creation and `glfw:poll-events` must run on the main
thread (a hard constraint on macOS, and the documented contract everywhere).
A blocking loop that *owns* the main thread cannot coexist with a second GUI
window, and cannot be driven by an external event dispatcher.

Three specific deficiencies blocked any such hosting:

- **The loop is uninterruptible from outside its own body.** The `running`
  flag, the window, and all resources are locals inside the entry function.
  (A cooperative `:stop-flag` had already been threaded through the loop
  guards, but the loop still owned the thread.)
- **One window per main thread.** `glfw:poll-events` services *all* windows in
  one call, but each blocking loop assumes it is the only window and calls
  poll-events itself. Two windows would mean two loops fighting over the main
  thread.
- **Lifetime is dynamic-extent.** `glfw:with-init-window` creates and destroys
  the window around a body, and initializes/terminates GLFW in the same
  dynamic extent. There is no point at which an external caller can hold the
  window open and step it.

The goal of this iteration was to invert that structure: keep all of Lexter's
single-threaded pipeline exactly as it is, but move the *loop* out of Lexter
and expose each frame as a callable step.


## Design: Approach B

Three integration strategies were weighed (recorded in the OriginII design
conversation):

- **A -- background thread on Linux.** Run each Lexter loop in an Origin-managed
  thread. Least change, but relies on GLFW-from-a-background-thread behavior
  that the library does not guarantee and that fails on macOS.
- **B -- main thread for GUI, background for everything else.** Refactor the
  loop into a steppable protocol; a main-thread dispatcher services all GLFW
  windows. More work upfront, scales cleanly to multiple windows, portable.
- **C -- split backend from renderer across threads.** Most aligned with crash
  isolation, but a large internal-threading refactor of Lexter.

**Approach B was chosen.** Its central insight is that this is *not* an
internal-threading change. The `terminal-tick` function does everything the old
loop body did -- read PTY, parse VT, update the model, render, swap -- in the
same thread, the same call stack. The only thing it stops doing is calling
`glfw:poll-events`, which is hoisted to the dispatcher so one call services
every window. Lexter remains single-threaded; only the `loop` form moves out.
What changes is **object lifetime management**: the locals that lived inside
the entry function become slots on a persistent object that survives across
ticks.


## Design Decisions

### 1. A window-level protocol in core Lexter (`lexter/gui`)

**Question:** Where do the lifecycle generics and the dispatcher live, and what
do they abstract over?

**Decision:** A new `lexter/gui` package and `src/gui.lisp` file in the **core**
`lexter` system, defining a small window-level protocol over five generics:

```lisp
(gui-initialize object)  ; create window/context/resources; register callbacks
(gui-tick object)        ; advance one frame; returns alive-p
(gui-destroy object)     ; idempotent teardown incl. destroy-window
(gui-window object)      ; the GLFW window handle, or NIL
(gui-alive-p object)     ; live predicate
```

Core was the right home because both `lexter/unix` (the terminal) and
`lexter/panes` (the compositor) depend on it transitively, so both can
implement the same protocol, and a dispatcher written once treats a
`unix-terminal` and a `compositor` uniformly. Core already depends on
`cl-glfw3`, so the dispatcher's `glfw:poll-events` has no new dependency.

The alternative -- defining the generics directly on each struct's package and
putting the dispatcher in `lexter/origin` -- was rejected because it would have
tied the steppable model to Origin. Keeping the protocol Origin-agnostic means
Lexter is independently usable and any future host (Origin or otherwise) reuses
the same five generics.

### 2. The dispatcher owns the loop; the caller owns GLFW init/terminate

**Question:** What runs the loop, and who calls `glfw:initialize` /
`glfw:terminate`?

**Decision:** `run-gui-loop (objects &key stop-flag)` is the dispatcher. It
holds a **list** of already-initialized objects and, each iteration: calls
`glfw:poll-events` once, ticks every object, destroys and drops any whose tick
returns false, and exits when no live objects remain or `(car stop-flag)` is
nil. It deliberately does **not** call `glfw:initialize` or `glfw:terminate`.

GLFW initialization is process-global and must happen exactly once, on the main
thread, before any window is created. Putting it in the dispatcher (or worse,
per object) would be wrong for the multi-window and embedded-host cases.
Instead, the *caller* owns it: the standalone wrappers initialize and terminate
GLFW around the dispatcher today, and an Origin main-thread dispatcher will own
it at the image level later. The dispatcher is a pure poll-tick-reap loop with
no global lifecycle responsibility.

### 3. Per-tick context switching is mandatory

**Question:** What makes several windows able to share one thread?

**Decision:** Every `gui-tick` calls `glfw:make-context-current` on its own
window before any GL work, and `gui-initialize` builds its renderer in the
context that `glfw:create-window` just made current.

Each window has its own OpenGL context, and a renderer's GL objects (VAOs,
textures, the palette UBO, shaders) are valid only in the context that created
them. With one window this was implicit -- there was only one context, made
current once. With the steppable model the dispatcher may tick window A then
window B in the same iteration, so each tick must re-establish its own context.
This single line is the linchpin of the whole refactor; omitting it would
render into the wrong window or corrupt GL state. For symmetry, `gui-destroy`
also makes the context current before destroying the renderer.

### 4. Config-on-struct, arg-free generics

**Question:** Should `gui-initialize` take configuration arguments, or read them
from the object?

**Decision:** Configuration lives on the struct, set by a constructor, and the
generics are argument-free. `make-terminal` / `make-paned-compositor` allocate
the object and store its config (command, font path, dimensions, title, etc.);
`gui-initialize` reads those slots to build the window and resources.

This keeps the protocol minimal and uniform -- every generic takes just the
object -- and matches the natural division: the constructor is the
configuration surface, the lifecycle generics are the mechanism. It also makes
an object inspectable before it is initialized, which a host scheduler wants.

### 5. Replace `with-init-window`; promote locals to slots

**Question:** How does window/resource lifetime change?

**Decision:** `glfw:with-init-window` (which creates *and* destroys the window
in dynamic extent, and brackets GLFW init/terminate) is replaced with explicit
`glfw:create-window` in `gui-initialize` and `glfw:destroy-window` in
`gui-destroy`. The per-run locals that the old loop closed over -- the window
handle, font and cell metrics, pixel dimensions, and the frame-timing
`last-time` -- become slots on the `unix-terminal` / `compositor` struct so they
persist across ticks and are reachable at destroy time.

The frame-timing promotion is the subtle one: the old loop kept `last-time` as
a loop local to compute the cursor-blink delta. Across independent tick calls
there is no loop local, so it becomes a `last-tick-time` slot.

### 6. Idempotent destroy; standalone wrappers preserved

**Question:** How do the public entry points keep working, and how is double
teardown avoided?

**Decision:** `run-terminal` and `run-paned-terminal` are reimplemented as thin
wrappers -- `glfw:initialize`, construct, `gui-initialize`, then
`unwind-protect (run-gui-loop (list obj) :stop-flag ...)` with `gui-destroy` +
`glfw:terminate` in the cleanup -- preserving their exact signatures and
`:stop-flag` semantics. Because the dispatcher destroys naturally-dead objects
*and* the wrapper destroys survivors on exit, `gui-destroy` is made idempotent:
it guards on the window slot and no-ops after the first call.


## Implementation

### `src/gui.lisp` (new) and `lexter/gui` package

Defines the five generics and `run-gui-loop`. The dispatcher:

```lisp
(defun run-gui-loop (objects &key stop-flag)
  (let ((live (copy-list objects)))
    (loop :while (and live (or (null stop-flag) (car stop-flag)))
          :do (glfw:poll-events)
              (setf live
                    (loop :for obj :in live
                          :if (gui-tick obj) :collect obj
                          :else :do (gui-destroy obj)))
              (sleep 0.001))
    live))
```

It returns survivors so a caller that stopped via `stop-flag` can tear them
down. Added to the core `lexter` system in `lexter.asd` after `src/renderer`.

### `unix-terminal` (`src/unix-term.lisp`)

- **Struct** gained `window`, `font`, `cell-w`, `cell-h`, `win-w`, `win-h`,
  `last-tick-time`, and config slots `command`, `args`, `font-path`, `title`.
- **`make-terminal`** allocates the struct and stores config.
- **`gui-initialize`** is the old `run-terminal` body minus `glfw:initialize`
  and `with-init-window`: `glfw:create-window` (which makes the context
  current), build atlas + cursor glyphs, screen, display, renderer, palette
  upload, VT handler, `pty-fork`, then register key/char/framebuffer-size
  callbacks on this window and record `last-tick-time`.
- **`gui-tick`** is the old loop body minus `glfw:poll-events` and the trailing
  `sleep`, plus a leading `glfw:make-context-current`; it computes the blink
  delta from `last-tick-time`, processes PTY output, handles a pending resize,
  renders if dirty, swaps the window's buffers, and returns
  `running ∧ window ∧ ¬should-close`.
- **`gui-destroy`** runs the old cleanup -- `pty-close`, `destroy-renderer`
  (with the context current) -- plus `glfw:destroy-window`, guarded for
  idempotence.
- **`run-terminal`** is now the thin wrapper described in Decision 6.

### `compositor` (`src/panes/compositor.lisp`)

The identical treatment: struct gains `window`, `win-w`, `win-h`,
`last-tick-time`, and config slots `fonts`, `font-path`, `title`, `prefix-key`.
`make-paned-compositor` stores config; `gui-initialize` creates the window,
renderer, palette, callbacks, initializes each pane, and clears the grid;
`gui-tick` makes the context current, processes I/O for every pane in every
workspace, and renders the active workspace (including the per-pane palette
upload and `set-active-palette-slot`); `gui-destroy` destroys workspaces, the
renderer, and the window. `run-paned-terminal` becomes the thin wrapper.

### Packaging

`lexter/gui` is exported from `src/packages.lisp`; `lexter/unix-term` and
`lexter/panes` `:use` it and re-export the protocol for convenience, plus the
new `make-terminal` / `make-paned-compositor` constructors.


## How an external host drives Lexter

```
glfw:initialize                         (once, main thread)            [host]
  |
  v
make-terminal / make-paned-compositor   construct, store config       [host]
  |
  v
gui-initialize                          create window+context+PTY      [host]
  |
  v
loop on main thread:                                                   [host]
  glfw:poll-events                      once for ALL windows
  for each obj: gui-tick                make-context-current; 1 frame
  reap dead via gui-destroy
  |
  v
glfw:terminate                          (once, at shutdown)            [host]
```

`run-gui-loop` *is* that loop for the standalone case (one object). An Origin
main-thread dispatcher is the same loop hosting several objects alongside other
main-thread work; it owns `glfw:initialize` / `glfw:terminate` at the image
level and otherwise calls the identical five generics.


## Design Properties

- **Single-threaded preserved.** No threads were added inside Lexter. An
  object's entire pipeline runs on the dispatcher's thread, once per tick,
  exactly as before.
- **Additive and backward-compatible.** `run-terminal` and `run-paned-terminal`
  keep their signatures and `:stop-flag` behavior; existing callers and the
  Origin stop-flag integration are unaffected.
- **Uniform and host-agnostic.** Both window types implement one five-generic
  protocol, so any main-thread dispatcher integrates with either the same way,
  with no dependency on Origin in the protocol.
- **Context-correct.** Every tick re-establishes its own GL context, so several
  windows can be ticked from one thread without interference.
- **Registry-ready.** The dispatcher already holds a list of objects and each
  tick is context-correct; only the multi-window callback registry remains to
  build (see Outstanding Work).


## Verification

The systems compile and load cleanly (`lexter`, `lexter/unix`, `lexter/panes`).
A symbol/method audit confirms `run-terminal`, `make-terminal`,
`run-paned-terminal`, and `make-paned-compositor` are all defined; all five
`lexter/gui` generics exist; and both `unix-terminal` and `compositor`
implement every method. The two residual style-warnings -- an unused `COUNT`
and the `cl-glfw3` `def-char-callback` `window` rebinding -- are pre-existing
and byte-identical in `HEAD`, not regressions. Runtime behavior on screen was
not exercised in this pass (it requires a live GLFW display); the
compile/load/protocol wiring is what was verified here.


## Files

| File | Action | Description |
|------|--------|-------------|
| `src/gui.lisp` | **New** | `lexter/gui` protocol (`gui-initialize`/`gui-tick`/`gui-destroy`/`gui-window`/`gui-alive-p`) and the `run-gui-loop` dispatcher |
| `src/packages.lisp` | Modified | Added the `lexter/gui` package and its exports |
| `lexter.asd` | Modified | Added `src/gui` to the core `lexter` system |
| `src/unix-term.lisp` | Modified | Struct slots; `make-terminal`; `gui-*` methods; `run-terminal` reduced to a thin wrapper; `run-terminal-loop` removed |
| `src/panes/compositor.lisp` | Modified | Struct slots; `make-paned-compositor`; `gui-*` methods; `run-paned-terminal` reduced to a thin wrapper; `run-pane-loop` removed |
| `src/packages-unix.lisp` | Modified | `lexter/unix-term` uses `lexter/gui`; exports `make-terminal` and the protocol |
| `src/panes/packages.lisp` | Modified | `lexter/panes` uses `lexter/gui`; exports `make-paned-compositor` and the protocol |


## Outstanding Work

- **Origin main-thread GUI dispatcher.** The consumer side of Approach B: a
  main-thread loop in Origin that owns `glfw:initialize`/`terminate`, hosts one
  or more Lexter objects via `gui-initialize` / `gui-tick` / `gui-destroy`, and
  reports their status. This refactor makes Lexter ready for it; the thread-
  based `lexter/origin:define-terminal` (Approach A) remains the current path.
- **Multi-window callback registry.** Callbacks are still set per window and
  capture their object directly, which is correct for one window. True
  simultaneous multi-window input needs a `(pointer-address window) -> object`
  registry so the (static, non-capturing) GLFW callbacks dispatch by the window
  argument. The dispatcher and context-switching are already built to support
  this; only the registry and window-arg dispatch remain.
- **Demo entry points.** `run-demo` / `run-cjk-demo` still use
  `glfw:with-init-window` and their own loops. They were left untouched
  intentionally -- their use case is narrow and porting them is low priority --
  but they could adopt the same protocol for uniformity.
