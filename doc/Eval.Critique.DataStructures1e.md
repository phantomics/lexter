---
id:            LEXTER-DRAFT-data-structures-1e-critique
title:         "Data Structures, First Edition: Critique"
genre:         Eval
subtype:       critique
scope:         project
project:       Lexter
language:      en
status:        Draft
provenance:
  assistant:   opencode
  session:     "Data-structures critique, Phase 2 (2026-10-26)"
relates-to:
  - LEXTER-DRAFT-data-structures-1e
  - LEXTER-0007
  - LEXTER-0003
  - LEXTER-0004
  - LEXTER-0006
  - LEXTER-0010
open-questions:
  - LEXTER-DRAFT-data-structures-1e-critique-O1
  - LEXTER-DRAFT-data-structures-1e-critique-O2
  - LEXTER-DRAFT-data-structures-1e-critique-O3
  - LEXTER-DRAFT-data-structures-1e-critique-O4
  - LEXTER-DRAFT-data-structures-1e-critique-O5
  - LEXTER-DRAFT-data-structures-1e-critique-O6
  - LEXTER-DRAFT-data-structures-1e-critique-O7
  - LEXTER-DRAFT-data-structures-1e-critique-O8
  - LEXTER-DRAFT-data-structures-1e-critique-O9
  - LEXTER-DRAFT-data-structures-1e-critique-O10
  - LEXTER-DRAFT-data-structures-1e-critique-O11
  - LEXTER-DRAFT-data-structures-1e-critique-O12
  - LEXTER-DRAFT-data-structures-1e-critique-O13
  - LEXTER-DRAFT-data-structures-1e-critique-O14
  - LEXTER-DRAFT-data-structures-1e-critique-O15
  - LEXTER-DRAFT-data-structures-1e-critique-O16
  - LEXTER-DRAFT-data-structures-1e-critique-O17
  - LEXTER-DRAFT-data-structures-1e-critique-O18
  - LEXTER-DRAFT-data-structures-1e-critique-O19
  - LEXTER-DRAFT-data-structures-1e-critique-O20
  - LEXTER-DRAFT-data-structures-1e-critique-O21
  - LEXTER-DRAFT-data-structures-1e-critique-O22
cites:
  - title:    "TN3270 Enhancements"
    locator:  "RFC 2355, section 4 (Command Meanings) and section 7.1 (DEVICE-TYPE Negotiation)"
    external: true
  - title:    "Telnet Protocol Specification"
    locator:  "RFC 854, the rules for preventing option negotiation loops"
    external: true
  - title:    "XTerm Control Sequences"
    locator:  "Moy, Gildea, Dickey; SGR 38/48 colour parameters, the alternate screen buffer, and OSC 4"
    external: true
  - title:    "Session transcript ses_2263-Lexter5"
    locator:  "session-ses_2263-Lexter5.md, lines 37 and 2569 (swatch tables sized at 2048 in the model, the grid, and the GPU)"
    external: true
  - title:    "Session transcript ses_2263-Lexter7"
    locator:  "session-ses_2263-Lexter7.md, lines 4122-4125 (the wide flag carried in bit 15 of the swatch field)"
    external: true
  - title:    "Session transcript ses_2263-Lexter9"
    locator:  "session-ses_2263-Lexter9.md, line 2800 (structs for performance, CLOS for extensibility)"
    external: true
---

# Data Structures, First Edition: Critique

This is an adversarial evaluation of Lexter's data model as specified in
[LEXTER-DRAFT-data-structures-1e](Spec.DataStructures1e.md) and as built at
commit `2d4d743`. It asks where the structures that carry a character from a
host byte to a pixel fail to keep their own invariants, where they interfere
with one another, and where host input or ordinary use can break them. It is
meant to inform the plan that fixes them and the design of the second edition
of the data model. Its findings are open: a person disposes of each one.


## Method

**Target.** The Spec [LEXTER-DRAFT-data-structures-1e](Spec.DataStructures1e.md)
at commit `50af242`, and the code it describes. The source tree is identical at
`2d4d743` and `50af242`; code references below are pinned to `2d4d743`, the
revision the Spec names. The Logs whose decisions are attacked are listed in
`relates-to`.

**Stance.** Red team: each structure is assumed broken until shown otherwise,
and each decision record is read for the case its authors made, then tested
against the scenarios below.

**Independence.** The critic is not independent of the Spec, which the same
assistant wrote earlier in this session; findings against the Spec's own text
are therefore likely to be under-counted. The code was written in earlier
LLM-assisted sessions, under the steward's direction, that the critic did not
take part in. A separate critique of the class and struct composition exists
in an earlier session transcript. To keep this critique independent of it, the
critic did not read that transcript or `doc/Plan.PaneProfiles.md`, which draws
on it. Exposure was limited to three incidents, all before this critique was
begun: the first 40 lines of that transcript (its header, the steward's opening
request, and a directory listing, with no findings); a count of the lines in it
matching one search term; and fragments of `doc/Plan.PaneProfiles.md` shown by a
repository search, one of which named, in part, a finding about panes and the
swatch indices of their screens. That subject overlaps
LEXTER-DRAFT-data-structures-1e-critique-O4, which an independent catalogue of
the code had already identified before the exposure.

