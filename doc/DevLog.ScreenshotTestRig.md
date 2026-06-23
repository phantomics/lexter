# Screenshot Test Rig: Development Log

This document chronicles the design and implementation of Lexter's
screenshot-based test rig: a mechanism for recording the raw byte stream
a terminal receives, replaying it deterministically through a headless
terminal, and asserting the rendered pixels against a stored checksum.

**Date:** 2026-06-23


## Problem

Lexter had no way to test the relationship between terminal input and
rendered output. Two approaches were considered and the first was
rejected:

**Cell-matrix snapshots (rejected).** The initial idea was to dump the
screen's cell matrix -- a flat grid of `(codepoint fg bg)` triples -- and
compare it against a reference. This is how kitty, tmux, alacritty's "ref
tests", and vte actually test: they feed a byte stream into the emulator
and assert on the resulting *screen model* (characters + attributes),
never on pixels. They stop at the model layer deliberately, because
vector-font rasterization (FreeType hinting, antialiasing, subpixel
positioning, GPU rasterization) is not reproducible across machines, so
pixel-exact comparison is hopeless for them and they fall back to
tolerance comparison (SSIM, per-pixel thresholds, blurring) where they do
compare images at all.

The cell matrix is **lossy**, though. Character attributes set by control
codes -- color, bold, underline, reverse, cursor position, scroll region,
alternate screen -- are ephemeral: they steer how the cell matrix is
generated and are then discarded. A flat matrix snapshot cannot represent
all the factors worth testing, and it tests only the renderer's read of an
already-built grid, not the VT parser and handler that built it.

**The insight.** The complete, replayable description of a terminal's
state is the **raw byte stream** it received from the host -- every escape
sequence, every UTF-8 byte, every SGR change. Recording that stream and
replaying it tests the entire input->pixel pipeline: parser, handler,
model, atlas, and renderer.

**Lexter's special advantage.** Unlike vector-font terminals, Lexter
renders bitmap glyphs blitted from an R8 atlas with nearest-neighbor
sampling and integer cell positioning. There is no antialiasing, no
hinting, no subpixel rounding: the output is a deterministic function of
(font file, palette, screen model, renderer). This makes exact-pixel
checksum comparison sound -- a luxury the mainstream terminals' designs
deny them. (The only residual cross-machine risk is float rounding at quad
edges in the vertex shader; on a single dev machine the output is bit
-identical, and a software rasterizer -- `LIBGL_ALWAYS_SOFTWARE=1` -- would
restore determinism on heterogeneous CI GPUs if ever needed.)


## Design Decisions

Settled before implementation:

**Record the raw input, not the cell matrix.** A `recording` tap on the
single byte choke point (`process-output`) accumulates every host-to
-terminal byte. The tap is pure: it never alters parsing behavior whether
on or off.

**Start/stop recording.** Authoring sets up the terminal first (resize,
configure), then records only the interesting span. Recording is
controlled explicitly rather than capturing everything from init.

**Exact-pixel checksums.** The assertion is the exact pixel content of the
screen, captured via the offscreen FBO. Any pixel difference flips the
checksum -- which is the desired behavior for regression detection.
Intentional rendering changes (font swap, shader fix) regenerate the
checksums.

**Config set once, many dumps.** The terminal configuration (font, cols,
rows, cell dimensions, pixel scale) is durable session-level data,
established once and printed for reuse. It is *not* stored per fixture.
Each dump produces only two things: the recorded byte stream and the
checksum.

**Separate blobs from references.** The byte stream is written as a binary
blob (`.ptyb`); it is the durable, version-portable artifact. The expected
checksum and the config are *not* stored in a sidecar file -- they live as
literals in the test source (the `with-terminal-test-config` macro head and
the `test-pixels` forms). When rendering intentionally changes, re-author
and paste the new checksums.

**Input recording deferred.** Recording captures PTY *output*
(host->terminal); keyboard *input* (terminal->host) is out of scope for
now. The screen state is fully determined by the output stream, so this is
sufficient for rendering tests.

**Single-terminal recording for now.** Recording targets one terminal.
The longer-term vision is window-level recording yielding one blob per
pane, replayed into a headless multipane compositor; the single-terminal
primitives here are the building blocks for that.

**No coupled authoring constructor.** Authoring runs on a standard live
terminal with `terminal-start-recording` called on it -- no special
`make-recording-terminal`, which would tightly couple authoring to the
recording machinery. The printed config is purely for pasting into the
test macro.


## Implementation

### Recording tap (`src/vt-handler.lisp`)

A `recording` slot was added to the `vt-handler` struct: `nil` when off,
otherwise an adjustable `(unsigned-byte 8)` vector with a fill pointer.
`process-output` appends each processed byte range to the buffer *before*
parsing:

