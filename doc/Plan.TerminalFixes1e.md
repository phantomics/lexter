---
id:            LEXTER-0015
title:         "Terminal Fixes, First Edition: Development Plan"
genre:         Plan
scope:         project
project:       Lexter
language:      en
status:        Accepted
authors:
  - Andrew Sengul
approved-by:   Andrew Sengul
reviewed:      2026-11-05
provenance:
  assistant:   opencode
  session:     "Terminal fixes plan (2026-11-02)"
relates-to:
  - LEXTER-0014
  - LEXTER-DRAFT-data-structures-1e
  - LEXTER-0017
  - LEXTER-DRAFT-pane-profiles
  - LEXTER-0013
  - LEXTER-0005
  - LEXTER-0006
  - LEXTER-0010
decisions:
  - LEXTER-D66
  - LEXTER-D67
  - LEXTER-D68
  - LEXTER-D69
  - LEXTER-D70
  - LEXTER-D71
  - LEXTER-D72
  - LEXTER-D73
  - LEXTER-D74
  - LEXTER-D75
  - LEXTER-D76
  - LEXTER-D77
  - LEXTER-D78
  - LEXTER-D79
  - LEXTER-D80
open-questions:
  - LEXTER-O41
  - LEXTER-O42
  - LEXTER-O43
  - LEXTER-O44
cites:
  - title:    "Session transcript ses_febe-LexterCritique"
    locator:  "session-ses_febe-LexterCritique.md, the closing review"
    external: true
  - title:    "TN3270 Enhancements"
    locator:  "RFC 2355, section 4 (Command Meanings) and section 7.1 (DEVICE-TYPE Negotiation)"
    external: true
  - title:    "Telnet Protocol Specification"
    locator:  "RFC 854, the rules for preventing option negotiation loops"
    external: true
  - title:    "The Q Method of Implementing TELNET Option Negotiation"
    locator:  "RFC 1143"
    external: true
  - title:    "XTerm Control Sequences"
    locator:  "Moy, Gildea, Dickey; SGR colour parameters, the scrolling region, and auto-wrap"
    external: true
---

# Terminal Fixes, First Edition: Development Plan

This plan repairs the faults of Lexter's first edition that lie outside the
cell model: in the VT handler's state, the buffers and views, the TN3270 and
telnet protocols, the PTY paths, and the package boundaries. It also takes up
the structural findings of the review cited above: the two parallel terminal
stacks, global state in place of instance state, mode state kept in two
places, and reliance on babel's internals. It is the companion of
[LEXTER-0017](Plan.CellModelRevision.md), which repairs
and then replaces the cells, and it answers the findings of
[LEXTER-0014](Eval.Critique.DataStructures1e.md)
that the cell plan leaves to it. It is the first of a series of plans for
fixes; later ones take the suffixes 2e, 3e, and so on.

## Problem

The critique found faults in the first edition that do not depend on how
cells are stored, and the review found structural weaknesses that every fix
has to work around.

- **Host input escapes its types.** Ordinary SGR sequences and a tab after a
  resize signal errors in the middle of a parse
  (LEXTER-O21), and autowrap ignores the
  scrolling region (LEXTER-O33).
- **Buffers and views disagree.** The Origin integration reads a cached
  screen instead of the active one, and a lazily created alternate screen
  loses OSC colour changes (LEXTER-O29). A
  workspace switch clears the grid without scheduling a repaint
  (LEXTER-O32).
- **The protocols diverge from their standards.** TN3270E negotiation cannot
  complete with a server that follows RFC 2355
  (LEXTER-O25); the TN3270 screen assumes
  80×24 and its record framing ignores escaping
  (LEXTER-O31); the telnet client mangles
  code 255 and keeps no option state
  (LEXTER-O34).
- **The terminal paths are fragile.** The headless and teardown paths
  dereference a missing PTY (LEXTER-O35),
  backends are told the pane's size rather than its content's
  (LEXTER-O38), and the package exports
  disagree with the code (LEXTER-O37).

The review adds four structural findings. `unix-term` and the compositor
duplicate each other, so "every fix lands twice or lands once". Instance
values are copied into globals (`*prefix-key*`, `*cursor-blink-on*`, the
window title), so two windows overwrite each other. The screen has mode
stubs while the handler holds the real mode state. And keystrokes are
encoded through babel's internal functions.

