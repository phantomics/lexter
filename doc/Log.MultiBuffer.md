---
id:            LEXTER-0006
title:         "Alternate Screen Buffer: Development Log"
genre:         Log
scope:         component
project:       Lexter
component:     vt
language:      en
status:        Implemented
authors:
  - Andrew Sengul
approved-by:   Andrew Sengul
reviewed:      2026-10-26
provenance:
  assistant:   opencode
decisions:
  - LEXTER-D28
  - LEXTER-D29
  - LEXTER-D30
  - LEXTER-D31
  - LEXTER-D32
  - LEXTER-D27
  - LEXTER-D33
---

# Alternate Screen Buffer: Development Log

This document chronicles the implementation of the VT alternate screen buffer
in Lexter -- DEC private modes 47, 1047, 1048, and 1049. Before this work,
full-screen programs (vim, less, htop, ...) drew their UI directly onto the
primary screen and left it behind on exit, so the editor's contents persisted
as spurious "history" above the shell prompt. After this work, those programs
draw on a separate alternate buffer that is discarded on exit, restoring the
pre-program screen intact -- the behavior every real terminal exhibits.

**Date:** 2026-06-09

*Migration note (2026-10-25):* the original Log was dated 2026-06-06. The
date is corrected to that of commit `b693eac`, which holds the work
(LEXTER-D60).


## Problem

A user reported that exiting vim in Lexter left the editor's contents on screen
as history above the new command line, whereas every other terminal cleanly
restores the pre-vim view. The cause was that the **alternate screen buffer was
stubbed out**.

`src/vt-handler.lisp` (`src/vt-handler.lisp@8179eb4`) recognized mode 1049
but did nothing structural:

- DECSET 1049 set `in-alt-screen` to T and did `(setf (vt-handler-alt-screen
  handler) screen)` -- storing a reference to the *same* current screen -- with
  a `;; TODO: create new screen buffer` comment. It never gave the program a
  fresh buffer.
- DECRST 1049 just cleared the flag with `;; TODO: restore main screen`.

So vim's `smcup`/`rmcup` sequences (`ESC [ ? 1049 h` / `ESC [ ? 1049 l`) were
received but never swapped any buffer; vim painted onto the primary screen, and
on exit nothing was swapped back. Modes 47, 1047, and 1048 were not handled at
all and fell through to the `unknown-decset/decrst` callback.


## How real terminals do this

xterm, libvte, kitty, and the rest use a **two-buffer pointer swap**: they keep
two distinct screen buffers -- a *normal* (primary) buffer and an *alternate*
buffer -- and switching is a swap of which one is "active." The decisive
property is that **the primary buffer is never touched while the alternate is
active**. Exiting a full-screen program is therefore clean not because anything
is "restored," but because the primary was simply left alone and becomes visible
again on the swap back. The alternate buffer is exactly viewport-sized and
carries no scrollback; it is discarded/abandoned on exit.

The four modes differ only in *when* clearing and cursor-save happen:

Table: What each alternate-screen mode does on set and on reset.

| Mode | On set (DECSET) | On reset (DECRST) |
|------|-----------------|-------------------|
| 47   | switch to alt (no clear)            | switch to primary (no clear) |
| 1047 | switch to alt                       | clear alt, then switch to primary |
| 1048 | save cursor (no switch)             | restore cursor (no switch) |
| 1049 | save cursor, switch to a cleared alt | switch to primary, restore cursor |

This is the approach taken here (LEXTER-D27).


## The architectural crux

The active screen object is referenced from two places that must agree:

- the **VT handler** writes into `(vt-handler-screen handler)`, and
- the **renderer** reads the terminal/pane's screen during flush.

They point at the same object at startup. For a pointer swap to be visible, the
renderer must **follow the handler's active screen** rather than a cached slot.
Because flush already runs every frame, the cleanest decoupled design is to make
the handler the single source of truth and have the terminal/pane poll
`(vt-handler-screen handler)` at render time -- no callbacks, no back-references.


## Design Decisions

*Migration note (2026-10-25):* the choice of the two-buffer approach was
stated in the background section "How real terminals do this", with the
alternative it rejected. It is recorded here as
LEXTER-D27 and placed first, because the other five
decisions refine it; LEXTER-D28 through
LEXTER-D32 keep the Log's original numbering.

