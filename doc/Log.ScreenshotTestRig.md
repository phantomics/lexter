---
id:            LEXTER-DRAFT-screenshot-test-rig
title:         "Screenshot Test Rig: Development Log"
genre:         Log
scope:         component
project:       Lexter
component:     test
language:      en
status:        Draft
provenance:
  assistant:   opencode
relates-to:
  - LEXTER-DRAFT-offscreen-fbo
  - LEXTER-DRAFT-data-structures-1e-critique
decisions:
  - LEXTER-DRAFT-screenshot-test-rig-D1
  - LEXTER-DRAFT-screenshot-test-rig-D2
  - LEXTER-DRAFT-screenshot-test-rig-D3
  - LEXTER-DRAFT-screenshot-test-rig-D4
  - LEXTER-DRAFT-screenshot-test-rig-D5
  - LEXTER-DRAFT-screenshot-test-rig-D6
  - LEXTER-DRAFT-screenshot-test-rig-D7
  - LEXTER-DRAFT-screenshot-test-rig-D8
---

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

### LEXTER-DRAFT-screenshot-test-rig-D1 — Record the raw input, not the cell matrix

**Status:** Proposed

**Context:** A test must capture everything that determines the rendered
screen. The cell matrix is lossy, while the raw byte stream is the
complete, replayable description of a terminal's state (see Problem).

**Decision:** A `recording` tap on the single byte choke point
(`process-output`) accumulates every host-to-terminal byte. The tap is
pure: it never alters parsing behavior whether on or off.

**Alternatives:**
- Cell-matrix snapshots, as kitty, tmux, alacritty, and vte test.
  Rejected: the matrix cannot represent all the factors worth testing,
  and it tests only the renderer's read of an already-built grid, not
  the VT parser and handler that built it (see Problem).

### LEXTER-DRAFT-screenshot-test-rig-D2 — Start/stop recording

**Status:** Proposed

**Context:** Authoring sets up the terminal first (resize, configure),
then records only the interesting span.

**Decision:** Recording is controlled explicitly rather than capturing
everything from init.

**Alternatives:**
- Capturing everything from init. Rejected: authoring records only the
  interesting span.

### LEXTER-DRAFT-screenshot-test-rig-D3 — Exact-pixel checksums

**Status:** Proposed

**Context:** Lexter's output is a deterministic function of font file,
palette, screen model, and renderer, which makes exact-pixel checksum
comparison sound (see Problem).

**Decision:** The assertion is the exact pixel content of the screen,
captured via the offscreen FBO. Any pixel difference flips the checksum
-- which is the desired behavior for regression detection. Intentional
rendering changes (font swap, shader fix) regenerate the checksums.

**Alternatives:**
- Tolerance comparison (SSIM, per-pixel thresholds, blurring), as
  vector-font terminals use where they compare images at all. Not needed:
  Lexter's rendering has no antialiasing, hinting, or subpixel rounding
  (see Problem).

### LEXTER-DRAFT-screenshot-test-rig-D4 — Config set once, many dumps

**Status:** Proposed

**Context:** The terminal configuration (font, cols, rows, cell
dimensions, pixel scale) is durable session-level data.

**Decision:** The configuration is established once and printed for
reuse. It is *not* stored per fixture. Each dump produces only two
things: the recorded byte stream and the checksum.

**Alternatives:**
- Storing the configuration with each fixture. Rejected: it is
  session-level data, established once.

### LEXTER-DRAFT-screenshot-test-rig-D5 — Separate blobs from references

**Status:** Proposed

**Context:** A fixture has a byte stream, an expected checksum, and a
configuration, and they must be stored somewhere.

**Decision:** The byte stream is written as a binary blob (`.ptyb`); it
is the durable, version-portable artifact. The expected checksum and the
config live as literals in the test source (the
`with-terminal-test-config` macro head and the `test-pixels` forms). When
rendering intentionally changes, re-author and paste the new checksums.

**Alternatives:**
- Storing the checksum and config in a sidecar file. Rejected: they live
  in the test source instead.

### LEXTER-DRAFT-screenshot-test-rig-D6 — Input recording deferred

**Status:** Proposed

**Context:** A terminal carries two streams: PTY *output*
(host->terminal) and keyboard *input* (terminal->host).

**Decision:** Recording captures PTY output; keyboard input is out of
scope for now. The screen state is fully determined by the output
stream, so this is sufficient for rendering tests.

**Alternatives:**
- None recorded.

### LEXTER-DRAFT-screenshot-test-rig-D7 — Single-terminal recording for now

**Status:** Proposed

