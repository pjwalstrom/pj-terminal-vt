import AppKit
import GhosttyVT

/// Converts NSEvent key presses into terminal escape sequences using
/// libghostty-vt's key encoder.
final class KeyEncoder {
    private var encoder: GhosttyKeyEncoder?

    init() {
        ghostty_key_encoder_new(nil, &encoder)
    }

    deinit {
        if let e = encoder { ghostty_key_encoder_free(e) }
    }

    /// Encode an NSEvent into bytes to send to the PTY.
    /// Returns nil if the event can't be encoded.
    func encode(_ event: NSEvent, action: GhosttyKeyAction = GHOSTTY_KEY_ACTION_PRESS) -> Data? {
        // For regular printable characters without control/command modifiers,
        // send characters directly — the ghostty encoder is meant for special
        // keys and kitty keyboard protocol, not basic text input.
        let significantMods = event.modifierFlags.intersection([.control, .command])
        if significantMods.isEmpty, let chars = event.characters, !chars.isEmpty,
           let first = chars.unicodeScalars.first, first.value >= 0x20 && first.value != 0x7F {
            return chars.data(using: .utf8)
        }

        // For special keys and modified keys, try ghostty encoder then fallback
        if let data = ghosttyEncode(event, action: action) {
            return data
        }
        return plainEncode(event)
    }

    /// Try encoding via the ghostty key encoder (useful for special keys).
    private func ghosttyEncode(_ event: NSEvent, action: GhosttyKeyAction) -> Data? {
        guard let encoder else { return nil }

        var keyEvent: GhosttyKeyEvent?
        guard ghostty_key_event_new(nil, &keyEvent) == GHOSTTY_SUCCESS,
              let ke = keyEvent else { return nil }
        defer { ghostty_key_event_free(ke) }

        guard let ghosttyKey = mapKeyCode(event.keyCode) else { return nil }

        ghostty_key_event_set_action(ke, action)
        ghostty_key_event_set_mods(ke, modsFromEvent(event))
        ghostty_key_event_set_key(ke, ghosttyKey)

        if let chars = event.characters, !chars.isEmpty {
            let utf8 = Array(chars.utf8)
            utf8.withUnsafeBufferPointer { buf in
                ghostty_key_event_set_utf8(ke, buf.baseAddress, buf.count)
            }
        }

        var buf = [CChar](repeating: 0, count: 128)
        var written: Int = 0
        let result = ghostty_key_encoder_encode(encoder, ke, &buf, buf.count, &written)

        if result == GHOSTTY_SUCCESS && written > 0 {
            return Data(bytes: buf, count: written)
        }
        return nil
    }

    /// Simple fallback: just send the characters as UTF-8.
    private func plainEncode(_ event: NSEvent) -> Data? {
        // Handle special keys that need escape sequences
        switch event.keyCode {
        case 36: return Data([0x0D]) // Return
        case 51: return Data([0x7F]) // Backspace
        case 53: return Data([0x1B]) // Escape
        case 48: return Data([0x09]) // Tab
        case 123: return Data([0x1B, 0x5B, 0x44]) // Left
        case 124: return Data([0x1B, 0x5B, 0x43]) // Right
        case 125: return Data([0x1B, 0x5B, 0x42]) // Down
        case 126: return Data([0x1B, 0x5B, 0x41]) // Up
        default: break
        }

        // Control key combinations
        if event.modifierFlags.contains(.control), let chars = event.charactersIgnoringModifiers {
            if let scalar = chars.unicodeScalars.first {
                let value = scalar.value
                if value >= 0x61 && value <= 0x7A { // a-z
                    return Data([UInt8(value - 0x60)])
                }
            }
        }

        // Regular characters
        if let chars = event.characters, let data = chars.data(using: .utf8) {
            return data
        }
        return nil
    }

