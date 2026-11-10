---
id:            LEXTER-DRAFT-cell-models-prior-art
title:         "Cell Models: Prior-Art Evaluation"
genre:         Eval
subtype:       prior-art
scope:         project
project:       Lexter
language:      en
status:        Draft
provenance:
  assistant:   opencode
  session:     "Cell model prior-art evaluation (2026-11-09)"
relates-to:
  - LEXTER-0016
  - LEXTER-0017
  - LEXTER-0013
  - LEXTER-0014
  - LEXTER-0010
  - LEXTER-DRAFT-cell-field-format
cites:
  - title:    "kitty source"
    locator:  "https://github.com/kovidgoyal/kitty at commit 2db470b78544f02d38c9df8ccef20acb171d4110"
    external: true
  - title:    "Alacritty source"
    locator:  "https://github.com/alacritty/alacritty at commit aa5d942f46c40184a3f214830ff5f7989f4733a1"
    external: true
  - title:    "vte crate"
    locator:  "https://github.com/alacritty/vte at commit 3b3da71c34cc1256c7e20981cf03f8eb95e08ffc (vte 0.15.0, as Alacritty's Cargo.lock pins it)"
    external: true
  - title:    "unicode-width crate"
    locator:  "https://github.com/unicode-rs/unicode-width at commit 9d98411769fe13c7c18cab0b3fbbab29ba8350ea (unicode-width 0.2.2, as Alacritty's Cargo.lock pins it)"
    external: true
  - title:    "WezTerm source"
    locator:  "https://github.com/wezterm/wezterm at commit 458a100c1bf4134d36cb5c42dd90e4c8266d9e1a"
    external: true
  - title:    "Ghostty source"
    locator:  "https://github.com/ghostty-org/ghostty at commit cf5519b22f910ddc7885d2ef62deb94d38d43f22"
    external: true
  - title:    "VTE source"
    locator:  "https://gitlab.gnome.org/GNOME/vte at commit 1db464a712308a3282a96dcf887a82ec5c830424 (0.85.0)"
    external: true
  - title:    "foot source"
    locator:  "https://codeberg.org/dnkl/foot at commit 152487e494993ad7fb5633a27c7d7ad0f8810ea5 (1.28.0)"
    external: true
  - title:    "xterm source"
    locator:  "https://github.com/ThomasDickey/xterm-snapshots at commit 5c75ead9a75d4b2e666ca06fa94503b5766ed93f (patch 412)"
    external: true
  - title:    "kitty graphics protocol"
    locator:  "docs/graphics-protocol.rst in the kitty source at commit 2db470b78544f02d38c9df8ccef20acb171d4110"
    external: true
  - title:    "kitty text sizing protocol"
    locator:  "docs/text-sizing-protocol.rst in the kitty source at commit 2db470b78544f02d38c9df8ccef20acb171d4110"
    external: true
  - title:    "VT330/VT340 Programmer Reference Manual"
    locator:  "Chapter 14, Sixel Graphics, https://vt100.net/docs/vt3xx-gp/chapter14.html"
    external: true
  - title:    "iTerm2 inline images protocol"
    locator:  "https://iterm2.com/documentation-images.html, Protocol"
    external: true
  - title:    "VT220 Programmer Reference Manual"
    locator:  "Chapter 4, sections 4.10 (line attributes) and 4.16 (down-line-loadable character set), https://vt100.net/docs/vt220-rm/chapter4.html"
    external: true
  - title:    "VT510 Video Terminal Programmer Information"
    locator:  "DECDLD, DECDHL, DECDWL, https://vt100.net/docs/vt510-rm/"
    external: true
  - title:    "Terminal Unicode Core"
    locator:  "spec/terminal-unicode-core.tex in https://github.com/contour-terminal/terminal-unicode-core at commit 64f53851ceab9a3cf08db4939bcaef75a0899573 (mode 2027, draft revision 1)"
    external: true
  - title:    "NESdev Wiki"
    locator:  "PPU nametables (revision 22659), PPU attribute tables (21522), PPU palettes (24257), PPU OAM (23161), https://www.nesdev.org/wiki/"
    external: true
  - title:    "SNESdev Wiki"
    locator:  "Tilemaps (revision 1500), Backgrounds (revision 1244), https://snes.nesdev.org/wiki/"
    external: true
  - title:    "Plutiedev"
    locator:  "Tile ID flags, https://plutiedev.com/tile-id; Tiles and palettes, https://plutiedev.com/tiles-and-palettes"
    external: true
  - title:    "Pan Docs"
    locator:  "src/Tile_Maps.md and src/Palettes.md in https://github.com/gbdev/pandocs at commit 89f82b2181dac4e335bbbdd1451534e6b3a716cf"
    external: true
  - title:    "Commodore 64 Programmer's Reference Guide"
    locator:  "Chapter 3, Programming Graphics: Standard Character Mode, p. 107; Multi-Color Mode Graphics, pp. 115-116"
    external: true
  - title:    "The MOS 6567/6569 video controller (VIC-II)"
    locator:  "C. Bauer, 1996, sections 3.3 and 3.7.3, https://www.zimmers.net/cbmpics/cbm/c64/vic-ii.txt"
    external: true
  - title:    "Enhanced Teletext specification"
    locator:  "ETSI EN 300 706 V1.2.1 (2003-04), sections 12 (presentation levels), 12.1 (Table 25), 12.2 (Table 26), 15.7.1"
    external: true
  - title:    "BeebWiki MODE 7"
    locator:  "https://beebwiki.mdfs.net/MODE_7 (revision 3727)"
    external: true
  - title:    "ILBM IFF Interleaved Bitmap"
    locator:  "Section CRNG, https://wiki.amigaos.net/wiki/ILBM_IFF_Interleaved_Bitmap (revision 3007)"
    external: true
  - title:    "CSS Text Decoration Module"
    locator:  "CSS Text Decoration Module Level 3, section 5.1, painting order of text decorations"
    external: true
