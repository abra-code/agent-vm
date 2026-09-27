// Sources/TerminalUI/Terminal.swift
//
// The terminal the widgets run on: its two descriptors, what it can show (colors, cursor
// movement), its size, and plain writes. Widgets check `isInteractive` before anything else,
// so a pipe is never read as keys.

import Darwin
import Foundation

public enum TerminalUIError: Error, Equatable, CustomStringConvertible {
    /// stdin or stdout is not a terminal.
    case notInteractive
    /// Escape, Control-C, or Control-D on an empty filter; end of input in the numbered menu.
    case canceled
    /// SIGINT, SIGTERM, SIGHUP or SIGQUIT arrived while a widget ran (a hang-up of the
    /// terminal counts as SIGHUP). The terminal is restored before this is thrown.
    case interrupted(signal: Int32)

    public var description: String {
        switch self {
        case .notInteractive:
            return "stdin or stdout is not a terminal"
        case .canceled:
            return "canceled"
        case .interrupted(let signal):
            return "interrupted by signal \(signal)"
        }
    }
}

public struct TerminalStyle: Equatable, Sendable {
    /// SGR attributes: bold, dim, reverse.
    public var colors: Bool
    /// Erase and redraw; false: numbered menus and line prompts.
    public var cursorControl: Bool

    public init(colors: Bool, cursorControl: Bool) {
        self.colors = colors
        self.cursorControl = cursorControl
    }

    /// TERM unset, empty or "dumb": neither. NO_COLOR set and not empty: no colors
    /// (no-color.org).
    public static func from(environment: [String: String]) -> TerminalStyle {
        let term = environment["TERM"] ?? ""
        if term.isEmpty || term == "dumb" {
            return TerminalStyle(colors: false, cursorControl: false)
        }
        let noColor = environment["NO_COLOR"] ?? ""
        return TerminalStyle(colors: noColor.isEmpty, cursorControl: true)
    }
}

public final class Terminal: @unchecked Sendable {
    public let input: Int32
    public let output: Int32
    public let style: TerminalStyle

    public init(input: Int32 = STDIN_FILENO, output: Int32 = STDOUT_FILENO,
                environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.input = input
        self.output = output
        self.style = TerminalStyle.from(environment: environment)
    }

    public var isInteractive: Bool {
        return isatty(input) == 1 && isatty(output) == 1
    }

    /// The window size from the output, then the input; 24 x 80 when neither answers or a
    /// dimension is 0.
    public func size() -> (rows: Int, columns: Int) {
        for descriptor in [output, input] {
            var size = winsize()
            if ioctl(descriptor, TIOCGWINSZ, &size) == 0, size.ws_row > 0, size.ws_col > 0 {
                return (Int(size.ws_row), Int(size.ws_col))
            }
        }
        return (24, 80)
    }

    /// Writes every byte, retrying on EINTR; other errors drop the rest (a closed terminal has
    /// no one to tell).
    public func write(_ text: String) {
        Terminal.writeAll(output, Array(text.utf8))
    }

    static func writeAll(_ descriptor: Int32, _ bytes: [UInt8]) {
        bytes.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else {
                return
            }
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(descriptor, base + offset, buffer.count - offset)
                if written < 0 {
                    if errno == EINTR {
                        continue
                    }
                    return
                }
                offset += written
            }
        }
    }
}