## Goals

- Repair every finding in scope, each with a headless regression test.
- Leave one terminal stack, so that this plan's fixes and the cell plan's
  land once.
- Leave no instance state in a global that instances write.
- Make the TN3270 and telnet clients follow the standards they implement.
- Land the workspace-switch repaint before the cell plan's dense model, which
  depends on it.

## Settled Decisions

### LEXTER-D66 — The plan covers the first edition's fixes outside the cell model

**Status:** Accepted

**Context:** The development sequence of
[LEXTER-0013](Survey.LayerMechanics.md) begins with fixes
needed under any design. The cell plan's
LEXTER-D96 keeps to the cell model and leaves the
other fixes to a separate plan. One finding in
that set, the scrollback viewport and the inverted scroll-bar thumb
(LEXTER-O30), is already planned in
[LEXTER-DRAFT-pane-profiles](Plan.PaneProfiles.md), whose
LEXTER-DRAFT-pane-profiles-D5 draws the history and whose Scrollback Viewing
section inverts the thumb.

**Decision:** This plan covers the critique's LEXTER-O21, LEXTER-O25,
LEXTER-O29, LEXTER-O31, LEXTER-O32, LEXTER-O33, LEXTER-O34, LEXTER-O35,
LEXTER-O37, and LEXTER-O38, and the review's findings on the parallel stacks,
global state, mode state, and babel's internals. LEXTER-O30 stays with the
pane-profiles plan. The review's finding that the 3270 pane bypasses the model
belongs to the cell plan, whose dense model must either rewrite that pane to
the record or keep its own path.

**Alternatives:**
- Fold the thumb's inversion into this plan. Rejected: the pane-profiles
  plan inverts it together with the history it reports, and splitting them
  would leave a thumb that moves over a picture that does not.

### LEXTER-D67 — The standalone terminal becomes a compositor with one pane, and this comes first

**Status:** Accepted

**Context:** `unix-term` and the compositor each have their own tick, key
encoding (`*key-sequences*` and its encoder), cursor blink, resize handling,
palette upload, and `setup-default-swatches`
(`src/unix-term.lisp:gui-tick@2d4d743`,
`src/panes/compositor.lisp:gui-tick@2d4d743`). The review found that every
fix lands twice or lands once, and the cell plan's Phase 1 changes the flush,
the cursor, and swatch setup in both. The test rig
([LEXTER-0010](Log.ScreenshotTestRig.md)) and the Origin integration use the
standalone terminal's API: `make-terminal`, `terminal-reset`,
`terminal-capture`, recording, and the headless `no-pty` mode.

**Decision:** The standalone terminal becomes a compositor holding one
workspace with one `uterm-pane`, behind the existing `unix-terminal` API,
which becomes a thin layer over it and keeps the `gui-*` protocol of
[LEXTER-0005](Log.GUILifecycle.md). The layer keeps the functions and the
accessors that callers use, as The Consolidated Stack lists. The duplicated
code in `unix-term` is removed. The consolidation is the first fix of this
plan, and the cell plan's
Phase 1 waits for it, so that its repairs land once. The headless mode keeps
working: a pane with no PTY is fed by `process-output`, and how the
compositor keeps such a terminal alive is
LEXTER-O41.

**Alternatives:**
- Extract shared helpers and keep both loops. Rejected: two loops remain,
  and each new behaviour has to be called from both.
- Remove `unix-term` and port its callers to the compositor. Rejected: the
  test rig and the Origin integration would change for no gain, and a thin
  layer keeps their API.
- Leave consolidation out, or let the cell plan proceed without it. Rejected
  by the steward: the cell plan would repair both copies.

As a consequence, the standalone terminal gains what panes have, including
the pane-profiles plan's wheel scrolling and profiles, which that plan had
excluded for the single-terminal path.

### LEXTER-D68 — Host input is checked at the boundary, never trusted against a slot's type

**Status:** Accepted

**Context:** `rgb-to-256` returns 256 for the grey (248, 248, 248), SGR
`38;5;n` stores any n, and `tab-stops` keeps its original length when the
screen is resized; each signals an error inside `process-output`
(LEXTER-O21,
`src/vt-handler.lisp:rgb-to-256@2d4d743`,
`src/vt-handler.lisp:vt-handler-resize-all@2d4d743`).

