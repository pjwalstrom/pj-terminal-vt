# pj-terminal-vt

A minimal macOS terminal emulator built from scratch, using [libghostty-vt](https://ghostty.org/docs/vt) — the standalone VT parser library from [Ghostty](https://github.com/ghostty-org/ghostty) — for escape sequence parsing.

**This entire project was built using [GitHub Copilot CLI](https://docs.github.com/en/copilot/github-copilot-in-the-cli) in a single interactive session.** This is the companion project to [pj-terminal](https://github.com/pjwalstrom/pj-terminal), which uses the full GhosttyKit embedding framework. This project deliberately uses only the lightweight `libghostty-vt` parser library to demonstrate how much more code you need to write yourself.

## What is libghostty-vt?

As [Mitchell Hashimoto explained](https://mitchellh.com/writing/libghostty-is-coming), `libghostty-vt` is the first library in the libghostty family — a zero-dependency library (not even libc!) for parsing terminal sequences. It's extracted directly from Ghostty's battle-tested core and provides:

- **SGR parser** — parses Select Graphic Rendition sequences (bold, italic, colors including RGB, 256-color, and named colors)
- **OSC parser** — parses Operating System Commands (window title, clipboard, etc.)
- **Key encoder** — encodes key events into terminal escape sequences (supports Kitty keyboard protocol)
- **Paste safety** — validates paste data for dangerous sequences

What it deliberately does **not** provide (yet — the C API is still evolving):
- Terminal state management (screen buffer, cursor tracking, scrollback)
- PTY management (spawning shells, reading/writing)
- Rendering
- Full VT state machine (CSI cursor movement, erase, scroll)

## GhosttyKit vs libghostty-vt — what's the difference?

| Aspect | pj-terminal (GhosttyKit) | pj-terminal-vt (libghostty-vt) |
|--------|--------------------------|--------------------------------|
| **Lines of Swift** | ~280 | ~900 |
| **What the library does** | Everything: rendering, input, shell, PTY, VT parsing | Only: SGR parsing, OSC parsing, key encoding |
| **What you build** | Wire up callbacks, provide an NSView | PTY management, VT state machine, screen buffer, CoreText renderer |
| **Rendering** | Metal (GPU-accelerated, via Ghostty) | CoreText (CPU, drawn by us) |
| **Terminal fidelity** | Production-grade (is Ghostty) | Basic (handles common sequences) |
| **Binary size** | ~60 MB (static lib) | ~3.4 MB (dynamic lib) |
| **Dependencies** | Xcode, Metal, Carbon, CoreText | Just the dylib + system frameworks |

The key insight from Mitchell's blog: *"Terminal emulation is a classic problem that appears simple on the surface but is riddled with unexpected complexities and edge cases."* Building with `libghostty-vt` makes you feel this firsthand.

## Architecture

```
PJTerminalVT/
├── main.swift              # Entry point
├── PJTerminalVTApp.swift   # SwiftUI App shell
├── ContentView.swift       # Wraps TerminalView in SwiftUI
├── PTY.swift               # PTY management (posix_openpt/fork/execv)
├── TerminalBuffer.swift    # Grid of cells with cursor + scrollback
├── VTParser.swift          # VT state machine + libghostty-vt SGR/OSC
├── KeyEncoder.swift        # Key input via libghostty-vt encoder
└── TerminalView.swift      # NSView rendering with CoreText
```

### What we built ourselves vs what libghostty-vt provides

**Built from scratch** (the hard parts):
- `PTY.swift` — Pseudo-terminal management using `posix_openpt`, `grantpt`, `unlockpt`, `fork`, `execv` to spawn the user's shell
- `TerminalBuffer.swift` — A grid of cells (character + attributes), cursor position tracking, scroll region support, insert/delete lines, erase operations
- `VTParser.swift` — A full VT state machine (GROUND → ESCAPE → CSI → OSC) handling C0 controls, cursor movement (CUU/CUD/CUF/CUB), positioning (CUP), erase (ED/EL), scroll regions (DECSTBM), line operations, and UTF-8 decoding
- `TerminalView.swift` — CoreText-based rendering with per-cell background colors, font metrics, cursor blinking, and window resize handling

**Delegated to libghostty-vt** (the complex parsing):
- **SGR parsing** — `VTParser.handleSGR()` feeds CSI `m` parameters to `ghostty_sgr_set_params()` / `ghostty_sgr_next()`, getting back typed attributes (bold, italic, RGB colors, 256-color, named colors, underline styles) that we apply to our cell buffer
- **OSC parsing** — `VTParser.finishOSC()` uses `ghostty_osc_next()` / `ghostty_osc_end()` to parse window title changes
- **Key encoding** — `KeyEncoder.encode()` uses `ghostty_key_encoder_new()` / `ghostty_key_encoder_encode()` to convert NSEvent key presses into proper terminal escape sequences

## How it was built — the Copilot CLI journey

### Starting point

This project started after building [pj-terminal](https://github.com/pjwalstrom/pj-terminal) with the full GhosttyKit framework. The question was: *"What if we only use libghostty-vt — the lightweight parser — instead of the full embedding framework?"*

### 1. Research phase

Copilot CLI researched `libghostty-vt` by:
- Reading Mitchell Hashimoto's blog post about the libghostty roadmap
- Examining the C headers in `include/ghostty/vt/` (osc.h, sgr.h, key/encoder.h, key/event.h, paste.h, color.h)
- Reading all four C example programs (c-vt, c-vt-key-encode, c-vt-sgr, c-vt-paste)
- Studying the build system (`GhosttyLibVt.zig`)

Key finding: the C API currently exposes parsers for specific sequence types (SGR, OSC, key encoding), but not the full terminal state machine. We'd need to build cursor movement, erase, scroll, and screen buffer management ourselves.

### 2. Building libghostty-vt

Much simpler than GhosttyKit — no Metal compiler needed:

```bash
cd vendor/ghostty
zig build lib-vt
# Produces: zig-out/lib/libghostty-vt.dylib + headers
```

The dylib is only 3.4 MB (vs ~60 MB for GhosttyKit's static library). Zero dependencies.

### 3. Linking challenge

Swift needs a module map to import C libraries. Created `lib/include/module.modulemap`:
```
module GhosttyVT {
    header "ghostty/vt.h"
    export *
}
```

The dylib also needed its install name fixed for embedding:
```bash
install_name_tool -id @rpath/libghostty-vt.dylib lib/libghostty-vt.dylib
```

And a post-build script to copy the dylib into the app bundle's `Frameworks/` directory.

### 4. Writing 900 lines of terminal emulator

This is where `libghostty-vt` contrasts sharply with GhosttyKit. With GhosttyKit, you write ~280 lines and get a production terminal. With `libghostty-vt`, you write ~900 lines and get a basic one.

**PTY management** (`PTY.swift`): Swift marks `fork()` and `execl()` as unavailable, so we used `@_silgen_name("fork")` to access the C function directly, and `execv()` instead of the variadic `execl()`.

**VT state machine** (`VTParser.swift`): Implemented the classic DEC ANSI parser state diagram — GROUND, ESCAPE, CSI, OSC states. CSI sequences dispatch to buffer operations for cursor movement, erase, scroll regions.

**SGR via libghostty-vt** (`VTParser.handleSGR()`): This is where the library shines. Instead of manually parsing the complex SGR parameter format (which supports semicolons, colons, chained params, RGB in multiple formats), we feed params to `ghostty_sgr_set_params()` and iterate with `ghostty_sgr_next()`, getting clean typed attributes back.

**Rendering** (`TerminalView.swift`): CoreText rendering — iterate every cell in the grid, draw background color if non-default, draw character with proper font and foreground color, add underline/strikethrough decorations, draw a blinking cursor.

### 5. Build errors encountered

| Error | Cause | Fix |
|-------|-------|-----|
| `'fork()' is unavailable` | Swift disables fork() | `@_silgen_name("fork")` to call C directly |
| `'execl' is unavailable` | Swift disables variadic C functions | Use `execv()` with explicit argv array |
| `GHOSTTY_KEY_ONE` not found | Enum names differ from GhosttyKit | Changed to `GHOSTTY_KEY_DIGIT_1` etc. |
| `GHOSTTY_SGR_ATTR_DIM` not found | Attribute name differs | Changed to `GHOSTTY_SGR_ATTR_FAINT` |
| `GHOSTTY_OSC_CHANGE_WINDOW_TITLE` not found | Enum prefix differs | Changed to `GHOSTTY_OSC_COMMAND_CHANGE_WINDOW_TITLE` |
| `Library not loaded: @rpath/libghostty-vt.dylib` | Dylib not in app bundle | Copy to `Frameworks/` dir in post-build script |

### 6. Result

A working terminal that renders your shell, handles keyboard input, supports ANSI colors, cursor movement, and line editing. Not production-grade, but functional enough to use interactively.

## Prerequisites

- **macOS 14.0+** (Sonoma or later)
- **Xcode** (for xcodebuild)
- **Zig 0.15.2** — `brew install zig`
- **XcodeGen** — `brew install xcodegen`

## Building

```bash
# Clone with submodules
git clone --recurse-submodules https://github.com/pjwalstrom/pj-terminal-vt.git
cd pj-terminal-vt

# Build libghostty-vt (fast — no Metal compiler needed)
make lib

# Generate Xcode project and build
make build

# Run
make run
```

## Current limitations

- **No clipboard support** — copy/paste not implemented
- **No alternate screen** — vim/less won't display correctly
- **No mouse reporting** — mouse events not forwarded to shell
- **Basic scroll** — scroll wheel sends arrow keys (not proper scrollback)
- **CPU rendering** — CoreText, not GPU-accelerated Metal
- **macOS arm64 only**

## What this project teaches

1. **Terminal emulation is hard** — Even a basic implementation needs ~900 lines of careful state machine code
2. **SGR parsing is deceptively complex** — This is exactly where libghostty-vt earns its keep, handling RGB in multiple formats, 256-color, named colors, underline styles, etc.
3. **libghostty-vt is the right abstraction** — It solves the parsing problems you don't want to solve yourself, while leaving you in control of rendering and state management
4. **The GhosttyKit vs libghostty-vt trade-off is clear** — 280 lines for a production terminal vs 900 lines for a basic one

## Acknowledgments

- [Ghostty](https://ghostty.org/) and [libghostty-vt](https://ghostty.org/docs/vt) by Mitchell Hashimoto
- [Mitchell's blog post on libghostty](https://mitchellh.com/writing/libghostty-is-coming) — roadmap and motivation
- [awesome-libghostty](https://github.com/lawrencecchen/awesome-libghostty) — curated project list
- [pj-terminal](https://github.com/pjwalstrom/pj-terminal) — the GhosttyKit version for comparison

## License

MIT
