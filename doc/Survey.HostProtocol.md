---
id:            LEXTER-0019
title:         "Exposing Lexter's Colour and Graphics to Hosts: Survey"
genre:         Survey
scope:         project
project:       Lexter
language:      en
status:        Accepted
authors:
  - Andrew Sengul
approved-by:   Andrew Sengul
reviewed:      2026-11-17
provenance:
  assistant:   opencode
  session:     "Host protocol survey (2026-11-16); rich scrollback and 24-bit colour (2026-11-17)"
relates-to:
  - LEXTER-0016
  - LEXTER-0017
  - LEXTER-0018
  - LEXTER-0002
  - LEXTER-0003
  - LEXTER-0004
open-questions:
  - LEXTER-O69
  - LEXTER-O70
  - LEXTER-O71
  - LEXTER-O72
  - LEXTER-O73
  - LEXTER-O74
  - LEXTER-O75
  - LEXTER-O76
cites:
  - title:    "ECMA-48"
    locator:  "ECMA-48, 5th edition (June 1991), section 8.3.54, GCC - Graphic Character Combination, and Annex A.2"
    external: true
  - title:    "xterm control sequences"
    locator:  "ctlseqs.txt in https://github.com/ThomasDickey/xterm-snapshots at commit 5c75ead9a75d4b2e666ca06fa94503b5766ed93f: XTGETTCAP, lines 545-583; XTVERSION, lines 1531-1534; OSC 4 and OSC 10-19 queries, lines 2008-2116"
    external: true
  - title:    "xterm source"
    locator:  "https://github.com/ThomasDickey/xterm-snapshots at commit 5c75ead9a75d4b2e666ca06fa94503b5766ed93f (patch 412)"
    external: true
  - title:    "kitty source"
    locator:  "https://github.com/kovidgoyal/kitty at commit 2db470b78544f02d38c9df8ccef20acb171d4110"
    external: true
  - title:    "kitty graphics protocol"
    locator:  "docs/graphics-protocol.rst in the kitty source at commit 2db470b78544f02d38c9df8ccef20acb171d4110, Unicode placeholders"
    external: true
  - title:    "foot source"
    locator:  "https://codeberg.org/dnkl/foot at commit 152487e494993ad7fb5633a27c7d7ad0f8810ea5 (1.28.0)"
    external: true
  - title:    "Ghostty source"
    locator:  "https://github.com/ghostty-org/ghostty at commit cf5519b22f910ddc7885d2ef62deb94d38d43f22"
    external: true
  - title:    "VTE source"
    locator:  "https://gitlab.gnome.org/GNOME/vte at commit 1db464a712308a3282a96dcf887a82ec5c830424 (0.85.0)"
    external: true
  - title:    "WezTerm source"
    locator:  "https://github.com/wezterm/wezterm at commit 458a100c1bf4134d36cb5c42dd90e4c8266d9e1a"
    external: true
  - title:    "less source"
    locator:  "https://github.com/gwsw/less at commit ca8a05dc238e25a9e6229688bade8043c49a37f3: less.nro.VER, lines 1586-1621 (-u, -U, overstrike); line.c, do_append, lines 1318-1375"
    external: true
  - title:    "groff source"
    locator:  "https://git.savannah.gnu.org/git/groff.git at commit 1a31239abfacc8ef73abf056f91b82b8f2237940: grotty.1.man, lines 134-291, 500-507, 662-669"
    external: true
  - title:    "man-db source"
    locator:  "https://gitlab.com/man-db/man-db at commit 74f9ff6116b4855ae4d2bc446ac3449e890f35dc: man.c, make_roff_command, lines 1447-1458, and make_display_command, lines 1655-1663"
    external: true
  - title:    "Debian groff packaging"
    locator:  "https://salsa.debian.org/debian/groff at commit 7ae2f7bdbe71dcf96ec8bc9da85f3cb936a1ad51: debian/changelog, lines 160-164 and 1243-1246"
    external: true
  - title:    "CTerm Manual"
    locator:  "src/conio/cterm.adoc in https://gitlab.synchro.net/main/sbbs at commit acce09a1778dc2c61a996a3407ff6ddcaf70acb3 (cterm.c revision 1.333)"
    external: true
  - title:    "SyncTERM source"
    locator:  "src/conio and src/syncterm in https://gitlab.synchro.net/main/sbbs at commit acce09a1778dc2c61a996a3407ff6ddcaf70acb3"
    external: true
  - title:    "Contour colour palette update notifications"
    locator:  "docs/vt-extensions/color-palette-update-notifications.md in https://github.com/contour-terminal/contour at commit 3c9e024cdc599916cdccb8cb2e965fbcc4c3325c"
    external: true
  - title:    "tmux source"
    locator:  "https://github.com/tmux/tmux at commit 71afaaff9c77768d1b2940b9b6b44d9284e93f2f"
    external: true
  - title:    "tmux FAQ"
    locator:  "FAQ.md in https://github.com/tmux/tmux.wiki at commit 678d0f02082785d8156150eb80cd0302fe581957, What is the passthrough escape sequence and how do I use it?"
    external: true
  - title:    "VT510 Video Terminal Programmer Information"
    locator:  "DECDLD, https://vt100.net/docs/vt510-rm/DECDLD.html"
    external: true
  - title:    "Enhanced Teletext specification"
    locator:  "ETSI EN 300 706 V1.2.1 (2003-04), section 12.1, Table 25 (DRCS)"
    external: true