---

# Cell Models: Prior-Art Evaluation

This evaluation sets Lexter's dense cell model, specified in
[LEXTER-0016](Arch.CellModel.md) and planned in
[LEXTER-0017](Plan.CellModelRevision.md), beside the screen models of seven
terminal emulators, the image and text-sizing protocols that extend them, and
the tile and character hardware of the consoles and home computers whose
methods Lexter's tile format draws on. Every claim about another project is
pinned to a commit or a page revision, so that later changes to those
projects do not invalidate it. Its purpose is to find what Lexter's model
takes from others, what it does that none of them does, and what they account
for that it does not yet; those findings are seeds for the plan and the
architecture, gathered under Synthesis.

## Method

- **Systems.** Seven terminals whose source is open: kitty, Alacritty,
  WezTerm, Ghostty, VTE, foot, and xterm. The image protocols of kitty, DEC
  sixel, and iTerm2; kitty's text-sizing protocol; DEC's line attributes and
  soft fonts; and the proposed mode 2027. The tile and character hardware of
  the NES, SNES, Mega Drive, Game Boy Color, Commodore 64, and teletext, and
  Deluxe Paint's colour cycling.
- **Evidence.** Each terminal's repository was cloned on 2026-11-09 at the
  commit its entry in `cites:` names, and read in its source; claims cite a
  file, a symbol, and a line range at that commit. Sizes are taken from
  static assertions or tests where the source has them, and otherwise
  computed from field widths, which this document says. Protocols and
  hardware are cited from their specifications or reference wikis at a named
  revision. What the source did not show is reported as not determined, and
  an absence is reported as found by search.
- **Stance.** Prior art, not critique: the aim is to learn from each system.
  The author of this evaluation is an assistant that also drafted Lexter's
  documents under evaluation, so it is not independent of them.
