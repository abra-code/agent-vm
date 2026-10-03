// Sources/AgentVMKit/TerminalOutputFilter.swift
//
// What a program in the box prints in a terminal session (`exec --tty`, `box shell`) goes to the
// Mac's terminal, which acts on escape sequences as well as showing text. Most sequences only
// draw: cursor moves, colors, erasing, the alternate screen. Others reach past the window: they
// write or read the Mac's clipboard (OSC 52), save or upload files (iTerm2's OSC 1337, kitty's
// graphics with a file path), tell the terminal which folder new tabs open in (OSC 7), show
// notifications, make links to any URL scheme (OSC 8), pass anything on to an outer terminal
// (tmux's passthrough), or move and resize the window. This filter passes what draws, and
// queries whose answers the terminal types back into the session, and drops the rest whole.
// It also remembers the modes a program turned on (mouse reporting, bracketed paste, the
// alternate screen, a hidden cursor, the kitty keyboard flags, xterm's modifyOtherKeys) for
// `resetSequence`, written when the session ends: a program killed with them on would leave
// the Mac's shell unusable.
//
// The filter is a byte stream parser after the DEC terminal parser that xterm and its
// successors follow: a sequence is kept until its last byte and then passed or dropped as a
// whole, so the terminal never sees half of one. The 8-bit forms (C1 controls, U+0080 to
// U+009F) are dropped, and so is anything that is not UTF-8.

import Foundation

public final class TerminalOutputFilter: @unchecked Sendable {
    private enum State {
        case ground
        case escape
        /// ESC followed by intermediate bytes (charset selection, ESC # 8).
        case escapeIntermediate
        case csi
        /// A string: OSC, DCS, or SOS, PM and APC (always dropped).
        case string(StringKind)
    }

    private enum StringKind {
        case osc
        case dcs
        case other
    }

    private let lock = NSLock()
    private var state: State = .ground
    /// The sequence being read, without its introducer.
    private var sequence: [UInt8] = []
    /// The sequence grew past its limit: the rest of it is read and dropped.
    private var discarding = false
    /// In a string, the last byte was ESC: a backslash ends the string, anything else
    /// abandons it.
    private var stringEscape = false
    /// A UTF-8 character that is not complete yet, and how many bytes it still needs.
    private var pending: [UInt8] = []
    private var pendingNeeded = 0
    /// What the next byte of that character may be: narrower than 80 to BF right after E0,
    /// ED, F0 and F4, so overlong forms, surrogates and code points past U+10FFFF are dropped.
    private var pendingNext: ClosedRange<UInt8> = 0x80...0xBF

    // What a program turned on, for `resetSequence`.
    private var modes: Set<Int> = []
    private var cursorHidden = false
    private var autowrapOff = false
    private var keypadApplication = false
    /// kitty keyboard flags pushed, counted per screen: the main and alternate screens have a
    /// stack each (kitty, Ghostty).
    private var keyboardPushes = 0
    private var alternateKeyboardPushes = 0
    private var otherKeysModified = false
    private var cursorShapeSet = false
    private var charsetChanged = false
    private var shiftedOut = false

    /// The longest CSI sequence, and the longest OSC or DCS string, that is passed.
    static let maxControl = 256
    static let maxString = 4096

    /// DEC private modes that `resetSequence` turns off when a program left them on: cursor
    /// keys, reverse video, origin mode, the mouse reports, focus events, bracketed paste,
    /// synchronized output, and the alternate screens (last, so the others are reset on the
    /// screen the shell comes back to).
    static let resettableModes: [Int] = [1, 5, 6, 9, 1000, 1001, 1002, 1003, 1004, 1005, 1006, 1015, 1016, 2004, 2026] + alternateScreens
    static let alternateScreens = [47, 1047, 1049]

    private var onAlternateScreen: Bool {
        return Self.alternateScreens.contains { modes.contains($0) }
    }

    public init() {}

    /// The bytes of `output` that may reach the Mac's terminal. A sequence cut by the end of
    /// `output` is kept for the next call.
    public func filter(_ output: [UInt8]) -> [UInt8] {
        lock.lock()
        defer { lock.unlock() }
        var passed: [UInt8] = []
        passed.reserveCapacity(output.count)
        for byte in output {
            take(byte, into: &passed)
        }
        return passed
    }

