# Offscreen Render Target (FBO): Development Log

This document chronicles the addition of an opt-in offscreen render target to
Lexter -- a framebuffer object (FBO) that `render-frame` can draw into instead
of the window's default framebuffer. Phase 1 (this work) delivers the FBO
foundation plus screenshot capture, primarily to support automated, pixel-level
testing. Phase 2 (not yet built) will layer a pluggable post-processing effect
chain (blur, bloom, CRT warp, ...) on the same foundation.

**Date:** 2026-06-06

**Status:** Phase 1 complete. Phase 2 (post-processing effects) outstanding.


## Motivation

Two interrelated goals prompted this work:

1. **Screenshots as `HxWx3` `(unsigned-byte 8)` arrays** -- mainly for *testing*.
   The ability to render a terminal to known dimensions and assert on the exact
   pixels (or serialize a PNG) is the highest-value piece: it turns the
   GL-dependent rendering path, previously only verifiable by eye, into
   something a test can check.
2. **Pluggable filtering shaders** applied to the whole screen after the layer
   structure is generated -- blur/bloom/CRT-style warping, etc.

Both want the same thing underneath: the scene must be rendered into a texture
we can read back (for screenshots) or re-sample (for effects), rather than
straight to the window. So the design built that shared foundation once.


## Starting point

`render-frame` drew the simple and layered passes directly to the default
framebuffer, and the `gui-tick` loops called `glfw:swap-buffers` immediately
after. There was no FBO anywhere; the renderer used no depth buffer (it is a 2D
cell grid with alpha-blended layers), so a colour-only target suffices. A
precursor experiment (`screenshot.lisp`, inherited from the predecessor
`pcf-gl` project) had already shown the read-back mechanism:
`gl:read-pixels … :rgb :unsigned-byte`, flipped vertically because GL's origin
is bottom-left.


## Design Decisions

These were settled with the user before implementation.

### 1. Opt-in, not always-on

When no effect is enabled and no capture is requested, `render-frame` draws to
the window exactly as before -- the common hot path is byte-for-byte unchanged.
The FBO path engages only when `enable-offscreen` has been called (today: when
a capture is taken; later: when an effect is active). This avoids imposing an
extra full-screen blit on every ordinary frame.

### 2. Window-resolution FBO; pixel-scale unchanged

`pixel-scale` is currently baked into the vertex shader, so the scene is already
rendered at window resolution. The FBO is sized to the window, and no scaling
behaviour changed. (A "more correct" CRT pass would render at *logical*
resolution and apply scaling + curvature in the present pass, but that is a
`pixel-scale` rework deferred to Phase 2.)

### 3. RGBA8 colour format

Sufficient for screenshots and for blur/CRT/basic bloom. HDR bloom would want
RGBA16F; that upgrade is left for Phase 2 if needed.

### 4. FBO is the screenshot source

Reading from the default framebuffer is subject to the window pixel-ownership
test (occluded/offscreen windows yield undefined pixels). Reading from the FBO
is deterministic and independent of window visibility -- exactly what tests
need.

### 5. Capture forces a render

`terminal-capture` / `compositor-capture` flush and render unconditionally
(ignoring dirty-tracking), so a capture is deterministic regardless of what the
last `gui-tick` happened to do.

### 6. Hidden-window flag for tests

`gui-initialize` now honours a `:visible` config flag threaded through the
constructors and entry points. Tests create the terminal with `:visible nil`,
get a GL context with no on-screen window, render to the FBO, and capture.


## Implementation

### `src/renderer.lisp` -- the FBO foundation

- **`render-state` fields:** `offscreen-enabled`, `offscreen-fbo`,
  `offscreen-tex`, `offscreen-w`, `offscreen-h`.
- **`%ensure-offscreen (rs w h)`** -- lazily creates / resizes the RGBA8 colour
  texture (nearest, clamp) and the FBO, attaches the texture to
  `:color-attachment0`, and verifies completeness. No depth attachment (the
  renderer needs none).
- **`enable-offscreen` / `disable-offscreen` / `offscreen-enabled-p` /
  `resize-offscreen`** -- the public toggles; `resize-offscreen` is a no-op
  unless an FBO already exists.
- **`render-frame`** -- now binds the offscreen FBO (and sets the viewport to
  its size) when enabled, else binds framebuffer 0. The rest of the function is
  untouched.
- **`present-offscreen (rs)`** -- blits the offscreen colour buffer 1:1 to the
  default framebuffer so the window shows the frame. No-op when disabled.
  (Phase 2 replaces this blit with the effect chain.) Uses
  `%gl:blit-framebuffer` -- cl-opengl exposes blit only in the low-level `%gl`
  package, not `gl`.
- **`capture-pixels (rs)`** -- binds the FBO as the read framebuffer, sets
  `(gl:pixel-store :pack-alignment 1)`, reads `:rgb :unsigned-byte`, and
  repacks the flat bottom-up buffer into a top-down `(H W 3)` array.
- **`update-viewport`** resizes the offscreen target alongside the window;
  **`destroy-renderer`** deletes the FBO and its texture.

### `src/unix-term.lisp` / `src/panes/compositor.lisp`