**Decision:** Every value the host supplies is clamped or ignored before it
reaches a typed slot or indexes an array. `rgb-to-256` maps into 0–255, an
indexed colour above 255 is ignored and leaves the current colour unchanged,
and tab stops are rebuilt for the new width whenever the screen is resized.
The rule extends to every parameter the handler stores. Where xterm's
behaviour for a value out of range is documented, the fix matches it; that
is checked against xterm's control-sequence documentation before the fix is
built.

**Alternatives:**
- Wrap `process-output` in a handler that discards the rest of a failing
  buffer. Rejected as the fix, though worth keeping as a last defence: it
  loses output, and the state may already be corrupt.

### LEXTER-D69 — Autowrap and line feed share one path, which owns the scrolling region

**Status:** Accepted

**Context:** Line feed scrolls within the scrolling region, but autowrap
tests the screen's last row, so wrapping inside a region that ends above it
moves the cursor out (LEXTER-O33,
`src/vt-handler.lisp:%print-codepoint@2d4d743`).

**Decision:** Autowrap moves to the next line through the same function as
line feed, which alone applies the region's rule.

**Alternatives:**
- Patch the test in `%print-codepoint`. Rejected: two places would again
  have to agree on the region.

### LEXTER-D70 — Every reader of a terminal's screen goes through the handler

**Status:** Accepted

**Context:** LEXTER-D28 has the handler own both buffers and requires
readers to poll `vt-handler-screen`, but the Origin integration reads and
writes `unix-terminal-screen`, which keeps the initial buffer; and the
alternate screen, created on first use, starts from the default palette, so
OSC 4 changes made before it existed are lost inside it
(LEXTER-O29,
`src/origin-impulse.lisp:%window-fields@2d4d743`,
`src/vt-handler.lisp:%ensure-alt-screen@2d4d743`).

**Decision:** The cached screen slot is removed, or replaced by a function
of the handler, and every reader, the Origin integration included, asks the
handler for the active screen. The alternate screen is created with a copy of
the primary's palette. Whether the two screens also share a swatch table is
the cell plan's LEXTER-O58.

**Alternatives:**
- Keep the slot and update it on every swap. Rejected: it is a second copy
  of the handler's state, which the critique shows drifting.

### LEXTER-D71 — A workspace switch marks every screen and its decorations dirty

**Status:** Accepted

**Context:** `switch-workspace` clears the grid but marks nothing dirty, so
the new workspace stays blank until its panes produce output, and its
decorations never return (LEXTER-O32,
`src/panes/compositor.lisp:switch-workspace@2d4d743`). The cell plan's dense
model uploads only dirty rows, which would make the fault worse.

**Decision:** Treat a switch as LEXTER-D33 treats the alternate-screen swap:
mark every screen of the new workspace and its decorations dirty at the
switch, so that the next frame repaints it whole. This fix is a precondition
of the cell plan's Phase 3.

**Alternatives:**
- Have the renderer detect a change of workspace. Rejected for the reason
  LEXTER-D33 gives: it spreads the concern into the render loop.

### LEXTER-D72 — The TN3270 client follows RFC 2355, and its screen is sized from its geometry

**Status:** Accepted

**Context:** The client tests for `DEVICE-TYPE SEND` where RFC 2355 has the
server send `SEND DEVICE-TYPE`, and answers with `IS`, which only the server
may send; the session stalls with a conforming server
(LEXTER-O25,
`src/tn3270/client.lisp:process-subnegotiation@2d4d743`). The screen's
arrays are always 1920 elements, and record framing scans for the byte pair
`FF EF` without regard to escaping
(LEXTER-O31,
`src/tn3270/screen.lisp:tn3270-screen@2d4d743`,
`src/tn3270/client.lisp:extract-3270-record@2d4d743`).

**Decision:** Negotiation follows RFC 2355: the client recognises
`SEND DEVICE-TYPE`, answers `DEVICE-TYPE REQUEST` with its device type,
accepts `DEVICE-TYPE IS … CONNECT …`, and then itself sends
`FUNCTIONS REQUEST`, as RFC 2355 section 7.2 requires of the client; today's
client only answers a server's request with `FUNCTIONS IS`
(`src/tn3270/client.lisp:send-tn3270e-functions@2d4d743`).
The screen is made by a constructor that sizes every array from its columns
and rows. Records are framed by a small IAC state machine that undoubles
`FF FF` and ends a record only at an unescaped IAC EOR. What a record larger
than the receive buffer does is LEXTER-O43.