    /// What turns off the modes the session left on, and the colors and character set; empty
    /// before any output. Afterwards the filter starts over: a second call adds only the
    /// colors' reset.
    public func resetSequence() -> [UInt8] {
        lock.lock()
        defer { lock.unlock() }
        var reset = ""
        for mode in Self.resettableModes where modes.contains(mode) {
            if Self.alternateScreens.contains(mode), alternateKeyboardPushes > 0 {
                // The alternate screen's own stack, while it is the current one.
                reset += "\u{1b}[<\(alternateKeyboardPushes)u"
                alternateKeyboardPushes = 0
            }
            reset += "\u{1b}[?\(mode)l"
        }
        if cursorHidden {
            reset += "\u{1b}[?25h"
        }
        if autowrapOff {
            reset += "\u{1b}[?7h"
        }
        if keypadApplication {
            reset += "\u{1b}>"
        }
        if keyboardPushes > 0 {
            reset += "\u{1b}[<\(keyboardPushes)u"
        }
        if otherKeysModified {
            // No value: the terminal's own setting, as vim leaves it.
            reset += "\u{1b}[>4;m"
        }
        if cursorShapeSet {
            reset += "\u{1b}[0 q"
        }
        if charsetChanged {
            reset += "\u{1b}(B"
        }
        if shiftedOut {
            reset += "\u{0f}"
        }
        reset += "\u{1b}[0m"
        forgetModes()
        state = .ground
        sequence.removeAll()
        pending.removeAll()
        pendingNeeded = 0
        return Array(reset.utf8)
    }

    private func forgetModes() {
        modes.removeAll()
        cursorHidden = false
        autowrapOff = false
        keypadApplication = false
        keyboardPushes = 0
        alternateKeyboardPushes = 0
        otherKeysModified = false
        cursorShapeSet = false
        charsetChanged = false
        shiftedOut = false
    }

    // MARK: - The parser

    private func take(_ byte: UInt8, into passed: inout [UInt8]) {
        switch state {
        case .ground:
            ground(byte, into: &passed)
        case .escape:
            escape(byte, into: &passed)
        case .escapeIntermediate:
            escapeIntermediate(byte, into: &passed)
        case .csi:
            csi(byte, into: &passed)
        case let .string(kind):
            string(byte, kind: kind, into: &passed)
        }
    }

    private func ground(_ byte: UInt8, into passed: inout [UInt8]) {
        if pendingNeeded > 0 {
            if pendingNext.contains(byte) {
                pending.append(byte)
                pendingNeeded -= 1
                pendingNext = 0x80...0xBF
                if pendingNeeded == 0 {
                    // U+0080 to U+009F, the C1 controls, are C2 80 to C2 9F.
                    if !(pending[0] == 0xC2 && pending[1] <= 0x9F) {
                        passed += pending
                    }
                    pending.removeAll()
                }
                return
            }
            // Not UTF-8: the bytes so far are dropped, and this one is read afresh.
            pending.removeAll()
            pendingNeeded = 0
        }
        switch byte {
        case 0x1B:
            state = .escape
        case 0x00..<0x20:
            control(byte, into: &passed)
        case 0x20..<0x80:
            passed.append(byte)
        case 0xC2...0xF4:
            pending = [byte]
            pendingNeeded = byte < 0xE0 ? 1 : byte < 0xF0 ? 2 : 3
            switch byte {
            case 0xE0:
                pendingNext = 0xA0...0xBF
            case 0xED:
                pendingNext = 0x80...0x9F
            case 0xF0:
                pendingNext = 0x90...0xBF
            case 0xF4:
                pendingNext = 0x80...0x8F
            default:
                pendingNext = 0x80...0xBF
            }
        default:
            // A continuation byte with no start, or a byte UTF-8 never has (C1 controls among them).
            break
        }
    }

    /// A C0 control other than ESC, CAN and SUB: it acts at once, in a sequence too, as in the
    /// terminal. Shift Out and Shift In choose the character set the text is drawn in.
    private func control(_ byte: UInt8, into passed: inout [UInt8]) {
        if byte == 0x0E {
            shiftedOut = true
        } else if byte == 0x0F {
            shiftedOut = false
        }
        passed.append(byte)
    }

