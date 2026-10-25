# Encoding Ranges: Development Log

This document chronicles two related problems uncovered while bringing up GNU
Unifont (`unifont-17.0.04.pcf.gz`, ~57k glyphs covering the BMP) as a Lexter
font. Both are about the *ranges* of integers that flow through the rendering
and parsing pipelines:

1. **Glyph index width** -- the atlas glyph index overflowed 16 bits, breaking
   ~38% of Unifont's glyphs. *Fixed* (widened to 32-bit).
2. **UTF-8 vs. 8-bit C1 control bytes** -- multi-byte UTF-8 characters whose
   continuation bytes fall in 0x80-0x9F are eaten by the VT parser's C1 control
   handling, so they never render. *Diagnosed; fix approach under discussion.*

**Date:** 2026-06-06


## Part 1 -- 32-bit glyph index (fixed)

### Problem

Loading Unifont and printing high-codepoint characters produced wrong glyphs
for a large, scattered set of characters. The glyph index that travels from the
screen model to the GPU was stored as `(unsigned-byte 16)` end to end:

- `model.lisp` `screen-glyphs`, `grid.lisp` display-grid glyphs and
  `cell-layer` glyph-idx,
- `build-render-data` packed the glyph as two bytes,
- the instance vertex attribute `i_glyph` was `:unsigned-short`.

The glyph index is an **atlas column-slot position** (`row*cols + col`, with
double-wide glyphs occupying two slots), so it scales with the number of atlas
cells, not the glyph count. For Unifont that is ~107k cells -- far past 65535.

A headless replay of the atlas packing measured the damage: **21,412 of 57,086
glyphs (37.5%) land at atlas positions > 65535**. Their 16-bit index wraps
`mod 65536` and renders the *wrong* (aliased) glyph. The probe against a live
atlas confirmed `max atlas-pos = 107095`.

### Fix

Widen the glyph index to 32-bit along the whole model -> GPU path (the GLSL
`i_glyph` was already `uint`):

- **`model.lisp`** -- `screen-glyphs` and `model-layer` glyph-idx ->
  `(unsigned-byte 32)`.
- **`grid.lisp`** -- `+simple-stride+` 8 -> 12 and `+layered-stride+` 12 -> 16
  (glyph grows 2 -> 4 bytes; 2 trailing pad bytes keep the next instance's
  32-bit glyph 4-byte aligned). `display-grid` glyphs and `cell-layer` glyph-idx
  -> uint32. Added little-endian `%u32-b0..b3` packers. `build-render-data`
  rewrites the simple and layered instance offsets (glyph as 4 bytes at 4-7,
  remaining fields shifted).
- **`renderer.lisp`** -- the simple and layered VAO attribute pointers:
  `i_glyph` `:unsigned-short` -> `:unsigned-int` at offset 4, with downstream
  attribute offsets and strides updated; same in `render-frame`'s per-layer
  re-pointer. Also reconciled a duplicate `+layered-stride+` constant
  (renderer.lisp shared the same symbol via `:use`).
- **`shaders.lisp`** -- unchanged (`i_glyph` already `uint`).

Swatch indices stay 16-bit (their range is <= 2048 plus a wide-flag bit).

### Verification

Clean compile/load of `lexter`, `lexter/unix`, `lexter/panes`. A round trip
confirms a glyph index of 100,000 survives `write-char-at` -> `cell-glyph`
(model) and is packed/read back correctly as a uint32 in the instance buffer
(`sbytes = 96` = 8 cells x 12-byte stride). On-screen confirmation of the
formerly-aliased high glyphs is the user's.


## Part 2 -- 3-byte UTF-8 vs. 8-bit C1 controls (diagnosed)

### Symptom

After the width fix, one class of characters still failed: APL symbols and many
other code points rendered **blank** (not a wrong glyph). The canonical example
was the APL functional symbol circle stile, U+233D (`⌽`).

### Why "blank" ruled out the obvious causes

A runtime probe (using the new hidden-window capture path) showed U+233D is in
the atlas at position **13566** -- a renderable position that fits even the old
16-bit index. Its glyph bitmap has ink (the circle-stile is clearly drawn). So:

- it is not the Part 1 overflow (13566 < 65536, and overflow aliases to a
  *wrong visible* glyph, not blank), and
- it is not an atlas miss (`atlas-glyph-index` returns 13566, not NIL).

Everything downstream of the codepoint was fine. The failure had to be in the
**input/decode path** -- the codepoint U+233D was not reaching the renderer.

### Root cause