- **Not examined.** Terminals without open source (Windows Terminal is open
  but was not read; iTerm2's source was not read, only its protocol page);
  performance, which was not measured; and accessibility interfaces.

## The Shared Scenario

One screen, which each model must hold and draw:

1. A shell prompt coloured with 24-bit SGR, marked as a prompt by OSC 133.
2. A line of Japanese text, underlined with an SGR 58 colour, that wraps
   onto the next row.
3. An emoji sequence joined by ZWJ, and a flag.
4. A menu boxed with box-drawing characters.
5. A warning that blinks.
6. A title in DEC double-height characters.
7. A small image beside the menu.
8. 100,000 lines of history, then a resize that reflows them.

## The Rubric

Table: The rubric, applied to each system.

| Criterion | What it asks |
|---|---|
| R1 Cell content | What a cell holds, and its size in bytes |
| R2 Colour | How colours are stored: palette indices, 24-bit colour, shared styles |
| R3 Text and glyphs | Where a cell's characters live, and where its glyph is found |
| R4 Width | What decides a character's width, and how clusters are handled |
| R5 Rows | What is kept for each row: soft wrap, double-size lines, prompt marks, damage |
| R6 History | How scrollback is stored, and what it costs |
| R7 Attributes | Which attributes are stored, and how blink is drawn |
| R8 Graphics | How images relate to the cells |
| R9 Drawing | How cells reach the screen, and how lines and box drawing are drawn |
| R10 Testing | How the screen model is tested |

## kitty

- **R1:** each cell is split in two parallel arrays, a 12-byte CPUCell and a
  20-byte GPUCell, 32 bytes in all, enforced by static assertions (*kitty
  source*, kitty/line.h, GPUCell, lines 38–43, and CPUCell, lines 45–88).
  The CPU half holds the text or an index to it, a 16-bit hyperlink id, and
  text-sizing fields; the GPU half three colours, a sprite index, and
  attributes.
- **R2:** each colour is a 32-bit word whose low byte says default, palette,
  or 24-bit colour (kitty/cursor.c, parse_color, lines 62–84); foreground,
  background, and underline colour per cell.
- **R3:** a cell of several codepoints holds an index into an interned text
  cache, limited to 24 codepoints a cell (kitty/text-cache.c, TextCache,
  lines 29–39; kitty/line.h, MAX_NUM_CODEPOINTS_PER_CELL, line 32). Glyphs
  are sprites cached per shaped run.
- **R4:** widths come from a three-stage table generated from Unicode 17.0.0
  (kitty/char-props-data.h, line 1; gen/wcwidth.py, lines 49–55), never from
  the font; text is segmented into grapheme clusters by UAX #29. Mode 2027
  is not implemented (found by search).
- **R5:** one byte per line holds a dirty flag, a placeholder flag, and the
  OSC 133 prompt kind (kitty/line.h, LineAttrs, lines 90–100); soft wrap is a
  bit on the line's last cell. DEC double-size lines are not supported
  (kitty/vt-parser.c, lines 377–383).
- **R6:** a ring of full cells in mmap'd segments of 2048 lines, without
  compression; 2000 lines by default (kitty/history.h, lines 12–37).
- **R7:** underline in five styles, strikethrough, bold, italic, reverse,
  dim, and blink; no overline or invisible (kitty/line.h, CellAttrs, lines
  12–27). Blink is drawn as an opacity on the cursor's blink clock
  (kitty/child-monitor.c, lines 836–856).
- **R8:** kitty's own graphics protocol, with placements outside the cells
  and Unicode placeholders that reference images from cells (kitty/screen.c,
  screen_render_line_graphics, lines 4068–4145).
- **R9:** instanced quads from the GPUCell array; underline styles and
  strikethrough are generated sprites, and the text is blended over the
  underline, which a row of each sprite masks beneath descenders
  (kitty/shaders/cell.slang, lines 271–297).
- **R10:** Python tests drive the real screen through the real parser and
  assert on text, widths, and attributes (kitty_tests/screen.py, 69 tests).

**Steal:** the split between what the CPU and the GPU read, which Lexter's
text grid and record already make; underlines beneath the text. **Reject:**
the font-shaped, 24-bit model as Lexter's core.

## Alacritty

- **R1:** a cell of at most 24 bytes, asserted by a test: a character, two
  colours, 16 flag bits, and a shared pointer to rarely used extras, such as
  combining characters, the underline colour, and hyperlinks
  (*Alacritty source*, alacritty_terminal/src/term/cell.rs, lines 125–147
  and 307–314).
- **R2:** each colour is named, indexed, or 24-bit (*vte crate*,
  src/ansi.rs, Color, lines 1126–1132), resolved on the CPU when drawn.
- **R3:** one character and up to nine zero-width characters; no grapheme
  segmentation. Glyphs are found in a cache keyed by character and font.
- **R4:** widths from the *unicode-width crate*, generated from Unicode
  17.0.0, ambiguous characters narrow (src/tables.rs, lines 165 and
  220–240); no clusters, no mode 2027.
- **R5:** rows carry nothing but cells; soft wrap is a flag on the last cell
  (alacritty_terminal/src/term/mod.rs, wrapline, lines 956–975). Damage is
  tracked beside the grid. No double-size lines or OSC 133.
- **R6:** a ring of full cells; 10,000 lines by default, at most 100,000.
- **R7:** five underline styles, strikethrough, and hidden; blink is parsed
  but not drawn, and overline is not parsed.
- **R8:** no images.
- **R9:** instanced quads built on the CPU; underlines and strikethrough are
  rules drawn over the text (alacritty/src/display/mod.rs, draw, lines
  858–895).
- **R10:** reference tests replay a recorded byte stream and compare the
  resulting grid with a stored one (alacritty_terminal/tests/ref.rs, lines
  17–138), the nearest relative of Lexter's test rig and cell checksum
  ([LEXTER-0010](Log.ScreenshotTestRig.md)).

**Steal:** rare data kept off the common path. **Reject:** lines over the
text.

## WezTerm

- **R1:** a 24-byte cell, by a test: a 64-bit string, inline for short
  clusters, and 16 bytes of attributes with a boxed extension for 24-bit
  colour, hyperlinks, images, and the underline colour (*WezTerm source*,
  wezterm-cell/src/lib.rs, lines 51–104, 548–565, and 1027–1037).
- **R2:** palette colours inline, 24-bit colours in the boxed extension; no
  shared style table.
- **R3:** a whole grapheme cluster per cell; glyphs shaped by HarfBuzz over
  runs of like cells.
- **R4:** widths from generated tables (Unicode 16), with a chosen Unicode
  version, a setting for ambiguous widths, and overrides per character
  (wezterm-cell/src/lib.rs, UnicodeVersion, lines 831–887); grapheme
  clustering is always on, and mode 2027 reports as set.
- **R5:** each line has flags for DEC double width and the top and bottom of
  double height, which the renderer draws doubled
  (wezterm-surface/src/line/linebits.rs, lines 5–53); soft wrap and OSC 133
  are bits of the cells; damage is a sequence number per line.
- **R6:** lines leaving the screen become a string with runs of attributes
  (wezterm-surface/src/line/clusterline.rs, lines 16–42); 3500 lines by
  default.
- **R7:** six underline styles, slow and rapid blink on their own timers,
  overline, invisible, and superscript and subscript.
- **R8:** kitty's protocol, sixel, and iTerm2's; each image is sliced into
  pieces attached to the cells it covers, each with a z-index
  (wezterm-cell/src/image.rs, ImageCell, lines 80–115). Unicode placeholders
  were not found.
- **R9:** quads without instancing; lines rasterised into sprites; box
  drawing and block characters drawn procedurally
  (wezterm-gui/src/customglyph.rs, lines 183–240).
- **R10:** a test terminal fed with bytes, asserting on line contents.

**Steal:** double-size lines as row attributes; history compacted into text
and runs of attributes; a configurable Unicode version for widths.
**Reject:** a boxed allocation for every 24-bit cell.

## Ghostty

- **R1:** an 8-byte cell, a packed 64-bit word whose zero value is the empty
  cell: a tag, 24 bits of content, a 16-bit style id, width, and flags
  (*Ghostty source*, src/terminal/page.zig, Cell, lines 2385–2485).
- **R2:** styles of 16 bytes, three colours and flags, stored once per page
  in a set shared by reference count; a cell holds only the style's id, and
  id 0 is the default (src/terminal/style.zig, lines 19–121 and 676–691;
  src/terminal/ref_counted_set.zig, lines 9–88). A cell of background colour
  alone keeps its colour in the cell, with no style.
- **R3:** the first codepoint in the cell, the rest in storage for the page.
- **R4:** widths from a table generated at build time; mode 2027 is on by
  default, with VS15 and VS16 changing a cluster's width
  (src/unicode/grapheme.zig, lines 5–89).
- **R5:** a packed 64-bit row: soft wrap, prompt marks, a placeholder flag,
  dirty, and blank (src/terminal/page.zig, Row, lines 2208–2316). No DEC
  double-size lines.
- **R6:** history in pages from a memory pool, compressed with LZ4 when idle
  (src/terminal/PageList.zig, lines 5256–5441); 50 MB by default.
- **R7:** six underline styles, overline, strikethrough, faint, invisible,
  and blink, which is stored but not drawn (found by search).
- **R8:** kitty's protocol only, with placements pinned to tracked positions
  and Unicode placeholders; no sixel or iTerm2 images.
- **R9:** instanced text quads; underlines, strikethrough, overline, and
  cursors are sprites named by pseudo-codepoints above U+10FFFF
  (src/font/sprite.zig, lines 17–36), and box drawing comes from a sprite
  font drawn in code.
- **R10:** inline tests beside the code, integrity checks in safe builds,
  esctest run headless, and fuzzing.

**Steal:** compressed history; pages as units of storage. **Confirms:**
Lexter's interned swatches (Ghostty's shared styles) and its names for
generated glyphs above U+10FFFF (LEXTER-D89), and zero as the empty cell.

