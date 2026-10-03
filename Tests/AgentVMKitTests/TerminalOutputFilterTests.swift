// Tests/AgentVMKitTests/TerminalOutputFilterTests.swift
//
// What a program in the box may and may not make the Mac's terminal do in a terminal session:
// drawing passes byte for byte, sequences that reach past the window are dropped whole, and
// the modes a program leaves on are turned off at the end.

import Foundation
import Testing
@testable import AgentVMKit

@Suite struct TerminalOutputFilterTests {
    private func filtered(_ text: String, in pieces: Int = 1) -> String {
        let filter = TerminalOutputFilter()
        let bytes = Array(text.utf8)
        var passed: [UInt8] = []
        let size = max(1, (bytes.count + pieces - 1) / pieces)
        var start = 0
        while start < bytes.count {
            passed += filter.filter(Array(bytes[start..<min(start + size, bytes.count)]))
            start += size
        }
        return String(decoding: passed, as: UTF8.self)
    }

    /// Byte by byte too: a sequence cut between two reads is the same sequence.
    private func expectSame(_ text: String, _ comment: Comment? = nil) {
        #expect(filtered(text) == text, comment)
        #expect(filtered(text, in: text.utf8.count) == text, comment)
    }

    private func expectDropped(_ sequence: String, _ comment: Comment? = nil) {
        #expect(filtered("a\(sequence)b") == "ab", comment)
        #expect(filtered("a\(sequence)b", in: sequence.utf8.count + 2) == "ab", comment)
    }

    @Test func drawingPassesAsItIs() {
        for text in [
            "plain text\r\n", "tab\there\u{08}\u{07}", "caf\u{e9} \u{4e2d}\u{6587} \u{1f600}",
            "\u{1b}[31mred\u{1b}[0m", "\u{1b}[38;2;10;20;30mrgb\u{1b}[m", "\u{1b}[4:3munderline\u{1b}[24m",
            "\u{1b}[2J\u{1b}[H\u{1b}[10;20H\u{1b}[K\u{1b}[1A\u{1b}[5;20r", "\u{1b}7\u{1b}8\u{1b}M\u{1b}D\u{1b}E",
            "\u{1b}[?1049h\u{1b}[?25l\u{1b}[?1000h\u{1b}[?1006h\u{1b}[?2004h", "\u{1b}[?2026h\u{1b}[?2026l",
            "\u{1b}[>1u\u{1b}[<u\u{1b}[=5;1u", "\u{1b}[2 q", "\u{1b}(0lqk\u{1b}(B", "\u{1b}#8", "\u{1b}=\u{1b}>",
            "\u{1b}[6n\u{1b}[c\u{1b}[>c\u{1b}[?u\u{1b}[?2026$p", "\u{1b}[14t\u{1b}[16t\u{1b}[18t\u{1b}[22;0t\u{1b}[23;0t",
            // Queries answered into the session: colors, settings, capabilities.
            "\u{1b}]11;?\u{07}", "\u{1b}]10;?\u{1b}\\", "\u{1b}]4;1;?;2;?\u{07}", "\u{1b}P$qm\u{1b}\\", "\u{1b}P+q544e\u{1b}\\",
            // Titles, links to web pages, prompt marks, color resets.
            "\u{1b}]0;my title\u{07}", "\u{1b}]2;caf\u{e9}\u{1b}\\", "\u{1b}]8;;https://example.com/a?b=c\u{1b}\\link\u{1b}]8;;\u{1b}\\",
            "\u{1b}]8;id=x1;http://example.com\u{07}x\u{1b}]8;;\u{07}", "\u{1b}]133;A\u{07}\u{1b}]133;D;0\u{07}", "\u{1b}]110\u{07}\u{1b}]104;1;2\u{07}",
        ] {
            expectSame(text, "\(text.debugDescription)")
        }
    }