**Evidence standard.** A finding is either *reproduced* or *traced*.
Reproduced findings were run headlessly in SBCL 2.3.4 against the loaded
systems `lexter/panes`, `lexter/tn3270-pane`, and `lexter/telnet-pane`, with
probe code kept outside the repository; each such finding's Evidence gives the
essential forms, so it can be rerun at the REPL. No GL context was available,
so GPU-side effects were shown with a stand-in for the renderer's upload rule
(`upload-swatch-table` uploads when the grid's generation differs from the one
it recorded, and copies the whole table) and, where an atlas was needed, with
an `atlas` struct built without a texture: codepoint 65 at position 1, space at
5, and U+4E00 at 10, marked wide. Traced findings were established by reading
the pinned code and following its control flow, and say so. The TN3270E
finding was checked against the text of RFC 2355.

**Left unexamined.** Rendering on a real GPU and the shaders' arithmetic;
performance, beyond noting work that is never used; platforms other than
Linux; the font loaders' parsing of malformed files; the Origin integration
beyond its use of screens; cl-vt, which is outside the target; and concurrency,
since Lexter is single-threaded by design.


## The Shared Scenario

Every finding is measured against one or more of these scenarios.

Table: Scenarios.

| Id | Scenario |
|---|---|
| S1 | Unifont in a `uterm-pane`; the shell prints Chinese text, then the user edits the line, scrolls, and resizes the window |
| S2 | A long session running colourful programs: a 256-colour theme, a truecolour gradient, `ls --color`, `htop` |
| S3 | One workspace holding two `uterm-pane`s and a `tn3270-pane`, with focus moving between them |
| S4 | A test run replaying several `.ptyb` fixtures through one headless terminal with `test-pixels` |
| S5 | `vim` with a colour scheme that redefines palette entries by OSC 4, entered and left repeatedly |
| S6 | The window is widened, and the shell then prints tab-separated output |
| S7 | Connecting a `tn3270-pane` to a server that offers TN3270E as RFC 2355 specifies |
| S8 | Hostile or merely unusual host output: out-of-range SGR parameters, sequences a recording contains verbatim |


## The Rubric

Table: Qualities the data model is judged against.

| Id | Quality | Holding up means |
|---|---|---|
| C1 | Invariant integrity | every invariant the Spec states for a structure holds after every operation on it |
| C2 | Synchronisation soundness | when a consumer's recorded generation equals its producer's, the two copies are equal |
| C3 | Ownership and isolation | each store has one writer, or writers that cannot corrupt one another |
| C4 | Robustness to host input | no byte sequence from the host can put a structure outside its declared type or bounds |
| C5 | Capacity at the boundary | every limit is enforced where data enters, not discovered by an out-of-bounds access |
| C6 | Single source of truth | each constant, default, and name is defined once |
| C7 | Description fidelity | documents, docstrings, comments, and exports match the code |
| C8 | Protocol conformance | backend structures follow the external standards they implement |


## Findings

Findings are ordered by severity, then by reach.

### LEXTER-DRAFT-data-structures-1e-critique-O1 — Double-width characters never reach the GPU from a screen

**Rationale:** The wide-glyph design keeps the full glyph range by carrying the
wide flag in bit 15 of the instance's swatch field (*Session transcript
ses_2263-Lexter7*, lines 4122-4125). LEXTER-D37 makes
the PCF loader extract full-width glyphs, and that Log's Implementation states
that "the screen/VT pipeline were all already in place from the CJK BDF demo
and needed no modification".

**Objection:** Under S1 every full-width character is drawn as a single narrow
cell: only the left half of the glyph is sampled, and the next character
overwrites the right half's cell. Three independent faults combine. The VT
handler never asks whether a glyph is wide, so it writes it narrow and advances
the cursor by one. Even a wide character written into a screen loses its flag
in `flush-to-display`, which writes the right half as an ordinary cell, and
`set-simple-cell` then clears the left half's wide flag because the right half
is a continuation (C1). The cursor overlay rewrites its cell without `:wide`.
The demo that the Log took as proof writes the grid directly, bypassing all
three. The Log's verification, "Unifont now renders correctly", could only have
covered narrow text.

**Evidence:** Reproduced. With the stand-in atlas,
`(process-output (make-vt-handler s atlas) #(#xE4 #xB8 #x80))` stores glyph 10
with `wide-flags` 0 and leaves the cursor at column 1, not 2
(`src/vt-handler.lisp:%print-codepoint@2d4d743`). Writing
`(write-char-at s 0 0 100 :wide t)` and flushing with the cursor hidden leaves
the grid's `wide-flags[0]` and `continuation-flags[1]` both 0, and
`build-render-data` emits 30 instances for a 10×3 grid with bit 15 clear
(`src/model.lisp:flush-to-display@2d4d743`,
`src/grid.lisp:set-simple-cell@2d4d743`). A wide cell written directly to the
grid loses both flags when the cursor's `set-simple-cell` call rewrites it.

**Severity:** high

**Seed:** Make width a property of the glyph index: the handler asks
`atlas-glyph-wide-p` and writes with `:wide`, and the flush skips model
continuation cells instead of writing them. A regression fixture with one CJK
character would have caught all three faults.

### LEXTER-DRAFT-data-structures-1e-critique-O2 — The grid's swatch generation has two meanings, and the GPU swatch table can stay stale for good

**Rationale:** LEXTER-D13 adopts a generation counter
as "a clean, race-free 'has this changed?' predicate", explicitly "the *same*
idiom already used for swatches (`swatch-table-generation` vs. the grid's
`swatch-generation`)".