---

# Exposing Lexter's Colour and Graphics to Hosts: Survey

This survey asks how the colour and graphics of Lexter's cell model, specified
in [LEXTER-0016](Arch.CellModel.md) and planned in
[LEXTER-0017](Plan.CellModelRevision.md), could reach the programs that run in
a terminal: Common Lisp applications that use Lexter as their front end,
bulletin boards that want to shape a Lexter user's experience, and the
ordinary terminal software, frameworks, and multiplexers of today. It sorts
the means into tiers, from what existing standards already carry to a
protocol of Lexter's own, and asks of every element how it degrades in
another terminal and under a multiplexer. It draws on the prior-art
evaluation of other terminals
([LEXTER-0018](Eval.CellModels.PriorArt.md)). It
decides nothing. **This work follows the new cell model**: it is a secondary
priority, to be taken up once LEXTER-0017's phases have built the record
and its renderers, and the evaluation that would weigh its options comes
after it.

## Motivation

Lexter's cell model gives a cell layers cut by masks, swatches drawn from
palette slots, cell-sized tiles with flips and priority, and colours that
cycle on clocks. None of this reaches a program unless the program can ask
for it. Today's terminal programs colour their output by sending 24-bit
colour with each character, which Lexter can draw only as inline colours or
by mapping to a palette; they compose text by sending characters, which
Lexter can overprint only if told to; and none of them knows that a tile is
something a terminal can draw. A host that wanted these features would need
to know that Lexter is there, to send what it understands, and to fall back
to something sensible everywhere else. kitty has shown the way this is done
for features of its own: a specification, a query to detect the feature, and
libraries, after which other terminals took up its keyboard and graphics
protocols. Lexter's overprinting and tiles are a different kind of feature
from kitty's, which are images beside the grid, and need their own
treatment.

## Two Channels

**The native side channel.** A Common Lisp program that runs Lexter as its
front end already extends Lexter directly, in the same image: it draws into
panes and chrome, and takes input through redirects
([LEXTER-0002](Log.InputRedirect.md)). Such a program can load palettes,
swatches, tiles, and cycle ranges through Lexter's API with no escape
sequences at all, and needs no protocol beyond the API that Lexter's own
chrome uses. That channel will grow with Lexter, and this survey leaves it
to Lexter's API.

**The in-band protocol.** Everything that arrives over a byte stream, from a
shell, an SSH session, a telnet connection, or a bulletin board, can reach
Lexter only through escape sequences in that stream. A bulletin board written
in Common Lisp could share an image with Lexter in principle, but it serves
users across a network whose programs it does not control, so for safety it
speaks the in-band protocol, as any other host does, and is subject to the
same limits. The rest of this survey is about the in-band protocol.

## How Terminal Extensions Are Adopted

Programs do not assume a terminal's features; they detect them:

- **Queries of identity and capability.** XTVERSION (`CSI > q`) asks for the
  terminal's name and version, and XTGETTCAP (`DCS + q` names `ST`) asks for
  named terminfo capabilities (*xterm control sequences*, lines 1531–1534 and
  545–583). xterm answers a few names beyond its special keys (`Co`, `TN`,
  and `RGB`); kitty answers the whole of its terminfo and names of its own,
  `kitty-query-*`, for runtime queries (*kitty source*, kitty/terminfo.py,
  get_capabilities, lines 529–576); foot answers from a table generated from
  its terminfo (*foot source*, dcs.c, lines 85–227).