    private func modsFromEvent(_ event: NSEvent) -> GhosttyMods {
        var mods: GhosttyMods = 0
        if event.modifierFlags.contains(.shift)   { mods |= UInt16(GHOSTTY_MODS_SHIFT) }
        if event.modifierFlags.contains(.control)  { mods |= UInt16(GHOSTTY_MODS_CTRL) }
        if event.modifierFlags.contains(.option)   { mods |= UInt16(GHOSTTY_MODS_ALT) }
        if event.modifierFlags.contains(.command)  { mods |= UInt16(GHOSTTY_MODS_SUPER) }
        if event.modifierFlags.contains(.capsLock) { mods |= UInt16(GHOSTTY_MODS_CAPS_LOCK) }
        return mods
    }

    /// Map macOS keyCode to GhosttyKey.
    private func mapKeyCode(_ keyCode: UInt16) -> GhosttyKey? {
        switch keyCode {
        case 0: return GHOSTTY_KEY_A
        case 1: return GHOSTTY_KEY_S
        case 2: return GHOSTTY_KEY_D
        case 3: return GHOSTTY_KEY_F
        case 4: return GHOSTTY_KEY_H
        case 5: return GHOSTTY_KEY_G
        case 6: return GHOSTTY_KEY_Z
        case 7: return GHOSTTY_KEY_X
        case 8: return GHOSTTY_KEY_C
        case 9: return GHOSTTY_KEY_V
        case 11: return GHOSTTY_KEY_B
        case 12: return GHOSTTY_KEY_Q
        case 13: return GHOSTTY_KEY_W
        case 14: return GHOSTTY_KEY_E
        case 15: return GHOSTTY_KEY_R
        case 16: return GHOSTTY_KEY_Y
        case 17: return GHOSTTY_KEY_T
        case 18: return GHOSTTY_KEY_DIGIT_1
        case 19: return GHOSTTY_KEY_DIGIT_2
        case 20: return GHOSTTY_KEY_DIGIT_3
        case 21: return GHOSTTY_KEY_DIGIT_4
        case 22: return GHOSTTY_KEY_DIGIT_6
        case 23: return GHOSTTY_KEY_DIGIT_5
        case 24: return GHOSTTY_KEY_EQUAL
        case 25: return GHOSTTY_KEY_DIGIT_9
        case 26: return GHOSTTY_KEY_DIGIT_7
        case 27: return GHOSTTY_KEY_MINUS
        case 28: return GHOSTTY_KEY_DIGIT_8
        case 29: return GHOSTTY_KEY_DIGIT_0
        case 30: return GHOSTTY_KEY_BRACKET_RIGHT
        case 31: return GHOSTTY_KEY_O
        case 32: return GHOSTTY_KEY_U
        case 33: return GHOSTTY_KEY_BRACKET_LEFT
        case 34: return GHOSTTY_KEY_I
        case 35: return GHOSTTY_KEY_P
        case 36: return GHOSTTY_KEY_ENTER
        case 37: return GHOSTTY_KEY_L
        case 38: return GHOSTTY_KEY_J
        case 39: return GHOSTTY_KEY_QUOTE
        case 40: return GHOSTTY_KEY_K
        case 41: return GHOSTTY_KEY_SEMICOLON
        case 42: return GHOSTTY_KEY_BACKSLASH
        case 43: return GHOSTTY_KEY_COMMA
        case 44: return GHOSTTY_KEY_SLASH
        case 45: return GHOSTTY_KEY_N
        case 46: return GHOSTTY_KEY_M
        case 47: return GHOSTTY_KEY_PERIOD
        case 48: return GHOSTTY_KEY_TAB
        case 49: return GHOSTTY_KEY_SPACE
        case 50: return GHOSTTY_KEY_BACKQUOTE
        case 51: return GHOSTTY_KEY_BACKSPACE
        case 53: return GHOSTTY_KEY_ESCAPE
        case 123: return GHOSTTY_KEY_ARROW_LEFT
        case 124: return GHOSTTY_KEY_ARROW_RIGHT
        case 125: return GHOSTTY_KEY_ARROW_DOWN
        case 126: return GHOSTTY_KEY_ARROW_UP
        default: return nil
        }
    }
}