**Alternatives:**
- Keep the order the client expects, if some servers use it. Rejected: the
  RFC is unambiguous, and a test against a recorded negotiation guards the
  fix.

### LEXTER-D73 — The telnet client encodes before escaping, and keeps option state by the Q method

**Status:** Accepted

**Context:** `telnet-write-string` masks each character to seven bits before
testing it for 255, so code 255 goes out as `7F FF`, and the client answers
every WILL and DO without recording which options are on, which RFC 854's
rules against negotiation loops forbid
(LEXTER-O34,
`src/telnet/client.lisp:telnet-write-string@2d4d743`,
`src/telnet/client.lisp:%handle-will@2d4d743`).

**Decision:** Strings are encoded first, in the pane's encoding (UTF-8 or
CP437, as the pane already decodes output), and IAC is doubled on the encoded
bytes. The encoding is known to the pane, not to the client in the
`lexter/telnet` package, so encoding moves into the telnet pane and the
client's write functions take bytes. Option negotiation keeps a state for
each option on each side, by the Q method of RFC 1143, and answers only a
request that changes it.

**Alternatives:**
- Keep the seven-bit mask and only fix the test for 255. Rejected: the mask
  already mangles every character above 127, and the pane knows its
  encoding.

### LEXTER-D74 — The PTY separates the child's life from the descriptor's

**Status:** Accepted

**Context:** `pty-close` does nothing once `alive-p` is false, which
`pty-read` sets at end of file, so the descriptor is never closed and the
child never reaped; and the standalone terminal's input handlers apply
`pty-alive-p` and `pty-set-size` to the missing PTY of a headless terminal
(LEXTER-O35,
`src/pty.lisp:pty-close@2d4d743`,
`src/unix-term.lisp:handle-key-press@2d4d743`).

**Decision:** The PTY records separately whether the child is alive and
whether the descriptor is open. Closing always closes an open descriptor and
reaps the child, signalling it first if it is alive. Every path that writes to
or resizes a backend tests for one; after LEXTER-D67
that is the pane's backend methods, which already do.

**Alternatives:**
- Clear `alive-p` only in `pty-close`. Rejected: end of file is real
  information about the child, and the descriptor still needs closing.

### LEXTER-D75 — Backends are sized from the screen the handler made

**Status:** Accepted

**Context:** `vt-pane-init-screen` sizes the screen from the content area,
but the PTY and the telnet client are opened at the pane's full size
(LEXTER-O38,
`src/panes/uterm-pane.lisp:pane-initialize@2d4d743`).

**Decision:** Each backend is opened at the size of the screen that
`vt-pane-init-screen` returns, as the resize path already does.

**Alternatives:**
- Size the screen to the full pane. Rejected: it would draw under the
  chrome.

### LEXTER-D76 — Exports name only what exists, and packages read each other through them

**Status:** Accepted

**Context:** Seven exported symbols name nothing, and the model and the VT
handler read other packages' internals with `::`
(LEXTER-O37,
`src/packages-unix.lisp@2d4d743`, `src/tn3270/packages.lisp@2d4d743`).

**Decision:** Undefined exports are removed or defined. Each `::` read across
packages becomes an exported function, except where the cell plan replaces
the code that makes it. A check run with the test suite fails when an
exported symbol of a Lexter package names nothing: it is not bound, not
fbound, and names neither a class (`find-class`) nor a type, unless it is on
a short, documented list of exceptions, such as symbols exported only for
use as keywords in a protocol.

**Alternatives:**
- Export the internals as they are. Rejected: it publishes slot accessors
  that the cell plan is about to replace.

### LEXTER-D77 — Instance state leaves the globals

**Status:** Accepted

**Context:** The compositor copies its `prefix-key` slot into `*prefix-key*`
and its blink state into `*cursor-blink-on*` on every tick, and the VT
handler's callbacks set the window title with no window argument, so two
windows overwrite each other's state
(`src/panes/compositor.lisp:gui-tick@2d4d743`,
`src/panes/vt-pane.lisp:make-vt-pane-callback@2d4d743`). The pane-profiles
plan left the two globals for later, at the steward's direction; the steward
now places them in this plan.