`⌽` is UTF-8 `E2 8C BD`. The middle byte **0x8C lies in the C1 control range
(0x80-0x9F)**. Lexter parses the byte stream with **cl-vt**, a faithful DEC
VT500 state machine that treats 0x80-0x9F as 8-bit C1 controls
(`cl-vt/tables.lisp`): 0x80-0x8F execute, 0x9B enters CSI, 0x9D enters OSC, and
so on. Lexter's UTF-8 assembly happens *after* the parser, in `handle-print`
(the parser's `:print` callback). So the continuation byte 0x8C is consumed by
the parser as a C1 control and never reaches the UTF-8 decoder -- the sequence
is left incomplete and nothing is printed.

A headless test fed byte sequences through `process-output` and inspected the
handler's UTF-8 state:

| Input | bytes | result |
|-------|-------|--------|
| `A`             | `41`       | ok |
| `é` U+00E9      | `C3 A9`    | ok (continuation `A9` is in the GR range 0xA0-0xBF) |
| `⌽` U+233D      | `E2 8C BD` | **broken** -- `8C` eaten as C1; needed=1, never printed |
| CJK U+4E00      | `E4 B8 80` | **broken** -- `80` eaten as C1 |
| U+2820          | `E2 A0 A0` | ok (both continuations in the GR range) |

So the rule is: **any multi-byte UTF-8 character with a continuation byte in
0x80-0x9F is broken** -- which is the vast majority of 3- and 4-byte characters,
including all of CJK and most symbol/APL blocks. (CJK was never actually
rendering; the dual-width work only verified the atlas, not on-screen output.)

The danger is broader than dropped bytes: a continuation byte of 0x9B (CSI) or
0x9D (OSC) makes cl-vt *start consuming following bytes as a control sequence*,
corrupting the stream.

### The underlying conflict

UTF-8 and 8-bit C1 controls are mutually exclusive: the bytes 0x80-0x9F are
either C1 controls *or* UTF-8 continuation bytes, never both at once. Real
terminals resolve this by **decoding UTF-8 before (or within) the control state
machine, so the C1 test applies to a decoded code point, not a raw byte** -- and
by disabling 8-bit C1 recognition entirely in UTF-8 mode (apps then use the
7-bit `ESC`-prefixed forms). The byte 0x8C inside a multi-byte sequence must
never be interpreted as a control; only an actual code point U+008C should be.

cl-vt is a pure byte-oriented parser with no UTF-8 awareness and no mode to
disable C1, so the fix has to change where/how UTF-8 is decoded relative to it.

### Candidate fixes (decision pending)

1. **UTF-8 front-end in Lexter.** Rewrite `process-output` to route ground-state
   high bytes (and in-progress UTF-8 continuations) to `handle-print` directly,
   feeding only the remaining bytes to `cl-vt:vt-parse-byte`. Self-contained, no
   cl-vt change, reuses the existing `handle-print` decoder. Slightly awkward:
   `handle-print` ends up called from two places, and the parser only ever sees
   sub-0x80 bytes plus high bytes inside string states.
2. **Make cl-vt UTF-8-aware (preferred direction).** Give cl-vt a UTF-8 mode in
   which the ground state treats 0x80-0xFF as printable rather than C1 controls
   (so it dispatches `:print` for continuation bytes and Lexter's existing
   `handle-print` assembles them). cl-vt is our own library and its primary
   consumer (Lexter) is UTF-8, so fixing it at the source removes the awkward
   "Lexter -> cl-vt -> Lexter" split. This matches how UTF-8-aware byte parsers
   (e.g. alacritty's `vte` crate) integrate UTF-8 into the ground state.

Both share a known limitation: UTF-8 *inside* OSC/DCS strings (e.g. a non-ASCII
window title) is still handled byte-wise (mojibake), as it is today.

The architectural choice between these is the subject of ongoing discussion (see
the project notes following this log).


## Files

| File | Action | Description |
|------|--------|-------------|
| `src/model.lisp` | Modified | `screen-glyphs` + `model-layer` glyph-idx -> uint32 |
| `src/grid.lisp` | Modified | strides 12/16; display-grid glyphs + cell-layer glyph-idx uint32; `%u32` packers; `build-render-data` offsets |
| `src/renderer.lisp` | Modified | simple/layered VAO + per-layer pointers: `i_glyph` `:unsigned-int`; stride/offset updates; dedup `+layered-stride+` |
| `src/vt-handler.lisp` | (pending) | UTF-8/C1 fix -- approach under discussion |
| cl-vt | (pending) | possible UTF-8 mode -- approach under discussion |


## Outstanding work

- **Implement the UTF-8/C1 fix** once the approach is chosen (front-end vs.
  cl-vt UTF-8 mode).
- **UTF-8 in OSC/DCS strings.** Decode non-ASCII inside string-collecting states
  so window titles etc. survive; out of scope for the initial fix.
- **Codepoints U+0080-U+009F.** Whichever fix lands, an actual code point in the
  C1 range (encoded as `C2 80` .. `C2 9F`) should remain distinguishable from a
  raw continuation byte; the decode-first architecture makes this automatic.
