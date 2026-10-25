# Stop Flag: Development Log

This document chronicles the design and implementation of Lexter's
stop flag system: the mechanism by which a Lexter render loop running
inside its own thread can be asked to shut down cleanly from outside
that thread. The need arose when Lexter terminals were placed under
the Origin process manager, but the mechanism is deliberately
independent of Origin and is shared uniformly across every blocking
loop in the codebase.

**Date:** 2026-06-06


## Problem

Every interactive entry point in Lexter is built around a single
blocking render loop. `run-terminal-loop` drives a Unix PTY terminal
(`src/unix-term.lisp:236`), `run-pane-loop` drives the pane compositor
(`src/panes/compositor.lisp:159`), and the demo entry points
(`run-demo`, `run-cjk-demo` in `src/demo.lisp`) run their own variants.
Each is a tight loop that polls GLFW events, processes I/O, renders a
frame, swaps buffers, and sleeps a millisecond. The loop owns the GLFW
window, the OpenGL context, and -- for the terminal loops -- a forked
child process attached to a PTY.

Run interactively, these loops have an obvious exit condition: the
window is closed, or the user presses a quit key, and
`glfw:window-should-close-p` becomes true. Cleanup then runs through an
`unwind-protect`: the PTY is closed, the renderer is destroyed, the
GLFW window is torn down.

The trouble started when Lexter terminals were registered as
Origin-managed processes. Origin runs each managed process in its own
SBCL thread and supervises it -- starting, stopping, restarting, and
restart-throttling it according to policy. The crux is Origin's stop
protocol (`~/src/lisp/origin/src/managed-process.lisp:233`):

1. Call the process's `stop-function` to request a graceful shutdown.
2. Wait up to `timeout` seconds (default 5) for the thread to exit on
   its own.
3. If the thread is still alive, call `sb-thread:terminate-thread` on
   it as a last resort.

Step 3 is the problem. `terminate-thread` injects an interrupt that
unwinds the thread wherever it happens to be -- very possibly in the
middle of a GLFW or OpenGL call, holding the context. GLFW is not
thread-safe and is emphatically not designed to have its window and
context functions interrupted and unwound from underneath it. Forcibly
terminating a thread mid-frame risks leaving GLFW in an inconsistent
state, leaking the window and GL context, and corrupting global GLFW
state that a *subsequent* terminal (e.g. an Origin restart) would
inherit. The PTY child process would also be orphaned, since
`pty-close` lives in the `unwind-protect` cleanup that a hard
termination may skip or run in a hostile context.

In other words: a Lexter loop cannot safely be stopped *from another
thread*. It can only be stopped safely from within its own thread, at
a point between frames where no GLFW/GL call is in flight and where the
normal `unwind-protect` cleanup can run. What was needed was a way for
Origin's `stop-function` -- which runs on the supervisor's thread -- to
*ask* the loop to exit at the top of its next iteration, turning the
dangerous "terminate-thread" path into a rarely-taken fallback rather
than the normal stop path.


## Design Decisions

### 1. Cooperative cancellation, not preemptive termination

**Question:** How should an external caller stop a render loop that
owns a GLFW context?

**Decision:** The loop polls a shared cancellation flag once per
iteration and exits voluntarily. The external caller never touches the
loop's thread, its window, or its context; it only sets the flag.

This is cooperative (poll-based) cancellation. It trades a small amount
of latency -- the loop honors the request at its next tick, within one
frame plus the per-tick `(sleep 0.001)` -- for the guarantee that
shutdown always happens at a safe point, with the full `unwind-protect`
cleanup running on the thread that owns the resources. Given Origin's
5-second graceful-stop window, sub-millisecond response latency is
irrelevant; correctness of teardown is everything.

Origin's `terminate-thread` fallback still exists, but with the flag in
place it should never fire for a healthy loop. It is now a backstop for
a wedged loop, not the primary stop mechanism.

### 2. The flag is a mutable cons cell ("box"), passed by reference

**Question:** What concrete object represents the flag, given that one
thread writes it and another reads it?

**Decision:** A one-element list -- a single cons -- whose `car` holds
the state. The loop reads `(car stop-flag)`; the stopper writes
`(setf (car stop-flag) ...)`. The same cons is shared by both sides.

Common Lisp has no first-class "mutable reference to a boolean." The
options considered:

- **A special (dynamic) variable.** Dynamic bindings are per-thread;
  a value bound on the supervisor thread is not visible in the loop
  thread, and a global `defvar` would be shared mutable state with no
  natural scoping to a particular terminal instance. Multiple terminals
  would collide on one global.