    private func escape(_ byte: UInt8, into passed: inout [UInt8]) {
        switch byte {
        case UInt8(ascii: "["):
            begin(.csi)
        case UInt8(ascii: "]"):
            begin(.string(.osc))
        case UInt8(ascii: "P"):
            begin(.string(.dcs))
        case UInt8(ascii: "X"), UInt8(ascii: "^"), UInt8(ascii: "_"), UInt8(ascii: "k"):
            // SOS, PM and APC: kitty's graphics (which can read a file on the Mac) are APC.
            // ESC k is screen's and tmux's window name, a string up to the next ESC there.
            begin(.string(.other))
            discarding = true
        case 0x20...0x2F:
            begin(.escapeIntermediate)
            sequence = [byte]
        case 0x30...0x7E:
            switch byte {
            case UInt8(ascii: "="):
                keypadApplication = true
            case UInt8(ascii: ">"):
                keypadApplication = false
            case UInt8(ascii: "n"), UInt8(ascii: "o"):
                // Locking shifts to G2 and G3: Shift In undoes them.
                shiftedOut = true
            case UInt8(ascii: "c"):
                // A full reset: the terminal turns everything off itself.
                forgetModes()
            case UInt8(ascii: "\\"):
                // ST with no string to end: nothing to pass.
                state = .ground
                return
            default:
                break
            }
            passed += [0x1B, byte]
            state = .ground
        case 0x1B:
            break
        case 0x18, 0x1A:
            state = .ground
        case 0x00..<0x20:
            // A control inside a sequence acts at once, as in the terminal.
            control(byte, into: &passed)
        default:
            state = .ground
        }
    }

    private func escapeIntermediate(_ byte: UInt8, into passed: inout [UInt8]) {
        switch byte {
        case 0x20...0x2F:
            if sequence.count < 4 {
                sequence.append(byte)
            } else {
                discarding = true
            }
        case 0x30...0x7E:
            // ESC % chooses the encoding: out of UTF-8 (ESC % @ in xterm), what this filter
            // passes as text could be read as 8-bit controls.
            // ESC SP G (S8C1T) makes the terminal answer with 8-bit controls, also to the Mac's
            // shell after the session.
            if !discarding && sequence.first != UInt8(ascii: "%") && !(sequence == [0x20] && byte == UInt8(ascii: "G")) {
                // ESC ( 0 and the like change the character set; ESC ( B is the usual one.
                if sequence.first == UInt8(ascii: "(") {
                    charsetChanged = sequence.count > 1 || byte != UInt8(ascii: "B")
                } else if [UInt8(ascii: ")"), UInt8(ascii: "*"), UInt8(ascii: "+")].contains(sequence.first ?? 0) {
                    charsetChanged = true
                }
                passed += [0x1B] + sequence + [byte]
            }
            state = .ground
        case 0x1B:
            begin(.escape)
        case 0x18, 0x1A:
            state = .ground
        case 0x00..<0x20:
            control(byte, into: &passed)
        default:
            state = .ground
        }
    }

    private func csi(_ byte: UInt8, into passed: inout [UInt8]) {
        switch byte {
        case 0x20...0x3F:
            if sequence.count < Self.maxControl {
                sequence.append(byte)
            } else {
                discarding = true
            }
        case 0x40...0x7E:
            if !discarding, let kept = controlSequence(sequence, final: byte) {
                passed += [0x1B, UInt8(ascii: "[")] + kept + [byte]
            }
            state = .ground
        case 0x1B:
            begin(.escape)
        case 0x18, 0x1A:
            state = .ground
        case 0x7F:
            break
        case 0x00..<0x20:
            control(byte, into: &passed)
        default:
            state = .ground
        }
    }

    private func string(_ byte: UInt8, kind: StringKind, into passed: inout [UInt8]) {
        if stringEscape {
            stringEscape = false
            if byte == UInt8(ascii: "\\") {
                finish(kind, bell: false, into: &passed)
                return
            }
            // ESC and anything else abandons the string and starts a new sequence.
            begin(.escape)
            escape(byte, into: &passed)
            return
        }
        switch byte {
        case 0x1B:
            stringEscape = true
        case 0x07 where kind == .osc:
            finish(kind, bell: true, into: &passed)
        case 0x18, 0x1A:
            state = .ground
        default:
            if discarding {
                return
            }
            if sequence.count < Self.maxString {
                sequence.append(byte)
            } else {
                discarding = true
            }
        }
    }

