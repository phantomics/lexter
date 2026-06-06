# Persistent Palette Model: Development Log

This document chronicles the introduction of a persistent, mutable
color palette into Lexter's screen model. Before this work the 256-color
palette was a fixed array constructed once at startup and uploaded to the
GPU a single time. The goal was to make the palette a piece of live
terminal state -- owned by the screen, mutable at runtime, and
efficiently re-synced to the GPU only when it changes -- so that terminal
applications requesting custom colors can eventually be honored.

**Date:** 2026-05-05


## Problem

Lexter renders cells through a two-level color indirection that was
already in place from the swatch work:

```
cell -> swatch index -> palette index -> RGB color (in the UBO)
```

A cell names a swatch; a swatch names up to four palette indices (bg,
fg, overlay, secondary); a palette index names an RGB triple stored in a
Uniform Buffer Object on the GPU. This indirection is what makes
recoloring cheap: changing an RGB value at the bottom of the chain
recolors every cell that transitively references it, with no per-cell
work.

The palette itself, however, was not live state. It was built once by a
`make-xterm-palette` function that lived in `demo.lisp`, uploaded to the
UBO a single time via `set-palette`, and never touched again. The float
array was a local variable in each entry point's main loop. There was
no object that owned the palette, no way for terminal logic to mutate
it, and no mechanism to re-upload it efficiently after a change.

This blocks the natural goal: terminal applications routinely request
palette changes through OSC escape sequences -- `OSC 4` to set an
individual entry, `OSC 10/11/12` for default fg/bg/cursor, `OSC 104` to
reset. To support any of that, three things were missing:

1. **A persistent home for the palette** -- somewhere the terminal logic
   (which receives OSC sequences) can reach and modify.
2. **Change tracking** -- so the 4 KB UBO is re-uploaded only when the
   palette actually changes, not every frame.
3. **A mutation API** -- functions to set one entry, set defaults, and
   reset, each marking the palette dirty.

The encouraging part was that the hard infrastructure already existed.
The palette is already an independent GPU resource (its own UBO), and
`set-palette` already uploads it in one call. The work was about state
ownership and change tracking, not new rendering machinery.


## Design Decisions

### 1. The palette lives on the screen model

**Question:** Where should the persistent palette state live -- on the
screen model, on the workspace/compositor, or on the renderer?

**Decision:** On the screen model, alongside the swatch table it already
owns.

The deciding factor is where palette changes *originate*. OSC sequences
arrive through the VT handler, which already has the screen in hand. The
screen is also the object that owns the swatch table -- the layer
directly above the palette in the indirection chain -- so colocating the
palette keeps the whole color model in one place. And because each pane
has its own screen, putting the palette there gives every pane an
independent palette for free: a 3270 pane and a Unix shell in the same
workspace can carry different color schemes without contending for a
shared global.

The renderer was rejected as a home because it is a plain rendering
struct with no business logic; the workspace was rejected because it is
further from where changes arrive and would force shared-palette
semantics onto panes that want their own.

### 2. Change tracking via a generation counter

**Question:** How does the renderer know when to re-upload the palette?

**Decision:** A generation counter on the screen, mirroring the existing
swatch-table generation pattern. Every mutation bumps
`palette-generation`; the renderer remembers the last generation it
uploaded and re-uploads only on a mismatch.