- **Flags of capability.** SyncTERM answers `CSI < c` with a list of
  numbered capabilities: loadable fonts, bright backgrounds, a palette set by
  OSC, pixel graphics, font selection, an extended palette, the mouse, and
  physical keys (*CTerm Manual*, CTerm Device Attributes, lines 800–830).
- **Libraries and frameworks.** A feature reaches most programs through the
  frameworks they are built on, as sixel and kitty's images reached many
  programs through one library's backends. A Lexter backend in such a
  framework would reach every program built on it.

An extension that hopes to be used is therefore detectable by a query,
ignored harmlessly by terminals that do not know it, versioned, written down
for others to implement, and wrapped in a library.

## Tier 0: What Existing Standards Already Carry

These need no new protocol: Lexter honours them, and its model makes them
exact.

- **Palettes.** OSC 4 sets and queries palette entries, OSC 104 resets them,
  and OSC 10, 11, and 12 set and query the default foreground, background,
  and cursor colours (*xterm control sequences*, lines 2008–2116). Each
  terminal in Lexter has a palette slot of its own
  (LEXTER-D92), so these changes stay in the pane that made them, as
  [LEXTER-0003](Log.PersistentPalette.md) and
  [LEXTER-0004](Log.PalettePaging.md) began. Programs and scripts that theme
  through 256 colours and OSC 4 already speak Lexter's colour model.
- **24-bit colour through a palette.** A program that sends 24-bit colour can
  be met by a palette slot kept for each terminal as a cache: each distinct
  colour the program sends takes an entry, and when the slot is full a new
  colour is mapped to the nearest. The program's colours are then drawn
  exactly, through swatches, and Lexter's inline-colour format (LEXTER-D82)
  is a fallback rather than the common path. SyncTERM keeps a temporary
  palette for 24-bit colours in the same spirit, and warns that scrollback
  may lose them (*CTerm Manual*, SGR, lines 1754–1781). The steward has since
  chosen inline colours instead (LEXTER-O71).
- **Graphics made of characters.** Box drawing, block elements, and Unicode's
  Symbols for Legacy Computing, such as sextants and octants, are the cell
  graphics of today's tools, and Lexter draws them from its fonts or as
  generated glyphs.
- **Overprinting by combining characters.** A base character followed by
  combining marks is one cell, which Lexter can draw as layers or masks; the
  terminals surveyed keep such sequences, within limits, and tmux keeps up to
  32 bytes of UTF-8 in a cell (*tmux source*, tmux.h, UTF8_SIZE, line 782).
- **Overprinting by GCC.** ECMA-48's Graphic Character Combination,
  `CSI Ps SP _`, asks that "two or more graphic characters are to be imaged
  as one single graphic symbol": with 0 the next two characters, and with 1
  and 2 the start and end of a string of them (*ECMA-48*, 8.3.54). The
  standard's annex says that a composite symbol should be made this way, not
  by moving the cursor back (*ECMA-48*, A.2). None of xterm, kitty, or foot
  implements it (*xterm source*, VTPrsTbl.c, csi_sp_table, line 1895; *kitty
  source*, kitty/vt-parser.c, dispatch_csi, lines 1473–1479; *foot source*,
  csi.c, lines 1855–1857). It is the one standard control function that says
  what Lexter's layers do, and Lexter would be among the few terminals to
  give it a meaning.
- **Overprinting by backspace.** The teletype convention of a character, a
  backspace, and a character, which `nroff` used for bold and underline, no
  longer reaches terminals in the usual setups: groff's grotty emits SGR by
  default (*groff source*, grotty.1.man, lines 134–196), man-db suppresses
  SGR only when output is not a terminal and then strips the result (*man-db
  source*, man.c, lines 1447–1458 and 1655–1663), Debian returned to SGR in
  2023 (*Debian groff packaging*, debian/changelog, lines 160–164), and less
  turns overstrike into bold and underline before it reaches the terminal
  unless told to pass it raw (*less source*, less.nro.VER, lines 1586–1621).
  Overprinting by backspace would be a mode a host turns on, for its own
  output, rather than a way to reach existing programs.

## Tier 1: Detection, Palettes in Bulk, and Clocks

Thin extensions, each answered or ignored:

- **Identity.** XTVERSION answers `Lexter(version)`, and XTGETTCAP answers
  Lexter's terminfo and capabilities of its own, such as whether palettes,
  layers, tiles, and cycles are available, so that a program asks rather than
  guesses (LEXTER-O70).
- **Palettes in bulk.** Loading a whole palette at once, and choosing among
  palettes, beyond OSC 4's entry at a time.
- **Clocks.** Setting the rates of the blink clock and the cycle clocks
  (LEXTER-D94, LEXTER-D95), within limits the user sets.
- **Styling variants**, under the section of that name.

## Tier 2: The Lexter Protocol

Lexter's own model, in sequences of Lexter's namespace
(LEXTER-O69), sent only after detection. Each element is
a candidate, not a design:

- **Swatches.** A host defines swatches, each four palette indices, receives
  their ids, and selects them for cells through an extended SGR form that it
  sends only to Lexter.
- **Layers and masks.** A mode in which printed characters go to a layer, or
  are printed as masks with an operation and a reach, so that the host still
  sends characters and the mode decides how they compose; or the same
  composition sent as GCC strings, or as combining sequences, which survive
  better elsewhere (see Degradation). Which forms are offered is
  LEXTER-O74.
- **Tiles as a character set the host loads.** DEC's soft fonts let a host
  load up to 94 or 96 glyphs and print them as a designated character set
  (*VT510 Video Terminal Programmer Information*, DECDLD), teletext's Level
  3.5 offers redefinable characters of 12 by 10 pixels in up to 16 colours
  (*Enhanced Teletext specification*, 12.1), and SyncTERM lets a host load
  whole fonts into numbered slots from base64 data, choosing among them by
  `CSI Ps1 ; Ps2 SP D` (*CTerm Manual*, CTerm Loadable Font, lines 2387–2394,
  and Font Selection, lines 406–575). Lexter's tiles (LEXTER-D91) are this
  line of work with colour, flips, and priority: a tile set loaded in a
  sequence of four-bit pixels, then printed as characters of a designated
  set, with flips, priority, offsets, and transparency set by the extended
  SGR. A terminal without Lexter prints the characters themselves, which a
  host can choose to be a readable fallback. The encoding is
  LEXTER-O75.
- **Cycles.** The tile cycles of LEXTER-D95, and the cycling of swatch ranges,
  whose design waits for the cell model to be built
  (LEXTER-O73).
- **Rich scrollback.** Lexter keeps history as text and styles, and makes
  records only for the rows on screen
  (LEXTER-DRAFT-cell-model-revision-D19), so layers, masks, and tiles do not
  survive into history. A program whose interface wants its graphics kept,
  such as a bulletin board written for Lexter, could ask that its rows be
  kept as records while its interface runs, within limits the user sets
  (LEXTER-O76).

## Tier 3: Native Front Ends and Bulletin Boards

A host that knows it is talking to Lexter, such as a bulletin board written
for it, begins with a handshake, which is detection followed by loading: the
host asks Lexter's identity and capabilities, then sends its palettes,
swatches, tile sets, and cycles, and its users see the board as its operator
designed it. SyncTERM is the precedent: a board identifies it by its device
attributes, which spell "CTerm" and give its revision (*CTerm Manual*,
Device Attributes, lines 773–798), loads fonts into its slots, sets its
palette by OSC 4, and switches it into PETSCII or ATASCII modes (*CTerm
Manual*, PETSCII Emulation, lines 3856–3878, and ATASCII Emulation, lines
4031–4049). A Lexter board would speak the Tier 2 protocol, so that the same
board serves any Lexter, and its handshake would be a use of that protocol
rather than a protocol of its own.

## Styling Variants

The colour scheme a terminal reports to programs is binary today. Contour
specified a query, `CSI ? 996 n`, answered by `CSI ? 997 ; 1 n` for dark and
`CSI ? 997 ; 2 n` for light, and a mode, 2031, in which the terminal reports
changes unasked (*Contour colour palette update notifications*). kitty, foot,
Ghostty, VTE, and tmux implement it, and WezTerm and xterm do not. Every
implementation sends only those two values: kitty and VTE decide by the
luminance of the default background (*kitty source*, kitty/window.py, lines
1787–1801; *VTE source*, src/vte.cc, lines 2670–2675), while foot and
Ghostty report which configured theme is active, foot noting that its themes
"aren't necessarily light/dark, but by convention" are reported so (*foot
source*, csi.c, lines 1584–1600; *Ghostty source*,
src/terminal/device_status.zig, lines 4–41). kitty tracks a third state, no
preference, and tmux an unknown one, but neither puts it on the wire
(*kitty source*, kitty/colors.py, line 32; *tmux source*, input.c, lines
4000–4020).