## VTE

- **R1:** a 20-byte cell, by static assertion: a character or interned
  string id, and 16 bytes of attributes (*VTE source*, src/cell.hh, lines
  156–276).
- **R2:** three colours packed into 64 bits: 25 bits each for foreground and
  background, palette or 24-bit, and 14 bits for the underline colour
  (src/color-triple.hh, lines 22–31).
- **R3:** combining sequences interned globally and never freed.
- **R4:** a table generated from GLib, with a setting for ambiguous widths
  (src/unicode-width.hh, lines 11569–11587); no clusters; mode 2027
  permanently reset.
- **R5:** one byte per row with soft wrap and bidirectional flags
  (src/vterowdata.hh, lines 37–51); OSC 133 per cell. DEC double-size lines
  are empty stubs (src/vteseq.cc, lines 3660–3733).
- **R6:** rows leaving the screen are frozen into streams in a temporary
  file, compressed with LZ4 and encrypted (src/vtestream-file.h, lines
  23–75); 512 lines by default.
- **R7:** blink drawn by skipping text and decorations in the off phase
  (src/vte.cc, draw_cells, lines 9020–9033).
- **R8:** sixel, off by default; images are kept beside the rows, not in
  cells.
- **R9:** cairo or GSK; decorations are rectangles drawn before the text, so
  that "if the descent of a letter crosses an underline of a different
  colour, it's the letter's colour that wins" (src/vte.cc, lines
  9035–9038).