### LEXTER-D27 — Two-buffer pointer swap, not snapshot-and-restore

**Status:** Implemented

**Context:** Full-screen programs need a screen of their own, and the
primary screen must look as it did when they exit. Real terminals keep
two distinct buffers and swap which one is active (see How real
terminals do this).

**Decision:** The two-buffer pointer swap real terminals use. This is
the approach taken here; it makes the primary inviolate by
construction.

**Alternatives:**
- Snapshotting the primary screen's contents on entry and restoring them
  on exit, keeping a single buffer. Rejected: it is not what terminals do
  and is fragile, because it requires perfectly deep-copying every field
  of the screen (cells, layered cells, attributes, cursor, scroll region,
  palette + generation, ...), and any field missed leaks across the
  boundary.

### LEXTER-D28 — Handler owns the buffers; renderer follows it

**Status:** Implemented

**Context:** The active screen is referenced from both the VT handler and
the renderer, and for a pointer swap to be visible the renderer must
follow the handler's active screen (see The architectural crux).

**Decision:** The VT handler holds all buffer state and exposes the
active one via `vt-handler-screen`. The terminal and pane read that
accessor on every flush (and for palette upload, dirty checks, and scroll
state), so a swap is picked up automatically. The terminal/pane's own
`screen` slot is retained only as the initial primary handle.

**Alternatives:**
- Callbacks or back-references from the handler to the terminal and
  pane. Rejected in favor of polling the handler at render time, which
  needs neither (see The architectural crux).

### LEXTER-D29 — One persistent alternate buffer, created lazily

**Status:** Implemented

**Context:** Mode 47 switches to the alternate screen without clearing
it, so the alternate buffer's contents must persist between uses.

**Decision:** The alternate buffer is allocated on first use and
**reused** across enter/exit cycles, not recreated each time. Clearing
is applied explicitly where the mode demands it (1049 on entry, 1047 on
exit).

**Alternatives:**
- Recreating the alternate buffer on each entry. Rejected: mode 47's
  "switch without clearing" semantics need its contents to persist.

### LEXTER-D30 — Dedicated cursor-save slots for 1048/1049

**Status:** Implemented

**Context:** Modes 1048 and 1049 save and restore the cursor, as DECSC
(`ESC 7` / `ESC 8`) does.

**Decision:** 1048/1049 cursor save/restore uses its own handler slots
(`alt-saved-col/row/fg/bg/attrs`), kept **separate** from the DECSC save
slots.

**Alternatives:**
- Sharing the DECSC save slots. Rejected: separate slots mean the two
  save/restore mechanisms can never interfere.

### LEXTER-D31 — Resize resizes *both* buffers

**Status:** Implemented

**Context:** A window resize while a program is on the alternate screen
must also resize the *inactive* primary buffer, so that returning from
the alternate screen after a resize shows a correctly-sized primary.

**Decision:** `vt-handler-resize-all` resizes the primary and (if
present) the alternate together.

**Alternatives:**
- None recorded.

### LEXTER-D32 — Alternate buffer carries no scrollback

**Status:** Implemented

**Context:** Real terminals give the alternate screen no scrollback.

**Decision:** The alternate screen is created with scrollback disabled,
matching real terminals.

**Alternatives:**
- None recorded.

A natural consequence: while a program is on the alternate screen,
`scroll-state` reports no scrollback, so no scroll bar is shown in
vim/less/etc.

## Implementation

### `src/vt-handler.lisp`

- **Struct slots:** `screen` is now documented as the *active* buffer;
  `primary-screen` holds the normal buffer while the alternate is active;
  `alt-screen` is the persistent alternate buffer; plus dedicated
  `alt-saved-col/row/fg/bg/attrs` for 1048/1049. `make-vt-handler`
  (`src/vt-handler.lisp:make-vt-handler@b693eac`) initializes
  `primary-screen` to the supplied screen.
- **Helpers:** `%save-alt-cursor` / `%restore-alt-cursor` (1048/1049 cursor
  state); `%ensure-alt-screen` (`src/vt-handler.lisp:%ensure-alt-screen@b693eac`; lazy creation matching primary dims and blank
  glyph, scrollback disabled); `%clear-screen-buffer` (`erase-in-display 2` +
  home); `%enter-alt-screen` / `%exit-alt-screen`
  (`src/vt-handler.lisp:%enter-alt-screen@b693eac`,
  `src/vt-handler.lisp:%exit-alt-screen@b693eac`; guarded swaps with optional
  clear); `vt-handler-resize-all`
  (`src/vt-handler.lisp:vt-handler-resize-all@b693eac`; resize every owned buffer).
