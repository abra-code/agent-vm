// Tests/AgentVMKitTests/ClipboardGateTests.swift
//
// When text a program in a box asks to put on the Mac's clipboard is taken: only while the
// person is using the session (the terminal's own answers do not count), a few requests at a
// time, as text made harmless to paste, and never as a way to read the clipboard.

import AgentVMGuestKit
import Foundation
import Testing
@testable import AgentVMKit

@Suite struct ClipboardGateTests {
    private let start = ContinuousClock.now

    private func at(_ milliseconds: Int) -> ContinuousClock.Instant {
        return start + .milliseconds(milliseconds)
    }

    private func request(_ text: String, selection: String = "c") -> [UInt8] {
        return Array("\(selection);\(Data(text.utf8).base64EncodedString())".utf8)
    }

    private func input(_ gate: ClipboardGate, _ text: String, at milliseconds: Int) {
        gate.sawInput(Array(text.utf8), at: at(milliseconds))
    }

    /// Whether a request is taken just after `text` came from the terminal.
    private func opens(_ text: String) -> Bool {
        let gate = ClipboardGate()
        input(gate, text, at: 0)
        return gate.take(request("x"), at: at(10)) == "x"
    }

    @Test func aRequestWithNobodyThereIsRefused() {
        let gate = ClipboardGate()
        #expect(gate.take(request("rm -rf ~"), at: at(0)) == nil)
        #expect(gate.refusals == 1)
        input(gate, "a", at: 1000)
        #expect(gate.take(request("x"), at: at(3000)) == "x")
        // Later than the window after the last key.
        #expect(gate.take(request("x"), at: at(3001)) == nil)
        #expect(gate.count == 1)
        #expect(gate.refusals == 2)
    }

    @Test func keysAndTheMouseAreThePerson() {
        // Text, a control key (Control-C, which copies a selection in opencode and Claude
        // Code), Return, Alt with a key, and a lone letter after Escape.
        for text in ["y", "\u{03}", "\r", "\u{1b}b", "zażółć"] {
            #expect(opens(text), "\(Array(text.utf8))")
        }
        // Arrows in both forms, Home, a function key, Shift+Tab, and the kitty keyboard
        // protocol's keys (Control+Shift+C, an arrow with its event type).
        for text in ["\u{1b}[A", "\u{1b}OA", "\u{1b}[1;5H", "\u{1b}[15~", "\u{1b}[Z", "\u{1b}[99;6u", "\u{1b}[1;1:3B"] {
            #expect(opens(text), "\(Array(text.utf8))")
        }
        // A press, a drag, a release and the wheel; and a paste.
        for text in ["\u{1b}[<0;10;5M", "\u{1b}[<32;14;5M", "\u{1b}[<0;20;5m", "\u{1b}[<64;10;5M", "\u{1b}[200~"] {
            #expect(opens(text), "\(Array(text.utf8))")
        }
    }

    @Test func whatTheTerminalTypesByItselfIsNotThePerson() {
        // Answers to questions any program may ask: the cursor's position, device attributes
        // (two kinds), status, a mode, the kitty keyboard flags, a window size, the terminal's
        // version (a DCS string), a color (an OSC string, ended either way).
        let answers = ["\u{1b}[12;40R", "\u{1b}[?62;22c", "\u{1b}[>1;95;0c", "\u{1b}[0n", "\u{1b}[?2026;2$y", "\u{1b}[?1u",
                       "\u{1b}[4;600;800t", "\u{1b}P>|iTerm2 3.5\u{1b}\\", "\u{1b}]11;rgb:0000/0000/0000\u{07}",
                       "\u{1b}]10;rgb:ffff/ffff/ffff\u{1b}\\", "\u{1b}P1+r544e=787465726d\u{1b}\\"]
        for text in answers {
            #expect(!opens(text), "\(Array(text.utf8))")
        }
        // The window got or lost focus, and the pointer moved over it with no button down.
        for text in ["\u{1b}[I", "\u{1b}[O", "\u{1b}[<35;11;5M"] {
            #expect(!opens(text), "\(Array(text.utf8))")
        }
        #expect(!opens(answers.joined()))
        // A key right after an answer counts.
        #expect(opens(answers.joined() + "c"))
    }