- **R10:** unit tests of parts; none of the screen model was found.

**Steal:** history out of memory. **Confirms:** a coloured underline beneath
the text (LEXTER-D88).

## foot

- **R1:** a 12-byte cell, by static assertion: a character and 8 bytes of
  attributes with two 24-bit colours (*foot source*, terminal.h, lines
  35–72). Underline styles, underline colours, and links are kept per row as
  ranges of columns.
- **R2:** each colour tagged as default, 16-colour, 256-colour, or 24-bit.
- **R3:** composed clusters in a tree of up to 255 codepoints, shaped as
  clusters when the font library can.
- **R4:** utf8proc or the C library's wcwidth; grapheme clustering with a
  choice of width methods, and mode 2027 supported (terminal.c, lines
  4385–4430; csi.c, lines 562–566).
- **R5:** a row holds dirty and line-break flags and OSC 133 marks
  (terminal.h, struct row, lines 148–160); no double-size lines.
- **R6:** a ring of rows in memory; 1000 lines by default.
- **R7:** blink blends the foreground toward black in the off phase; no
  overline.
- **R8:** sixel images in a list beside the grid; printing over an image cuts
  the printed area out of it (sixel.c, lines 661–700).
- **R9:** drawn on the CPU with pixman; box drawing drawn in code; lines are
  rules after the text.
- **R10:** unit tests compiled into debug builds; no test of whole screens.

**Steal:** rare per-cell data kept as ranges on the row; a terminal drawn
entirely on the CPU, as Lexter's CPU renderer will be.

## xterm

