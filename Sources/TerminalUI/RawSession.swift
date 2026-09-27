// Sources/TerminalUI/RawSession.swift
//
// One widget's hold on the terminal. `RawSession.run` saves the terminal settings, puts the
// terminal in raw mode (or, for the numbered menus of TERM=dumb, in line mode), watches the
// signals that must end or redraw a widget, and on every way out (a return, a thrown error, a
// signal) erases what the widget drew and gives everything back: the settings, the cursor, the
// signal dispositions, the fault handlers. No other code sets the terminal's modes while a
// widget runs.
//
// Signals are watched with a kqueue (EVFILT_SIGNAL), polled beside the terminal: registering is
// synchronous, so no signal is missed right after a widget starts, and a signal never runs code
// inside a handler; the loop sees it as an event, and the restore runs on the widget's own
// thread. The dispositions are SIG_IGN meanwhile (kqueue records a signal even then).

import Darwin
import Foundation

final class RawSession {
    enum Mode: Equatable {
        /// No echo, no line editing, no signals from keys: every key arrives as typed.
        case raw
        /// The terminal's own line editing, with or without echo (the numbered menus).
        case line(echo: Bool)
    }

    enum Event {
        /// Bytes read, valid until the next call to `next`.
        case input(UnsafeBufferPointer<UInt8>)
        case timeout
        case resize
        case signal(Int32)
        /// The terminal hung up, or reading it failed.
        case closed
    }

    /// Watched while a widget runs: these end it, except SIGWINCH, which redraws.
    static let watched: [Int32] = [SIGINT, SIGTERM, SIGHUP, SIGQUIT, SIGWINCH]

    let terminal: Terminal
    let mode: Mode
    private let saved: termios
    private let queue: Int32
    private var previousActions: [(Int32, sigaction)] = []
    private var pendingSignals: [Int32] = []
    private let buffer = UnsafeMutableBufferPointer<UInt8>.allocate(capacity: 1024)

    /// What is drawn: each line's display width, and where the cursor was left.
    private var drawnWidths: [Int] = []
    private var cursorLine = 0
    private var cursorColumn = 0
    private var cursorHidden = false

    /// Runs `body` with the terminal in `mode`, and restores everything however it ends.
    static func run<T>(_ terminal: Terminal, mode: Mode = .raw, _ body: (RawSession) throws -> T) throws -> T {
        guard terminal.isInteractive else {
            throw TerminalUIError.notInteractive
        }
        // Lines already printed with stdio come first.
        fflush(nil)
        let session = try RawSession(terminal: terminal, mode: mode)
        defer {
            session.restore()
        }
        return try body(session)
    }

    private init(terminal: Terminal, mode: Mode) throws {
        self.terminal = terminal
        self.mode = mode
        var settings = termios()
        guard tcgetattr(terminal.input, &settings) == 0 else {
            buffer.deallocate()
            throw TerminalUIError.notInteractive
        }
        saved = settings
        let queue = kqueue()
        guard queue >= 0 else {
            buffer.deallocate()
            throw TerminalUIError.notInteractive
        }
        _ = fcntl(queue, F_SETFD, FD_CLOEXEC)
        self.queue = queue

        // Watched first, ignored second: a signal in between is recorded by the queue rather
        // than lost.
        var changes = Self.watched.map {
            kevent(ident: UInt($0), filter: Int16(EVFILT_SIGNAL), flags: UInt16(EV_ADD), fflags: 0, data: 0, udata: nil)
        }
        _ = kevent(queue, &changes, Int32(changes.count), nil, 0, nil)
        var ignore = sigaction()
        ignore.__sigaction_u.__sa_handler = SIG_IGN
        sigemptyset(&ignore.sa_mask)
        for signalNumber in Self.watched {
            var old = sigaction()
            if sigaction(signalNumber, &ignore, &old) == 0 {
                previousActions.append((signalNumber, old))
            }
        }

        CrashRestore.install(input: terminal.input, output: terminal.output, settings: saved,
                             cursorControl: terminal.style.cursorControl)
        var changed = saved
        switch mode {
        case .raw:
            changed.c_lflag &= ~tcflag_t(ECHO | ICANON | ISIG | IEXTEN)
            changed.c_iflag &= ~tcflag_t(IXON | ICRNL)
            // Output processing stays on: "\n" still returns the carriage.
            withUnsafeMutableBytes(of: &changed.c_cc) { cc in
                cc[Int(VMIN)] = 1
                cc[Int(VTIME)] = 0
            }
        case .line(let echo):
            changed.c_lflag |= tcflag_t(ICANON | ISIG)
            changed.c_iflag |= tcflag_t(ICRNL)
            if echo {
                changed.c_lflag |= tcflag_t(ECHO)
            } else {
                changed.c_lflag &= ~tcflag_t(ECHO)
            }
        }
        _ = tcsetattr(terminal.input, TCSADRAIN, &changed)
    }