    @Test func anAnswerCutBetweenReadsIsStillAnAnswer() {
        // Whatever runs in the box can make its input be read slowly, in pieces far apart:
        // the rest of an answer must not read as typed text.
        for answer in ["\u{1b}[12;40R", "\u{1b}]11;rgb:0000/0000/0000\u{07}", "\u{1b}P>|term 1.0\u{1b}\\"] {
            let gate = ClipboardGate()
            for (offset, character) in answer.enumerated() {
                input(gate, String(character), at: offset * 5000)
                #expect(gate.take(request("x"), at: at(offset * 5000 + 1)) == nil)
            }
        }
        // And a key cut the same way is still a key.
        let gate = ClipboardGate()
        input(gate, "\u{1b}", at: 0)
        input(gate, "[", at: 9000)
        input(gate, "A", at: 18000)
        #expect(gate.take(request("x"), at: at(18001)) == "x")
    }

    @Test func theOldMouseReportsCountByTheirButton() {
        // "CSI M" and three bytes (no mode 1006): a press, a release, a drag and the wheel.
        for report in [[0x20, 0x21, 0x21], [0x23, 0x21, 0x21], [0x40, 0x30, 0x21], [0x60, 0x21, 0x21]] as [[UInt8]] {
            let gate = ClipboardGate()
            gate.sawInput([0x1B, 0x5B, 0x4D] + report, at: at(0))
            #expect(gate.take(request("x"), at: at(10)) == "x", "\(report)")
        }
        // The pointer moving with no button down is not the person, though its three bytes
        // look like typed text: one byte at a time, with columns and rows past 95 as two bytes
        // (mode 1005), and many in a row.
        let moves: [[UInt8]] = [[0x43, 0x21, 0x21], [0x43, 0x7E, 0x7E], [0x43, 0xC3, 0x88, 0x30], [0x43, 0xC3, 0x88, 0xC2, 0x80], [0x43, 0xFF, 0x00]]
        for report in moves {
            let gate = ClipboardGate()
            for (offset, byte) in ([0x1B, 0x5B, 0x4D] + report + [0x1B, 0x5B, 0x4D] + report).enumerated() {
                gate.sawInput([byte], at: at(offset))
                #expect(gate.take(request("x"), at: at(offset)) == nil, "\(report) \(offset)")
            }
            // A key right after it counts.
            gate.sawInput([0x61], at: at(100))
            #expect(gate.take(request("x"), at: at(101)) == "x", "\(report)")
        }
        // A press whose last byte could begin a two-byte character counts when it is read, not
        // when the next input comes (an answer the program asked for, any time later).
        let gate = ClipboardGate()
        gate.sawInput([0x1B, 0x5B, 0x4D, 0x20, 0x21, 0xC8], at: at(0))
        gate.sawInput(Array("\u{1b}[12;40R".utf8), at: at(9000))
        #expect(gate.take(request("x"), at: at(9001)) == nil)
        gate.sawInput([0x1B, 0x5B, 0x4D, 0x20, 0x21, 0xC8, 0x61], at: at(20000))
        #expect(gate.take(request("x"), at: at(20001)) == "x")
    }

    @Test func inputReadLateIsNotThePerson() {
        // Typed some time ago and read only now (the box held its input up): followed, so
        // what comes next is read right, but nobody is known to be there.
        let gate = ClipboardGate()
        gate.sawInput(Array("abc\u{1b}[A\u{1b}[<0;1;1M".utf8), at: at(0), late: true)
        #expect(gate.take(request("x"), at: at(1)) == nil)
        gate.sawInput(Array("\u{1b}[12;4".utf8), at: at(2), late: true)
        gate.sawInput(Array("0R".utf8), at: at(3))
        #expect(gate.take(request("x"), at: at(4)) == nil)
        // It does not undo a key read in time.
        gate.sawInput(Array("a".utf8), at: at(5000))
        gate.sawInput(Array("b".utf8), at: at(5001), late: true)
        #expect(gate.take(request("x"), at: at(5002)) == "x")
    }

    /// What the forwarding thread saw, for the test below.
    private final class Seen: @unchecked Sendable {
        private let lock = NSLock()
        private var reads: [(last: UInt8, late: Bool)] = []

        func add(_ bytes: [UInt8], _ late: Bool) {
            lock.lock()
            defer { lock.unlock() }
            reads.append((bytes[bytes.count - 1], late))
        }

        /// Whether the read that ended with `byte` was late, once it has come.
        func late(_ byte: UInt8) -> Bool? {
            for _ in 0..<500 {
                lock.lock()
                let found = reads.last { $0.last == byte }
                lock.unlock()
                if let found {
                    return found.late
                }
                Thread.sleep(forTimeInterval: 0.01)
            }
            return nil
        }
    }

