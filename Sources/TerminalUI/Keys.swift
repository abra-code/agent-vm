// Sources/TerminalUI/Keys.swift
//
// Bytes from a terminal in raw mode, turned into keys. Arrows and the other special keys come
// as escape sequences in two forms (CSI "ESC [" and SS3 "ESC O"); Escape itself is a lone ESC,
// told apart from the start of a sequence only by nothing following it within a short time,
// which the caller measures (`isPending`, then `timeout()`). Text arrives as UTF-8 and may be
// split across reads.

public enum Key: Equatable, Sendable {
    case up, down, left, right, home, end, pageUp, pageDown, delete
    case enter, escape, backspace, tab
    case controlC, controlD, controlU, controlW
    case character(Character)
}

struct KeyDecoder {
    /// How long a lone ESC waits for the rest of a sequence, in milliseconds. Long enough for
    /// an SSH hop to deliver an arrow's bytes together, short enough not to be noticed after
    /// Escape.
    static let escapeTimeout: Int32 = 50

    /// The longest sequence kept; longer ones (never a key) are consumed without being stored.
    private static let sequenceLimit = 32

    private enum State {
        case ground
        case escape
        case csi
        case ss3
        case utf8(needed: Int)
    }

    private var state = State.ground
    private var sequence: [UInt8] = []

    /// A lone ESC or an unfinished sequence or character is held.
    var isPending: Bool {
        if case .ground = state {
            return false
        }
        return true
    }

    mutating func feed(_ byte: UInt8) -> [Key] {
        switch state {
        case .ground:
            return ground(byte)
        case .escape:
            switch byte {
            case 0x5B:  // [
                state = .csi
                sequence = []
                return []
            case 0x4F:  // O
                state = .ss3
                sequence = []
                return []
            case 0x1B:
                // ESC ESC: the first is Escape, the second starts over.
                return [.escape]
            default:
                // Alt with a key: nothing the widgets use.
                state = .ground
                return []
            }
        case .csi, .ss3:
            return sequenceByte(byte)
        case .utf8(let needed):
            guard byte & 0xC0 == 0x80 else {
                // Not a continuation: the partial character is dropped and this byte read
                // afresh.
                state = .ground
                sequence = []
                return ground(byte)
            }
            sequence.append(byte)
            if needed > 1 {
                state = .utf8(needed: needed - 1)
                return []
            }
            state = .ground
            let bytes = sequence
            sequence = []
            guard let text = String(validating: bytes, as: UTF8.self), let character = text.first else {
                return []
            }
            return [.character(character)]
        }
    }

    /// Nothing more arrived in time: a held lone ESC is Escape; an unfinished sequence or
    /// character is dropped.
    mutating func timeout() -> [Key] {
        let wasEscape: Bool
        if case .escape = state {
            wasEscape = true
        } else {
            wasEscape = false
        }
        state = .ground
        sequence = []
        return wasEscape ? [.escape] : []
    }

    private mutating func ground(_ byte: UInt8) -> [Key] {
        switch byte {
        case 0x1B:
            state = .escape
            return []
        case 0x0D, 0x0A:
            return [.enter]
        case 0x7F, 0x08:
            return [.backspace]
        case 0x03:
            return [.controlC]
        case 0x04:
            return [.controlD]
        case 0x15:
            return [.controlU]
        case 0x17:
            return [.controlW]
        case 0x09:
            return [.tab]
        case 0x10:
            return [.up]  // Control-P
        case 0x0E:
            return [.down]  // Control-N
        case 0x20...0x7E:
            return [.character(Character(Unicode.Scalar(byte)))]
        case 0xC2...0xDF:
            state = .utf8(needed: 1)
            sequence = [byte]
            return []
        case 0xE0...0xEF:
            state = .utf8(needed: 2)
            sequence = [byte]
            return []
        case 0xF0...0xF4:
            state = .utf8(needed: 3)
            sequence = [byte]
            return []
        default:
            // Other control bytes (Control-Z too: signals from keys are off), stray
            // continuation bytes and bytes never valid in UTF-8.
            return []
        }
    }

    /// Parameters (0x30-0x3F) and intermediates (0x20-0x2F), then a final byte (0x40-0x7E)
    /// ends the sequence. Any other byte abandons it and is read afresh.
    private mutating func sequenceByte(_ byte: UInt8) -> [Key] {
        let isSS3: Bool
        if case .ss3 = state {
            isSS3 = true
        } else {
            isSS3 = false
        }
        switch byte {
        case 0x20...0x3F:
            if sequence.count < Self.sequenceLimit {
                sequence.append(byte)
            } else {
                // Too long to be a key: marked so it is dropped at its final byte.
                sequence[0] = 0x21
            }
            return []
        case 0x40...0x7E:
            let body = sequence
            state = .ground
            sequence = []
            guard let key = isSS3 ? Self.ss3Key(body, final: byte) : Self.csiKey(body, final: byte) else {
                return []
            }
            return [key]
        default:
            state = .ground
            sequence = []
            return ground(byte)
        }
    }

    /// Digits and semicolons only: the key's number and its modifiers (Control-Up is
    /// "1;5A"). A private marker ("<", "?") or an intermediate byte means a report, not a key.
    private static func parameters(_ body: [UInt8]) -> [Int]? {
        guard body.allSatisfy({ ($0 >= 0x30 && $0 <= 0x39) || $0 == 0x3B }) else {
            return nil
        }
        return String(decoding: body, as: UTF8.self).split(separator: ";", omittingEmptySubsequences: false).map { Int($0) ?? 0 }
    }

    private static func letterKey(_ final: UInt8) -> Key? {
        switch final {
        case 0x41: return .up  // A
        case 0x42: return .down  // B
        case 0x43: return .right  // C
        case 0x44: return .left  // D
        case 0x48: return .home  // H
        case 0x46: return .end  // F
        default: return nil
        }
    }

    private static func csiKey(_ body: [UInt8], final: UInt8) -> Key? {
        guard let parameters = parameters(body) else {
            return nil
        }
        if final == 0x7E {  // ~
            switch parameters.first ?? 0 {
            case 1, 7: return .home
            case 4, 8: return .end
            case 5: return .pageUp
            case 6: return .pageDown
            case 3: return .delete
            default: return nil
            }
        }
        // Plain ("A") or with modifiers ("1;5A"); nothing else is a letter key.
        guard parameters == [0] && body.isEmpty || parameters.first == 1 else {
            return nil
        }
        return letterKey(final)
    }

    private static func ss3Key(_ body: [UInt8], final: UInt8) -> Key? {
        guard parameters(body) != nil else {
            return nil
        }
        return letterKey(final)
    }
}
