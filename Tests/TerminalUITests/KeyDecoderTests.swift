// Tests/TerminalUITests/KeyDecoderTests.swift
//
// Bytes to keys: both arrow forms, modifiers, the lone Escape and its timeout, sequences that
// are not keys, UTF-8 split across reads, and the control bytes.

import Testing
@testable import TerminalUI

@Suite struct KeyDecoderTests {
    func decode(_ bytes: [UInt8], timeout: Bool = false) -> [Key] {
        var decoder = KeyDecoder()
        var keys = bytes.flatMap { decoder.feed($0) }
        if timeout {
            keys += decoder.timeout()
        }
        return keys
    }

    func decode(_ text: String, timeout: Bool = false) -> [Key] {
        return decode(Array(text.utf8), timeout: timeout)
    }

    @Test func arrowsInBothForms() {
        #expect(decode("\u{1B}[A\u{1B}[B\u{1B}[C\u{1B}[D") == [.up, .down, .right, .left])
        #expect(decode("\u{1B}OA\u{1B}OB\u{1B}OC\u{1B}OD") == [.up, .down, .right, .left])
    }

    @Test func modifiedArrowsAreArrows() {
        #expect(decode("\u{1B}[1;5A") == [.up])
        #expect(decode("\u{1B}[1;2D") == [.left])
        #expect(decode("\u{1B}[3;5~") == [.delete])
    }

    @Test func homeEndAndPagesInEveryForm() {
        #expect(decode("\u{1B}[H\u{1B}[F\u{1B}[1~\u{1B}[4~\u{1B}[7~\u{1B}[8~\u{1B}[5~\u{1B}[6~")
            == [.home, .end, .home, .end, .home, .end, .pageUp, .pageDown])
        #expect(decode("\u{1B}OH\u{1B}OF") == [.home, .end])
        #expect(decode("\u{1B}[3~") == [.delete])
    }

    @Test func aLoneEscapeNeedsTheTimeout() {
        var decoder = KeyDecoder()
        #expect(decoder.feed(0x1B) == [])
        #expect(decoder.isPending)
        #expect(decoder.timeout() == [.escape])
        #expect(!decoder.isPending)
        #expect(decoder.feed(0x61) == [.character("a")])
    }

    @Test func twoEscapes() {
        #expect(decode([0x1B, 0x1B], timeout: true) == [.escape, .escape])
        // The second ESC starts a sequence of its own.
        #expect(decode("\u{1B}\u{1B}[A") == [.escape, .up])
    }

    @Test func unknownSequencesAreDroppedWhole() {
        for sequence in ["\u{1B}[Z", "\u{1B}[I", "\u{1B}[<0;1;2M", "\u{1B}OP", "\u{1B}[?1;2c", "\u{1B}[15~", "\u{1B}[2A"] {
            #expect(decode(sequence + "x") == [.character("x")], "\(Array(sequence.utf8))")
        }
        // Alt with a letter.
        #expect(decode("\u{1B}bx") == [.character("x")])
        // An unfinished sequence is dropped at the timeout.
        #expect(decode("\u{1B}[1;", timeout: true) == [])
        // A sequence longer than any key is consumed whole.
        #expect(decode("\u{1B}[" + String(repeating: "1;", count: 40) + "Mx") == [.character("x")])
    }

    @Test func utf8SplitAcrossFeeds() {
        var decoder = KeyDecoder()
        var keys: [Key] = []
        for scalar in ["\u{00E9}", "\u{20AC}", "\u{1F600}"] {
            for byte in scalar.utf8 {
                keys += decoder.feed(byte)
            }
        }
        #expect(keys == [.character("\u{00E9}"), .character("\u{20AC}"), .character("\u{1F600}")])
    }

    @Test func invalidUTF8IsDropped() {
        #expect(decode([0xFF, 0x61]) == [.character("a")])
        #expect(decode([0xE2, 0x61, 0x62]) == [.character("a"), .character("b")])
        #expect(decode([0x80, 0xC0, 0xAF, 0x63]) == [.character("c")])
        // An overlong or surrogate form completes but is not a character.
        #expect(decode([0xE0, 0x80, 0xAF, 0xED, 0xA0, 0x80, 0x64]) == [.character("d")])
        // Unfinished at the timeout.
        #expect(decode([0xF0, 0x9F], timeout: true) == [])
    }

    @Test func controlKeys() {
        #expect(decode([0x0D, 0x0A]) == [.enter, .enter])
        #expect(decode([0x7F, 0x08]) == [.backspace, .backspace])
        #expect(decode([0x03, 0x04, 0x15, 0x17, 0x09]) == [.controlC, .controlD, .controlU, .controlW, .tab])
        #expect(decode([0x10, 0x0E]) == [.up, .down])
        #expect(decode([0x20]) == [.character(" ")])
        // Control-Z and the other control bytes do nothing.
        #expect(decode([0x1A, 0x00, 0x01, 0x07, 0x1C]) == [])
    }
}
