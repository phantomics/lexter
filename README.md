# Lexter

### Lisp-Emergent eXtensible Terminal EmulatoR

## What Lexter Is

Lexter is a GPU-accelerated pixel-font terminal emulator written in Common Lisp (SBCL). It uses OpenGL 3.3 via cl-glfw3/cl-opengl to render bitmap fonts (PCF, BDF, PBM) with integer pixel scaling. The architecture is designed around a modular pane system that supports multiple terminal protocols -- Unix VT, IBM 3270, ANSI telnet -- and custom CL application modes, all within a single window managed by a compositor.

The rendering philosophy is strictly bitmap: no vector fonts, no antialiasing, no fractional scaling. This yields a significantly simpler GPU pipeline than vector-font terminals like Alacritty or Kitty -- the fragment shader is a binary mask lookup with no blending needed for simple cells.

## Architecture Layers

**Font Loading** (`src/pcf.lisp`): Parses PCF, BDF, and PBM bitmap fonts into a `bitmap-font` struct containing pixel arrays and a codepoint-to-glyph-index encoding table. Supports multi-font fallback chains where the first font covering a codepoint wins. Cell dimensions are derived from the font's accelerator tables (fontAscent + fontDescent) for correct sizing across all PCF fonts. BDF loading supports explicit cell-size overrides for proportional-width pixel fonts like zpix.

**Glyph Atlas** (`src/atlas.lisp`): Packs all glyphs from the font chain into a single GL_R8 texture. Codepoints map to atlas column positions via a hash table. Double-wide glyphs occupy 2 adjacent atlas columns with row-boundary alignment. A `position-pixels` hash table enables texture rebuilds when cursor glyphs are added post-construction. The atlas tracks which positions are wide via `wide-set`.

**Display Grid** (`src/grid.lisp`): A flat cell array with per-row dirty tracking. Each cell stores a uint16 glyph index and uint16 swatch index. Wide characters use a `wide-flags` bit vector on the left cell and a `continuation-flags` bit vector on the right (skipped during render). Layered cells (up to 3 layers) are stored in a sparse hash table. The grid builds GPU instance buffers: 8 bytes per simple cell, 12 bytes per layered cell. The wide flag is encoded in bit 15 of the swatch index in the GPU buffer.

**Shaders** (`src/shaders.lisp`): Two shader pairs -- simple and layered. Both vertex shaders extract the wide flag from swatch bit 15 and scale the quad and UV span to 2 cell widths when set. The fragment shaders look up colors via a two-level indirection: swatch table (1D RGBA8 texture) maps to palette indices, palette UBO maps indices to RGBA colors. The palette UBO holds 4 slots (16KB total) for palette paging -- switching between pane palettes is a single `glUniform1i` call.

**Renderer** (`src/renderer.lisp`): Manages GL state, VAOs, VBOs, the swatch texture, and the palette UBO. Uploads swatch tables and palettes with generation tracking to avoid redundant GPU transfers. Simple cells render with blending disabled; layered overlay cells use SRC_ALPHA blending.

**Terminal Model** (`src/model.lisp`): Screen buffer with glyph, swatch, attribute, and wide-flag arrays. Swatch interning deduplicates color combinations. Cursor with block/underline/bar styles and blink. Scrollback ring buffer. `flush-to-display` copies model state to the display grid with cursor rendering via reverse video. All cell write operations handle wide character edge cases (overwriting half of a wide char, cursor advance by 2).

**VT Handler** (`src/vt-handler.lisp`): Parses VT100/xterm escape sequences and drives the screen model. Supports SGR color (16, 256, and truecolor), cursor movement, scrolling regions, line editing, and mode flags.

