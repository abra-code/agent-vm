// Tests/TerminalUITests/PseudoTerminalTests.swift
//
// The widgets on a real pseudo-terminal: keys written to its master side reach the widget, the
// frames drawn come back, and the terminal's settings and the process's signal dispositions are
// what they were afterwards, however the widget ended. Serialized: the widgets change
// process-wide signal dispositions while they run.

import Darwin
import Foundation
import Testing
@testable import TerminalUI

/// A pseudo-terminal pair: the widget runs on `slave`, the test types into and reads `master`.
final class PseudoTerminal {
    let master: Int32
    let slave: Int32
    private var output = Data()

    init(rows: UInt16 = 24, columns: UInt16 = 80) throws {
        master = posix_openpt(O_RDWR | O_NOCTTY)
        guard master >= 0 else {
            throw PseudoTerminalError("posix_openpt: \(String(cString: strerror(errno)))")
        }
        guard grantpt(master) == 0, unlockpt(master) == 0, let name = ptsname(master).map({ String(cString: $0) }) else {
            close(master)
            throw PseudoTerminalError("cannot set up the pseudo-terminal")
        }
        slave = open(name, O_RDWR | O_NOCTTY)
        guard slave >= 0 else {
            close(master)
            throw PseudoTerminalError("open \(name): \(String(cString: strerror(errno)))")
        }
        _ = fcntl(master, F_SETFL, fcntl(master, F_GETFL) | O_NONBLOCK)
        resize(rows: rows, columns: columns)
    }

    deinit {
        // The master first: closing the slave waits for its output to be read.
        close(master)
        close(slave)
    }

    func resize(rows: UInt16, columns: UInt16) {
        var size = winsize(ws_row: rows, ws_col: columns, ws_xpixel: 0, ws_ypixel: 0)
        _ = ioctl(master, TIOCSWINSZ, &size)
    }

    func type(_ text: String) {
        type(Array(text.utf8))
    }

    func type(_ bytes: [UInt8]) {
        _ = bytes.withUnsafeBytes { write(master, $0.baseAddress!, $0.count) }
    }

    /// Everything the widget wrote so far.
    var text: String {
        drain()
        return String(decoding: output, as: UTF8.self)
    }

    /// Waits up to `seconds` for `predicate` on the output; true when it held.
    @discardableResult
    func waitFor(seconds: Double = 5, _ predicate: (String) -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if predicate(text) {
                return true
            }
            var descriptor = pollfd(fd: master, events: Int16(POLLIN), revents: 0)
            _ = poll(&descriptor, 1, 20)
        }
        return predicate(text)
    }

    @discardableResult
    func waitFor(_ expected: String, seconds: Double = 5) -> Bool {
        return waitFor(seconds: seconds) { $0.contains(expected) }
    }

    /// Reads what the widget wrote. A widget's restore (TCSADRAIN) waits until its output is
    /// read, as a real terminal always does, so the test keeps reading while it waits.
    func drain() {
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = read(master, &chunk, chunk.count)
            guard count > 0 else {
                return
            }
            output.append(contentsOf: chunk[0..<count])
        }
    }

    func settings() -> termios {
        var settings = termios()
        _ = tcgetattr(slave, &settings)
        return settings
    }
}

struct PseudoTerminalError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) {
        self.description = description
    }
}

/// A widget run on another thread, as it would run on connect's main thread while the test
/// plays the person at the keyboard.
final class Running<T: Sendable>: @unchecked Sendable {
    private let done = DispatchSemaphore(value: 0)
    private var result: Result<T, Error>?

    init(_ body: @escaping @Sendable () throws -> T) {
        Thread.detachNewThread {
            let outcome = Result { try body() }
            self.result = outcome
            self.done.signal()
        }
    }

    /// The widget's result, reading `pty` meanwhile (see `PseudoTerminal.drain`).
    func wait(_ pty: PseudoTerminal, seconds: Double = 10) throws -> T {
        let deadline = Date().addingTimeInterval(seconds)
        while done.wait(timeout: .now() + 0.02) != .success {
            pty.drain()
            guard Date() < deadline else {
                throw PseudoTerminalError("the widget did not end")
            }
        }
        guard let result else {
            throw PseudoTerminalError("the widget did not end")
        }
        return try result.get()
    }
}