- **R1:** parallel arrays per line rather than a cell struct: about 24 bytes
  a cell with the default options, computed (*xterm source*, ptyx.h,
  LineData, lines 1963–2036; screen.c, sizeofScrnRow, lines 308–346).
- **R2:** palette indices, or X pixel values for direct colour.
- **R3:** a fixed number of planes for combining characters, two by default.
- **R4:** Markus Kuhn's table, or the C library's wcwidth if it agrees, with
  a CJK setting (util.c, decode_wcwidth, lines 6313–6349); no clusters.
- **R5:** one byte per line: soft wrap, a flag that the line holds blinking
  text, and the DEC double-size setting, all fully implemented (ptyx.h,
  lines 1677–1695 and 3816–3826; doublechr.c, lines 48–145).
- **R6:** a ring of lines in memory; 1024 by default.
- **R7:** blink drawn by setting the foreground to the background, and only
  lines flagged as blinking are refreshed when it changes
  (charproc.c, HandleBlinking, lines 14232–14306).
- **R8:** sixel, with at most 16 images, drawn over the text; writing text
  clears the image's pixels beneath it (graphics.c, lines 1786–1874).
- **R9:** X11 or Xft; lines drawn after the text.
- **R10:** width tests, and vttest for the rest by hand.

**Steal:** a flag per row that it holds blinking text, which is the mask
Lexter's partial redraw derives (LEXTER-0017, Partial Redraw and Eviction).

## Graphics, Text Sizing, and DEC Line Attributes

- **kitty's graphics protocol** places images at the cursor cell, scaled to
  a number of columns and rows, with a 32-bit z-index; negative values draw
  under the text, and values below −1,073,741,824 under cell backgrounds
  (*kitty graphics protocol*, Controlling displayed image layout). Images
  scroll with the text; erasing text does not remove them, and what writing
  over them does is not specified. **Unicode placeholders** reference an
  image from ordinary cells: U+10EEEE, with the image id in the foreground
  colour, the placement id in the underline colour, and the row and column
  in combining diacritics (Unicode placeholders). This is the closest
  precedent for Lexter's void format, whose cells reference a surface
  (LEXTER-D82).
- **kitty's text-sizing protocol** draws text in blocks of several cells, up
  to seven times the base size, and defines how such characters behave when
  written over, edited, or scrolled (*kitty text sizing protocol*, How it
  works; Wrapping and overwriting behavior).
- **Sixel** anchors an image at the cursor cell and scrolls with it
  (*VT330/VT340 Programmer Reference Manual*, 14.4.1); the manual says
  nothing of text written over an image, which xterm erases and foot cuts
  out.
- **iTerm2's protocol** sizes an image in cells, pixels, or percentages, and
  does not say how it scrolls or is overwritten (*iTerm2 inline images
  protocol*).
- **DEC line attributes** "affect a complete display line" and move with it
  when it scrolls (*VT220 Programmer Reference Manual*, 4.10): double
  height, top and bottom, and double width are attributes of a row, not of
  cells.
- **DEC soft fonts** let a host load 94 or 96 glyphs, up to 10 by 16 pixels
  on the VT510 (*VT510 Video Terminal Programmer Information*, DECDLD).
- **Mode 2027** asks a terminal to segment grapheme clusters by UAX #29 and
  to give emoji two cells (*Terminal Unicode Core*, Semantics and Emoji).

## Tile and Character Hardware

Table: The tile entries Lexter's tile format descends from.

| System | Entry | Tile | Colour choice | Flips | Priority | Transparency |
|---|---|---|---|---|---|---|
| NES | One byte per 8×8 cell, attributes per 16×16 area | 8 bits | 2 bits per area: 4 palettes of 3 colours and a backdrop | Sprites only | Sprites behind the background | Colour 0 |
| SNES | 16 bits | 10 bits | 3 bits | H, V | 1 bit | Colour 0 |
| Mega Drive | 16 bits | 11 bits | 2 bits: 4 lines of 16 colours | H, V | 1 bit | Colour 0 of each line |
| Game Boy Color | A second byte per entry | 8 bits and a bank bit | 3 bits | H, V | 1 bit | — |
| Lexter (LEXTER-D91) | Two 16-bit fields per cell | 14 bits | 2-bit offset over four swatches, per tile | H, V | 1 bit for the top tile | Value 0, 4, 8, or 12 of the top tile |

