// Tests/AgentVMKitTests/PrintableTests.swift
//
// Text agent-vm did not write, as it is shown: nothing in it acts on a terminal or starts a
// line of its own.

import Foundation
import Testing
@testable import AgentVMKit

@Suite struct PrintableTests {
    @Test func controlCharactersAreReplaced() {
        #expect(Printable.line("plain text, as it is") == "plain text, as it is")
        #expect(Printable.line("a\u{1B}]52;c;eA==\u{07}b") == "a?]52;c;eA==?b")
        #expect(Printable.line("a\r\u{1B}[2Kb\nc\td") == "a??[2Kb?c?d")
        // The 8-bit forms a terminal also reads as the start of a command, and DEL.
        #expect(Printable.line("a\u{9B}2J\u{9D}0;t\u{9C}\u{7F}") == "a?2J?0;t??")
        // Shown in another order than written.
        #expect(Printable.line("a\u{202E}gnp.exe\u{2066}b\u{2028}c\u{200F}d\u{061C}") == "a?gnp.exe?b?c?d?")
        #expect(Printable.line("caf\u{E9} \u{65E5}\u{672C}") == "caf\u{E9} \u{65E5}\u{672C}")
    }

    @Test func severalLinesKeepTheirLineEndsOnly() {
        #expect(Printable.lines("one\n\ttwo\r\u{1B}[1A") == "one\n\ttwo??[1A")
    }

    @Test func aLimitCutsTheRest() {
        #expect(Printable.line("abcdef", limit: 3) == "abc...")
        #expect(Printable.line("abc", limit: 3) == "abc")
        #expect(Printable.lines("a\u{1B}cdef", limit: 3) == "a?c...")
    }

    @Test func tokens() {
        for token in ["0.5.10", "26A434", "terminal-pixels", "27.0.1", "1.2.3+build_4"] {
            #expect(Printable.isToken(token), "\(token)")
        }
        for text in ["", "a b", "a\nb", "a\u{1B}", "caf\u{E9}", String(repeating: "1", count: 33)] {
            #expect(!Printable.isToken(text))
        }
    }

    @Test func anErrorIsPrintable() {
        let error = AgentVMError.guestCommandFailed(command: "network setup", status: 1, output: "one\ntwo\u{1B}]0;title\u{07}")
        #expect(!"\(error)".unicodeScalars.contains { $0.value == 0x1B || $0.value == 0x07 })
        #expect("\(error)".contains("one\ntwo?]0;title?"))
        let long = AgentVMError.guestRefused(String(repeating: "x", count: 100_000))
        #expect("\(long)".count < 9000)
    }

    @Test func oneRecordOfTheExecLogHasALimit() throws {
        let scratch = try Scratch()
        let log = ExecLog(url: scratch.root.appendingPathComponent("exec.jsonl"))
        #expect(log.append(ExecLog.Entry(id: "a", event: .start, time: Date())) == nil)
        let problem = log.append(ExecLog.Entry(id: "a", event: .notice, time: Date(), program: String(repeating: "p", count: 100_000)))
        #expect(problem != nil)
        #expect(log.records().count == 1)
    }

    /// A run with a very long command line is still listed, by the start of its arguments.
    @Test func aLongCommandLineIsRecordedByItsStart() throws {
        let scratch = try Scratch()
        let log = ExecLog(url: scratch.root.appendingPathComponent("exec.jsonl"))
        let argv = ["/bin/sh", "-c", String(repeating: "s", count: 100_000)] + Array(repeating: "more", count: 200)
        #expect(log.append(ExecLog.Entry(id: "a", event: .start, time: Date(), argv: argv, user: "agent")) == nil)
        let line = try String(contentsOf: log.url, encoding: .utf8)
        #expect(line.utf8.count < ExecLog.maxLineBytes)
        let entry = try JSONDecoder.iso8601().decode(ExecLog.Entry.self, from: Data(line.utf8))
        #expect(entry.argvCut == true)
        #expect(entry.argv?.count == 64)
        #expect(entry.argv?[2] == String(repeating: "s", count: 200) + "...")
        #expect(entry.argv?.prefix(2) == ["/bin/sh", "-c"])
        // A short one is recorded as it is.
        #expect(log.append(ExecLog.Entry(id: "b", event: .start, time: Date(), argv: ["/bin/ls"])) == nil)
        #expect(log.records().count == 2)
    }
}

private extension JSONDecoder {
    static func iso8601() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