**Objection:** The grid's counter is used for two things. `set-swatch`
increments it, and `flush-to-display` also overwrites it with the model's
counter after copying the table. With the cursor visible and not blinking (the
defaults from `make-screen`), every flush ends with the cursor's own
`set-swatch`, leaving the grid one ahead of the model. When a new swatch is
interned, the next flush sees the model's new number equal the grid's stale
one, skips the copy, and the cursor's increment then triggers an upload of a
table that lacks the new swatch. The flush after that does copy it, but resets
the grid to the model's number, and the cursor's increment brings it back to
exactly the number the renderer last recorded, so the corrected table is never
uploaded (C2). Under S2 any new colour can be drawn from an all-zero swatch,
black on black, until some unrelated swatch is interned. The Spec's
synchronisation table lists both increments as the contract while its
invariant forbids the result.

**Evidence:** Reproduced with the stand-in upload rule. After three idle frames
(model 2, grid 3, recorded 3), interning `(0 4 4 0)` as swatch 2 and writing a
cell with it gives: frame 0, model 3, grid 4, uploaded, GPU swatch 2 =
`#(0 0 0 0)`; frames 1 to 3, model 3, grid 4, no upload, grid swatch 2 =
`#(0 4 4 0)`, GPU swatch 2 = `#(0 0 0 0)`
(`src/grid.lisp:set-swatch@2d4d743`,
`src/model.lisp:flush-to-display@2d4d743`).

**Severity:** high