- **A closure over a lexical variable.** Workable, but then the "flag"
  is two functions (a getter and a setter) that have to be passed
  around together, which is heavier than the value it guards.
- **A struct or CLOS object with a boolean slot.** Correct, but
  introduces a type and a dependency for what is conceptually one bit.
- **A cons cell.** The minimal idiomatic Lisp "box": a heap-allocated
  cell with a writable place (`car`) that any number of closures can
  capture and share by identity. No new type, no global, naturally
  one-per-terminal.

The cons won on minimalism. It is the smallest thing that is (a)
shared by identity across the thread boundary and (b) has a writable
place. Each terminal gets its own cons, so there is no cross-terminal
interference.

### 3. Polarity: car = T means "run", NIL means "stop"

**Question:** Which value means "keep going" and which means "stop"?

**Decision:** `(car stop-flag)` is T (truthy) while the loop should
run and is set to NIL to request a stop. The loop's continuation
condition is therefore "the flag's car is non-nil."

The name "stop flag" with `T`-means-go polarity is mildly
counterintuitive, but it makes the loop guard read naturally as a
*continue* predicate (see Decision 4) and lets NIL -- the natural
Lisp "off"/"done" value -- mean "stop." It also dovetails with making
the flag optional: an absent flag and a "still running" flag both read
as "don't stop."

### 4. The flag is optional; absence means "run until window close"

**Question:** Should every loop require a flag, even when run
interactively outside any supervisor?

**Decision:** No. The flag is an optional keyword argument defaulting
to NIL, and the loop guard treats "no flag supplied" identically to
"flag says run." The two phrasings used in the codebase are:

```lisp
;; run-terminal-loop / run-pane-loop  (continue predicate, :while)
(or (null stop-flag) (car stop-flag))

;; demo loops  (stop predicate, :until)
(and stop-flag (not (car stop-flag)))
```

Both encode the same truth table: stop only when a flag is present
*and* its car is NIL. An interactively launched terminal passes no
flag and behaves exactly as before -- it exits on window close or quit
key. Only when a supervisor supplies a flag does the new path engage.
This keeps the mechanism strictly additive: existing direct callers
were untouched.

### 5. The flag is re-armed on every (re)start, inside the entry point

**Question:** Origin reuses the same `managed-process` -- and therefore
the same `entry-args`, including the same cons -- across restarts.
After a stop sets the car to NIL, a restart would find a flag that
already says "stop." How is it rearmed?

**Decision:** The Origin entry point re-arms the flag to T *before*
invoking the loop, every time it is called
(`src/origin.lisp:24-29`):

```lisp
:entry-point (lambda (&rest entry-args)
               (setf (car stop-flag) t)
               (apply #'lexter/unix-term:run-terminal entry-args))
:entry-args (list* command :stop-flag stop-flag lexter-args)
:stop-function (lambda () (setf (car stop-flag) nil))
```

The single cons created by `define-terminal` (`src/origin.lisp:21`)
is captured three times: it is spliced into `entry-args` so the loop
receives it, captured by the entry-point closure so each start can
re-arm it to T, and captured by the stop-function closure so a stop
can set it to NIL. Because all three references are the *same* cons,
the stop-function and the running loop are talking through one shared
cell, and the entry point guarantees a freshly-armed flag on every
supervised start and restart.


## Implementation

### The shared contract

Every blocking loop documents and honors the same contract, stated
identically in each docstring: *"STOP-FLAG, if provided, is a list
whose CAR is checked each tick. When (CAR STOP-FLAG) is NIL, the loop
terminates."* The flag is threaded from the public entry point
(`run-terminal`, `run-paned-terminal`, `run-demo`, `run-cjk-demo`)
down into the loop function as a keyword argument.

### Terminal loop

`run-terminal-loop` (`src/unix-term.lisp:236`) adds the flag to its
`:while` guard alongside the pre-existing `running` flag and the GLFW
close check:

```lisp
(loop :while (and (unix-terminal-running term)
                  (not (glfw:window-should-close-p))
                  (or (null stop-flag) (car stop-flag)))
      :do ...)
```

The flag is checked once per iteration, at the top, before any GLFW or
GL work for that frame. When it trips, the loop falls out and control
returns to `run-terminal`, whose `unwind-protect`
(`src/unix-term.lisp:418`) runs the safe teardown -- `pty-close` and
`destroy-renderer` -- on the loop's own thread.

### Pane compositor loop

`run-pane-loop` (`src/panes/compositor.lisp:159`) uses the same guard
shape:

```lisp
(loop :while (and (compositor-running comp)
                  (not (glfw:window-should-close-p))
                  (or (null stop-flag) (car stop-flag)))
      :do ...)
```