    /// The next thing that happens: input, a signal, or `timeoutMilliseconds` passing (nil:
    /// wait for ever). Signals come before input read at the same time.
    func next(timeoutMilliseconds: Int32?) -> Event {
        while true {
            if let signalNumber = takePendingSignal() {
                return signalNumber == SIGWINCH ? .resize : .signal(signalNumber)
            }
            var descriptors = [
                pollfd(fd: queue, events: Int16(POLLIN), revents: 0),
                pollfd(fd: terminal.input, events: Int16(POLLIN), revents: 0),
            ]
            let ready = poll(&descriptors, 2, timeoutMilliseconds ?? -1)
            if ready < 0 {
                if errno == EINTR {
                    continue
                }
                return .closed
            }
            if ready == 0 {
                return .timeout
            }
            if descriptors[0].revents != 0 {
                collectSignals()
                continue
            }
            if descriptors[1].revents != 0 {
                let count = read(terminal.input, buffer.baseAddress, buffer.count)
                if count > 0 {
                    return .input(UnsafeBufferPointer(rebasing: buffer[0..<count]))
                }
                if count < 0 && (errno == EINTR || errno == EAGAIN) {
                    continue
                }
                return .closed
            }
        }
    }

    /// Zeroes the input buffer (after reading a secret).
    func zeroInput() {
        _ = memset_s(buffer.baseAddress, buffer.count, 0, buffer.count)
    }

    /// Discards input typed but not yet read.
    func flushInput() {
        _ = tcflush(terminal.input, TCIFLUSH)
    }

    func write(_ text: String) {
        terminal.write(text)
    }

    /// The terminal's size now.
    func size() -> (rows: Int, columns: Int) {
        return terminal.size()
    }

    /// Draws `lines` in place of what this session drew before (cursor control only). Each line
    /// must fit in the window's columns minus 1, so none wraps. The cursor is left at the end of
    /// the last line, or at `cursor` (line index, display column) when it is on an earlier line.
    func draw(_ lines: [String], cursor: (line: Int, column: Int)? = nil, hideCursor: Bool = false) {
        var text = backToTop()
        if hideCursor && !cursorHidden {
            text = "\u{1B}[?25l" + text
            cursorHidden = true
        } else if !hideCursor && cursorHidden {
            text += "\u{1B}[?25h"
            cursorHidden = false
        }
        text += lines.joined(separator: "\n")
        let widths = lines.map { TextWidth.of(Self.visible($0)) }
        drawnWidths = widths
        cursorLine = max(0, widths.count - 1)
        cursorColumn = widths.last ?? 0
        if let cursor, cursor.line < cursorLine {
            text += "\r\u{1B}[\(cursorLine - cursor.line)A"
            if cursor.column > 0 {
                text += "\u{1B}[\(cursor.column)C"
            }
            cursorLine = cursor.line
            cursorColumn = cursor.column
        }
        terminal.write(text)
    }