Light and dark are one axis of a wider system of variants. Lexter's palette
slots can hold any number of styles: a theme for each pane, a palette for a
time of day, a high-contrast palette, a dimmed palette for a pane that lacks
focus, or a set a bulletin board defines. A program that knows only light
and dark should be answered by the existing query, as a projection of the
active variant onto that axis; a program that knows Lexter could ask for the
variant itself, by name, and be told when it changes. How variants are named,
announced, and chosen is LEXTER-O72.

## Degradation in Other Terminals and Under Multiplexers

Every element of the protocol should say how it degrades. Two settings
matter: a terminal that is not Lexter, and a multiplexer between the host
and Lexter. tmux redraws each pane from its own grid, so whatever its grid
does not hold is lost at the next redraw. Its cell keeps UTF-8 with combining
characters, the attributes it knows, foreground, background, and underline
colours, and a hyperlink (*tmux source*, tmux.h, grid_cell, lines 923–931);
it ignores SGR parameters it does not know and drops OSC and DCS sequences
it does not handle (input.c, lines 2406–2553, 2724–2804, and 2645–2709);
passthrough, `DCS tmux;` wrapped, is off by default and is not kept for
redraws, so that tmux "can undo" what it changed (*tmux FAQ*, passthrough);
and it keeps a palette for each pane, substituting the pane's colours as it
redraws rather than forwarding OSC 4 (input.c, lines 3099–3144; tty.c, line
2682).

Table: How each element degrades.

| Element | In another terminal | Under tmux |
|---|---|---|
| OSC 4, 10, 11 | Standard; supported widely | Kept per pane; tmux draws the colours, not the palette |
| 24-bit colour cache | Unchanged: the host sends 24-bit colour | Unchanged |
| Combining characters | Drawn as the terminal draws them | Kept, up to 32 bytes a cell |
| GCC | Ignored; the characters appear side by side | Ignored, likewise |
| Backspace overstrike mode | The later character replaces the earlier | The same |
| XTVERSION, XTGETTCAP | Answered with the other terminal's identity | To be confirmed: whether tmux answers for itself or passes the query |
| Extended SGR for swatches and tiles | Ignored, or misread if not guarded by detection | Ignored, and lost |
| Private OSC, DCS, APC | Ignored | Dropped unless passed through, and then lost at a redraw |
| Tiles printed as a designated set | The fallback characters | The characters are kept; the tiles' appearance is lost |
| Styling variants | The light or dark answer, where supported | tmux answers with its own view of each pane |

The table suggests a rule for the protocol's design: prefer encodings made
of characters and SGR that a multiplexer keeps, as kitty made its Unicode
placeholders of text and colours so that images survive tmux (*kitty
graphics protocol*, Unicode placeholders), and give every element a fallback
that reads sensibly where it is not understood.

## Safeguards

A host that loads palettes, tiles, and cycles into a terminal is trusted with
the user's screen. The protocol should bound what a host may store, as kitty
bounds images at 320 MB a buffer and tmux bounds them by count and size;
scope what a host loads to the terminal that loaded it, so that one pane
cannot restyle another or Lexter's chrome; reset it on RIS and when the
alternate screen is left; let the user refuse it; and never let a host read
back another host's resources, or the user's palettes beyond the answers the
standard queries give. Clock rates and cycles should stay within limits the
user sets, since blinking and cycling at high rates can harm people with
photosensitive conditions.

## Honest Limits

- **Reach.** Tier 2 and Tier 3 reach only programs written for Lexter, or
  frameworks with a Lexter backend; the programs of today gain only Tier 0
  and Tier 1.
- **Multiplexers.** Under tmux, little beyond characters, SGR that tmux
  knows, and palettes survives; Lexter's layers, swatches, and tiles do not,
  except as the characters and colours that carry them.
- **Overprinting.** GCC has no implementations elsewhere to learn from, and
  backspace overstrike no longer arrives from the programs that used it.
- **24-bit colour.** A palette slot used as a cache holds 256 colours; a
  program that sends more falls back to the nearest, and the cache's
  contents depend on the order colours arrive.
