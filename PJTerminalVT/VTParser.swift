import AppKit
import GhosttyVT

/// Parses VT escape sequences from PTY output, updating the terminal buffer.
/// Uses libghostty-vt's SGR parser for text attributes and OSC parser for
/// operating system commands (e.g. window title). CSI sequences for cursor
/// movement, erase, and scroll are handled directly.
final class VTParser {
    private let buffer: TerminalBuffer
    private var state: State = .ground
    private var params: [Int] = []
    private var currentParam: Int? = nil
    private var intermediates: [UInt8] = []
    private var oscPayload: [UInt8] = []
    private var privateMarker: UInt8? = nil

    private var sgrParser: GhosttySgrParser?
    private var oscParser: GhosttyOscParser?

    private enum State {
        case ground, escape, escapeIntermediate, csi, oscString
    }

    init(buffer: TerminalBuffer) {
        self.buffer = buffer
        ghostty_sgr_new(nil, &sgrParser)
        ghostty_osc_new(nil, &oscParser)
    }

    deinit {
        if let p = sgrParser { ghostty_sgr_free(p) }
        if let p = oscParser { ghostty_osc_free(p) }
    }

    /// Feed a chunk of bytes from the PTY.
    func feed(_ data: Data) {
        for byte in data {
            processByte(byte)
        }
    }

    // MARK: - State machine

    private func processByte(_ byte: UInt8) {
        // Handle C0 controls in any state
        if state != .oscString {
            switch byte {
            case 0x00: return // NUL
            case 0x07: handleBEL(); return
            case 0x08: buffer.moveCursorBackward(1); return // BS
            case 0x09: buffer.tab(); return // HT
            case 0x0A, 0x0B, 0x0C: buffer.lineFeed(); return // LF, VT, FF
            case 0x0D: buffer.carriageReturn(); return // CR
            default: break
            }
        }

        switch state {
        case .ground:
            if byte == 0x1B {
                state = .escape
            } else if byte >= 0x20 {
                putUTF8(byte)
            }

        case .escape:
            switch byte {
            case 0x5B: // [  → CSI
                state = .csi
                params = []
                currentParam = nil
                intermediates = []
                privateMarker = nil
            case 0x5D: // ]  → OSC
                state = .oscString
                oscPayload = []
                ghostty_osc_reset(oscParser)
            case 0x4D: // M  → Reverse Index
                buffer.reverseLineFeed()
                state = .ground
            case 0x37: // 7  → Save Cursor (DECSC)
                state = .ground
            case 0x38: // 8  → Restore Cursor (DECRC)
                state = .ground
            case 0x28...0x2F: // intermediate
                state = .escapeIntermediate
            default:
                state = .ground
            }

        case .escapeIntermediate:
            if byte >= 0x30 && byte <= 0x7E {
                state = .ground
            }

        case .csi:
            if byte >= 0x30 && byte <= 0x39 { // digit
                currentParam = (currentParam ?? 0) * 10 + Int(byte - 0x30)
            } else if byte == 0x3B { // ;
                params.append(currentParam ?? 0)
                currentParam = nil
            } else if byte == 0x3F || byte == 0x3E || byte == 0x21 { // ? > !
                privateMarker = byte
            } else if byte >= 0x20 && byte <= 0x2F { // intermediate
                intermediates.append(byte)
            } else if byte >= 0x40 && byte <= 0x7E { // final byte
                params.append(currentParam ?? 0)
                dispatchCSI(byte)
                state = .ground
            } else {
                state = .ground
            }

        case .oscString:
            if byte == 0x07 { // BEL terminates OSC
                finishOSC()
                state = .ground
            } else if byte == 0x1B {
                // Could be ST (\e\\) — handle in next byte
                finishOSC()
                state = .ground
            } else {
                oscPayload.append(byte)
                ghostty_osc_next(oscParser, byte)
            }
        }
    }

    // MARK: - UTF-8 decoding

    private var utf8Buffer: [UInt8] = []
    private var utf8Remaining: Int = 0

    private func putUTF8(_ byte: UInt8) {
        if utf8Remaining > 0 {
            utf8Buffer.append(byte)
            utf8Remaining -= 1
            if utf8Remaining == 0 {
                if let s = String(bytes: utf8Buffer, encoding: .utf8), let ch = s.first {
                    buffer.putChar(ch)
                }
                utf8Buffer = []
            }
        } else if byte < 0x80 {
            buffer.putChar(Character(UnicodeScalar(byte)))
        } else if byte & 0xE0 == 0xC0 {
            utf8Buffer = [byte]; utf8Remaining = 1
        } else if byte & 0xF0 == 0xE0 {
            utf8Buffer = [byte]; utf8Remaining = 2
        } else if byte & 0xF8 == 0xF0 {
            utf8Buffer = [byte]; utf8Remaining = 3
        }
    }

    // MARK: - CSI dispatch