- **DECSET/DECRST:** rewrote modes 47 / 1047 / 1048 / 1049 per the table above;
  unknown modes still reach the callback.

### `src/unix-term.lisp`

- `gui-tick` (`src/unix-term.lisp:gui-tick@b693eac`) renders the active screen via
  `(vt-handler-screen (unix-terminal-vt-handler term))` for the dirty check,
  `flush-to-display`, blank glyph, and palette upload.
- `handle-resize` (`src/unix-term.lisp:handle-resize@b693eac`) calls `vt-handler-resize-all` (both buffers) and takes the
  blank glyph from the active screen.

### `src/panes/vt-pane.lisp` (covers `uterm-pane`, which inherits these)

- Added `vt-pane-active-screen`
  (`src/panes/vt-pane.lisp:vt-pane-active-screen@b693eac`; the handler's active screen, falling back to
  the slot before the handler exists).
- `pane-flush`, `pane-palette`, `scroll-state`, and `pane-dirty-p` use it.
- `pane-resize` resizes both buffers via `vt-handler-resize-all`.

### `src/packages-unix.lisp`

- Exported `vt-handler-resize-all` and `vt-handler-in-alt-screen`.


## Verification

The library compiles and loads clean (`lexter/unix`, `lexter/panes`). A
handler-level self-check (no GLFW/atlas needed, writing directly into the
buffers to isolate the swap logic) confirms:

- entering 1049 swaps to a **distinct** buffer that is **cleared** on entry;
- writes hit the **active** buffer only -- the primary is untouched while on the
  alternate screen;
- exiting 1049 makes the primary active again with its **content intact**;
- mode 47 re-entry **preserves** the alternate buffer (no clear);
- mode 1048 **saves and restores** the cursor position;
- `vt-handler-resize-all` resizes both the primary and alternate buffers.

(An earlier test appeared to fail on "alt received B" -- that was a test
artifact: with a `nil` atlas, `%print-codepoint` cannot map codepoints to
glyphs, so no characters were written. Writing directly into the buffers
verified routing without needing a font/GL context.) End-to-end confirmation
in a live vim/less session is the user's to make, since it requires a GLFW
window.


## Files

Table: Files changed in commit `b693eac`.

| File | Action | Description |
|------|--------|-------------|
| `src/vt-handler.lisp` | Modified | Alt-buffer + cursor-save slots; helpers; rewrote 47/1047/1048/1049; `vt-handler-resize-all` |
| `src/unix-term.lisp` | Modified | Render/palette via active screen; resize both buffers |
| `src/panes/vt-pane.lisp` | Modified | `vt-pane-active-screen`; flush/palette/scroll/dirty via active screen; resize both buffers |
| `src/packages-unix.lisp` | Modified | Exported `vt-handler-resize-all`, `vt-handler-in-alt-screen` |


## Outstanding Work

- **Tab stops are not rebuilt on resize (out of scope, deferred).** The
  handler's tab-stop bit vector is sized to the column count and populated once
  in `make-vt-handler` (default stops every 8 columns). A resize currently
  resizes the screen buffers but does **not** rebuild the tab-stop vector, so
  after a width change the tab stops can be stale or mis-sized relative to the
  new width. This predates the alternate-screen work and was intentionally left
  for a later iteration: rebuild (or grow/shrink and re-seed) the tab-stop
  vector inside the resize path, preserving any host-set custom stops where
  feasible.
- **Per-mode cursor-save fidelity.** 1048/1049 save the cursor and SGR state;
  xterm also tracks a few additional cursor attributes (e.g. origin mode,
  selected character set). Not needed for the common vim/less case, but worth
  revisiting for stricter compatibility.
- **Alternate-screen scrollback gestures.** With scrollback disabled on the
  alternate buffer (correct), any future mouse/scroll-wheel handling should
  route wheel events to the application (as arrow keys, per xterm
  `alternateScroll`) rather than attempting local scrollback while on the
  alternate screen.


## Update 2026-06-09 — Stale Grid After Buffer Swap

