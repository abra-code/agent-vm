// Sources/AgentVMKit/ClipboardGate.swift
//
// Decides whether text a program in a box asks to put on the Mac's clipboard (OSC 52, which
// TerminalOutputFilter takes out of the output) is taken. A program with a full-screen
// interface turns on mouse reports, so a drag in the terminal goes to it as input, it draws the
// selection itself, and it copies by asking the terminal: on release, on a key, or on a typed
// command, as the program likes. The gate does not guess which: it takes a request while the
// person is using the session, which is when a key or a mouse report of theirs went into the
// box within the last moments, and no more than a few requests in that time. A request that
// comes while nobody touches the session (the person is in another window, or away) is
// refused, so the clipboard does not change behind their back.
//
// The terminal also types by itself: answers to the questions a program may ask it (where the
// cursor is, which colors, which features), and reports that the window got or lost focus. A
// program in the box can ask at any time, so those are not the person and are told apart here:
// what counts is text, control keys, and the escape sequences that keys and the mouse send.
//
// What this does not show: that the text is what the person selected. The program chooses it.
// So the text is also made harmless to paste: text only, no control characters but line ends
// and tabs, nothing that hides or reorders what is read, and no larger than a limit. The Mac's
// clipboard is never read for the box.

import Foundation

public final class ClipboardGate: @unchecked Sendable {
    /// How long after the person's last key or mouse report a request is taken.
    public static let window: Duration = .seconds(2)
    /// The largest request read (base64 text), and so about three quarters of it as text.
    public static let maxRequest = 1 << 20
    /// How many requests are taken within one `window`: a program may name two selections, or
    /// ask twice.
    public static let maxPerWindow = 4
    /// The longest a key's or the mouse's control sequence is read to, between "CSI" and its
    /// last byte.
    static let maxKeySequence = 64

    private enum Input {
        case ground
        case escape
        case csi
        /// An OSC, DCS, APC, PM or SOS string: only the terminal sends those.
        case string
        case stringEscape
        /// A mouse report in the old form: "CSI M" and three characters (button, column, row).
        case mouse
    }

    private let lock = NSLock()
    private var input = Input.ground
    private var sequence: [UInt8] = []
    /// In an old-form mouse report: how many characters are still to come, the button's byte,
    /// and whether the last byte may be the first of a two-byte character (mode 1005 writes
    /// them as UTF-8).
    private var mouseLeft = 0
    private var mouseButton: UInt8?
    private var mousePair = false
    private var present: ContinuousClock.Instant?
    /// When the requests of the last `window` were taken.
    private var recent: [ContinuousClock.Instant] = []
    private var taken = 0
    private var refused = 0

    public init() {}