    @Test func sequencesThatReachPastTheWindowAreDropped() {
        for sequence in [
            // The clipboard, written and read.
            "\u{1b}]52;c;ZWNobyBoaQ==\u{07}", "\u{1b}]52;c;?\u{1b}\\", "\u{1b}]52;;ZWNobw==\u{07}",
            // The folder new tabs open in; notifications; iTerm2's files, uploads and commands;
            // kitty's file transfer; font and pointer changes.
            "\u{1b}]7;file:///Users/me/\u{07}", "\u{1b}]9;Enter your password\u{07}", "\u{1b}]777;notify;title;body\u{07}",
            "\u{1b}]1337;File=name=eA==;inline=0:aGk=\u{07}", "\u{1b}]1337;RequestUpload=format=tgz\u{07}",
            "\u{1b}]1337;SetUserVar=a=Yg==\u{07}", "\u{1b}]5113;ac=send;id=x\u{1b}\\", "\u{1b}]50;font\u{07}", "\u{1b}]22;wait\u{07}",
            // Setting colors lasts past the session.
            "\u{1b}]11;#000000\u{07}", "\u{1b}]4;1;rgb:ff/00/00\u{07}", "\u{1b}]4;1;?;2;rgb:ff/00/00\u{07}",
            // Links to anything but a web page.
            "\u{1b}]8;;file:///etc/passwd\u{07}", "\u{1b}]8;;x-man-page://ls\u{07}", "\u{1b}]8;;ssh://host\u{07}",
            "\u{1b}]8;;javascript:alert(1)\u{07}", "\u{1b}]8;;https://a b\u{07}", "\u{1b}]8;;https://caf\u{e9}.com\u{07}",
            // Not a command number.
            "\u{1b}]L\u{07}", "\u{1b}];x\u{07}", "\u{1b}]\u{07}",
            // kitty graphics (which can read a file on the Mac), PM, SOS.
            "\u{1b}_Ga=T,t=f;L2V0Yy9wYXNzd2Q=\u{1b}\\", "\u{1b}^private\u{1b}\\", "\u{1b}Xstring\u{1b}\\",
            // tmux passthrough, sixel, key definitions.
            "\u{1b}Ptmux;\u{1b}\u{1b}]52;c;eA==\u{07}\u{1b}\\", "\u{1b}P0;1;0q\"1;1;2;2#0~~\u{1b}\\", "\u{1b}P1;1|17/61\u{1b}\\",
            // Window operations: move, resize, iconify, raise, the title report.
            "\u{1b}[3;0;0t", "\u{1b}[8;100;100t", "\u{1b}[2t", "\u{1b}[21t", "\u{1b}[20t", "\u{1b}[t", "\u{1b}[>2t", "\u{1b}[11t",
            // Printing.
            "\u{1b}[5i", "\u{1b}[?5i",
        ] {
            expectDropped(sequence, "\(sequence.debugDescription)")
        }
    }

    /// The 8-bit forms of CSI, OSC, DCS, APC and ST, as UTF-8 or as single bytes, and bytes
    /// that are not UTF-8: none reaches the terminal.
    @Test func eightBitControlsAndBrokenUTF8AreDropped() {
        let filter = TerminalOutputFilter()
        #expect(filter.filter([0x61, 0xC2, 0x9B, 0x32, 0x4A, 0x62]) == Array("a2Jb".utf8))
        #expect(filter.filter([0x61, 0x9D, 0x35, 0x32, 0x9C, 0x62]) == Array("a52b".utf8))
        #expect(filter.filter([0x61, 0xC2, 0x90, 0xC2, 0x9F, 0xC2, 0x9E, 0x62]) == Array("ab".utf8))
        #expect(filter.filter([0x61, 0xFF, 0xC0, 0x80, 0xE2, 0x41]) == Array("aA".utf8))
        // U+00A0 and later are text.
        #expect(filter.filter([0xC2, 0xA0, 0xC3, 0xA9]) == [0xC2, 0xA0, 0xC3, 0xA9])
        // A character cut between two reads.
        #expect(filter.filter([0xE4, 0xB8]) == [])
        #expect(filter.filter([0xAD, 0x41]) == [0xE4, 0xB8, 0xAD, 0x41])
    }