/// Field by field (the structure has padding), without PENDIN: a state bit, not a setting,
/// that the kernel sets when a terminal goes back to canonical mode so queued input is
/// processed again.
func sameSettings(_ a: termios, _ b: termios) -> Bool {
    let aCC = withUnsafeBytes(of: a.c_cc) { Array($0) }
    let bCC = withUnsafeBytes(of: b.c_cc) { Array($0) }
    let state = ~tcflag_t(PENDIN)
    return a.c_iflag == b.c_iflag && a.c_oflag == b.c_oflag && a.c_cflag == b.c_cflag && a.c_lflag & state == b.c_lflag & state
        && aCC == bCC && a.c_ispeed == b.c_ispeed && a.c_ospeed == b.c_ospeed
}

@Suite(.serialized) struct PseudoTerminalTests {
    let sections = [
        PickerSection(title: "Running", rows: [
            PickerRow(id: "first", columns: ["b1", "dev", "running"]),
            PickerRow(id: "second", columns: ["b2", "dev", "stopped"]),
        ]),
    ]

    func terminal(_ pty: PseudoTerminal, environment: [String: String] = ["TERM": "xterm-256color"]) -> Terminal {
        return Terminal(input: pty.slave, output: pty.slave, environment: environment)
    }

    func picker(on pty: PseudoTerminal, environment: [String: String] = ["TERM": "xterm-256color"]) -> Running<String> {
        let terminal = terminal(pty, environment: environment)
        let sections = sections
        return Running { try Picker(title: "Pick a box", sections: sections).run(on: terminal) }
    }

    @Test func aPickerChoosesOnAPseudoTerminal() throws {
        let pty = try PseudoTerminal()
        let running = picker(on: pty)
        #expect(pty.waitFor("Pick a box"))
        pty.type("\u{1B}[B\r")
        #expect(try running.wait(pty) == "second")
        // The block is erased and the cursor shown again.
        #expect(pty.text.hasSuffix("\u{1B}[J\u{1B}[0m\u{1B}[?25h"))
    }

    @Test func theTerminalSettingsComeBack() throws {
        for keys in ["\r", "\u{1B}", "\u{03}"] {
            let pty = try PseudoTerminal()
            let before = pty.settings()
            let running = picker(on: pty)
            #expect(pty.waitFor("Pick a box"))
            // Raw while the picker runs.
            #expect(pty.settings().c_lflag & tcflag_t(ICANON | ECHO | ISIG) == 0)
            pty.type(keys)
            let outcome = Result { try running.wait(pty) }
            if keys == "\r" {
                #expect(try outcome.get() == "first")
            } else {
                #expect(throws: TerminalUIError.canceled) { try outcome.get() }
            }
            #expect(sameSettings(pty.settings(), before), "after \(Array(keys.utf8)): \(pty.settings()), before: \(before)")
        }
    }