    private func begin(_ next: State) {
        state = next
        sequence.removeAll()
        discarding = false
        stringEscape = false
    }

    private func finish(_ kind: StringKind, bell: Bool, into passed: inout [UInt8]) {
        defer { state = .ground }
        guard !discarding else {
            return
        }
        switch kind {
        case .osc:
            if let kept = operatingSystemCommand(sequence) {
                passed += [0x1B, UInt8(ascii: "]")] + kept + (bell ? [0x07] : [0x1B, UInt8(ascii: "\\")])
            }
        case .dcs:
            if Self.isQueryString(sequence) {
                passed += [0x1B, UInt8(ascii: "P")] + sequence + [0x1B, UInt8(ascii: "\\")]
            }
        case .other:
            break
        }
    }

    // MARK: - Which sequences pass

    /// A CSI sequence's parameters and intermediates, as passed, or nil to drop it.
    private func controlSequence(_ body: [UInt8], final: UInt8) -> [UInt8]? {
        let marker = body.first.flatMap { (0x3C...0x3F).contains($0) ? $0 : nil }
        let intermediates = body.filter { (0x20...0x2F).contains($0) }
        let parameters = String(decoding: body.filter { (0x30...0x3B).contains($0) }, as: UTF8.self)
        let numbers = parameters.split(separator: ";", omittingEmptySubsequences: false).map { Int($0.split(separator: ":").first ?? "") }
        switch (final, marker) {
        case (UInt8(ascii: "t"), nil) where intermediates.isEmpty:
            // Window operations: only the size reports (programs that draw images use them)
            // and saving and restoring the title. Moving, resizing, raising or iconifying the
            // window is not the box's to do, and the title report types the title back.
            return [14, 16, 18, 19, 22, 23].contains(numbers.first ?? 0) ? body : nil
        case (UInt8(ascii: "t"), _):
            // With a marker or an intermediate: none of them is needed, and a terminal that
            // reads one as a window operation must not get it.
            return nil
        case (UInt8(ascii: "p"), nil) where intermediates == [UInt8(ascii: "\"")]:
            // DECSCL, the conformance level: it can switch the terminal's answers to 8-bit controls.
            return nil
        case (UInt8(ascii: "i"), _):
            // Media copy: printing.
            return nil
        case (UInt8(ascii: "h"), UInt8(ascii: "?")), (UInt8(ascii: "l"), UInt8(ascii: "?")):
            let on = final == UInt8(ascii: "h")
            // VT52 mode (mode 2 off) and Tektronix mode (38 on) read what follows by other
            // rules than this filter's.
            // 132 columns (3, and 40 that allows it) resizes the window.
            if numbers.contains(on ? 38 : 2) || numbers.contains(3) || numbers.contains(40) {
                return nil
            }
            if intermediates.isEmpty {
                for case let mode? in numbers {
                    if mode == 25 {
                        cursorHidden = !on
                    } else if mode == 7 {
                        autowrapOff = !on
                    } else if Self.resettableModes.contains(mode) {
                        if on {
                            modes.insert(mode)
                        } else {
                            if Self.alternateScreens.contains(mode) {
                                // Back on the main screen, whose stack is the one in use.
                                alternateKeyboardPushes = 0
                            }
                            modes.remove(mode)
                        }
                    }
                }
            }
            return body
        case (UInt8(ascii: "u"), UInt8(ascii: ">")) where intermediates.isEmpty:
            if onAlternateScreen {
                alternateKeyboardPushes += 1
            } else {
                keyboardPushes += 1
            }
            return body
        case (UInt8(ascii: "u"), UInt8(ascii: "<")) where intermediates.isEmpty:
            let count = max(1, (numbers.first ?? 1) ?? 1)
            if onAlternateScreen {
                alternateKeyboardPushes = max(0, alternateKeyboardPushes - count)
            } else {
                keyboardPushes = max(0, keyboardPushes - count)
            }
            return body
        case (UInt8(ascii: "m"), UInt8(ascii: ">")) where intermediates.isEmpty:
            // xterm's key modifier settings; 4 is modifyOtherKeys, and no number resets them all.
            let resource = numbers.first ?? nil
            if resource == 4 {
                otherKeysModified = numbers.count > 1 && (numbers[1] ?? 0) > 0
            } else if resource == nil {
                otherKeysModified = false
            }
            return body
        case (UInt8(ascii: "n"), UInt8(ascii: ">")) where intermediates.isEmpty:
            if [4, nil].contains(numbers.first ?? nil) {
                otherKeysModified = false
            }
            return body
        case (UInt8(ascii: "q"), nil) where intermediates == [0x20]:
            cursorShapeSet = true
            return body
        default:
            return body
        }
    }