- **Not researched.** Whether tmux answers XTVERSION and XTGETTCAP for
  itself; how frameworks would take a Lexter backend; and the version
  history of the terminals that report colour schemes, which is taken from
  Contour's own table.

## Relationship to Other Work

- [LEXTER-0016](Arch.CellModel.md) specifies the record whose features this
  survey would expose; [LEXTER-0017](Plan.CellModelRevision.md) builds it,
  and this work follows.
- [LEXTER-0018](Eval.CellModels.PriorArt.md) compares
  the screen models of other terminals; this survey asks how Lexter's model
  reaches the programs those terminals serve.
- [LEXTER-0002](Log.InputRedirect.md) is the native channel's input path;
  [LEXTER-0003](Log.PersistentPalette.md) and
  [LEXTER-0004](Log.PalettePaging.md) are its palettes as they stand.
- **Outside Lexter:** ECMA-48 and DEC's soft fonts and line attributes;
  teletext's redefinable characters; SyncTERM and CTerm; kitty's protocols
  and its Unicode placeholders; Contour's colour-scheme reports; tmux's
  grid and passthrough.

## Open Questions

### LEXTER-O69 — Which sequences carry the protocol?

OSC numbers in a range of Lexter's, a DCS with an introducer of Lexter's, or
an APC, as kitty uses for graphics and SyncTERM for its own commands. Each
differs in how terminals that do not know it pass it over and in what tmux
does with it. A version, reported with the identity, lets the protocol
change.

### LEXTER-O70 — Which capabilities does XTGETTCAP answer?

Lexter's terminfo, as foot and kitty answer theirs, and names of Lexter's
own for its features, in a form that a program can test one at a time.
Whether Lexter also answers a flag query, as SyncTERM does, is part of the
question.

### LEXTER-O71 — What is the policy for 24-bit colour?

The nearest palette colour; a palette slot kept for each terminal as a cache,
with a rule for a full cache; or inline colours. The choice decides how
exactly today's programs are drawn, and how scrollback keeps their colours.

**Resolution:** 2026-11-17 — settled by the steward in
[LEXTER-0017](Plan.CellModelRevision.md), not in this survey, which decides
nothing. The plan's Later Formats has the handler write 24-bit SGR colours
as inline colours once that format (LEXTER-D82) is built, and map them to
the nearest of the 256 palette colours until then, as it does today; and
LEXTER-DRAFT-cell-model-revision-D19 keeps 24-bit colour in history's
styles from the start. The details of the format's handling, such as a cell
that mixes a palette colour with a 24-bit one, are left to the step that
builds it. The palette cache of Tier 0 is therefore not pursued.

### LEXTER-O72 — How are styling variants named and chosen?

Light and dark are reported by the existing query. A program that knows
Lexter could ask for the active variant by name, be told when it changes,
and offer palettes for variants of its own; whether variants are a list the
user defines, or axes such as contrast and focus beside light and dark, is
open.

### LEXTER-O73 — How are swatch ranges cycled?

The cycling of a range of swatches, rotated as a renderer looks them up, is
a candidate for Tier 2, but its design, with reserved swatches and its
clocks, waits for the cell model to be built.

### LEXTER-O74 — Which forms of overprinting are offered?

GCC strings, combining sequences, a mode that directs characters to layers
and masks, and a mode of backspace overstrike each say how characters
compose; which of them Lexter honours, and which a host is told to prefer,
is open.

### LEXTER-O75 — How are tile sets encoded and designated?

Four-bit pixels in a DCS, as DEC's soft fonts carry one-bit ones, or base64
as SyncTERM carries fonts; how many tiles a set holds; how a set is
designated and its characters chosen as a fallback; and the quotas that
bound what a host loads.

### LEXTER-O76 — How does a host ask for rich scrollback?

By default Lexter keeps history as text and styles, and records only for the
rows on screen (LEXTER-DRAFT-cell-model-revision-D19), so the layers, masks,
and tiles of an interface are lost when its rows scroll away. A host that
wants them kept, such as a bulletin board written for Lexter, could ask that
the rows it writes be kept as records while its interface runs, as a
departure from Lexter's usual behaviour. Open: the sequence that asks and
ends it; whether it applies to a region, a pane, or the rows written while it
is set; the bound on how many rows are kept, which the user sets; how such
rows are shown, copied, and reflowed beside rows of text; and that the
alternate screen, which has no history, never keeps them.