**Seed:** Give each copy its own counter with one meaning (a grid "content
version" bumped on any change to `swatch-data`), or have the cursor use a
swatch interned once rather than writing the table every frame.

### LEXTER-DRAFT-data-structures-1e-critique-O3 — Host input can put the VT handler's state outside its declared types

**Rationale:** Palette indices are 0 to 255 by construction, so the handler's
colour slots are typed `(unsigned-byte 8)`, and `rgb-to-256` exists to map
truecolour into that range. The tab-stop vector is sized to the screen at
construction. Typed struct slots are the project's choice for hot-path state
(*Session transcript ses_2263-Lexter9*, line 2800), and
LEXTER-D31 makes resize cover both screen buffers.

**Objection:** Ordinary host output signals errors inside `process-output`
(C4, S2, S6, S8). `rgb-to-256` returns 256 for the grey (248, 248, 248), so
`ESC [ 38;2;248;248;248 m`, a plausible light grey in a truecolour theme, fails
the slot's type. `ESC [ 38;5;300 m` stores 300 unchecked. The resize that
LEXTER-D31 specifies resizes screens but not `tab-stops`, so
after the window is widened, a tab at a column beyond the old width indexes
past the vector. Each failure
aborts the parse in the middle of a buffer, and a pane in the compositor has no
handler around it.

**Evidence:** Reproduced. `(rgb-to-256 248 248 248)` returns 256
(`src/vt-handler.lisp:rgb-to-256@2d4d743`); feeding the SGR sequence signals a
`type-error` setting `current-fg` to 256, and `38;5;300` signals the same for
300 (`src/vt-handler.lisp:handle-sgr@2d4d743`). After
`(vt-handler-resize-all h 40 3)` on a 10-column handler, `tab-stops` still has
length 10, and `ESC [ 1;12 H` followed by HT signals an invalid-index error
(`src/vt-handler.lisp:vt-handler-resize-all@2d4d743`).

**Severity:** high

**Seed:** Validate at the boundary: clamp or ignore out-of-range SGR
parameters, fix the grey ramp's upper bound, and make tab stops part of what
resize resizes. A fuzz fixture of malformed sequences would guard C4.

### LEXTER-DRAFT-data-structures-1e-critique-O4 — Every pane writes its own swatch numbering into one shared swatch store

**Rationale:** One display grid per window keeps a single GPU-facing resource;
LEXTER-D33 rejects per-buffer grids as "heavier; the grid is
a GPU-facing resource". Swatches belong to each screen, so each pane interns
its own colours, and the grid's swatch table is a mirror of per-cell state
(LEXTER-D15).

**Objection:** A mirror of *which* screen? Every VT screen numbers its swatches
from 0 in its own table, and every pane's flush copies its table into the same
grid indices, comparing its own generation against a grid counter that the
previous pane set (C3, S3). The panes therefore draw with each other's colours,
and because generations from different screens can be equal, a pane's table
may not be copied at all. The `tn3270-pane` writes into the same store from a
global cache keyed by colour pair, capped at 256 entries and cleared whenever
any 3270 pane initialises. The Spec claims that each structure has one writer;
the grid has as many writers as there are panes, plus the decorator and
`clear-grid`.

**Evidence:** Reproduced. Screen A interns `(0 1 1 0)` and screen B interns
`(0 2 2 0)`, both as swatch 1; after flushing A at column 0 and B at column 5
into one grid, both cells use swatch 1 and the grid holds `#(0 1 1 0)`, so B's
cell is drawn in A's colour (`src/model.lisp:flush-to-display@2d4d743`). The
3270 cache is traced
(`src/tn3270-pane/tn3270-pane.lisp:get-or-create-swatch@2d4d743`).

**Severity:** high

**Seed:** Either one swatch table per window, owned by the grid and shared by
every writer, or a per-pane base offset into a partitioned GPU table. The
second edition should decide who owns the swatch namespace.

### LEXTER-DRAFT-data-structures-1e-critique-O5 — Generation records are trusted across producers, so replays depend on fixture order

**Rationale:** LEXTER-D18 keeps one recorded generation per
palette slot so that each resident palette is uploaded only when it changes.
`terminal-reset` reuses the window, atlas, and renderer so that one headless
terminal can serve many fixtures "without rebuilding the (expensive) GL atlas"
([LEXTER-0010](Log.ScreenshotTestRig.md)), and
LEXTER-D47 rests on the output being "a deterministic
function of font file, palette, screen model, and renderer".

**Objection:** A recorded generation says nothing about *whose* generation it
was. Under S4, `terminal-reset` gives the reused renderer a fresh grid whose
counter climbs through the same small numbers as the last one, so the second
fixture's swatch table is never uploaded and it is drawn with the first
fixture's colours: the checksum depends on which fixtures ran before it,
against LEXTER-D47 (C2). Palettes have the same flaw:
every screen's palette generation starts at 1, so two panes that share a slot, or a pane and a reset terminal,
can present equal numbers for different palettes (S3). Detecting a change of
producer in the renderer is the fix that LEXTER-D33 rejected
for a related problem, which suggests the protocol needs it anyway.

**Evidence:** Reproduced with the stand-in upload rule. Fixture one on a fresh
grid with `setup-default-swatches` interns `(0 1 1 0)` as swatch 1 and uploads
at grid generation 2; fixture two, on another fresh grid, interns `(0 2 2 0)`
as swatch 1 and reaches generation 2, so nothing is uploaded and the GPU keeps
`#(0 1 1 0)` (`src/unix-term.lisp:terminal-reset@2d4d743`,
`src/renderer.lisp:upload-swatch-table@2d4d743`). Two screens that each change
palette entry 1 once, to red and to green, both report generation 2
(`src/renderer.lisp:upload-palette@2d4d743`).

**Severity:** high

**Seed:** Record the producer's identity with its generation, or draw
generations from one global counter so that no two states share a number;
`terminal-reset` can also clear the renderer's records.

### LEXTER-DRAFT-data-structures-1e-critique-O6 — The swatch table grows past what the grid and the GPU can hold

**Rationale:** Interning removes duplicate colour combinations, so a screen
needs only as many swatches as it uses distinct colour pairs, and 2048 entries
was chosen for the model, the grid, and the 2048-texel swatch texture together
(*Session transcript ses_2263-Lexter5*, lines 37 and 2569).

**Objection:** Nothing frees a swatch, and `intern-swatch` doubles the model's
table when it fills, while the grid's array and the texture stay at 2048. The
first flush after the 2049th distinct colour pair writes past the grid's array
(C5). Under S2 the count of pairs is bounded only by 256 × 256 background and
foreground combinations, and truecolour gradients, after mapping to 256
colours, reach new pairs quickly; reverse-video cursor swatches add more. The
failure is an error in the render loop, not a degraded picture.

**Evidence:** Reproduced. After interning 2100 distinct swatches, the model's
capacity is 4096 and the grid's `swatch-count` 2048, and `flush-to-display`
signals an invalid-index error at index 8192 of an 8192-byte array
(`src/model.lisp:intern-swatch@2d4d743`).

**Severity:** high

**Seed:** Enforce the limit at interning (evict unreferenced swatches, or fall
back to the nearest existing one), and size the grid and texture from one
constant.

### LEXTER-DRAFT-data-structures-1e-critique-O7 — TN3270E negotiation cannot complete with a server that follows RFC 2355

**Rationale:** No decision record covers the TN3270 client. Its code accepts
`DO TN3270E` so that it can use the enhanced protocol and its 5-byte record
header, and falls back to traditional tn3270 when the server sends
`DONT TN3270E`.

**Objection:** RFC 2355 has the server send `IAC SB TN3270E SEND DEVICE-TYPE
IAC SE` and the client answer `DEVICE-TYPE REQUEST <device-type>`; only the
server may send `DEVICE-TYPE IS`. The client tests for the bytes in the
opposite order (`DEVICE-TYPE SEND`) and answers with `IS`. Against a conforming
server (S7) the client agrees to TN3270E, never recognises the request, never
answers, and the session waits for ever with `client-tn3270e` set (C8).

**Evidence:** Reproduced. With `send-tn3270e-device-type` replaced by a
recorder, `process-subnegotiation` on `#(255 250 40 8 2 255 240)` (the RFC's
order) does not call it, while `#(255 250 40 2 8 255 240)` does
(`src/tn3270/client.lisp:process-subnegotiation@2d4d743`,
`src/tn3270/client.lisp:send-tn3270e-device-type@2d4d743`). The order and the
REQUEST rule are in RFC 2355, sections 4 and 7.1.

**Severity:** high

**Seed:** Parse `SEND DEVICE-TYPE`, answer `DEVICE-TYPE REQUEST`, and accept
`DEVICE-TYPE IS … CONNECT …` before the FUNCTIONS exchange; test against a
recorded negotiation.

### LEXTER-DRAFT-data-structures-1e-critique-O8 — Model operations that move or clear cells leave wide flags behind

**Rationale:** The screen keeps no continuation array; the right half of a wide
character is implied by glyph 0 next to a set `wide-flags` bit, which saves a
second bit vector, and `write-char-at` repairs either half when it is
overwritten.

**Objection:** Every other operation that moves or clears cells ignores
`wide-flags` (C1, S1). Scrolling copies glyphs but not flags, so the flag stays
on the old row and marks an unrelated cell wide. Inserting characters shifts
the glyph and its continuation but not the flag. Erasing the display blanks the
glyph but keeps the flag. `put-char` with `:wide` in the last column writes a
wide character that has no right half. `resize-grid` drops the grid's wide and
continuation flags. These are hidden today only because of
LEXTER-DRAFT-data-structures-1e-critique-O1; fixing that exposes them all.

**Evidence:** Reproduced. After `(write-char-at s 0 1 100 :wide t)` and
`(scroll-up s)`, row 0 holds glyph 100 with flag 0 and row 1 holds the blank
with flag 1 (`src/model.lisp:%copy-row@2d4d743`). `insert-chars` at column 0
gives glyphs `#(5 100 0 5)` and flags `#*1000`
(`src/model.lisp:insert-chars@2d4d743`). `(erase-in-display s 2)` leaves glyph
5 with flag 1 (`src/model.lisp:erase-in-display@2d4d743`). `put-char` at column
9 of 10 sets the flag at column 9 (`src/model.lisp:put-char@2d4d743`).
`resize-grid` from 10 to 12 columns leaves both grid flags 0
(`src/grid.lisp:resize-grid@2d4d743`).

**Severity:** medium

**Seed:** Treat a cell as the unit of every array operation: one helper that
copies or clears a cell's glyph, swatch, attributes, wide flag, and layered
entry together.

### LEXTER-DRAFT-data-structures-1e-critique-O9 — Layered cells diverge between the model and the grid

**Rationale:** The three-layer overprinting system keeps layered cells sparse,
in a hash table, so an all-simple grid pays nothing for them, and the model
and grid each keep a record per layered cell that the flush keeps in step.

**Objection:** The flush only adds. It writes a layered cell's non-NIL layers
into the grid's existing record, so a layer the model has cleared stays drawn
in the grid. `write-char-at` on a layered cell changes the top layer's glyph
and silently ignores the swatch and attributes it was given. The cursor,
drawn with `set-simple-cell`, turns a layered cell simple in the grid every
frame it sits there, so overlays vanish under the cursor and return when it
leaves (C1).

**Evidence:** Reproduced. After `(set-layer s 2 1 1 77 :ink-slot 2
:transparent-side :bg)`, a flush, `(clear-overlay-layers s 2 1)`, and another
flush, the grid's layer 1 still holds glyph 77
(`src/model.lisp:clear-overlay-layers@2d4d743`). `write-char-at` with a new
swatch on a layered cell leaves its swatch at 0
(`src/model.lisp:write-char-at@2d4d743`). With the cursor on a layered cell,
the model reports it layered and the grid does not.

**Severity:** medium

**Seed:** Make the flush write a layered cell's whole record, NIL layers
included, and draw the cursor as an overlay layer rather than by rewriting the
cell.

### LEXTER-DRAFT-data-structures-1e-critique-O10 — Glyph index 0 and codepoint 32 are both overloaded

**Rationale:** Glyph 0 in a screen means "blank" or "continuation", which lets
a cleared cell and a wide character's right half share one cheap sentinel that
the flush replaces with the blank glyph (*Session transcript ses_2263-Lexter5*
shows the substitution in the flush, quoted at line 5121).

**Objection:** Atlas position 0 is a real glyph, whichever codepoint the atlas
happens to pack first, and it can never be shown through a screen. The other
blank, 32, is a codepoint used as an atlas position: `make-screen` fills its
glyphs with 32 and leaves `blank-glyph` at 0; `delete-char` and `clear-grid`
write 32, and the function-pane helpers default to 32 or write raw character
codes. A screen made without a handler, or a
grid cleared by a workspace switch, shows whatever glyph sits at atlas
position 32 (C1, C7).

**Evidence:** Reproduced: `(make-screen :cols 4 :rows 1)` has glyphs
`#(32 32 32 32)` and `blank-glyph` 0 (`src/model.lisp:make-screen@2d4d743`).
Traced: `src/panes/workspace.lisp:clear-grid@2d4d743` defaults to glyph 32;
`src/atlas.lisp:build-atlas@2d4d743` assigns position 0 to the first codepoint
packed.

**Severity:** medium

**Seed:** Reserve atlas position 0 for an empty glyph at build time, so the
sentinel and the atlas agree, and make every writer take its blank from the
atlas.

### LEXTER-DRAFT-data-structures-1e-critique-O11 — The rule that the active buffer is read through the handler is not carried through

**Rationale:** LEXTER-D28 has the handler own both buffers
and requires readers to poll `vt-handler-screen`; the terminal's own `screen`
slot "is retained only as the initial primary handle".
LEXTER-D29 creates the alternate buffer lazily, and the
handler applies OSC colour changes to every buffer it owns.

**Objection:** The Origin integration reads and writes `unix-terminal-screen`:
it reports scrollback and cursor from the primary buffer while `vim` holds the
alternate one, and its state import moves the cursor on the hidden buffer
(C3). The lazily created alternate buffer starts from the default palette, so
OSC 4 redefinitions made before `vim` starts are lost inside it (S5), although
the handler's own rule is that palette changes are shared by both buffers.

**Evidence:** Traced: `src/origin-impulse.lisp:%window-fields@2d4d743` and the
`import-state` and `export-state` methods in `src/origin-impulse.lisp@2d4d743`
use `unix-terminal-screen`. Reproduced: after `ESC ] 4;1;rgb:00/ff/00 ESC \`,
the primary's entry 1 is green; after `ESC [ ?1049 h`, the alternate's entry 1
is the default red (`src/vt-handler.lisp:%ensure-alt-screen@2d4d743`).

**Severity:** medium

**Seed:** Remove the cached slot or make it a function of the handler, and
build the alternate buffer from a copy of the primary's palette.

### LEXTER-DRAFT-data-structures-1e-critique-O12 — The scrollback viewport moves the scroll bar but not the picture

**Rationale:** The screen records a scrollback ring and a viewport offset, and
`scroll-state` reports them so that chrome can draw a scroll bar whose thumb
is, by its code comment, at 0 "when at bottom".

**Objection:** Setting the viewport changes nothing that is drawn: the flush
ignores it, `scrollback-line` has no caller, and setting it does not even mark
a row dirty. Meanwhile the thumb geometry places offset 0, the live screen, at
the top of the bar, the opposite of its own comment. A user who scrolls the
wheel in a pane sees the bar move, in the wrong sense, over an unchanged screen
(C1, C7).

**Evidence:** Reproduced. With one line in scrollback, setting the viewport to
1 leaves `any-row-dirty-p` false, and a forced full flush leaves the grid
showing the live line, not the history line
(`src/model.lisp:set-scrollback-viewport@2d4d743`). For `scroll-state`
`(values 100 0 24)`, `scroll-bar-thumb-geometry` returns position 0 of 24
(`src/panes/chrome-mixin.lisp:scroll-bar-thumb-geometry@2d4d743`).

**Severity:** medium

**Seed:** Either draw the viewport in the flush or stop exposing it; in either
case invert the thumb so offset 0 is at the bottom.

### LEXTER-DRAFT-data-structures-1e-critique-O13 — The TN3270 screen and record framing assume a fixed size and clean byte boundaries

**Rationale:** The 3270 screen is a set of flat per-cell arrays plus two
addresses, separated so the host's paint pointer cannot move the operator's
cursor, and the client frames records at IAC EOR in an 8 KB buffer.

**Objection:** The arrays' initial forms are always 80 × 24, whatever `cols`
and `rows` are given, so any other size, including the 27 × 132 of
IBM-3278-5, indexes past them. Record framing scans for the byte pair `FF EF`
without regard to escaping, so a data byte 255 followed by a data byte 239,
sent as `FF FF EF`, ends the record early. A record that does not fit in the
receive buffer can never be framed, and the client stops reading once the
buffer is full (C1, C5, C8).

**Evidence:** Reproduced. `(make-tn3270-screen :cols 132 :rows 27)` has a
buffer of 1920 elements, and writing at address 2000 signals an invalid-index
error (`src/tn3270/screen.lisp:tn3270-screen@2d4d743`). The wire bytes
`F5 FF FF EF C1 FF EF` yield the record `F5 FF` instead of `F5 FF EF C1`
(`src/tn3270/client.lisp:extract-3270-record@2d4d743`). Traced:
`src/tn3270/client.lisp:client-recv-available@2d4d743` reads only while the
buffer has room.

**Severity:** medium

**Seed:** Allocate the arrays from `cols` and `rows` in a constructor, and
frame records with a small IAC state machine like the telnet client's.

### LEXTER-DRAFT-data-structures-1e-critique-O14 — Switching workspace clears the grid without scheduling a repaint

**Rationale:** One grid serves every workspace, so `switch-workspace` clears it
before the new workspace draws, as its comment says, "for full redraw".

**Objection:** Nothing marks the new workspace's panes or decorations dirty. A
frame is drawn only when a pane is dirty, so the new workspace stays blank
until its panes produce output, and then only the changed rows appear; its
decorations, flagged clean when last drawn, never return (C2 in spirit: the
grid's content and its sources disagree with no signal).

**Evidence:** Traced. `src/panes/compositor.lisp:switch-workspace@2d4d743`
calls `clear-grid` only; `src/panes/compositor.lisp:gui-tick@2d4d743` renders
when `workspace-any-dirty-p` is true, and `flush-workspace` draws decorations
only while `workspace-decorations-dirty` is set.

**Severity:** medium

**Seed:** Treat a workspace switch like the alternate-screen swap of
LEXTER-D33: mark every screen and the decorations dirty at
the switch.

### LEXTER-DRAFT-data-structures-1e-critique-O15 — Autowrap ignores the scrolling region

**Rationale:** The screen holds an inclusive scrolling region, and line feed
scrolls within it.

**Objection:** When a character wraps at the right margin, the handler tests
the screen's last row rather than the region's bottom. Inside a region that
ends above the last row, wrapping moves the cursor out of the region instead of
scrolling it, so status lines and split layouts drawn by programs such as
`less` and `tmux` are overwritten (C1).

**Evidence:** Reproduced. On a 10-row screen with `ESC [ 1;5 r`, writing two
characters at row 5, column 5 (1-based) leaves the cursor on row 5 (0-based),
outside the region (`src/vt-handler.lisp:%print-codepoint@2d4d743`).

**Severity:** medium

**Seed:** Wrap through the same path as line feed, so one function owns the
region rule.

### LEXTER-DRAFT-data-structures-1e-critique-O16 — The telnet client mangles code 255 and does not track option state

**Rationale:** In telnet mode the client doubles IAC on output, and it answers
the server's option requests so that common BBS servers connect without
configuration.

**Objection:** `telnet-write-string` masks each character to 7 bits before
testing it for 255, so a character of code 255 is sent as `7F FF`, a DEL
followed by a lone IAC. The client answers every WILL and DO without recording
which options are already on, which RFC 854's loop-prevention rules forbid
(C8).

**Evidence:** Reproduced: writing `(string (code-char 255))` to an in-memory
stream sends `7F FF`
(`src/telnet/client.lisp:telnet-write-string@2d4d743`). Traced:
`src/telnet/client.lisp:%handle-will@2d4d743` replies unconditionally.

**Severity:** low

**Seed:** Encode before escaping, and keep a per-option state table.

### LEXTER-DRAFT-data-structures-1e-critique-O17 — The headless and teardown paths dereference a missing PTY

**Rationale:** A `no-pty` terminal reuses the whole live render path, so replay
tests exactly what the live terminal draws
([LEXTER-0010](Log.ScreenshotTestRig.md), "Headless
replay path"); `pty-close` is guarded by `alive-p` so that it is safe to call
more than once.

**Objection:** The live input handlers were not guarded: a key, character, or
resize event on a `no-pty` terminal applies `pty-alive-p` or `pty-set-size` to
NIL. `pty-close` does nothing once `alive-p` is false, which `pty-read` sets on
end of file, so the descriptor is never closed and the child is never reaped
(C1).

**Evidence:** Reproduced: `(handle-key-press (make-terminal nil :no-pty t
:visible nil) :a 0 :press nil)` signals a `type-error`, NIL is not a `pty`
(`src/unix-term.lisp:handle-key-press@2d4d743`). Traced:
`src/pty.lisp:pty-close@2d4d743`.

**Severity:** low

**Seed:** Separate "the child is alive" from "the descriptor is open".

### LEXTER-DRAFT-data-structures-1e-critique-O18 — Constants, defaults, and names are defined more than once

**Rationale:** Each package keeps its own small set of constants so that it
loads without the others; the renderer marks its copy of the layered stride
"must match grid.lisp".

**Objection:** Copies drift (C6). `+layered-stride+` is defined in both
`grid.lisp` and `renderer.lisp`, and since the renderer uses the grid package
it is the same symbol defined twice, an error waiting for the first change.
`+max-layers+` and `+swatch-slots+` are separate symbols in model and grid, and
the 3 appears again as a literal in `render-frame` and in a type. The model's
layer slots are `ink-slot` and `bg-slot`, the grid's `ink-idx` and `bg-idx`.
`setup-default-swatches` exists in two places and the default palette in two
versions, which differ at entry 7, so colour 7 changes when the first pane is
focused. The grid's struct default for `swatch-count` is 256 and its
constructor's 2048; the screen's struct default for `cursor-blink` is T and
its constructor's NIL.

**Evidence:** Reproduced: entry 7 is (0.667 0.667 0.667) in
`make-default-palette` and (0.863 0.863 0.863) in
`src/panes/compositor.lisp:make-xterm-palette@2d4d743`. Traced:
`src/renderer.lisp@2d4d743` and `src/grid.lisp@2d4d743` both define
`+layered-stride+`; `src/unix-term.lisp:setup-default-swatches@2d4d743` and
`src/panes/compositor.lisp:setup-default-swatches@2d4d743`.

**Severity:** low

**Seed:** One constants package that every layer uses; one default palette.

### LEXTER-DRAFT-data-structures-1e-critique-O19 — Package exports and package boundaries disagree with the code

**Rationale:** Each subsystem is its own package with an export list, so that
other subsystems depend only on what is exported.

**Objection:** Seven exported symbols name nothing, and the model and the VT
handler reach into other packages' internals with `::`, including the grid's
cell arrays during the flush and the screen's glyph and swatch arrays from the
handler. The boundaries document a design the code does not follow (C7).

**Evidence:** Reproduced: `pty-open` in package `lexter/pty`;
`terminal-screen` and `terminal-pty` in `lexter/unix-term`; and
`screen-attributes`, `field-start`, `field-end`, and `field-length` in
`lexter/tn3270` are external and not `fboundp`
(`src/packages-unix.lisp@2d4d743`, `src/tn3270/packages.lisp@2d4d743`). Traced:
`src/model.lisp:flush-to-display@2d4d743` reads the grid's internal accessor
`display-grid-glyphs` through a double-colon reference.

**Severity:** low

**Seed:** Export what is used and remove what is not; let a load-time check
fail on undefined exports.

### LEXTER-DRAFT-data-structures-1e-critique-O20 — Backends are told the pane's size, not its content size

**Rationale:** `vt-pane-init-screen` sizes the screen from `content-width` and
`content-height` so that chrome can reserve a column or rows.

**Objection:** The PTY and the telnet client are opened at `pane-width` and
`pane-height`. With a scroll bar the host believes it has one more column than
the screen, and its line wrapping disagrees with Lexter's (C1). The resize path
uses the content size, so the disagreement lasts only until the first resize.

**Evidence:** Traced. `src/panes/uterm-pane.lisp:pane-initialize@2d4d743` and
`src/telnet-pane/telnet-pane.lisp@2d4d743` pass the pane's width and height;
`src/panes/vt-pane.lisp:vt-pane-init-screen@2d4d743` uses the content size.

**Severity:** low

**Seed:** Size the backend from the screen the handler just made.

### LEXTER-DRAFT-data-structures-1e-critique-O21 — Descriptions of the data model have drifted from it

**Rationale:** README.md, docstrings, and file headers are how a newcomer
learns the data model before reading the Spec.

**Objection:** They describe an earlier model (C7). README.md gives the
instance strides as 8 and 12 bytes and the glyph index as 16 bits; they are 12,
16, and 32. README.md also promises block, underline, and bar cursor styles,
which are stored but not drawn: the cursor is always reverse video. The cell
comment in `model.lisp` and the shader comments still say 16 bits; `grid.lisp`'s header
assigns swatch slots 2 and 3 to cursor and selection, which nothing does;
`load-pcf` says it returns a `PCF-FONT`; the swatch table's index comment
describes list keys where the code packs an integer; and the telnet client's
state comment lists states it does not have.

**Evidence:** Traced against `README.md@2d4d743`, `src/model.lisp@2d4d743`,
`src/shaders.lisp@2d4d743`, `src/grid.lisp@2d4d743`,
`src/pcf.lisp:load-pcf@2d4d743`, and `src/telnet/client.lisp:telnet-client@2d4d743`.

**Severity:** low

**Seed:** Compile the README's architecture section from the Spec, as
LEXTER-O3 contemplates.

### LEXTER-DRAFT-data-structures-1e-critique-O22 — The grid's dirty bits are maintained but never consulted

**Rationale:** Per-row dirty tracking lets each stage skip unchanged rows, and
`build-render-data` documents a `force-full` flag and incremental rebuilds.

**Objection:** `build-render-data` ignores `force-full` and its dirty bits and
rebuilds every instance each frame, and `render-frame` uploads the whole buffer
each frame. The grid's dirty bits are written by every grid operation and
cleared by the build, but nothing reads them. The cost is small at 80 × 24, but
the docstring promises a property the code does not have (C7).

**Evidence:** Traced. `src/grid.lisp:build-render-data@2d4d743` declares
`force-full` ignored and loops over every cell;
`src/renderer.lisp:render-frame@2d4d743` uploads the returned buffers whole.

**Severity:** low

**Seed:** Either rebuild only dirty rows into the persistent buffers, or
delete the dirty bits and the docstring's claim.


## What Held Up

- **The GPU instance layout.** Strides, offsets, attribute types, and the
  per-layer pointer sliding agree byte for byte between `build-render-data` and
  the vertex array setup, and the shaders mask bit 15 off before indexing.
- **The three identifier spaces.** Codepoints, font glyph indices, and atlas
  positions are kept apart everywhere the VT path touches them; the confusions
  in LEXTER-DRAFT-data-structures-1e-critique-O10 are at the edges.
- **The palette's placement.** Keeping the palette on the screen and sending
  it straight to the renderer (LEXTER-D12, -D4) made
  the alternate-screen and OSC work simple; the faults in
  LEXTER-DRAFT-data-structures-1e-critique-O5 are in the generation protocol,
  not the placement.
- **The alternate-screen pointer swap.** Entering and leaving are guarded and
  idempotent, the save slots are separate, and the swap forces a repaint, as
  LEXTER-D30, -D6, and -D7 intend.
- **The PTYB format.** Framing and validation are complete and simple, and the
  recording tap does not alter parsing.
- **The input redirect.** Interception by method combination needs no data
  beyond one slot, and `*redirect-suppressed*` makes forwarding reentrant.


## Synthesis

**Themes.** The high-severity findings share two causes.

1. *Copies without an owner.* The model, the grid, and the GPU hold copies of
   the same swatch and layer data, synchronised by bare integers that carry no
   identity (LEXTER-DRAFT-data-structures-1e-critique-O2, -O4, -O5, -O9). Each
   copy was added for a good local reason, but no structure owns the swatch
   namespace or the definition of "changed". The second edition should name
   one owner per namespace and one meaning per counter.
2. *Invariants kept by one writer and broken by the rest.* `write-char-at`
   honours the wide-character and layer rules; the flush, the cursor, the row
   operations, and resize do not
   (LEXTER-DRAFT-data-structures-1e-critique-O1, -O8, -O9). The Spec's
   invariants are stated per structure, but the code enforces them per
   function. A per-cell helper that every operation goes through would make
   them hold by construction.

Robustness at the boundary is the third theme. Host input reaches typed slots
and fixed arrays without validation
(LEXTER-DRAFT-data-structures-1e-critique-O3, -O6, -O13), and the external
protocols were implemented without checking against their texts
(LEXTER-DRAFT-data-structures-1e-critique-O7, -O16).

**Seeds worth a Plan or Survey.**

- A Plan to fix the high-severity findings, with a regression fixture for
  each, in the order of LEXTER-DRAFT-data-structures-1e-critique-O1 to -O7: a
  CJK line; a new colour after idle frames; malformed SGR and a tab after a
  resize; two panes with different colours; two fixtures replayed in either
  order; 2049 colour pairs; and a recorded TN3270E negotiation. Most can run
  headlessly, as this critique's probes did.
- A Survey of how other terminals own colour and glyph data across panes and
  the GPU, to inform the second edition's answer to the first theme.
- The test rig cannot detect LEXTER-DRAFT-data-structures-1e-critique-O2 or
  -O5, because both depend on what the renderer recorded before the capture. A
  check that compares the GPU's swatch table with the grid's would make such
  faults visible.

**Observed outside the target.** An OSC sequence ended by BEL rather than
`ESC \` is accumulated but never dispatched, so palette changes and window
titles in the common BEL form are ignored. The handler dispatches `:osc-end`
correctly; the probe suggests cl-vt does not emit it for BEL, which this
critique did not examine.

**Not examined.** The items listed under Method, and the Spec's own text
beyond the places where it codifies a defect
(LEXTER-DRAFT-data-structures-1e-critique-O2) or overstates ownership
(LEXTER-DRAFT-data-structures-1e-critique-O4): the critic wrote the Spec and
is a poor judge of it.