Sources: *NESdev Wiki*, PPU attribute tables, PPU palettes, and PPU OAM;
*SNESdev Wiki*, Tilemaps; *Plutiedev*, Tile ID flags, and Tiles and palettes;
*Pan Docs*, BG Map Attributes.

- **The Commodore 64's multicolour characters** give each cell four colours,
  three shared and one its own, at half the horizontal resolution
  (*Commodore 64 Programmer's Reference Guide*, pp. 115–116; *The MOS
  6567/6569 video controller (VIC-II)*, 3.7.3.2), the same budget as a
  Lexter swatch.
- **Teletext** offers 63 block mosaics, serial attributes that last to the
  end of a row, and, from Level 2.5, 32 colours in four tables of eight and
  redefinable characters of 12 by 10 pixels in 1, 2, or 4 bits (*Enhanced
  Teletext specification*, 12.1 and 12.2; *BeebWiki MODE 7*).
- **Deluxe Paint** cycled contiguous ranges of colour registers at a rate,
  forwards or backwards, with four ranges by default (*ILBM IFF Interleaved
  Bitmap*, CRNG); Lexter's cycles by swatch pair (LEXTER-D95) are the same
  idea, driven by clocks.

## Comparison

Table: The terminals on the rubric, beside Lexter.

| | Cell bytes | Colour | Width | Row data | History | Blink drawn | Images |
|---|---|---|---|---|---|---|---|
| kitty | 32 (CPU 12, GPU 20) | Tagged per colour | Unicode 17 table, clusters | 1 byte: dirty, prompt | Full cells, 2000 lines | Yes, on the cursor's clock | kitty protocol, placeholders |
| Alacritty | ≤ 24 | Named, indexed, RGB | unicode-width (17), no clusters | None; wrap on last cell | Full cells, 10,000 | No | None |
| WezTerm | 24 | Palette inline, RGB boxed | Tables (16), clusters, settings | Double-size, sequence | Clustered text | Yes, two timers | kitty, sixel, iTerm2, in cells |
| Ghostty | 8 + shared style | Shared styles per page | Build-time table, mode 2027 | 64-bit row: wrap, prompt, dirty | Pages, LZ4 | No | kitty, placeholders |
| VTE | 20 | Packed 25-bit | GLib table, ambiguous setting | 1 byte: wrap, bidi | Frozen streams on disk | Yes | Sixel, off by default |
| foot | 12 | Tagged 24-bit | utf8proc, clusters, 2027 | Dirty, line break, prompt | Rows in memory | Yes | Sixel |
| xterm | ≈ 24 | Palette or X pixel | Kuhn table, CJK setting | 1 byte: wrap, blink, double-size | Lines in memory | Yes | Sixel |
| Lexter (LEXTER-0016) | 32 | Swatch and palette slot; inline colours later | The atlas (LEXTER-D98) | None yet | Records, 32 bytes a cell | Yes, on the cursor's clock | Void cells, later |

## Synthesis

**What Lexter shares.** A dense record drawn by instanced quads from an
atlas is common ground with kitty, Ghostty, and Alacritty, and kitty's split
of what the CPU and the GPU read is Lexter's text grid beside its record.
Interned colours are Ghostty's shared styles; zero as the empty cell, and
generated glyphs named above U+10FFFF, are Ghostty's too. Underlines beneath
the text follow kitty, VTE, and CSS (*CSS Text Decoration Module*), against
Alacritty, foot, and xterm. Blink on the cursor's clock is kitty's, and a
mark per row of blinking text is xterm's. Alacritty's reference tests are
the nearest relative of Lexter's cell checksum.

**What Lexter does that none of them does.** No terminal surveyed composes
several glyphs within a cell by masks; none renders by exact selection with a
CPU renderer that matches the GPU pixel for pixel, and checks both; none
animates colour by clocks; and none offers tiles with flips, priority, and
offsets into swatches, which come instead from the consoles of the 1990s.
Lexter's palette-first colour, limited by design to four colours a swatch
and sixteen a tile, has its precedent in the C64 and the consoles, not in
terminals, every one of which stores 24-bit colour per cell.