    @Test func interruptedRestoresToo() throws {
        let pty = try PseudoTerminal()
        let before = pty.settings()
        var dispositionBefore = sigaction()
        sigaction(SIGTERM, nil, &dispositionBefore)
        let running = picker(on: pty)
        #expect(pty.waitFor("Pick a box"))
        kill(getpid(), SIGTERM)
        #expect(throws: TerminalUIError.interrupted(signal: SIGTERM)) { try running.wait(pty) }
        #expect(sameSettings(pty.settings(), before))
        var dispositionAfter = sigaction()
        sigaction(SIGTERM, nil, &dispositionAfter)
        #expect(unsafeBitCast(dispositionAfter.__sigaction_u.__sa_handler, to: Int.self)
            == unsafeBitCast(dispositionBefore.__sigaction_u.__sa_handler, to: Int.self))
        #expect(dispositionAfter.sa_flags == dispositionBefore.sa_flags)
    }

    @Test func aResizeRedraws() throws {
        let pty = try PseudoTerminal()
        let running = picker(on: pty)
        #expect(pty.waitFor("Pick a box"))
        let drawnBefore = pty.text.count
        pty.resize(rows: 24, columns: 60)
        kill(getpid(), SIGWINCH)
        // A new frame: erased from the block's top, then drawn again.
        #expect(pty.waitFor { $0.count > drawnBefore && String($0.dropFirst(drawnBefore)).contains("Pick a box") })
        let frame = String(pty.text.dropFirst(drawnBefore))
        for line in frame.components(separatedBy: "\r\n") {
            let visible = RawSession.visible(line).replacingOccurrences(of: "\r", with: "")
            #expect(TextWidth.of(visible) <= 59, "\(line)")
        }
        pty.type("\u{03}")
        #expect(throws: TerminalUIError.canceled) { try running.wait(pty) }
    }

    @Test func secretInputIsNotEchoed() throws {
        let pty = try PseudoTerminal()
        let before = pty.settings()
        let terminal = terminal(pty)
        let running = Running { try LineInput.secret(prompt: "Value of TOKEN: ", maxBytes: 65536, on: terminal) }
        #expect(pty.waitFor("Value of TOKEN: "))
        pty.type("s3cr\u{00E9}t-x\u{7F}y\r\n")
        let value = try running.wait(pty)
        #expect(value == Array("s3cr\u{00E9}t-y".utf8))
        #expect(pty.waitFor("(8 characters)"))
        #expect(!pty.text.contains("s3cr"))
        #expect(sameSettings(pty.settings(), before))
        // The "\n" after the "\r" was discarded: nothing is left for the next read.
        _ = fcntl(pty.slave, F_SETFL, fcntl(pty.slave, F_GETFL) | O_NONBLOCK)
        var byte: UInt8 = 0
        #expect(read(pty.slave, &byte, 1) == -1 && errno == EAGAIN)
        _ = fcntl(pty.slave, F_SETFL, fcntl(pty.slave, F_GETFL) & ~O_NONBLOCK)
    }

    @Test func secretSummaryFitsAWindowNarrowedMeanwhile() throws {
        let pty = try PseudoTerminal()
        let terminal = terminal(pty)
        let running = Running { try LineInput.secret(prompt: "Value of TOKEN: ", maxBytes: 64, on: terminal) }
        #expect(pty.waitFor("Value of TOKEN: "))
        pty.resize(rows: 24, columns: 20)
        pty.type("abc\r")
        #expect(try running.wait(pty) == Array("abc".utf8))
        #expect(pty.waitFor("..."))
        let frame = pty.text.components(separatedBy: "\u{1B}[J").last ?? ""
        let line = RawSession.visible(frame).components(separatedBy: "\n")[0].replacingOccurrences(of: "\r", with: "")
        #expect(line == "Value of TOKEN: ...", "\(frame)")
    }

    @Test func secretInputCancels() throws {
        let pty = try PseudoTerminal()
        let terminal = terminal(pty)
        let running = Running { try LineInput.secret(prompt: "Value: ", maxBytes: 4, on: terminal) }
        #expect(pty.waitFor("Value: "))
        pty.type("abc\u{1B}")
        #expect(throws: TerminalUIError.canceled) { try running.wait(pty) }
        // Longer than maxBytes: the rest is dropped; an arrow is not Escape.
        let limited = Running { try LineInput.secret(prompt: "Value: ", maxBytes: 4, on: terminal) }
        #expect(pty.waitFor { $0.components(separatedBy: "Value: ").count > 2 })
        pty.type("abcdef\u{1B}[Ag\r")
        #expect(try limited.wait(pty) == Array("abcd".utf8))
    }

    @Test func choicesConfirmsAndLines() throws {
        let pty = try PseudoTerminal()
        let terminal = terminal(pty)
        let choice = Choice(prompt: nil, options: [Choice.Option(key: "k", label: "keep the changes"),
                                                   Choice.Option(key: "u", label: "undo them all")], defaultKey: "k")
        let first = Running { try choice.run(on: terminal) }
        #expect(pty.waitFor("k) keep the changes  u) undo them all [K/u] "))
        pty.type("x")
        pty.type("U")
        #expect(try first.wait(pty) == "u")
        #expect(pty.waitFor("[K/u] undo them all"))

        let byDefault = Running { try choice.run(on: terminal) }
        #expect(pty.waitFor { $0.components(separatedBy: "[K/u] ").count > 3 })
        pty.type("\r")
        #expect(try byDefault.wait(pty) == "k")

        let confirm = Confirm("Go on without?", defaultAnswer: false)
        let answer = Running { try confirm.run(on: terminal) }
        #expect(pty.waitFor("Go on without? [y/N] "))
        pty.type("\r")
        #expect(try answer.wait(pty) == false)

        let line = Running {
            try LineInput(prompt: "Name: ", initial: "app") { $0.contains(" ") ? "no spaces" : nil }.run(on: terminal)
        }
        #expect(pty.waitFor("Name: app"))
        pty.type(" x\r")
        #expect(pty.waitFor("no spaces"))
        pty.type("\u{17}\u{7F}-2\r")
        #expect(try line.wait(pty) == "app-2")
    }

    @Test func aLongQuestionKeepsItsKeys() throws {
        let pty = try PseudoTerminal(rows: 24, columns: 40)
        let terminal = terminal(pty)
        let question = "~ cannot be shared, and this question goes on well past the window's edge. Go on?"
        let confirm = Confirm(question, defaultAnswer: true)
        let answer = Running { try confirm.run(on: terminal) }
        #expect(pty.waitFor("... [Y/n] "))
        pty.type("n")
        #expect(try answer.wait(pty) == false)
        // Every frame, each drawn after a carriage return.
        for line in pty.text.components(separatedBy: CharacterSet(charactersIn: "\r\n")) {
            #expect(TextWidth.of(RawSession.visible(line)) <= 39, "\(line)")
        }
        #expect(pty.text.contains("[Y/n] no"))
        // The pieces alone: the keys survive any width they fit in.
        let choice = Choice(prompt: String(repeating: "x", count: 100), options: [Choice.Option(key: "k", label: "keep")], defaultKey: "k")
        for width in 1...30 {
            let line = choice.line(fitting: width)
            #expect(TextWidth.of(line) <= width, "\(width)")
            // From 9 columns, room for at least "x..." before the keys.
            if width >= 9 {
                #expect(line.hasSuffix(" [K] "), "\(width): \(line)")
            }
        }
    }

    @Test func dumbTerminalsGetNumbers() throws {
        let pty = try PseudoTerminal()
        let before = pty.settings()
        let running = picker(on: pty, environment: ["TERM": "dumb"])
        #expect(pty.waitFor("(Enter for 1, text to filter, q to quit): "))
        #expect(pty.text.contains("  1) b1  dev  running"))
        #expect(pty.text.contains("  2) b2  dev  stopped"))
        #expect(!pty.text.contains("\u{1B}"))
        pty.type("stop\n")
        #expect(pty.waitFor { $0.components(separatedBy: "q to quit): ").count > 2 })
        pty.type("2\n")
        #expect(try running.wait(pty) == "second")
        #expect(sameSettings(pty.settings(), before))

        let quitting = picker(on: pty, environment: ["TERM": "dumb"])
        #expect(pty.waitFor { $0.components(separatedBy: "q to quit): ").count > 3 })
        pty.type("q\n")
        #expect(throws: TerminalUIError.canceled) { try quitting.wait(pty) }
    }

    @Test func notATerminalThrows() throws {
        var descriptors: [Int32] = [0, 0]
        #expect(pipe(&descriptors) == 0)
        defer {
            close(descriptors[0])
            close(descriptors[1])
        }
        let terminal = Terminal(input: descriptors[0], output: descriptors[1], environment: ["TERM": "xterm"])
        #expect(!terminal.isInteractive)
        #expect(throws: TerminalUIError.notInteractive) { try Picker(title: "t", sections: sections).run(on: terminal) }
        #expect(throws: TerminalUIError.notInteractive) { try Confirm("q", defaultAnswer: true).run(on: terminal) }
        #expect(throws: TerminalUIError.notInteractive) { try LineInput(prompt: "p").run(on: terminal) }
        #expect(throws: TerminalUIError.notInteractive) { try LineInput.secret(prompt: "p", maxBytes: 4, on: terminal) }
        // Nothing was written.
        _ = fcntl(descriptors[0], F_SETFL, O_NONBLOCK)
        var byte: UInt8 = 0
        #expect(read(descriptors[0], &byte, 1) == -1)
    }

    @Test func stylesFollowTheEnvironment() {
        #expect(TerminalStyle.from(environment: [:]) == TerminalStyle(colors: false, cursorControl: false))
        #expect(TerminalStyle.from(environment: ["TERM": ""]) == TerminalStyle(colors: false, cursorControl: false))
        #expect(TerminalStyle.from(environment: ["TERM": "dumb"]) == TerminalStyle(colors: false, cursorControl: false))
        #expect(TerminalStyle.from(environment: ["TERM": "xterm"]) == TerminalStyle(colors: true, cursorControl: true))
        #expect(TerminalStyle.from(environment: ["TERM": "xterm", "NO_COLOR": ""]) == TerminalStyle(colors: true, cursorControl: true))
        #expect(TerminalStyle.from(environment: ["TERM": "xterm", "NO_COLOR": "1"]) == TerminalStyle(colors: false, cursorControl: true))
    }
}