**Context:** The longer-term vision is window-level recording yielding
one blob per pane, replayed into a headless multipane compositor.

**Decision:** Recording targets one terminal; the single-terminal
primitives here are the building blocks for that.

**Alternatives:**
- None recorded.

### LEXTER-DRAFT-screenshot-test-rig-D8 — No coupled authoring constructor

**Status:** Proposed

**Context:** Authoring needs a terminal whose output is being recorded.

**Decision:** Authoring runs on a standard live terminal with
`terminal-start-recording` called on it. The printed config is purely
for pasting into the test macro.

**Alternatives:**
- A special `make-recording-terminal`. Rejected: it would tightly couple
  authoring to the recording machinery.


## Implementation

### Recording tap (`src/vt-handler.lisp`)

A `recording` slot was added to the `vt-handler` struct: `nil` when off,
otherwise an adjustable `(unsigned-byte 8)` vector with a fill pointer.
`process-output` (`src/vt-handler.lisp:process-output@1f07ee8`) appends each
processed byte range to the buffer *before*
parsing:

```lisp
(let ((rec (vt-handler-recording handler)))
  (when rec
    (loop :for i :from start :below (or end (length data))
          :do (vector-push-extend (aref data i) rec))))
(cl-vt:vt-parse (vt-handler-parser handler) data start end)
```

Control functions: `start-recording`
(`src/vt-handler.lisp:start-recording@1f07ee8`; allocate a fresh buffer),
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

*Note (2026-10-26):* the guards stop at `gui-initialize` and `gui-tick`. The
input handlers were not guarded, so a key, character, or resize event on a
`no-pty` terminal applies `pty-alive-p` or `pty-set-size` to NIL and signals
a type error (LEXTER-DRAFT-data-structures-1e-critique-O17). A hidden replay
window rarely receives such events, but nothing prevents it.

`terminal-reset` (`src/unix-term.lisp:terminal-reset@1f07ee8`) rebuilds a blank
screen, display grid, and VT handler on
an existing terminal, reusing its window/atlas/renderer. This lets one
headless terminal serve many fixtures without rebuilding the (expensive)
GL atlas.

*Note (2026-10-26):* reusing the renderer also reuses its records of what it
last uploaded, and those records are bare generation numbers. A fresh grid's
swatch generation climbs through the same small numbers as the previous
fixture's, so the second fixture's swatch table is never uploaded and it is
drawn with the first fixture's colours; palettes have the same flaw, since
every screen's palette generation starts at 1. A fixture's checksum
therefore depends on which fixtures ran before it, against the determinism
LEXTER-DRAFT-screenshot-test-rig-D3 rests on
(LEXTER-DRAFT-data-structures-1e-critique-O5). `terminal-config-plist`
(`src/unix-term.lisp:terminal-config-plist@1f07ee8`) returns the durable config
plist.
`terminal-start-recording` / `terminal-stop-recording`
(`src/unix-term.lisp:terminal-start-recording@1f07ee8`) delegate to the handler.

### Test rig module (`src/test-rig.lisp`, system `lexter/test`)

**Checksum.** `fnv1a-64` (`src/test-rig.lisp:fnv1a-64@1f07ee8`) computes a 64-bit FNV-1a hash over the flat bytes
of the `(H W 3)` capture (via a displaced array). FNV-1a was chosen over
`sxhash` for cross-implementation stability and over crypto hashes for
speed.

**Blob format.** A minimal frame guards against silent corruption:

```text
bytes 0-3  magic   "PTYB" (#x50 #x54 #x59 #x42)
byte  4    version (1)
bytes 5-8  payload length, big-endian u32
bytes 9..  payload (the raw recorded byte stream)
```

Description: The layout of a blob, by byte offset: bytes 0 to 3 hold the
magic "PTYB" (`#x50 #x54 #x59 #x42`); byte 4 holds the version, 1; bytes
5 to 8 hold the payload's length as a big-endian 32-bit unsigned
integer; and the payload, the raw recorded byte stream, begins at
byte 9.

`read-blob` (`src/test-rig.lisp:read-blob@1f07ee8`) validates magic, version, and length, erroring on any
mismatch. The blob is written through a pluggable handler:
`default-blob-writer` writes `<name>.ptyb`; a custom handler with the same
`(bytes &key name checksum)` signature can route the blob elsewhere.

**Authoring.** `dump-terminal` (`src/test-rig.lisp:dump-terminal@1f07ee8`) stops the recording, captures pixels,
computes the checksum, writes the blob, optionally invokes a `pixel-fn`
(for writing a reference PNG), and prints `<blob>  #x<checksum>` -- a
paste-ready `test-pixels` line. `pixel-fn` receives the capture plus
`:width :height :channels :checksum :name :config` keywords and is
declared with `&allow-other-keys` so future arguments stay compatible.