**Decision:** Key handling reads the prefix key from the compositor that
received the key, or from its profile once the pane-profiles plan provides
one. The blink state reaches the flush as an argument, or a binding around
the flush, from the compositor that is drawing. A title change is applied to
the window that owns the pane. The 3270 pane's global swatch cache is
replaced by the cell plan's Phase 2. How a pane reaches its window is
LEXTER-O42.

**Alternatives:**
- Keep the globals and bind them per compositor around each tick. Rejected
  for the prefix key and the title, which are read in callbacks outside the
  tick; kept as an option for the blink state.

### LEXTER-D78 — Mode state has one home, the handler

**Status:** Accepted

**Context:** The screen has a `mode-flags` slot with `set-mode` and
`get-mode` stubs, while the VT handler keeps the real modes in its own slots
(`src/model.lisp:set-mode@2d4d743`).

**Decision:** The handler is the one home of terminal modes. The screen's
`mode-flags` slot and the two stubs are removed, and their exports with them.

**Alternatives:**
- Implement the stubs and move the modes onto the screen. Rejected: modes
  such as mouse tracking belong to the handler, not to a buffer, as
  LEXTER-DRAFT-data-structures-1e specifies, and the screen is already the
  review's god-struct.

### LEXTER-D79 — Keystrokes are encoded without babel's internals

**Status:** Accepted

**Context:** The key path encodes each character through
`babel::lookup-mapping`, `babel::*string-vector-mappings*`, and
`babel::encoder`, internal symbols that may change between releases
(`src/panes/vt-pane.lisp:*utf8-mapping*@2d4d743`).

**Decision:** A small UTF-8 encoder writes a codepoint's one to four bytes
into the pane's write buffer. It needs no allocation and no library.

**Alternatives:**
- babel's public `string-to-octets`. Rejected: it allocates a vector for
  every keystroke, which the internal call was written to avoid.

### LEXTER-D80 — Every fix gets a headless regression test

**Status:** Accepted

**Context:** The critique reproduced its findings in SBCL with no display,
and the cell plan's LEXTER-D106 makes the same rule
for its own.

**Decision:** Each finding in scope gets a test that reproduces it before it
is fixed, in the same test system as the cell plan's, using FiveAM and
cl-hamcrest. The TN3270E fix is tested against a recorded negotiation, and
the telnet fixes against an in-memory stream.

**Alternatives:**
- Test the protocols only against live servers. Rejected: the tests would
  depend on the network and on servers outside the project.

## The Consolidated Stack

After LEXTER-D67, one compositor serves both uses. The
standalone terminal's constructor builds a compositor with one workspace and
one `uterm-pane`, and its functions delegate:

Table: The standalone terminal's API after consolidation.

| Function | Delegates to |
|---|---|
| `make-terminal`, `run-terminal` | A compositor with one workspace and one `uterm-pane` |
| `gui-initialize`, `gui-tick`, `gui-destroy` | The compositor's methods |
| `terminal-capture` | `compositor-capture` |
| `terminal-start-recording`, `terminal-stop-recording` | The pane's VT handler |
| `terminal-reset` | A new screen and handler for the pane, with the window, atlas, and renderer kept |
| `no-pty` mode | A pane with no PTY, fed by `process-output` |
| `unix-terminal-vt-handler`, used by the test rig's `replay-blob` | The pane's VT handler |
| `unix-terminal-cols`, `-rows`, `-command`, `-pixel-scale`, `-title`, read by the Origin integration | The compositor's configuration and the pane's |
| `unix-terminal-pty`, read by the Origin integration | The pane's PTY, or NIL for a headless terminal |
| `unix-terminal-screen`, read by the Origin integration | Removed; readers ask the handler for the active screen (LEXTER-D70) |

The Origin integration reads the accessors through `::`
(`src/origin-impulse.lisp:%window-fields@2d4d743`); those it keeps are
exported (LEXTER-D76).

Key encoding, cursor blink, resize, palette upload, and default swatches then
exist once, in the pane and compositor code. The Origin integration keeps the
names it uses, and reads screens through the handler
(LEXTER-D70).

## Interaction with the Other Plans

- **The cell plan.** Its Phase 1 waits for LEXTER-D67.
  Its Phase 3 waits for LEXTER-D71. It owns the 3270
  pane's swatch cache and the review's finding that the 3270 pane bypasses the
  model.