    /// An OSC string's text, as passed, or nil to drop it.
    private func operatingSystemCommand(_ body: [UInt8]) -> [UInt8]? {
        let text = String(decoding: body, as: UTF8.self)
        let parts = text.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)
        let command = String(parts[0])
        let rest = parts.count > 1 ? String(parts[1]) : ""
        guard !command.isEmpty, command.allSatisfy({ $0.isASCII && $0.isNumber }) else {
            return nil
        }
        switch command {
        case "0", "1", "2":
            // The window and tab titles, as one line of plain text.
            return Array("\(command);\(Printable.line(rest, limit: 256))".utf8)
        case "8":
            return Self.isSafeLink(rest) ? body : nil
        case "4":
            // Color queries only ("4;1;?"): setting the palette lasts past the session.
            let fields = rest.split(separator: ";", omittingEmptySubsequences: false)
            let queries = fields.count >= 2 && fields.count % 2 == 0 && stride(from: 0, to: fields.count, by: 2).allSatisfy { index in
                Int(fields[index]) != nil && fields[index + 1] == "?"
            }
            return queries ? body : nil
        case "10", "11", "12", "17", "19":
            // The foreground, background, cursor and selection colors, asked for (programs
            // choose a light or dark theme by the answer), never set.
            return !rest.isEmpty && rest.split(separator: ";", omittingEmptySubsequences: false).allSatisfy({ $0 == "?" }) ? body : nil
        case "104", "110", "111", "112", "117", "119":
            // Back to the terminal's own colors.
            return rest.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == ";") }) ? body : nil
        case "133":
            // Prompt marks (shell integration): jumping between prompts in the terminal.
            return rest.utf8.count <= Self.maxControl && rest.utf8.allSatisfy({ (0x20...0x7E).contains($0) }) ? body : nil
        default:
            // The clipboard (52), the working folder (7), notifications (9, 777), iTerm2's
            // files and commands (1337), kitty's file transfer (5113), fonts and pointers, and
            // whatever else a terminal may add.
            return nil
        }
    }

    /// An OSC 8 hyperlink's "params;URI": a link to a web page, or the end of a link.
    static func isSafeLink(_ text: String) -> Bool {
        let parts = text.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else {
            return false
        }
        let parameters = parts[0].utf8
        let target = parts[1]
        guard parameters.count <= Self.maxControl, parameters.allSatisfy({ (0x21...0x7E).contains($0) }) else {
            return false
        }
        if target.isEmpty {
            return true
        }
        // A URL scheme opens whatever app claims it on the Mac, and a file URL a file on it:
        // only web pages, written plainly.
        let lowered = target.lowercased()
        return (lowered.hasPrefix("https://") || lowered.hasPrefix("http://")) && target.utf8.count <= 2048
            && target.utf8.allSatisfy { (0x21...0x7E).contains($0) }
    }

    /// DECRQSS ("$q") and XTGETTCAP ("+q"): questions about the terminal's settings and
    /// capabilities, answered into the session. Any other DCS is dropped: sixel images, tmux's
    /// passthrough (which hands anything to the terminal outside tmux), ReGIS, key definitions.
    static func isQueryString(_ body: [UInt8]) -> Bool {
        guard body.count >= 2, body.count <= maxControl * 4, [UInt8(ascii: "$"), UInt8(ascii: "+")].contains(body[0]), body[1] == UInt8(ascii: "q") else {
            return false
        }
        return body.allSatisfy { (0x20...0x7E).contains($0) }
    }
}