    /// Keeps what is drawn: the cursor goes below it and the next draw starts a new block.
    func commit() {
        guard !drawnWidths.isEmpty else {
            return
        }
        var text = ""
        let below = drawnWidths.count - 1 - cursorLine
        if below > 0 {
            text += "\u{1B}[\(below)B"
        }
        text += "\r\n"
        drawnWidths = []
        cursorLine = 0
        cursorColumn = 0
        terminal.write(text)
    }

    /// Rows a line of each display width takes once the window has `columns` columns: the
    /// terminals rewrap lines when a window narrows.
    static func physicalLines(_ widths: [Int], columns: Int) -> Int {
        let columns = max(1, columns)
        return widths.reduce(0) { $0 + max(1, ($1 + columns - 1) / columns) }
    }

    /// `text` without SGR sequences (the only escapes the widgets put inside a line).
    static func visible(_ text: String) -> String {
        guard text.contains("\u{1B}") else {
            return text
        }
        var result = ""
        var inEscape = false
        for scalar in text.unicodeScalars {
            if inEscape {
                if scalar.value >= 0x40 && scalar.value <= 0x7E && scalar != "[" {
                    inEscape = false
                }
                continue
            }
            if scalar == "\u{1B}" {
                inEscape = true
                continue
            }
            result.unicodeScalars.append(scalar)
        }
        return result
    }

    /// Moves to the first line of the block and erases from there down; "" when nothing is
    /// drawn.
    private func backToTop() -> String {
        guard !drawnWidths.isEmpty else {
            return ""
        }
        let columns = terminal.size().columns
        var rows = Self.physicalLines(Array(drawnWidths[0..<cursorLine]), columns: columns)
        rows += max(0, cursorColumn - 1) / max(1, columns)
        var text = "\r"
        if rows > 0 {
            text += "\u{1B}[\(rows)A"
        }
        return text + "\u{1B}[J"
    }

    private static func ignores(_ action: sigaction) -> Bool {
        return unsafeBitCast(action.__sigaction_u.__sa_handler, to: Int.self) == unsafeBitCast(SIG_IGN, to: Int.self)
    }

    private func takePendingSignal() -> Int32? {
        // Signals that end the widget first; a resize can wait.
        if let index = pendingSignals.firstIndex(where: { $0 != SIGWINCH }) {
            return pendingSignals.remove(at: index)
        }
        return pendingSignals.isEmpty ? nil : pendingSignals.removeFirst()
    }

    private func collectSignals() {
        let empty = kevent(ident: 0, filter: 0, flags: 0, fflags: 0, data: 0, udata: nil)
        var events = Array(repeating: empty, count: Self.watched.count)
        var zero = timespec(tv_sec: 0, tv_nsec: 0)
        let count = kevent(queue, nil, 0, &events, Int32(events.count), &zero)
        guard count > 0 else {
            return
        }
        for event in events[0..<Int(count)] {
            let signalNumber = Int32(event.ident)
            if !pendingSignals.contains(signalNumber) {
                pendingSignals.append(signalNumber)
            }
        }
    }

    /// Erases the block, then puts back the attributes, the cursor, the settings, the fault
    /// handlers and the signal dispositions, in that order. A signal that arrived after the
    /// widget last looked is delivered again under the disposition put back, so it is not lost.
    private func restore() {
        if terminal.style.cursorControl {
            var text = backToTop()
            if terminal.style.colors {
                text += "\u{1B}[0m"
            }
            text += "\u{1B}[?25h"
            terminal.write(text)
        }
        drawnWidths = []
        var settings = saved
        _ = tcsetattr(terminal.input, TCSADRAIN, &settings)
        CrashRestore.uninstall()

        collectSignals()
        for (signalNumber, action) in previousActions {
            var old = action
            _ = sigaction(signalNumber, &old, nil)
        }
        close(queue)
        // Zeroed before a signal delivered again can end the process (SIGQUIT dumps core).
        zeroInput()
        buffer.deallocate()
        for signalNumber in pendingSignals where signalNumber != SIGWINCH {
            if let action = previousActions.first(where: { $0.0 == signalNumber })?.1, !Self.ignores(action) {
                kill(getpid(), signalNumber)
            }
        }
        pendingSignals = []
    }
}