    private func dispatchCSI(_ finalByte: UInt8) {
        let p = params
        let n = p.first.flatMap({ $0 == 0 ? 1 : $0 }) ?? 1

        if privateMarker == 0x3F { // DEC private modes (?...)
            handleDECPrivateMode(finalByte)
            return
        }

        switch finalByte {
        case 0x41: // A — Cursor Up
            buffer.moveCursorUp(n)
        case 0x42: // B — Cursor Down
            buffer.moveCursorDown(n)
        case 0x43: // C — Cursor Forward
            buffer.moveCursorForward(n)
        case 0x44: // D — Cursor Backward
            buffer.moveCursorBackward(n)
        case 0x45: // E — Cursor Next Line
            buffer.moveCursorDown(n); buffer.carriageReturn()
        case 0x46: // F — Cursor Previous Line
            buffer.moveCursorUp(n); buffer.carriageReturn()
        case 0x47: // G — Cursor Horizontal Absolute
            buffer.moveCursor(row: buffer.cursorRow, col: max(0, n - 1))
        case 0x48: // H — Cursor Position
            let row = max(1, p.count > 0 ? (p[0] == 0 ? 1 : p[0]) : 1) - 1
            let col = max(1, p.count > 1 ? (p[1] == 0 ? 1 : p[1]) : 1) - 1
            buffer.moveCursor(row: row, col: col)
        case 0x4A: // J — Erase in Display
            buffer.eraseInDisplay(p.first ?? 0)
        case 0x4B: // K — Erase in Line
            buffer.eraseLine(p.first ?? 0)
        case 0x4C: // L — Insert Lines
            buffer.insertLines(n)
        case 0x4D: // M — Delete Lines
            buffer.deleteLines(n)
        case 0x50: // P — Delete Characters
            buffer.deleteChars(n)
        case 0x58: // X — Erase Characters
            buffer.eraseChars(n)
        case 0x64: // d — Vertical Position Absolute
            buffer.moveCursor(row: max(0, n - 1), col: buffer.cursorCol)
        case 0x66: // f — Horizontal and Vertical Position (same as H)
            let row = max(1, p.count > 0 ? (p[0] == 0 ? 1 : p[0]) : 1) - 1
            let col = max(1, p.count > 1 ? (p[1] == 0 ? 1 : p[1]) : 1) - 1
            buffer.moveCursor(row: row, col: col)
        case 0x6D: // m — SGR (Select Graphic Rendition)
            handleSGR()
        case 0x72: // r — Set Scrolling Region
            let top = max(1, p.count > 0 ? (p[0] == 0 ? 1 : p[0]) : 1) - 1
            let bot = max(1, p.count > 1 ? (p[1] == 0 ? buffer.rows : p[1]) : buffer.rows) - 1
            buffer.scrollTop = top
            buffer.scrollBottom = bot
            buffer.moveCursor(row: 0, col: 0)
        default:
            break // Unhandled CSI sequence
        }
    }

    private func handleDECPrivateMode(_ finalByte: UInt8) {
        // Acknowledge but don't implement cursor visibility, alt screen, etc.
    }

    // MARK: - SGR via libghostty-vt

    private func handleSGR() {
        guard let parser = sgrParser else { fallbackSGR(); return }
        ghostty_sgr_reset(parser)

        // Build params and separators arrays for ghostty
        var gParams = params.map { UInt16($0) }
        // Separators: 0 = semicolon for all params
        var separators = [UInt8](repeating: 0, count: params.count)

        let result = ghostty_sgr_set_params(parser, &gParams, &separators, gParams.count)
        guard result == GHOSTTY_SUCCESS else { fallbackSGR(); return }

        var attr = GhosttySgrAttribute()
        while ghostty_sgr_next(parser, &attr) {
            applySGRAttribute(attr)
        }
    }