This is deliberately the *same* idiom already used for swatches
(`swatch-table-generation` vs. the grid's `swatch-generation`), so the
two synchronization paths look and behave identically. Re-uploading 4 KB
is cheap enough that the optimization is almost academic, but the
counter also gives a clean, race-free "has this changed?" predicate and
keeps the GPU upload off the hot path for the common case where the
palette is static frame to frame.

### 3. Scope: persistent state and generation now, OSC parsing later

**Question:** Should this change also parse the OSC sequences that drive
palette changes?

**Decision:** No. This iteration implements the persistent state and the
generation-tracked sync, plus a programmatic mutation API, and
explicitly defers VT-handler OSC parsing.

Separating the two is sound layering. The palette model and its sync are
a self-contained unit that can be built and verified on their own. The
mutation functions (`set-palette-entry`, `reset-palette`, and friends)
are precisely the hooks a future OSC handler will call -- so deferring
the parser costs nothing and lets the color model land first.

### 4. Palette syncs screen -> renderer directly, not through the grid

**Question:** Should `flush-to-display` carry the palette to the GPU, the
way it carries swatches?

**Decision:** No. The palette bypasses the display grid and goes
straight from the screen to the renderer at render time, in the caller's
loop, after flush and before `render-frame`.

This respects the existing module boundaries. `flush-to-display` does
model -> grid and lives in the model package, which has no dependency on
the renderer. Swatches flow through the grid because the grid is a GPU
mirror of per-cell state; the palette is not per-cell -- it is a single
shared resource -- so routing it through the grid would be artificial.
Instead each entry point (compositor, Unix terminal, demo) calls
`upload-palette` with the active screen's palette and generation between
flushing and rendering:

```lisp
(flush-to-display screen grid ...)
(upload-palette renderer (screen-palette screen) (screen-palette-generation screen))
(render-frame renderer grid)
```

With one renderer and possibly several panes, the caller uploads the
*active* pane's palette each frame -- correct for the single-palette GPU
state of the time, and cheap.


## Implementation

### Model: screen state and mutation API (`src/model.lisp`)

Two slots were added to the `screen` struct (`src/model.lisp:258`):

```lisp
(palette nil :type (or null (simple-array single-float (1024))))
(palette-generation 1 :type fixnum)
```

The palette is 1024 single-floats -- 256 entries x RGBA. The generation
starts at 1 (see "The generation handshake" below). `make-screen`
initializes the palette via `make-default-palette`.

`make-default-palette` (`src/model.lisp:109`) was promoted from the
demo's `make-xterm-palette` into the model proper. It builds the
standard xterm 256-color layout: entries 0-15 the ANSI set, 16-231 the
6x6x6 color cube, 232-255 the 24-step greyscale ramp, each normalized to
0.0-1.0 RGBA.

The mutation API, each call incrementing the generation:

- `set-palette-entry (screen idx r g b &optional a)` -- set one entry
  from float RGBA, bump generation (`src/model.lisp:151`)
- `set-palette-entry-rgb8 (screen idx r g b)` -- convenience for 0-255
  byte values (`src/model.lisp:162`)
- `get-palette-entry (screen idx)` -- read an entry as four values
  (`src/model.lisp:167`)
- `reset-palette (screen)` -- `replace` the palette with a fresh default
  and bump generation (`src/model.lisp:176`)

These are the seams the future OSC handlers will call: `OSC 4` maps to
`set-palette-entry-rgb8`, `OSC 104` to `reset-palette`.

### Renderer: generation-gated upload (`src/renderer.lisp`)

The render state gained a counter for the last-uploaded generation, and
the upload itself was split into a low-level primitive and a
generation-gated wrapper:

- `set-palette (rs palette-floats ...)` -- the low-level UBO upload
  (`%gl:buffer-sub-data` of 4096 bytes).
- `upload-palette (rs palette-floats generation ...)` -- compares
  `generation` against the render state's recorded value, uploads via
  `set-palette` only on a mismatch, records the new generation, and
  returns T if an upload occurred (`src/renderer.lisp:181`).

This is exactly parallel to the swatch-table path's `swatch-gen` /
`upload-swatch-table` pair.

### Callers (`src/demo.lisp`, `src/unix-term.lisp`)

The entry points stopped constructing their own palettes and instead use
the screen's persistent palette, calling `upload-palette` at render time
with the screen's generation. The old per-loop local palette array is
gone.

### The generation handshake

The screen's `palette-generation` initializes to 1; the render state's
last-uploaded generation initializes to 0. The first frame therefore
always sees a mismatch (1 != 0) and uploads, guaranteeing the GPU starts
from the correct palette without a special-case "prime the UBO" step.
Thereafter every mutation increments the screen's counter, and the next
`upload-palette` notices and re-syncs. It is the same self-priming
handshake the swatch table uses.


## Design Properties Preserved

- **O(1) recoloring.** A palette change touches only the 256-entry array
  and a counter. No swatch table rebuild, no instance-data rebuild, no
  per-cell update -- the two-level indirection propagates the new colors
  on the GPU automatically.
- **Upload only on change.** The generation gate keeps the 4 KB UBO
  upload off the frame path whenever the palette is static.
- **Per-screen ownership.** Each pane's screen owns its palette, so
  independent per-pane color schemes are possible; the single-renderer
  constraint only limits how many are *active* at once, not how many can
  exist.
- **Clean layering.** The model package gained palette state and a
  mutation API without taking any dependency on the renderer; the
  screen->GPU sync stays in the caller where the renderer is in scope.


## Verification

The change was verified by compilation and by running the existing demo
and Unix-terminal entry points against the screen-owned palette: the
xterm colors render identically to the previous startup-constructed
palette, confirming `make-default-palette` and the first-frame upload
handshake reproduce the prior output. Programmatic mutation via
`set-palette-entry` followed by a frame re-uploads and recolors the
referencing cells without any swatch or cell rebuild.


## Outstanding Work

- **VT handler OSC parsing.** The deferred half of the feature: wire
  `OSC 4` / `OSC 10/11/12` / `OSC 104` in the VT handler to
  `set-palette-entry-rgb8`, the default-color setters, and
  `reset-palette`. The model API is already shaped for these calls.
- **Multiple live palettes on one renderer.** With a single renderer the
  caller can only make one screen's palette active per frame (the
  focused pane's). Supporting several panes with distinct palettes
  simultaneously needs the UBO to hold more than one palette -- which was
  subsequently addressed by palette *paging*: the UBO was widened to
  several slots, each pane reports a slot via `pane-palette`, and the
  renderer activates the focused pane's slot. That work builds directly
  on the per-screen palette and generation counter established here.
- **OSC default-color semantics.** `OSC 10/11/12` set "the default
  foreground/background/cursor," which interact with how the default
  swatch (index 0) maps onto palette entries. Defining that mapping
  precisely is a small design task to settle when the OSC handlers land.