    @Test func aKeyTypedWhileTheBoxHeldItsInputUpIsReadLate() throws {
        var pair: [Int32] = [-1, -1]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0)
        var keys: [Int32] = [-1, -1]
        #expect(pipe(&keys) == 0)
        let (typing, terminal, client) = (keys[1], keys[0], pair[0])
        // A guest that starts the program, then reads nothing until told to.
        let guest = FrameChannel(descriptor: pair[1])
        let resume = DispatchSemaphore(value: 0)
        let ended = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            defer { ended.signal() }
            _ = try? guest.receive()
            try? guest.send(.response, json: GuestResponse(ok: true, v: AgentVM.guestProtocolVersion, pid: 42))
            resume.wait()
            while let frame = try? guest.receive(), frame.type != .stdinEnd {}
        }
        let session = try ExecSession(descriptor: client, request: GuestRequest(op: .exec, argv: ["/bin/cat"]))
        defer {
            // The forwarding thread ends with the input, and the guest has read it all.
            close(typing)
            ended.wait()
            close(terminal)
            close(client)
            guest.close()
        }
        // Typed before the session began: late.
        #expect(write(typing, "t", 1) == 1)
        let seen = Seen()
        session.forwardStdin(from: terminal, observe: { bytes, late in seen.add(bytes, late) })
        #expect(seen.late(UInt8(ascii: "t")) == true)
        Thread.sleep(forTimeInterval: 0.5)
        #expect(write(typing, "a", 1) == 1)
        #expect(seen.late(UInt8(ascii: "a")) == false)
        // The terminal's answers fill the connection (the guest reads none), and then a key.
        Thread.detachNewThread {
            let answers = [UInt8](repeating: 0x1B, count: 1 << 20) + [UInt8(ascii: "k")]
            var offset = 0
            while offset < answers.count {
                let count = answers.withUnsafeBytes { write(typing, $0.baseAddress! + offset, answers.count - offset) }
                if count <= 0 {
                    return
                }
                offset += count
            }
        }
        Thread.sleep(forTimeInterval: 1)
        resume.signal()
        #expect(seen.late(UInt8(ascii: "k")) == true)
        // Nothing for a moment: what is typed now is read as it is typed.
        Thread.sleep(forTimeInterval: 0.5)
        #expect(write(typing, "z", 1) == 1)
        #expect(seen.late(UInt8(ascii: "z")) == false)
    }

    @Test func aFewRequestsAtATime() {
        let gate = ClipboardGate()
        input(gate, "\r", at: 0)
        for _ in 0..<ClipboardGate.maxPerWindow {
            #expect(gate.take(request("x"), at: at(1)) == "x")
        }
        #expect(gate.take(request("x"), at: at(2)) == nil)
        // Typing on does not allow more until the window has passed.
        input(gate, "abc", at: 1500)
        #expect(gate.take(request("x"), at: at(1501)) == nil)
        input(gate, "d", at: 2100)
        #expect(gate.take(request("y"), at: at(2101)) == "y")
        #expect(gate.count == ClipboardGate.maxPerWindow + 1)
        #expect(gate.refusals == 2)
    }

    @Test func onlyTextIsTaken() {
        let gate = ClipboardGate()
        input(gate, "\r", at: 0)
        // A question reads the clipboard; an empty request would clear it.
        #expect(gate.take(Array("c;?".utf8), at: at(1)) == nil)
        #expect(gate.take(Array("c;".utf8), at: at(1)) == nil)
        #expect(gate.take(Array("c".utf8), at: at(1)) == nil)
        #expect(gate.take(Array("c;not base64!".utf8), at: at(1)) == nil)
        // Not UTF-8.
        #expect(gate.take(Array("c;\(Data([0xFF, 0xFE, 0x41]).base64EncodedString())".utf8), at: at(1)) == nil)
        // Nothing left once it is cleaned.
        #expect(gate.take(request("\u{1b}\u{07}"), at: at(1)) == nil)
        #expect(gate.count == 0)
        // None of these is counted as a refusal: that count is of text that was not taken.
        #expect(gate.refusals == 0)
        // Padding left off, and no selection named.
        #expect(gate.take(Array(";aGk".utf8), at: at(1)) == "hi")
        #expect(gate.take(Array("c;" .utf8) + [UInt8](repeating: UInt8(ascii: "A"), count: ClipboardGate.maxRequest), at: at(1)) == nil)
    }

    @Test func controlCharactersAreTakenOut() {
        // What would act when pasted into a shell: an escape sequence, the end of a bracketed
        // paste, a backspace over what is shown, the 8-bit controls.
        #expect(ClipboardGate.sanitized("echo ok\u{1b}[201~\nrm -rf ~\n") == "echo ok[201~\nrm -rf ~\n")
        #expect(ClipboardGate.sanitized("a\u{08}b\u{00}c\u{7f}d\u{9b}e\u{85}f") == "abcdef")
        // Line ends become "\n", the last one included; tabs and everything printable stay.
        #expect(ClipboardGate.sanitized("one\r\ntwo\rthree\n\tfour\r\r\nfive\r\n") == "one\ntwo\nthree\n\tfour\n\nfive\n")
        // What makes text read differently from what it is: direction controls, characters
        // that take no room, and tag characters (a message nobody sees).
        #expect(ClipboardGate.sanitized("echo \u{202e}dab\u{202c} \u{2066}x\u{2069}") == "echo dab x")
        #expect(ClipboardGate.sanitized("pay\u{200b}pal\u{2060}.com\u{feff}") == "paypal.com")
        #expect(ClipboardGate.sanitized("ok\u{e0049}\u{e0067}\u{e006e}\u{e007f}") == "ok")
        #expect(ClipboardGate.sanitized("a\u{e0101}\u{fe01}b\u{ad}c\u{2062}d\u{180e}e\u{200e}\u{200f}\u{061c}f") == "abcdef")
        #expect(ClipboardGate.sanitized("one\u{2028}two\u{2029}") == "one\ntwo\n")
        // The emoji form of a character is chosen with a selector that stays.
        #expect(ClipboardGate.sanitized("\u{2764}\u{fe0f}") == "\u{2764}\u{fe0f}")
        // A control sequence longer than any key's is not a key.
        #expect(!opens("\u{1b}[" + String(repeating: "1;", count: 40) + "A"))
        // Joiners stay: scripts and emoji are written with them.
        #expect(ClipboardGate.sanitized("zażółć 日本語 🙂 👩\u{200d}💻 \u{0646}\u{200c}\u{0645}") == "zażółć 日本語 🙂 👩\u{200d}💻 \u{0646}\u{200c}\u{0645}")
    }

    @Test func theFilterHandsRequestsOverAndNeverPassesThem() {
        var requests: [String] = []
        let filter = TerminalOutputFilter(clipboard: { requests.append(String(decoding: $0, as: UTF8.self)) })
        let output = "a\u{1b}]52;c;aGk=\u{07}b\u{1b}]52;c;?\u{1b}\\c\u{1b}]2;title\u{07}"
        #expect(String(decoding: filter.filter(Array(output.utf8)), as: UTF8.self) == "abc\u{1b}]2;title\u{07}")
        #expect(requests == ["c;aGk=", "c;?"])
        // Longer than any other string may be, in pieces.
        let long = String(repeating: "QUJD", count: 5000)
        #expect(filter.filter(Array("\u{1b}]52;c;".utf8)).isEmpty)
        #expect(filter.filter(Array(long.utf8)).isEmpty)
        #expect(filter.filter([0x07, 0x78]) == [0x78])
        #expect(requests.last == "c;\(long)")
        // Other strings keep their limit, and so does the clipboard's with nobody to take it.
        let title = "\u{1b}]2;\(String(repeating: "t", count: 5000))\u{07}x"
        #expect(String(decoding: filter.filter(Array(title.utf8)), as: UTF8.self) == "x")
        let plain = TerminalOutputFilter()
        #expect(plain.filter(Array("\u{1b}]52;c;\(long)\u{07}x".utf8)) == [0x78])
        // Past the clipboard's own limit the request is dropped whole.
        let count = requests.count
        #expect(filter.filter(Array("\u{1b}]52;c;".utf8) + [UInt8](repeating: UInt8(ascii: "A"), count: ClipboardGate.maxRequest) + [0x07, 0x78]) == [0x78])
        #expect(requests.count == count)
    }

    @Test func theAnswerbackQuestionNeverReachesTheTerminal() {
        // ENQ: a terminal set up to answer it types plain text, which would read as typing.
        let filter = TerminalOutputFilter()
        #expect(filter.filter(Array("a\u{05}b\u{1b}[\u{05}1mc".utf8)) == Array("ab\u{1b}[1mc".utf8))
    }
}