**What the others account for that Lexter does not yet.** In order of
urgency:

1. **Width from Unicode, not the font.** Every terminal surveyed decides a
   character's width from a table generated from Unicode's data, and none
   from the font; several add settings for ambiguous widths, a Unicode
   version, or grapheme clusters by mode 2027. LEXTER-D98 has the handler
   ask the atlas. Seed: settle
   [LEXTER-DRAFT-cell-model-revision-O14](Plan.CellModelRevision.md) for
   Unicode's tables.
2. **Information per row.** Every terminal but Alacritty keeps something per
   row: soft wrap for reflow (Ghostty, VTE, foot, xterm; the others on the
   last cell), prompt marks for OSC 133 (kitty, Ghostty, foot), damage, and
   in WezTerm and xterm the DEC double-size attributes, which the VT220
   manual defines per row. Lexter's cell model has no row record. Seed: a
   row record beside the grid, its fields drawn from this list, and a
   decision whether double-size lines are a row attribute that the renderer
   reads.
3. **The cost of history.** Lexter's scrollback of records costs 32 bytes a
   cell, as kitty's does, but 100,000 lines of 200 columns is about 640 MB.
   Ghostty compresses whole pages with LZ4, VTE freezes rows into compressed
   streams on disk, and WezTerm keeps text with runs of attributes. Seed:
   history kept as the text grid and interned styles, rebuilt into records
   for the rows shown.
4. **24-bit colour.** Every terminal stores 24-bit colour per cell, and
   programs use it constantly. Until Lexter's inline-colour format arrives,
   such colours are mapped to the 256-colour palette. Seed: state the
   policy, whether nearest colour, a palette slot used as a cache of 24-bit
   colours, or inline colours.
5. **Emoji and shaped text.** kitty, WezTerm, Ghostty, and foot shape
   clusters and draw colour emoji. Seed: state what Lexter draws for an
   emoji or a cluster it cannot shape, such as a 16-colour tile made from it
   when its font is loaded.
6. **Text larger than a cell.** WezTerm and xterm draw DEC double-size
   lines, and kitty's text-sizing protocol draws characters across up to
   seven cells. Lexter's halves cover two cells side by side.
7. **Images and the grid.** The protocols differ on what writing over an
   image does: xterm erases its pixels, foot cuts the area out, and kitty's
   specification is silent. WezTerm attaches image slices to cells, as
   Lexter's void cells would reference a surface. Seed: the survey of
   surfaces settles overwriting, scrolling, z-order, and storage limits,
   with kitty's Unicode placeholders as the model for references from cells.
8. **Box drawing.** WezTerm, Ghostty, and foot draw box-drawing and block
   characters in code, so that lines meet across cells at any size. Lexter's
   bitmap fonts meet already at their native size; generated glyphs could
   cover fonts that lack them.

Each seed points at a record of [LEXTER-0016](Arch.CellModel.md) or
[LEXTER-0017](Plan.CellModelRevision.md) that it would change; none is a
decision of this evaluation.

## Appendix — Source Map

Table: The primary sources behind each section.

| Section | Primary sources |
|---|---|
| kitty | *kitty source* |
| Alacritty | *Alacritty source*, *vte crate*, *unicode-width crate* |
| WezTerm | *WezTerm source* |
| Ghostty | *Ghostty source* |
| VTE | *VTE source* |
| foot | *foot source* |
| xterm | *xterm source* |
| Graphics, Text Sizing, and DEC Line Attributes | *kitty graphics protocol*, *kitty text sizing protocol*, *VT330/VT340 Programmer Reference Manual*, *iTerm2 inline images protocol*, *VT220 Programmer Reference Manual*, *VT510 Video Terminal Programmer Information*, *Terminal Unicode Core*, *xterm source* |
| Tile and Character Hardware | *NESdev Wiki*, *SNESdev Wiki*, *Plutiedev*, *Pan Docs*, *Commodore 64 Programmer's Reference Guide*, *The MOS 6567/6569 video controller (VIC-II)*, *Enhanced Teletext specification*, *BeebWiki MODE 7*, *ILBM IFF Interleaved Bitmap* |
| Synthesis | All of the above, and *CSS Text Decoration Module* |
