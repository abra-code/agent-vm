// Tests/TerminalUITests/TextWidthTests.swift
//
// Display widths and cutting: ASCII, combining marks, East Asian wide characters, emoji, and
// control characters made harmless.

import Testing
@testable import TerminalUI

@Suite struct TextWidthTests {
    @Test func widths() {
        #expect(TextWidth.of("abc") == 3)
        #expect(TextWidth.of("e\u{0301}") == 1)
        #expect(TextWidth.of("\u{0301}") == 0)
        #expect(TextWidth.of("\u{200B}") == 0)
        #expect(TextWidth.of("\u{65E5}\u{672C}") == 4)
        #expect(TextWidth.of("\u{AC00}") == 2)
        #expect(TextWidth.of("\u{1F600}") == 2)
        #expect(TextWidth.of("\u{1F916}") == 2)
        #expect(TextWidth.of("a\u{FE0F}") == 1)
        #expect(TextWidth.of("\u{00E9}t\u{00E9}") == 3)
    }

    @Test func cuttingAtEveryWidth() {
        let text = "abcdef"
        let expected = ["", "a", "ab", "abc", "a...", "ab...", "abcdef"]
        for width in 0...6 {
            #expect(TextWidth.cut(text, to: width) == expected[width], "width \(width)")
        }
        // Wide characters are never split; the cut text may be a column short.
        let wide = "\u{65E5}\u{672C}\u{8A9E}\u{6587}"
        let wideExpected = ["", "", "\u{65E5}", "\u{65E5}", "...", "\u{65E5}...", "\u{65E5}..."]
        for width in 0...6 {
            let cut = TextWidth.cut(wide, to: width)
            #expect(cut == wideExpected[width], "width \(width)")
            #expect(TextWidth.of(cut) <= width)
        }
        #expect(TextWidth.cut(wide, to: 8) == wide)
        // Combining marks stay with their letter.
        #expect(TextWidth.cut("e\u{0301}e\u{0301}e\u{0301}e\u{0301}e\u{0301}", to: 4) == "e\u{0301}...")
    }

    @Test func controlCharactersBecomeQuestionMarks() {
        #expect(TextWidth.printable("a\u{1B}[2Jb\nc\u{7F}\u{9B}d") == "a?[2Jb?c??d")
        #expect(TextWidth.printable("plain \u{00E9}") == "plain \u{00E9}")
        #expect(TextWidth.printable("a\u{202E}gpj.exe\u{2066}") == "a?gpj.exe?")
    }
}