    /// Overlong forms (C1 controls among what they spell) and UTF-16 surrogates are not UTF-8:
    /// a lenient decoder could read E0 82 9B as CSI.
    @Test func overlongFormsAndSurrogatesAreDropped() {
        let filter = TerminalOutputFilter()
        #expect(filter.filter([0x61, 0xE0, 0x82, 0x9B, 0x62]) == Array("ab".utf8))
        #expect(filter.filter([0x61, 0xF0, 0x80, 0x82, 0x9D, 0x62]) == Array("ab".utf8))
        #expect(filter.filter([0x61, 0xED, 0xA0, 0x80, 0x62]) == Array("ab".utf8))
        #expect(filter.filter([0x61, 0xF4, 0x90, 0x80, 0x80, 0x62]) == Array("ab".utf8))
        // The edges that are UTF-8: U+0800, U+D7FF, U+10000, U+10FFFF.
        for valid: [UInt8] in [[0xE0, 0xA0, 0x80], [0xED, 0x9F, 0xBF], [0xF0, 0x90, 0x80, 0x80], [0xF4, 0x8F, 0xBF, 0xBF]] {
            #expect(filter.filter(valid) == valid)
        }
    }

    /// Sequences that change how the terminal reads what follows, so the filter would no
    /// longer read it the same way: screen's and tmux's window name string (ESC k, ended only
    /// by ESC, CAN or SUB in tmux), leaving UTF-8 (ESC % @), VT52 mode and Tektronix mode.
    @Test func sequencesThatChangeTheTerminalsGrammarAreDropped() {
        for sequence in ["\u{1b}kname\u{1b}\\", "\u{1b}kname\u{07}more\u{1b}\\", "\u{1b}%@", "\u{1b}%G", "\u{1b}[?2l", "\u{1b}[?1049;2l", "\u{1b}[?38h"] {
            expectDropped(sequence, "\(sequence.debugDescription)")
        }
        #expect(filtered("\u{1b}kname\u{1b}[31mred") == "\u{1b}[31mred")
        expectSame("\u{1b}[?2h\u{1b}[?38l\u{1b}(%5")
    }

    @Test func aTitleIsPlainText() {
        #expect(filtered("\u{1b}]0;a\u{08}b\u{7f}\u{202e}c\u{07}") == "\u{1b}]0;a?b??c\u{07}")
        #expect(TerminalOutputFilter().filter(Array("\u{1b}]2;x".utf8) + [0xC2, 0x9B] + Array("y\u{1b}\\".utf8)) == Array("\u{1b}]2;x?y\u{1b}\\".utf8))
        // An ESC in a title ends it, as in the terminal; what follows is read as a sequence.
        #expect(filtered("\u{1b}]0;a\u{1b}[2Jb\u{07}") == "\u{1b}[2Jb\u{07}")
        let long = String(repeating: "t", count: 300)
        #expect(filtered("\u{1b}]2;\(long)\u{07}") == "\u{1b}]2;\(String(repeating: "t", count: 256))...\u{07}")
    }

    /// A sequence never ends early in a way the terminal would not see: what follows an
    /// abandoned one is read as the terminal reads it.
    @Test func endsAndInterruptionsAreTheTerminals() {
        // ESC that is not ST abandons the string; the new sequence counts.
        #expect(filtered("\u{1b}]52;c;eA==\u{1b}[31mred") == "\u{1b}[31mred")
        // CAN and SUB abandon a sequence.
        #expect(filtered("\u{1b}]52;c;eA==\u{18}after") == "after")
        #expect(filtered("\u{1b}[31\u{1a}x") == "x")
        // BEL ends an OSC string but not a DCS or APC one.
        #expect(filtered("\u{1b}_G\u{07}still inside\u{1b}\\after") == "after")
        // A control inside CSI acts at once, as in the terminal.
        #expect(filtered("\u{1b}[3\r1m") == "\r\u{1b}[31m")
        // Too long to be real: dropped, and its end still found.
        let huge = String(repeating: "1;", count: 300)
        #expect(filtered("\u{1b}[\(huge)mafter") == "after")
        let hugeTitle = String(repeating: "t", count: 10_000)
        #expect(filtered("\u{1b}]2;\(hugeTitle)\u{07}after") == "after")
        // A string that never ends swallows the rest, as in the terminal; nothing of it passes.
        #expect(filtered("\u{1b}P0;1;0q" + String(repeating: "x", count: 100_000)) == "")
        // tmux's passthrough doubles each ESC inside it: the first one abandons the DCS, and
        // what it wrapped is read, and dropped, on its own.
        #expect(filtered("\u{1b}Ptmux;\u{1b}\u{1b}]52;c;eA==\u{07}after") == "after")
    }