```lisp
(let ((rec (vt-handler-recording handler)))
  (when rec
    (loop :for i :from start :below (or end (length data))
          :do (vector-push-extend (aref data i) rec))))
(cl-vt:vt-parse (vt-handler-parser handler) data start end)
```

Control functions: `start-recording` (allocate a fresh buffer),
`stop-recording` (return the captured bytes as a fresh simple vector, clear
the slot), `recording-active-p`.

### Headless replay path (`src/unix-term.lisp`)

A `no-pty` slot was added to `unix-terminal`. When set:

- `gui-initialize` skips `pty-fork` (and `command` may be `nil`).
- `gui-tick` skips `process-pty-output` and the `pty-check-child`
  liveness test.

This reuses the entire real render path -- crucially the existing
`terminal-capture` (offscreen FBO + forced full flush + `capture-pixels`)
-- so replay tests exactly what the live terminal renders.

`terminal-reset` rebuilds a blank screen, display grid, and VT handler on
an existing terminal, reusing its window/atlas/renderer. This lets one
headless terminal serve many fixtures without rebuilding the (expensive)
GL atlas. `terminal-config-plist` returns the durable config plist.
`terminal-start-recording` / `terminal-stop-recording` delegate to the
handler.

### Test rig module (`src/test-rig.lisp`, system `lexter/test`)

**Checksum.** `fnv1a-64` computes a 64-bit FNV-1a hash over the flat bytes
of the `(H W 3)` capture (via a displaced array). FNV-1a was chosen over
`sxhash` for cross-implementation stability and over crypto hashes for
speed.

**Blob format.** A minimal frame guards against silent corruption:

```
bytes 0-3  magic   "PTYB" (#x50 #x54 #x59 #x42)
byte  4    version (1)
bytes 5-8  payload length, big-endian u32
bytes 9..  payload (the raw recorded byte stream)
```

`read-blob` validates magic, version, and length, erroring on any
mismatch. The blob is written through a pluggable handler:
`default-blob-writer` writes `<name>.ptyb`; a custom handler with the same
`(bytes &key name checksum)` signature can route the blob elsewhere.

**Authoring.** `dump-terminal` stops the recording, captures pixels,
computes the checksum, writes the blob, optionally invokes a `pixel-fn`
(for writing a reference PNG), and prints `<blob>  #x<checksum>` -- a
paste-ready `test-pixels` line. `pixel-fn` receives the capture plus
`:width :height :channels :checksum :name :config` keywords and is
declared with `&allow-other-keys` so future arguments stay compatible.

**Testing.** `with-terminal-test-config` owns the GLFW lifecycle, builds
one headless (`:no-pty`, hidden) terminal from the config, and binds
`*test-terminal*` for its dynamic extent. If the config declares
`:cell-width`/`:cell-height` they are verified against the loaded font so a
font swap cannot silently shift the geometry. `test-pixels` resets the
terminal, replays a blob, captures, and asserts the checksum -- silent on
success, erroring on mismatch (with an optional `on-mismatch` pixel handler
sharing `pixel-fn`'s signature, e.g. to dump an `actual-*.png`).

```lisp
(with-terminal-test-config (:font-path "unifont-17.0.04.pcf.gz"
                            :cols 80 :rows 24
                            :cell-width 8 :cell-height 16 :pixel-scale 1)
  (test-pixels "./1044.ptyb" #xAABBCCDDEEFF0011)
  (test-pixels "./1051.ptyb" #x1122334455667788))
```


## Workflow

Authoring (interactive, one-time):

```lisp
(terminal-start-recording term)
;; ... drive the terminal: colors, vim, scrolling ...
(print-terminal-config term)                 ; paste into the macro head
(dump-terminal term :name "1044")            ; -> 1044.ptyb  #x....
```

Testing (automated, deterministic, headless): the `with-terminal-test-config`
form above, run from a test driver.


## Verification

The system compiles and loads clean from scratch (cache cleared), as does
`lexter/panes` (which shares the modified `vt-handler` struct and
`process-output`). The GL-independent logic was smoke-tested directly:
`fnv1a-64` is deterministic, blob framing round-trips, and truncated/bad
-magic blobs are rejected. The full GL replay path could not be exercised
headlessly here (no display), matching the project's standing constraint.


## Files

- `src/vt-handler.lisp` -- `recording` slot, `process-output` tap,
  `start-recording` / `stop-recording` / `recording-active-p`.
- `src/packages-unix.lisp` -- exports for the recording and replay API.
- `src/unix-term.lisp` -- `no-pty` slot + guards, `terminal-start-recording`
  / `terminal-stop-recording`, `terminal-reset`, `terminal-config-plist`.
- `src/test-rig.lisp` -- checksum, blob API, `dump-terminal`,
  `with-terminal-test-config`, `test-pixels`, `replay-blob`.
- `lexter.asd` -- new `lexter/test` system.