**Pane System** (`src/panes/`):
- **Protocol** (`protocol.lisp`): Base `pane` class with position, dimensions, focus, workspace back-reference, and input redirect. Generic functions for flush, key/char handling, I/O processing, resize, lifecycle. The `input-redirect` slot enables modal dialogs -- when set to a function, all key/char events are diverted to it instead of the normal handler.
- **Chrome Mixin** (`chrome-mixin.lisp`): `chrome-pane` mixin adds scroll bars, headers, and footers. Reserves columns/rows from the pane's allocated space and delegates drawing to the workspace's `decorator` function. Provides `content-width`, `content-height`, `content-row` for subclasses. Includes scroll bar geometry computation and mouse hit-testing hooks.
- **VT Pane** (`vt-pane.lisp`): Base class for VT-style terminal panes. Provides screen model, VT handler, key encoding (including Ctrl/Alt combos and function keys), and grid rendering. Subclasses implement 6 abstract I/O methods. Uses `content-width`/`content-height` for screen sizing (respecting chrome). Supports per-pane palette slots for GPU palette paging.
- **Unix Terminal Pane** (`uterm-pane.lisp`): Subclasses `vt-pane` with PTY backend.
- **Function Pane** (`function-pane.lisp`): Rendered by a user-supplied CL function. Used for status bars, custom widgets, and application UIs.
- **Workspace** (`workspace.lisp`): Named collection of panes with focus management. Supports a `decorator` function called with different modes (`:borders`, `:scroll-bar`, `:header`, `:footer`) for unified visual styling. Sets pane workspace back-references on initialization.
- **Compositor** (`compositor.lisp`): Main event loop with cursor blink, I/O polling, resize handling, palette sync, and meta-mode (prefix key for workspace/focus commands). Routes input to focused pane (with input redirect checked at the pane level via `:around` methods).

**TN3270 System** (`src/tn3270/`, `src/tn3270-pane/`): Separate ASDF systems. TCP client with IAC state machine, option negotiation, TN3270E protocol, EBCDIC codec, 3270 data stream parser, screen model with 7-color support, field attributes, and keyboard input mapping. The `tn3270-pane` subclasses `pane` directly (not `vt-pane`).

**Telnet System** (`src/telnet/`, `src/telnet-pane/`): TCP telnet client with `telnet-pane` inheriting from `vt-pane`.

**PBM Font Loader** (`src/pbm.lisp`): Loads PBM bitmap fonts with CP437-to-Unicode encoding.


## Character Overprinting (Layered Cells)

Lexter's design is radically character-oriented: all visual elements, including UI chrome like borders, scroll bars, headers, and modal dialogs, are constructed from text glyphs. To support richer terminal graphics within this paradigm, Lexter provides a 3-layer cell overprinting system.

Each cell can operate in simple mode (1 glyph, 1 swatch, blending disabled) or layered mode (up to 3 glyph layers composited per cell). A layered cell has a 4-slot swatch (bg, fg, overlay1, overlay2) and each layer references slots within it:

- **Layer 0** (base): Fully opaque. Has both ink and background colors from swatch slots. Renders like a normal cell but with explicit slot selection. `transparent-side = :none`.
- **Layer 1** (overlay): One side is transparent. With `transparent-side = :bg`, the glyph's foreground pixels (mask=1) draw in the ink color while background pixels (mask=0) are transparent, letting layer 0 show through. This overlays one glyph's shape on top of another.
- **Layer 2** (overlay): Same as layer 1, a second overlay. Composites on top of layers 0 and 1.

The `:fg` transparency mode inverts this: foreground pixels become transparent and background pixels draw in ink. This creates a "cut-out" effect where one glyph's shape is punched through another, revealing the layer beneath through the letter form.

The system is implemented efficiently: simple cells (the vast majority) use the fast path with blending disabled (8 bytes, 1 draw call). Only cells that actually use layers pay the layered cost (12 bytes per layer instance, SRC_ALPHA blending). Layered cells are stored sparsely in a hash table, not in the per-cell arrays, so memory overhead for an all-simple grid is zero.

This enables effects that are impossible with single-glyph-per-cell terminals:
- Overlaying a colored symbol on a patterned background character
- Punching letter shapes through block characters for embossed/debossed text
- Compositing box-drawing characters with text for decorative borders
- Building complex UI elements from layered glyph combinations

Combined with the decorator system and the fact that all chrome is glyph-based, this means scroll bar tracks, dialog borders, status bar separators, and window decorations are all composed from the same bitmap font glyphs the terminal text uses -- no separate "widget" rendering path exists.