    /// The end of the session turns off what the program left on, and only that.
    @Test func theResetTurnsOffWhatWasLeftOn() {
        let filter = TerminalOutputFilter()
        #expect(String(decoding: filter.resetSequence(), as: UTF8.self) == "\u{1b}[0m")
        _ = filter.filter(Array("\u{1b}[?1049h\u{1b}[?1000;1006h\u{1b}[?2004h\u{1b}[?25l\u{1b}[?1004h\u{1b}[?1004l\u{1b}=\u{1b}[>1u\u{1b}[>3u\u{1b}[<u\u{1b}[4 q\u{1b}(0\u{0e}".utf8))
        let reset = String(decoding: filter.resetSequence(), as: UTF8.self)
        // The keyboard flags were pushed on the alternate screen: popped there, before leaving it.
        #expect(reset == "\u{1b}[?1000l\u{1b}[?1006l\u{1b}[?2004l\u{1b}[<1u\u{1b}[?1049l\u{1b}[?25h\u{1b}>\u{1b}[0 q\u{1b}(B\u{0f}\u{1b}[0m")
        // Nothing twice.
        #expect(String(decoding: filter.resetSequence(), as: UTF8.self) == "\u{1b}[0m")
        // What the program turned off itself, or a full reset, needs nothing.
        _ = filter.filter(Array("\u{1b}[?1049h\u{1b}[?25l\u{1b}[?1049l\u{1b}[?25h\u{1b}(0\u{1b}(B".utf8))
        #expect(String(decoding: filter.resetSequence(), as: UTF8.self) == "\u{1b}[0m")
        _ = filter.filter(Array("\u{1b}[?1049h\u{1b}[?1002h\u{1b}c".utf8))
        #expect(String(decoding: filter.resetSequence(), as: UTF8.self) == "\u{1b}[0m")
        // A sequence cut off by the end of the session is not finished by the reset.
        _ = filter.filter(Array("\u{1b}]52;c;eA".utf8))
        #expect(String(decoding: filter.resetSequence(), as: UTF8.self) == "\u{1b}[0m")
        #expect(filter.filter(Array("==\u{07}x".utf8)) == Array("==\u{07}x".utf8))
        // Shift Out inside a sequence, and the locking shifts to G2 and G3, are shifts too;
        // a G0 set chosen with two intermediates is a changed character set.
        _ = filter.filter(Array("\u{1b}[\u{0e}m".utf8))
        #expect(String(decoding: filter.resetSequence(), as: UTF8.self) == "\u{0f}\u{1b}[0m")
        _ = filter.filter(Array("\u{1b}*0\u{1b}n".utf8))
        #expect(String(decoding: filter.resetSequence(), as: UTF8.self) == "\u{1b}(B\u{0f}\u{1b}[0m")
        _ = filter.filter(Array("\u{1b}(%0".utf8))
        #expect(String(decoding: filter.resetSequence(), as: UTF8.self) == "\u{1b}(B\u{1b}[0m")
        // xterm's modifyOtherKeys (vim turns it on), back to the terminal's own setting.
        _ = filter.filter(Array("\u{1b}[>4;2m".utf8))
        #expect(String(decoding: filter.resetSequence(), as: UTF8.self) == "\u{1b}[>4;m\u{1b}[0m")
        _ = filter.filter(Array("\u{1b}[>4;2m\u{1b}[>4;m".utf8))
        #expect(String(decoding: filter.resetSequence(), as: UTF8.self) == "\u{1b}[0m")
        _ = filter.filter(Array("\u{1b}[>4;1m\u{1b}[>4n".utf8))
        #expect(String(decoding: filter.resetSequence(), as: UTF8.self) == "\u{1b}[0m")
    }