- A `visible` config slot (default `t`), threaded through `make-terminal` /
  `make-paned-compositor` and the `run-*` wrappers, and passed to
  `glfw:create-window` as `:visible`.
- `present-offscreen` is called in each `gui-tick`, right after `render-frame`
  and before `swap-buffers` (a no-op unless offscreen is enabled).
- **`terminal-capture (term)`** and **`compositor-capture (comp)`** -- make the
  GL context current, enable offscreen, force a full flush + render, and return
  the captured `(H W 3)` array. `terminal-capture` marks the active screen
  dirty before flushing (the unix terminal flushes incrementally);
  `compositor-capture` relies on `flush-workspace` already flushing every pane.

### Exports

`lexter/renderer`: `enable-offscreen`, `disable-offscreen`,
`offscreen-enabled-p`, `resize-offscreen`, `present-offscreen`,
`capture-pixels`. `lexter/unix-term`: `terminal-capture`,
`unix-terminal-renderer`. `lexter/panes`: `compositor-capture`,
`compositor-renderer`.


## A recurring gotcha: pixel store alignment

This is the third time a GL row-alignment default has bitten this codebase, so
it is worth recording as a pattern. GL defaults `GL_UNPACK_ALIGNMENT` and
`GL_PACK_ALIGNMENT` to 4; any single-channel (or 3-byte RGB) image whose row
byte-width is not a multiple of 4 is then read/written with a per-row skew.
`capture-pixels` reads tightly-packed `w*3`-byte rows, so it sets
`:pack-alignment 1` -- the read-side counterpart of the `:unpack-alignment 1`
fix made earlier for the glyph atlas. Rule of thumb for this project: any time
we move single-channel or RGB pixel data across the GL boundary at an arbitrary
width, set the relevant alignment to 1.


## Verification

The systems compile and load cleanly (`lexter`, `lexter/unix`, `lexter/panes`),
with all new symbols `fboundp` and `:visible` present in the entry-point lambda
lists. The actual pixel round-trip needs a live GL context (a GLFW window, even
if hidden), so end-to-end capture is exercised by the user; the intended test
shape is:

```lisp
(glfw:initialize)
(let ((term (lexter/unix-term:make-terminal "/bin/sh" :cols 20 :rows 4
                                            :visible nil)))
  (lexter/unix-term:gui-initialize term)
  ;; feed input / gui-tick a few frames ...
  (let ((img (lexter/unix-term:terminal-capture term)))   ; (H W 3) ub8, top-down
    ;; assert on pixels or serialize to PNG
    )
  (lexter/unix-term:gui-destroy term)
  (glfw:terminate))
```


## Files

| File | Action | Description |
|------|--------|-------------|
| `src/renderer.lisp` | Modified | Offscreen FBO fields, `%ensure-offscreen`, enable/disable/resize, `render-frame` targeting, `present-offscreen`, `capture-pixels`, viewport resize + teardown |
| `src/unix-term.lisp` | Modified | `:visible` slot/flag; `present-offscreen` in `gui-tick`; `terminal-capture` |
| `src/panes/compositor.lisp` | Modified | `:visible` slot/flag; `present-offscreen` in `gui-tick`; `compositor-capture` |
| `src/packages.lisp` | Modified | Export offscreen/capture renderer symbols |
| `src/packages-unix.lisp` | Modified | Export `terminal-capture`, `unix-terminal-renderer` |
| `src/panes/packages.lisp` | Modified | Export `compositor-capture`, `compositor-renderer` |


## Phase 2: outstanding work (post-processing effect chain)

The FBO foundation is deliberately shaped so the following can be added without
disturbing it:

- **Fullscreen-quad pass infrastructure.** A passthrough vertex shader + a unit
  quad VAO, so a fragment shader can sample the scene texture across the whole
  screen. This replaces the `present-offscreen` blit as the final stage.
- **Ping-pong FBOs.** A second (and for bloom, several downsampled) FBO so
  multi-pass effects can read one target and write another in turn.
- **Pluggable effect registry.** An ordered list of effects, each
  `{name, compiled-program, uniform-setup-fn, enabled?}`, with runtime
  enable/disable/reorder. The render loop becomes: scene -> FBO A; for each
  enabled effect, source A -> target B (draw fullscreen quad), swap; final pass
  -> default framebuffer.
- **First effects.** CRT warp + scanlines + vignette (single pass; easy),
  separable Gaussian blur (two passes; easy), bloom (bright-pass + downsample +
  blur + composite; the most involved, possibly wanting RGBA16F).
- **Logical-resolution rendering (optional).** Rendering at the unscaled grid
  resolution and applying `pixel-scale` + curvature in the present pass would
  give crisper CRT results, at the cost of reworking how `pixel-scale` flows
  through the vertex shader.
- **Capture from a chosen pipeline stage.** `capture-pixels` currently reads the
  scene FBO; once effects exist it should be able to read either the raw scene
  or the post-processed result.
- **True headless capture.** Capture still requires a GL context via a (hidden)
  GLFW window. An EGL/surfaceless context path would allow capture with no
  windowing system at all -- useful for CI -- but is a separate undertaking.