and its `unwind-protect` (`src/panes/compositor.lisp:331`) destroys
every workspace and the renderer on exit. `run-paned-terminal` accepts
and forwards the flag identically to `run-terminal`.

### Demo loops

The demo loops in `src/demo.lisp` use the inverted `:until` phrasing
(`src/demo.lisp:178` and `src/demo.lisp:249`):

```lisp
(loop :until (or (glfw:window-should-close-p)
                 (and stop-flag (not (car stop-flag))))
      :do (render-frame renderer grid)
          (glfw:swap-buffers)
          (glfw:poll-events))
```

This is the same predicate negated: stop on window close, or on a
present-and-NIL flag. The demos thus participate in the same
supervision contract as the real terminals.

### Origin integration

`define-terminal` (`src/origin.lisp:3`) is the only place that
constructs a flag and wires it to a supervisor. It allocates one cons
(`(list t)`), strips Origin-specific keywords from the argument list,
and registers an Origin process whose entry point re-arms the flag and
runs the terminal, and whose stop-function clears the flag. The result
is that `(origin:stop :my-terminal)` flips the cons to NIL; the loop
notices at its next tick and exits cleanly through `unwind-protect`;
and Origin's `terminate-thread` fallback never fires unless the loop is
genuinely stuck.


## How the two stop paths now compose

With the flag in place, Origin's three-step stop protocol degrades
gracefully:

```
origin:stop
  |
  v
stop-function sets (car stop-flag) -> NIL      [supervisor thread]
  |
  v
loop's next :while check fails                 [loop thread]
  |
  v
unwind-protect cleanup: pty-close,             [loop thread]
destroy-renderer, GLFW teardown
  |
  v
thread exits normally, well before timeout
  |
  +--- (only if the loop is wedged and never
        reaches its guard within `timeout`) --->
        sb-thread:terminate-thread  [last-resort fallback]
```

The dangerous path is still present for true hangs, but the flag moves
the common case onto the safe path where GLFW and the PTY are released
in an orderly fashion on the thread that owns them.


## Design Properties

- **Thread-affinity respected.** No GLFW, OpenGL, or PTY resource is
  ever touched from a thread other than the one that created it. The
  stopper only writes a cons cell.
- **Additive and backward-compatible.** The flag is optional; every
  pre-existing direct caller (interactive launch, demos run by hand)
  behaves exactly as before when no flag is supplied.
- **Uniform.** All four loops honor one documented contract, so a
  supervisor (Origin or any future one) integrates with any Lexter
  loop the same way.
- **Minimal.** One cons per terminal, no new types, no globals, no
  dependency on Origin in the loops themselves -- the loops only know
  about "a list whose car I check."
- **Per-instance.** Each terminal owns its own cons, so multiple
  supervised terminals never interfere.


## Verification

Verified manually by registering a terminal with `define-terminal`,
starting it under Origin, and confirming that `origin:stop` returns the
process to `:stopped` with the GLFW window torn down and the PTY child
reaped -- with no `terminate-thread` fallback observed (the loop exits
within one tick, far inside Origin's 5-second graceful window).
Restarting the same process confirms the flag is re-armed: the
entry-point's `(setf (car stop-flag) t)` lets a previously-stopped
terminal run again without reallocating the cons. Interactive launches
that pass no flag continue to exit only on window close or quit key.


## Files

| File | Action | Description |
|------|--------|-------------|
| `src/unix-term.lisp` | Modified | `run-terminal-loop` / `run-terminal` accept and check `:stop-flag` in the `:while` guard |
| `src/panes/compositor.lisp` | Modified | `run-pane-loop` / `run-paned-terminal` accept and check `:stop-flag` |
| `src/demo.lisp` | Modified | `run-demo` / `run-cjk-demo` accept and check `:stop-flag` (inverted `:until` form) |
| `src/origin.lisp` | New | `define-terminal` allocates the shared cons, re-arms it in the entry point, and clears it in the stop-function |


## Outstanding Work

- **Quiescing the loop without exiting.** The flag is binary: run or
  shut down. A future "pause/resume" (stop rendering but keep the PTY
  and window alive) would want a richer state than a single boolean
  car -- at which point the cons would graduate to a small struct.
- **Stop-reason reporting.** The loop currently cannot distinguish
  "stopped by supervisor" from "window closed" from "child exited."
  Carrying a reason back out (e.g. via the flag cell or a return value)
  would let Origin's restart-policy logic treat a user-closed window
  differently from a crash.
- **Multiplexed supervision.** A compositor hosting many panes is
  stopped as a unit. Per-pane lifecycle under a supervisor would need
  each pane to carry its own flag, which the current single-cons design
  does not yet model.