    /// Window operations however they are spelled, the 132-column switch (which resizes the
    /// window), and the switches to 8-bit answers, which would reach the Mac's shell later.
    @Test func windowSizeAndEightBitAnswersAreNotTheBoxs() {
        for sequence in ["\u{1b}[8;100;100 t", "\u{1b}[3;0;0$t", "\u{1b}[?3h", "\u{1b}[?3l", "\u{1b}[?40h", "\u{1b}[?40;3h", "\u{1b}[?1;3h",
                         "\u{1b} G", "\u{1b}[62;0\"p", "\u{1b}[65\"p"] {
            expectDropped(sequence, "\(sequence.debugDescription)")
        }
        // Their harmless neighbors still pass.
        expectSame("\u{1b} F\u{1b}[?7l\u{1b}[?7h\u{1b}[\"q\u{1b}[!p")
    }

    @Test func theResetCoversWrapReverseVideoAndOriginMode() {
        let filter = TerminalOutputFilter()
        _ = filter.filter(Array("\u{1b}[?7l\u{1b}[?5h\u{1b}[?6h".utf8))
        #expect(String(decoding: filter.resetSequence(), as: UTF8.self) == "\u{1b}[?5l\u{1b}[?6l\u{1b}[?7h\u{1b}[0m")
        _ = filter.filter(Array("\u{1b}[?7l\u{1b}[?7h".utf8))
        #expect(String(decoding: filter.resetSequence(), as: UTF8.self) == "\u{1b}[0m")
    }

    /// kitty and Ghostty keep a stack of keyboard flags for each screen: what a program pushed
    /// on the alternate screen is popped there, and the Mac's shell keeps its own entries on
    /// the main screen.
    @Test func keyboardFlagsArePoppedOnTheirOwnScreen() {
        let filter = TerminalOutputFilter()
        _ = filter.filter(Array("\u{1b}[>1u\u{1b}[?1049h\u{1b}[>3u\u{1b}[>5u\u{1b}[<u".utf8))
        #expect(String(decoding: filter.resetSequence(), as: UTF8.self) == "\u{1b}[<1u\u{1b}[?1049l\u{1b}[<1u\u{1b}[0m")
        // Left by the program itself: the alternate screen's stack is no longer in use.
        _ = filter.filter(Array("\u{1b}[?1049h\u{1b}[>3u\u{1b}[?1049l".utf8))
        #expect(String(decoding: filter.resetSequence(), as: UTF8.self) == "\u{1b}[0m")
        // Popping more than was pushed takes nothing of the shell's.
        _ = filter.filter(Array("\u{1b}[>1u\u{1b}[<5u".utf8))
        #expect(String(decoding: filter.resetSequence(), as: UTF8.self) == "\u{1b}[0m")
    }

    @Test func linksAreWebPagesOnly() {
        #expect(TerminalOutputFilter.isSafeLink(";https://example.com"))
        #expect(TerminalOutputFilter.isSafeLink("id=1;HTTPS://EXAMPLE.COM"))
        #expect(TerminalOutputFilter.isSafeLink(";"))
        #expect(!TerminalOutputFilter.isSafeLink("https://example.com"))
        #expect(!TerminalOutputFilter.isSafeLink(";https://example.com/\u{1b}"))
        #expect(!TerminalOutputFilter.isSafeLink("a b;https://example.com"))
        #expect(!TerminalOutputFilter.isSafeLink(";https://" + String(repeating: "a", count: 2048)))
        #expect(!TerminalOutputFilter.isSafeLink(";vscode://file/etc/passwd"))
    }

    /// A program's output of a megabyte with sequences all through it is filtered quickly
    /// enough not to be noticed in a session.
    @Test func largeOutputIsQuick() {
        let filter = TerminalOutputFilter()
        let chunk = Array((String(repeating: "text \u{1b}[31mred\u{1b}[0m \u{e9}", count: 1000) + "\r\n").utf8)
        let began = ContinuousClock.now
        var total = 0
        for _ in 0..<40 {
            total += filter.filter(chunk).count
        }
        #expect(total == chunk.count * 40)
        #expect(ContinuousClock.now - began < .seconds(5))
    }
}