- **The pane-profiles plan.** It owns
  LEXTER-O30. Its workspace-to-compositor
  reference (LEXTER-DRAFT-pane-profiles-O2) would answer this plan's
  LEXTER-O42, and its profiles would hold the prefix
  key (LEXTER-D77). Both it and the cell plan's Phase
  1 change `flush-to-display`, so their order is settled when the phases are
  scheduled.

## Tensions and Risks

- **Consolidation touches everything.** The standalone terminal, the test
  rig, and the Origin integration all change at once. The thin layer keeps
  their API, and the regression suite and the existing screenshot fixtures
  are run before and after.
- **The headless terminal's life.** A compositor stops when no pane is
  alive, and a pane with no PTY reports its backend as dead
  (LEXTER-O41).
- **Three plans in one area.** This plan, the cell plan, and the
  pane-profiles plan all change the flush and the panes; each phase states
  what it waits for.
- **Fixes outside Lexter.** An OSC sequence ended by BEL is not dispatched,
  which the critique traced to cl-vt (LEXTER-O44).

## Open Questions

### LEXTER-O41 — How does a headless terminal stay alive?

A pane with no PTY is fed by `process-output`, but its backend reports itself
dead, and the compositor stops when every pane is. A headless flag on the
compositor, or a pane that counts as alive when it was made without a
command, are the candidates.

### LEXTER-O42 — How does a pane reach its window?

The title and the prefix key need the compositor that owns a pane. Panes
refer to their workspace; the pane-profiles plan leans to a
`workspace-compositor` slot (LEXTER-DRAFT-pane-profiles-O2), which would
serve here too.

### LEXTER-O43 — What does an oversized TN3270 record do?

A record larger than the 8 KB receive buffer can never be framed. The buffer
could grow to fit, up to a limit, or the record could be discarded with an
error and the stream resynchronised at the next IAC EOR.

### LEXTER-O44 — Is the BEL terminator fixed in cl-vt or worked around?

The critique observed that an OSC sequence ended by BEL is accumulated but
never dispatched, so palette changes and window titles in that common form
are ignored, and traced it to cl-vt. The steward maintains cl-vt, so the fix
can be made there; a workaround in Lexter would duplicate the parser's work.

## Prior Art

Table: Prior systems and what this plan draws from each.

| System | What to draw from |
|---|---|
| xterm | The behaviour to match for SGR parameters out of range, auto-wrap within a scrolling region, and the alternate screen |
| RFC 1143's Q method | Option negotiation that cannot loop |
| x3270 and c3270 | A TN3270E client that negotiates by RFC 2355 and supports screen sizes other than 80×24 |
| VTE | One terminal core serving every application that embeds a terminal, rather than parallel implementations |

## Roadmap

1. **Tests.** The regression tests of LEXTER-D80 for every finding in scope,
   in the suite the cell plan's Phase 0 creates.
2. **Consolidation (LEXTER-D67).** One stack behind the standalone terminal's
   API, after LEXTER-O41 is settled. The cell plan's Phase 1 starts after this
   step. A Log records it.
3. **The VT handler (LEXTER-D68, LEXTER-D69, LEXTER-D70, LEXTER-D78,
   LEXTER-D79).** Host input at the boundary, autowrap through line feed,
   readers through the handler, one home for modes, and the keystroke encoder.
4. **Panes and the compositor (LEXTER-D71, LEXTER-D75, LEXTER-D77).** The
   workspace-switch repaint, which the cell plan's Phase 3 waits for; backend
   sizing; and the globals, after LEXTER-O42 is settled.
5. **Protocols (LEXTER-D72, LEXTER-D73).** TN3270E negotiation, screen sizing,
   and framing, after LEXTER-O43 is settled; then telnet encoding and option
   state. These depend on nothing above and may proceed at any time.
6. **The PTY and the packages (LEXTER-D74, LEXTER-D76).** Separate child and
   descriptor state, and exports that name what exists.
7. **Outside Lexter.** The BEL terminator, as LEXTER-O44 decides.
8. **Records.** A Log for each group of steps, and the Known nonconformance
   list of [LEXTER-DRAFT-data-structures-1e](Spec.DataStructures1e.md) updated
   as its items are fixed.

How these steps interleave with the cell plan's phases and the pane-profiles
plan is set out in the ordering table at the end of the cell plan's Roadmap
([LEXTER-0017](Plan.CellModelRevision.md)).