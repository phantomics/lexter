# GPU Palette Paging: Development Log

This document chronicles the extension of Lexter's palette system from a
single GPU-resident palette to several. The persistent palette model
gave each screen its own 256-color palette synced to a single-palette
UBO. Palette paging widens that UBO to hold several palettes at once and
adds a slot-selection uniform, so switching which palette a pane renders
with costs one integer uniform write and zero data transfer.

**Date:** 2026-05-05


## Problem

The persistent palette model established that each screen owns a
256-color palette (1024 single-floats, RGBA) plus a generation counter,
and that the renderer re-uploads the palette UBO only when the
generation changes. That UBO held exactly one palette: 256 `vec4`s,
4 KB.

With one renderer and one single-palette UBO, only one palette can be
GPU-resident at a time. The compositor uploads the focused pane's
palette each frame (generation-gated, so a static palette costs nothing).
But the moment two panes carry *different* palettes, the single slot
becomes a bottleneck: every time rendering moves from a pane with
palette A to a pane with palette B, the 4 KB of palette B must be pushed
over the bus, and back again on the return. The palette data churns
across the PCIe boundary even though both palettes are small, fixed, and
were already uploaded moments earlier. The generation gate doesn't help
here -- the generations differ because the *palettes* differ, not because
either one changed.

The question that motivated this work (recorded in
`session-ses_2263-Lexter6.md:783`) was precisely this: rather than
re-sending palette data whenever the active palette changes, could we
hold several palettes resident in the UBO simultaneously -- appended one
after another -- and select among them by changing the *offset* at which
the shader fetches colors? In other words, make a palette switch a
pointer move on the GPU, not a memory transfer.


## Design Decisions

### 1. Larger UBO plus a slot uniform (Option A)

**Question:** How should multiple palettes be made simultaneously
resident and selectable?

**Decision:** Keep the existing UBO but make it hold several palettes
contiguously, and add a `u_palette_slot` integer uniform that the shader
uses to offset its color lookup. This was "Option A" from the design
discussion, chosen over two texture-based alternatives.

The contenders were:

- **Option A -- larger UBO + offset uniform.** Store N palettes back to
  back in the UBO (N x 256 x `vec4`); the shader indexes
  `colors[slot * 256 + color_index]`. Switching is one `glUniform1i`.
  Upload happens only when a slot's palette is first registered or
  changes.
- **Option B -- 1D `RGBA8` texture with paging.** Store all palettes in a
  single 1D texture (256 x N texels) and `texelFetch` with a base
  offset. This is 1 KB per palette instead of 4 KB (16 palettes in
  16 KB) and reuses the swatch-table texture pattern, at the cost of a
  texture migration.
- **Option C -- texture array.** One palette per layer of a
  `sampler1DArray`. Cleanest conceptually, but `sampler1DArray` has
  driver-portability quirks.

Option A won as the path of least resistance: the UBO already exists,
the change is a larger allocation plus one uniform plus a multiply-add in
the shader, and the data path (generation-gated upload) carries over
unchanged. For a terminal emulator -- a handful of palettes at most, one
per pane type or a user theme -- a few slots is ample. If the count ever
grows into the dozens, Option B remains the migration path and would also
consolidate with the swatch-table texture (see Outstanding Work).

This also settled the companion question from the same discussion --
whether colors *must* be floats. They need not be; `RGBA8` would be 4x
denser and the GPU normalizes it for free. But floats map cleanly to
`std140` `vec4` arrays, and at four palettes the 4x memory cost is
irrelevant, so the float UBO was retained. The density argument is the
one that would tip a future move to Option B.

### 2. Four slots, sized to the guaranteed UBO floor

**Question:** How many palette slots?

**Decision:** Four (`+max-palette-slots+` = 4), giving a 16 KB UBO at
4 KB per slot.

The number is pinned to portability, not ambition. The OpenGL 3.3 spec
guarantees `GL_MAX_UNIFORM_BLOCK_SIZE` of at least 16 KB. At 4 KB per
float palette, four slots is exactly what every conformant
implementation must support. Typical desktop hardware allows 64 KB (16
slots), but four is the safe floor that needs no capability query and no
fallback path -- and four distinct palettes is already more than a
terminal is likely to show at once.

### 3. Per-slot generation tracking

**Question:** How does the renderer decide when a given slot needs
re-uploading?

**Decision:** One generation counter per slot, not one global counter.
The render state holds an array of `+max-palette-slots+` generations;
`upload-palette` compares the incoming screen generation against the
recorded generation *for that slot* and uploads only that slot's 4 KB on
a mismatch.

This preserves the generation-gated upload property independently for
each resident palette. Mutating the palette in slot 2 re-uploads slot 2
and leaves slots 0, 1, and 3 untouched. A partial `buffer-sub-data` write
at the slot's byte offset means the other resident palettes are never
disturbed.

### 4. Slot threaded through the pane protocol

**Question:** Where does a pane's slot assignment live, and how does it
reach the renderer?

**Decision:** `pane-palette` returns the slot as a third value alongside
the palette array and its generation; a pane carries its slot in a slot
(`palette-slot`, default NIL meaning "use slot 0"). The compositor reads
all three and drives the upload and the uniform.

The protocol was already shaped for this in the persistent-palette work
-- `pane-palette` returned `(values palette generation)`. Adding the slot
as a third value is a backward-compatible extension: panes that don't set
a slot return NIL, the compositor coerces NIL to 0, and the
single-palette behavior is preserved exactly.


## Implementation

### Shaders (`src/shaders.lisp`)