*Migration note (2026-10-25):* this section was "Addendum: Stale Grid
After Buffer Swap", dated 2026-06-06. It becomes a dated Update
(LEXTER-D57), dated by commit `4864f01`, which
holds the work (LEXTER-D60). Its "Design
Decision" becomes LEXTER-D33.

### Context

After the alternate-screen buffers landed, a user reported a residual
rendering bug: when the shell prompt sat partway down the window with empty
space below it, exiting a full-screen app (vim/less) left the restored prompt
in the middle of the screen surrounded by the *application's* leftover
characters -- "dead characters" above and below the prompt. Curiously, when
the window was full of history and the prompt was on the bottom line, exit was
clean. The buffer swap itself was correct (the primary buffer's contents were
intact); the defect was purely in what reached the screen.

### Problem

`flush-to-display` (`src/model.lisp:flush-to-display@b693eac`) is an
**incremental** flush: it copies only the screen rows
whose `row-dirty` bit is set, force-marks just the cursor row each frame, and
clears all dirty bits afterward. The **display grid is a single buffer shared**
by the primary and alternate screens.

On a buffer swap, the newly-active screen's *clean* rows are therefore never
re-copied into the shared grid, which still holds the previous buffer's pixels
for those rows. On exit from vim only the cursor row repainted (the restored
prompt), while every other grid row kept vim's leftover content.

The full-screen / prompt-at-bottom case worked only by accident: returning to a
prompt on the last line makes the shell **scroll** the primary buffer, and
`scroll-up` marks every row dirty -- incidentally forcing a full re-flush. With
the prompt mid-screen there was no scroll, so only the rows the shell rewrote
were repainted and the rest of the grid kept the application's characters. The
bug affected both standalone `unix-term` and the pane compositor, since both
render the active screen through the same incremental flush.

### LEXTER-D33 — Force a full repaint at the swap, mode-agnostically

**Status:** Implemented

**Context:** The display grid is shared by both buffers and flushed
incrementally, so after a swap the newly-active screen's clean rows are
never re-copied into it (see Problem).

**Decision:** **Force a full repaint at the swap, mode-agnostically.**
The swap is the single point where the shared grid stops matching the
active buffer, so it is the correct place to invalidate. After each swap the now-active screen is marked
entirely dirty, so the next `flush-to-display` re-copies all of its rows into
the grid (and `any-row-dirty-p` also becomes true, triggering `needs-render`).

**Alternatives:**
- Giving each buffer its own display grid. Rejected: heavier; the grid
  is a GPU-facing resource.
- Having the renderer detect a screen-identity change between frames.
  Rejected: it spreads the concern into the render loop.

Marking dirty at the swap keeps the fix in one place and covers both
frontends, since both route through the VT handler.

### Implementation

- **`src/model.lisp`** -- added `mark-screen-dirty`
  (`src/model.lisp:mark-screen-dirty@4864f01`), which fills the screen's
  `row-dirty` vector with 1s, and exported it from `lexter/model`.
- **`src/vt-handler.lisp`** (`src/vt-handler.lisp@4864f01`) --
  `%enter-alt-screen` and `%exit-alt-screen` now
  call `mark-screen-dirty` on the now-active screen after the swap. This also
  fixes **mode 47 re-entry** (no-clear, reused alt) and **all exits** uniformly;
  1049 entry already dirtied via its clear, and 1048 (no swap) correctly needs
  no mark. No renderer, terminal, or pane code changed.

### Verification

The library compiles and loads clean. The headless self-check was extended to
clear a screen's dirty bits (simulating an idle, already-flushed buffer) and
then confirm that a swap re-dirties the whole active buffer: entering 1049
fully dirties the alternate, exiting fully dirties the restored primary, and
mode 47 re-entry fully dirties the (unclear) alternate. Live confirmation in a
partially-filled vim/less session -- clean prompt with no surrounding dead
characters, including the previously-working bottom-line case -- is the user's
to make, as it requires a GLFW window.

### Files

Table: Files changed in commit `4864f01`.

| File | Action | Description |
|------|--------|-------------|
| `src/model.lisp` | Modified | Added `mark-screen-dirty` |
| `src/packages.lisp` | Modified | Exported `mark-screen-dirty` |
| `src/vt-handler.lisp` | Modified | Mark active screen fully dirty after each buffer swap |