    /// How many requests were taken.
    public var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return taken
    }

    /// How many requests to put text on the clipboard were refused: nobody was using the
    /// session, or too many came at once. A request to read the clipboard, and one that is not
    /// text, is dropped without being counted.
    public var refusals: Int {
        lock.lock()
        defer { lock.unlock() }
        return refused
    }

    // MARK: - What the person does

    /// Bytes from the Mac's terminal on their way to the program. A sequence may be cut
    /// anywhere between two calls, and however long apart: whatever runs in the box can slow
    /// down how fast its input is read, so no part of a sequence is ever read as text because
    /// time passed. For the same reason input read `late` (ExecSession.forwardStdin: it may
    /// have been typed long before) is followed here but does not say the person is there.
    public func sawInput(_ bytes: [UInt8], at now: ContinuousClock.Instant = .now, late: Bool = false) {
        lock.lock()
        defer { lock.unlock() }
        let before = present
        defer {
            if late {
                present = before
            }
        }
        for byte in bytes {
            take(byte, at: now)
        }
    }

    private func take(_ byte: UInt8, at now: ContinuousClock.Instant) {
        switch input {
        case .ground:
            if byte == 0x1B {
                input = .escape
            } else {
                present = now
            }
        case .escape:
            escape(byte, at: now)
        case .csi:
            if (0x20...0x3F).contains(byte) {
                // One past the longest a key has: such a sequence is nobody's key.
                if sequence.count <= Self.maxKeySequence {
                    sequence.append(byte)
                }
            } else if byte == 0x1B {
                input = .escape
            } else if byte == UInt8(ascii: "M") && sequence.isEmpty {
                input = .mouse
                mouseLeft = 3
                mouseButton = nil
                mousePair = false
            } else {
                input = .ground
                if (0x40...0x7E).contains(byte), sequence.count <= Self.maxKeySequence, Self.isThePersons(sequence, final: byte) {
                    present = now
                }
            }
        case .mouse:
            mouse(byte, at: now)
        case .string:
            if byte == 0x07 {
                input = .ground
            } else if byte == 0x1B {
                input = .stringEscape
            }
        case .stringEscape:
            if byte == UInt8(ascii: "\\") {
                input = .ground
            } else {
                // Not the end of the string: a new sequence. A key that reads as the start
                // of a string (Alt with "]" or "P") is left behind at the next arrow key or
                // mouse report.
                input = .escape
                escape(byte, at: now)
            }
        }
    }

    /// The three characters after "CSI M": each a byte, or two as UTF-8 (mode 1005, for columns
    /// and rows past 95). They are not text; the report counts by its button, as in
    /// `isThePersons`, and at its third character: what comes after it, whenever that is, may
    /// be the terminal's. An ESC is never one of them and starts a new sequence.
    private func mouse(_ byte: UInt8, at now: ContinuousClock.Instant) {
        if byte == 0x1B {
            input = .escape
            return
        }
        if mousePair {
            mousePair = false
            if (0x80...0xBF).contains(byte) {
                if mouseLeft == 0 {
                    input = .ground
                }
                return
            }
            if mouseLeft == 0 {
                // The report ended with the byte before: this one is what comes next.
                input = .ground
                take(byte, at: now)
                return
            }
        }
        mousePair = (0xC2...0xDF).contains(byte)
        if mouseLeft == 3 {
            // A button past 95 (two bytes) is none a person's hand has: not counted.
            mouseButton = mousePair ? nil : byte
        }
        mouseLeft -= 1
        guard mouseLeft == 0 else {
            return
        }
        if !mousePair {
            input = .ground
        }
        // The button is sent with 32 added. The pointer moving with no button down (32 and
        // all of the low two bits) is not somebody at work.
        if let mouseButton, mouseButton >= 32 {
            let button = Int(mouseButton) - 32
            if !(button & 32 != 0 && button & 3 == 3) {
                present = now
            }
        }
    }

    private func escape(_ byte: UInt8, at now: ContinuousClock.Instant) {
        switch byte {
        case UInt8(ascii: "["):
            input = .csi
            sequence.removeAll(keepingCapacity: true)
        case UInt8(ascii: "]"), UInt8(ascii: "P"), UInt8(ascii: "X"), UInt8(ascii: "^"), UInt8(ascii: "_"):
            input = .string
        case 0x1B:
            break
        default:
            // Alt with a key, or a function or arrow key's "ESC O" form.
            input = .ground
            present = now
        }
    }

    /// Whether a control sequence is one a key or the mouse sends. The terminal's own answers
    /// and reports are not: a cursor position ("R", which a modified F3 also is), device
    /// attributes ("c"), status ("n"), modes ("$y"), window sizes ("t"), focus ("I", "O"), and
    /// everything with a "?", ">" or "=" before its numbers.
    static func isThePersons(_ sequence: [UInt8], final: UInt8) -> Bool {
        if sequence.first == UInt8(ascii: "<") {
            // A mouse report in the SGR form (mode 1006): "<button;x;y". The pointer moving
            // with no button down (32 and all of the low two bits) is not somebody at work.
            guard final == UInt8(ascii: "M") || final == UInt8(ascii: "m") else {
                return false
            }
            let fields = sequence.dropFirst().split(separator: UInt8(ascii: ";"), omittingEmptySubsequences: false)
            guard fields.count == 3, let button = Int(String(decoding: fields[0], as: UTF8.self)), button >= 0 else {
                return false
            }
            return !(button & 32 != 0 && button & 3 == 3)
        }
        // Numbers only, as keys have them (":" is in the kitty keyboard protocol's).
        guard sequence.allSatisfy({ (0x30...0x3B).contains($0) }) else {
            return false
        }
        // Function, editing and pasting keys ("~"), the kitty protocol's keys ("u"), arrows,
        // Home and End, F1, F2 and F4 with a modifier, and Shift+Tab.
        return "~uABCDEFHPQSZ".utf8.contains(final)
    }

    // MARK: - What the program asks

    /// The text to put on the Mac's clipboard for an OSC 52 request (`body` is what follows
    /// "52;": the selections named, ";", and the text in base64), or nil: nobody was using the
    /// session, too many requests came at once, it asks to read the clipboard ("?"), or it is
    /// not text.
    public func take(_ body: [UInt8], at now: ContinuousClock.Instant = .now) -> String? {
        guard let text = Self.text(body) else {
            return nil
        }
        lock.lock()
        defer { lock.unlock() }
        recent.removeAll { now - $0 > Self.window }
        guard let present, now - present <= Self.window, recent.count < Self.maxPerWindow else {
            refused += 1
            return nil
        }
        recent.append(now)
        taken += 1
        return text
    }

    /// The text of a request, made harmless to paste; nil when it is a question, not base64,
    /// not UTF-8, or empty.
    static func text(_ body: [UInt8]) -> String? {
        guard body.count <= maxRequest, let separator = body.firstIndex(of: UInt8(ascii: ";")) else {
            return nil
        }
        var encoded = String(decoding: body[(separator + 1)...], as: UTF8.self)
        // Programs leave the padding off.
        while encoded.utf8.count % 4 != 0 {
            encoded.append("=")
        }
        guard let data = Data(base64Encoded: encoded), let decoded = String(data: data, encoding: .utf8) else {
            return nil
        }
        let text = sanitized(decoded)
        return text.isEmpty ? nil : text
    }

    /// Line ends as "\n", tabs kept, every other control character taken out (C0, DEL and C1):
    /// pasted into a shell, an escape sequence or the end of a bracketed paste acts. What makes
    /// text read differently from what it is goes too: the characters that change the direction
    /// text is shown in (embeddings, overrides, isolates and the direction marks), the ones that
    /// take no room (soft hyphen, zero width space, word joiner, the invisible operators, the
    /// Mongolian vowel separator, byte order mark), and the tag characters and variation
    /// selectors, which are not shown at all and can carry a whole hidden message. The line and
    /// paragraph separators become line ends. The joiners U+200C and U+200D stay (scripts and
    /// emoji are written with them), and so do the two selectors that choose between a
    /// character's text and emoji forms (U+FE0E, U+FE0F).
    static func sanitized(_ text: String) -> String {
        var result = String.UnicodeScalarView()
        var afterReturn = false
        for scalar in text.unicodeScalars {
            let wasReturn = afterReturn
            afterReturn = false
            switch scalar.value {
            case 0x0D:
                result.append("\n")
                afterReturn = true
            case 0x0A:
                if !wasReturn {
                    result.append("\n")
                }
            case 0x2028, 0x2029:
                result.append("\n")
            case 0x09:
                result.append(scalar)
            case 0x00..<0x20, 0x7F...0x9F, 0xAD, 0x061C, 0x180E, 0x200B, 0x200E, 0x200F, 0x202A...0x202E, 0x2060...0x2064,
                 0x2066...0x2069, 0xFE00...0xFE0D, 0xFEFF, 0xE0000...0xE007F, 0xE0100...0xE01EF:
                break
            default:
                result.append(scalar)
            }
        }
        return String(result)
    }
}