    private func applySGRAttribute(_ attr: GhosttySgrAttribute) {
        let tag = attr.tag
        let value = attr.value

        switch tag {
        case GHOSTTY_SGR_ATTR_UNSET: // Reset
            buffer.currentAttrs = CellAttributes()

        case GHOSTTY_SGR_ATTR_BOLD:
            buffer.currentAttrs.bold = true
        case GHOSTTY_SGR_ATTR_RESET_BOLD:
            buffer.currentAttrs.bold = false

        case GHOSTTY_SGR_ATTR_FAINT:
            buffer.currentAttrs.dim = true

        case GHOSTTY_SGR_ATTR_ITALIC:
            buffer.currentAttrs.italic = true
        case GHOSTTY_SGR_ATTR_RESET_ITALIC:
            buffer.currentAttrs.italic = false

        case GHOSTTY_SGR_ATTR_UNDERLINE:
            buffer.currentAttrs.underline = true
        case GHOSTTY_SGR_ATTR_RESET_UNDERLINE:
            buffer.currentAttrs.underline = false

        case GHOSTTY_SGR_ATTR_INVERSE:
            buffer.currentAttrs.inverse = true
        case GHOSTTY_SGR_ATTR_RESET_INVERSE:
            buffer.currentAttrs.inverse = false

        case GHOSTTY_SGR_ATTR_STRIKETHROUGH:
            buffer.currentAttrs.strikethrough = true
        case GHOSTTY_SGR_ATTR_RESET_STRIKETHROUGH:
            buffer.currentAttrs.strikethrough = false

        case GHOSTTY_SGR_ATTR_FG_8:
            buffer.currentAttrs.fg = namedColor(Int(value.fg_8), bold: buffer.currentAttrs.bold)
        case GHOSTTY_SGR_ATTR_BRIGHT_FG_8:
            buffer.currentAttrs.fg = namedColor(Int(value.bright_fg_8) + 8, bold: false)
        case GHOSTTY_SGR_ATTR_DIRECT_COLOR_FG:
            let c = value.direct_color_fg
            buffer.currentAttrs.fg = NSColor(red: CGFloat(c.r)/255, green: CGFloat(c.g)/255, blue: CGFloat(c.b)/255, alpha: 1)
        case GHOSTTY_SGR_ATTR_FG_256:
            buffer.currentAttrs.fg = color256(Int(value.fg_256))
        case GHOSTTY_SGR_ATTR_RESET_FG:
            buffer.currentAttrs.fg = .white

        case GHOSTTY_SGR_ATTR_BG_8:
            buffer.currentAttrs.bg = namedColor(Int(value.bg_8), bold: false)
        case GHOSTTY_SGR_ATTR_BRIGHT_BG_8:
            buffer.currentAttrs.bg = namedColor(Int(value.bright_bg_8) + 8, bold: false)
        case GHOSTTY_SGR_ATTR_DIRECT_COLOR_BG:
            let c = value.direct_color_bg
            buffer.currentAttrs.bg = NSColor(red: CGFloat(c.r)/255, green: CGFloat(c.g)/255, blue: CGFloat(c.b)/255, alpha: 1)
        case GHOSTTY_SGR_ATTR_BG_256:
            buffer.currentAttrs.bg = color256(Int(value.bg_256))
        case GHOSTTY_SGR_ATTR_RESET_BG:
            buffer.currentAttrs.bg = .black

        default:
            break
        }
    }

    /// Fallback SGR when libghostty-vt can't parse.
    private func fallbackSGR() {
        if params.isEmpty || params == [0] {
            buffer.currentAttrs = CellAttributes()
        }
    }

    // MARK: - OSC via libghostty-vt

    private func finishOSC() {
        guard let parser = oscParser else { return }
        let command = ghostty_osc_end(parser, 0)
        let type = ghostty_osc_command_type(command)

        if type == GHOSTTY_OSC_COMMAND_CHANGE_WINDOW_TITLE {
            var titlePtr: UnsafePointer<CChar>? = nil
            if ghostty_osc_command_data(command, GHOSTTY_OSC_DATA_CHANGE_WINDOW_TITLE_STR, &titlePtr) {
                if let ptr = titlePtr {
                    buffer.title = String(cString: ptr)
                }
            }
        }
    }

    private func handleBEL() {
        NSSound.beep()
    }

    // MARK: - Color helpers

    private static let ansiColors: [NSColor] = [
        NSColor(red: 0, green: 0, blue: 0, alpha: 1),           // 0 black
        NSColor(red: 0.8, green: 0, blue: 0, alpha: 1),         // 1 red
        NSColor(red: 0, green: 0.8, blue: 0, alpha: 1),         // 2 green
        NSColor(red: 0.8, green: 0.8, blue: 0, alpha: 1),       // 3 yellow
        NSColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1),     // 4 blue
        NSColor(red: 0.8, green: 0, blue: 0.8, alpha: 1),       // 5 magenta
        NSColor(red: 0, green: 0.8, blue: 0.8, alpha: 1),       // 6 cyan
        NSColor(red: 0.75, green: 0.75, blue: 0.75, alpha: 1),  // 7 white
        // Bright variants
        NSColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1),     // 8
        NSColor(red: 1, green: 0.33, blue: 0.33, alpha: 1),     // 9
        NSColor(red: 0.33, green: 1, blue: 0.33, alpha: 1),     // 10
        NSColor(red: 1, green: 1, blue: 0.33, alpha: 1),        // 11
        NSColor(red: 0.33, green: 0.56, blue: 1, alpha: 1),     // 12
        NSColor(red: 1, green: 0.33, blue: 1, alpha: 1),        // 13
        NSColor(red: 0.33, green: 1, blue: 1, alpha: 1),        // 14
        NSColor(red: 1, green: 1, blue: 1, alpha: 1),           // 15
    ]

    private func namedColor(_ idx: Int, bold: Bool) -> NSColor {
        var i = idx
        if bold && i < 8 { i += 8 }
        guard i >= 0 && i < Self.ansiColors.count else { return .white }
        return Self.ansiColors[i]
    }

    private func color256(_ idx: Int) -> NSColor {
        if idx < 16 { return Self.ansiColors[idx] }
        if idx < 232 {
            let n = idx - 16
            let r = CGFloat((n / 36) % 6) / 5.0
            let g = CGFloat((n / 6) % 6) / 5.0
            let b = CGFloat(n % 6) / 5.0
            return NSColor(red: r, green: g, blue: b, alpha: 1)
        }
        let gray = CGFloat(idx - 232) / 23.0
        return NSColor(red: gray, green: gray, blue: gray, alpha: 1)
    }
}