**Testing.** `with-terminal-test-config`
(`src/test-rig.lisp:with-terminal-test-config@1f07ee8`) owns the GLFW lifecycle, builds
one headless (`:no-pty`, hidden) terminal from the config, and binds
`*test-terminal*` for its dynamic extent. If the config declares
`:cell-width`/`:cell-height` they are verified against the loaded font so a
font swap cannot silently shift the geometry. `test-pixels` (`src/test-rig.lisp:test-pixels@1f07ee8`)
resets the terminal, replays a blob, captures, and asserts the checksum -- silent on
success, erroring on mismatch (with an optional `on-mismatch` pixel handler
sharing `pixel-fn`'s signature, e.g. to dump an `actual-*.png`).

```lisp
(with-terminal-test-config (:font-path "unifont-17.0.04.pcf.gz"
                            :cols 80 :rows 24
                            :cell-width 8 :cell-height 16 :pixel-scale 1)
  (test-pixels "./1044.ptyb" #xAABBCCDDEEFF0011)
  (test-pixels "./1051.ptyb" #x1122334455667788))
```

### Workflow

*Migration note (2026-10-25):* this was a section of its own, after
Implementation; it is placed in Implementation as a subsection.

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

*Note (2026-10-26):* the replay of several fixtures through one terminal,
the path left unexercised, is where the order dependence noted under
Headless replay path lies; the data-structures critique showed it with a
stand-in for the renderer's upload rule.


## Files

*Migration note (2026-10-25):* the Files section was a bulleted list; it
is rewritten as a table, with the same files and descriptions. Commit
`1f07ee8` also changed `src/origin-impulse.lisp` and
`tests/origin-impulse-tests.lisp`, which this table does not list; that
work, the `:lexter-host` handoff, is recorded in Origin's Log
[ORIGIN-0012](../../../lisp/origin/doc/Log.ImpulseIII.md).

Table: Files added or changed in commit `1f07ee8`.

| File | Action | Description |
|------|--------|-------------|
| `src/vt-handler.lisp` | Modified | `recording` slot, `process-output` tap, `start-recording` / `stop-recording` / `recording-active-p` |
| `src/packages-unix.lisp` | Modified | Exports for the recording and replay API |
| `src/unix-term.lisp` | Modified | `no-pty` slot + guards, `terminal-start-recording` / `terminal-stop-recording`, `terminal-reset`, `terminal-config-plist` |
| `src/test-rig.lisp` | **New** | Checksum, blob API, `dump-terminal`, `with-terminal-test-config`, `test-pixels`, `replay-blob` |
| `lexter.asd` | Modified | New `lexter/test` system |


## Outstanding Work

*Migration note (2026-10-25):* this Log had no Outstanding Work section.
Its items are gathered, in the Log's own words, from the work it defers.

- **Input recording.** Keyboard *input* (terminal->host) is out of scope
  for now (LEXTER-DRAFT-screenshot-test-rig-D6).
- **Window-level recording.** The longer-term vision is window-level
  recording yielding one blob per pane, replayed into a headless
  multipane compositor (LEXTER-DRAFT-screenshot-test-rig-D7).
- **Determinism on heterogeneous CI GPUs.** The only residual
  cross-machine risk is float rounding at quad edges in the vertex
  shader; a software rasterizer -- `LIBGL_ALWAYS_SOFTWARE=1` -- would
  restore determinism on heterogeneous CI GPUs if ever needed (see
  Problem).
- **Replays depend on fixture order.** `terminal-reset` should clear the
  renderer's recorded swatch and palette generations, so that the first
  frame after a reset uploads both. The general fix, recording the identity
  of the producer with its generation or drawing generations from one global
  counter, belongs to the swatch work the critique proposes
  (LEXTER-DRAFT-data-structures-1e-critique-O5). A regression test replays
  two fixtures with different colours in both orders.
- **Unguarded handlers on a `no-pty` terminal.** `handle-key-press`,
  `handle-char-input`, and `handle-resize` should do nothing to the PTY when
  there is none (LEXTER-DRAFT-data-structures-1e-critique-O17). The same
  finding's other half, that `pty-close` never closes the descriptor once
  the child has exited, belongs to the PTY code rather than to this rig.
- **A check the rig cannot make.** Both faults above depend on what the
  renderer recorded before the capture, which a checksum cannot see. A check
  that compares the GPU's swatch table with the grid's, as the critique's
  Synthesis suggests, would make such faults visible.