Both fragment shaders -- simple and layered -- had their palette block
widened and a slot uniform added:

```glsl
uniform int u_palette_slot;        // which palette slot (0-3) to use

layout(std140) uniform Palette {
    vec4 colors[1024];  // 4 palettes x 256 colors
} u_palette;
```

The color fetch is offset by the slot. In the simple shader:

```glsl
frag_color = u_palette.colors[u_palette_slot * 256 + int(idx)];
```

and in the layered shader the same `base = u_palette_slot * 256` offset
is applied to both the ink and background palette indices. The array is
still a flat `vec4[]` -- just four times longer -- so `std140` layout is
unchanged; only the indexing arithmetic moved into the shader.

### Renderer (`src/renderer.lisp`)

Two constants frame the scheme (`src/renderer.lisp:15`):

```lisp
(defconstant +max-palette-slots+ 4)
(defconstant +palette-slot-size+ 4096)   ; bytes per slot (256 x vec4)
```

`%make-palette-ubo` now allocates `+max-palette-slots+ * +palette-slot-size+`
= 16 KB as `:dynamic-draw` (`src/renderer.lisp:153`).

`set-palette` gained an optional `slot` argument and writes that slot's
region only, via `buffer-sub-data` at offset `slot * +palette-slot-size+`
(`src/renderer.lisp:170`). `upload-palette` gained the same argument and
gates on the per-slot generation array (`src/renderer.lisp:181`):

```lisp
(let ((gens (render-state-palette-gens rs)))
  (when (/= generation (aref gens slot))
    (set-palette rs palette-floats slot)
    (setf (aref gens slot) generation)
    t))
```

`set-active-palette-slot` (`src/renderer.lisp:195`) selects the rendering
slot by writing `u_palette_slot` in both shader programs, guarded by the
render state's `current-palette-slot` so a redundant switch is a no-op:

```lisp
(unless (= slot (render-state-current-palette-slot rs))
  (setf (render-state-current-palette-slot rs) slot)
  ... gl:uniformi the cached locations in both programs ...)
```

The render state carries the new bookkeeping: the per-slot generation
array (`palette-gens`), the active slot (`current-palette-slot`), and the
cached `u_palette_slot` uniform locations for each shader
(`simple-palette-slot-loc`, `layered-palette-slot-loc`). The locations
are looked up once at renderer creation and both shaders are primed to
slot 0 (`src/renderer.lisp:290`), so a default single-palette setup
renders correctly with no further slot calls.

### Pane protocol (`src/panes/protocol.lisp`, `src/panes/vt-pane.lisp`)

`pane-palette`'s contract was extended to return
`(values palette-array generation slot)`, with the default method
returning NIL. `vt-pane` gained a `palette-slot` slot with a
`:palette-slot` initarg (default NIL) and its `pane-palette` method
returns the screen's palette, the screen's generation, and the pane's
slot.

### Compositor (`src/panes/compositor.lisp`)

After flushing the workspace, the compositor syncs the focused pane's
palette to its slot and activates it (`src/panes/compositor.lisp:201`):

```lisp
(multiple-value-bind (palette gen slot) (pane-palette pane)
  (when palette
    (let ((s (or slot 0)))
      (upload-palette (compositor-renderer comp) palette gen s)
      (set-active-palette-slot (compositor-renderer comp) s))))
```

The `upload-palette` call is generation-gated, so in steady state it
transfers nothing; `set-active-palette-slot` is the cheap uniform write
that does the actual switching.


## Design Properties

- **Zero-transfer switching.** Changing which resident palette a pane
  uses is a single `glUniform1i`. No buffer upload occurs unless a slot's
  palette is first registered or subsequently mutated.
- **Per-slot isolation.** A partial UBO write touches only the target
  slot's 4 KB; the other resident palettes are untouched, and each has
  its own generation gate.
- **Backward compatible.** Slot defaults to 0 everywhere -- pane initform,
  the compositor's `(or slot 0)`, the shaders' primed uniform -- so the
  single-palette demo and Unix-terminal paths render identically with no
  changes.
- **`std140` simplicity preserved.** The palette is still a flat `vec4`
  array; only its length and the shader's index arithmetic changed. No
  new buffer type, no texture migration.


## Verification

Verified by compilation and by running the existing single-palette entry
points, which render identically (everything resolves to slot 0). A pane
constructed with `:palette-slot 1` and a distinct palette uploads that
palette to slot 1 once; thereafter focusing it sets `u_palette_slot` to 1
with no further transfer, and the standard palette in slot 0 remains
resident and correct for the other panes.


## Outstanding Work

- **Per-region slot switching within a frame.** Today the compositor sets
  one active slot per frame -- the focused pane's. Several panes are
  resident in distinct slots, but a single frame renders them all through
  one slot. True simultaneous multi-palette display (each pane's region
  drawn with its own slot) requires `render-frame` to iterate pane
  regions and call `set-active-palette-slot` before each region's draw
  calls. The resident-palette infrastructure is in place; this is the
  remaining step to exploit it fully.
- **A slot allocator.** Slots are assigned by hand via `:palette-slot`.
  A registry that maps distinct palettes to slots, uploads on first-seen,
  recycles freed slots, and reports exhaustion would remove the manual
  bookkeeping and make slot assignment automatic.
- **More than four palettes (Option B).** If a configuration ever needs
  more than four palettes, migrate the store to a 1D `RGBA8` texture
  (1 KB per palette, 16 in 16 KB), which also consolidates with the
  existing swatch-table texture and answers the standing "floats vs.
  bytes" density question.
