// Sources/TerminalUI/Prompts.swift
//
// One-line questions: a choice of lettered options (Choice), yes or no (Confirm), a line of
// text (LineInput), and a secret typed without echo (LineInput.secret). With cursor control
// each reads single keys in raw mode; without it (TERM=dumb) each reads a line.

import Darwin
import Foundation

public struct Choice: Sendable {
    public struct Option: Equatable, Sendable {
        /// A lower-case letter.
        public var key: Character
        public var label: String

        public init(key: Character, label: String) {
            self.key = key
            self.label = label
        }
    }

    public let prompt: String?
    public let options: [Option]
    public let defaultKey: Character?
    /// False for Confirm, whose question stands without a list of options.
    let listsOptions: Bool

    public init(prompt: String?, options: [Option], defaultKey: Character?) {
        self.init(prompt: prompt, options: options, defaultKey: defaultKey, listsOptions: true)
    }

    init(prompt: String?, options: [Option], defaultKey: Character?, listsOptions: Bool) {
        self.prompt = prompt
        self.options = options
        self.defaultKey = defaultKey
        self.listsOptions = listsOptions
    }

    /// "k) keep ...  r) ... [K/r/u] ", one key read; Enter takes the default. The chosen label is
    /// echoed and the line ended.
    public func run(on terminal: Terminal) throws -> Character {
        guard terminal.isInteractive else {
            throw TerminalUIError.notInteractive
        }
        if !terminal.style.cursorControl {
            return try RawSession.run(terminal, mode: .line(echo: true)) { session in
                while true {
                    session.write(line)
                    let answer = try LineReader.readLine(session).trimmingCharacters(in: .whitespaces).lowercased()
                    if answer.isEmpty, let defaultKey {
                        return defaultKey
                    }
                    if let first = answer.first, options.contains(where: { $0.key == first }) {
                        return first
                    }
                }
            }
        }
        return try RawSession.run(terminal) { session in
            var decoder = KeyDecoder()
            func redraw() {
                session.draw([line(fitting: max(1, session.size().columns - 1))])
            }
            redraw()
            while true {
                var keys: [Key] = []
                switch session.next(timeoutMilliseconds: decoder.isPending ? KeyDecoder.escapeTimeout : nil) {
                case .input(let bytes):
                    for byte in bytes {
                        keys += decoder.feed(byte)
                    }
                case .timeout:
                    keys = decoder.timeout()
                case .resize:
                    redraw()
                    continue
                case .signal(let signalNumber):
                    throw TerminalUIError.interrupted(signal: signalNumber)
                case .closed:
                    throw TerminalUIError.interrupted(signal: SIGHUP)
                }
                for key in keys {
                    let chosen: Character?
                    switch key {
                    case .enter:
                        chosen = defaultKey
                    case .escape, .controlC:
                        throw TerminalUIError.canceled
                    case .character(let character):
                        let lower = Character(character.lowercased())
                        chosen = options.contains { $0.key == lower } ? lower : nil
                    default:
                        chosen = nil
                    }
                    if let chosen, let option = options.first(where: { $0.key == chosen }) {
                        let label = TextWidth.printable(option.label)
                        let width = max(1, session.size().columns - 1)
                        session.draw([TextWidth.cut(line(fitting: width - TextWidth.of(label)) + label, to: width)])
                        session.commit()
                        return chosen
                    }
                }
            }
        }
    }

    /// The prompt, the options and the keys, the default in upper case.
    var line: String {
        return head.isEmpty ? keys : head + " " + keys
    }

    /// `line` in at most `width` columns: the prompt and options are cut, never the keys.
    func line(fitting width: Int) -> String {
        if TextWidth.of(line) <= width || head.isEmpty {
            return TextWidth.cut(line, to: width)
        }
        let room = width - TextWidth.of(keys) - 1
        guard room >= 4 else {
            return TextWidth.cut(keys, to: width)
        }
        return TextWidth.cut(head, to: room) + " " + keys
    }

    /// The prompt and the lettered options.
    private var head: String {
        var parts: [String] = []
        if let prompt {
            parts.append(TextWidth.printable(prompt))
        }
        if listsOptions {
            parts.append(options.map { "\($0.key)) \(TextWidth.printable($0.label))" }.joined(separator: "  "))
        }
        return parts.joined(separator: " ")
    }

    /// "[K/r/u] ", the default in upper case.
    private var keys: String {
        return "[" + options.map { $0.key == defaultKey ? $0.key.uppercased() : String($0.key) }.joined(separator: "/") + "] "
    }
}

public struct Confirm: Sendable {
    let choice: Choice

    /// "question [Y/n]" or "question [y/N]".
    public init(_ question: String, defaultAnswer: Bool) {
        choice = Choice(prompt: question, options: [Choice.Option(key: "y", label: "yes"), Choice.Option(key: "n", label: "no")],
                        defaultKey: defaultAnswer ? "y" : "n", listsOptions: false)
    }

    public func run(on terminal: Terminal) throws -> Bool {
        return try choice.run(on: terminal) == "y"
    }
}

public struct LineInput {
    public let prompt: String
    public let initial: String
    public let validate: (String) -> String?

    public init(prompt: String, initial: String = "", validate: @escaping (String) -> String? = { _ in nil }) {
        self.prompt = prompt
        self.initial = initial
        self.validate = validate
    }

    /// A line with the initial text editable; `validate` returns a message to show under it
    /// and ask again, or nil to accept.
    public func run(on terminal: Terminal) throws -> String {
        guard terminal.isInteractive else {
            throw TerminalUIError.notInteractive
        }
        if !terminal.style.cursorControl {
            return try RawSession.run(terminal, mode: .line(echo: true)) { session in
                while true {
                    let shown = initial.isEmpty ? "" : "[\(TextWidth.printable(initial))] "
                    session.write(TextWidth.printable(prompt) + shown)
                    var text = try LineReader.readLine(session)
                    if text.isEmpty {
                        text = initial
                    }
                    guard let message = validate(text) else {
                        return text
                    }
                    session.write("  " + TextWidth.printable(message) + "\n")
                }
            }
        }
        return try RawSession.run(terminal) { session in
            var decoder = KeyDecoder()
            var text = initial
            var message: String?
            func redraw() {
                let width = max(1, session.size().columns - 1)
                let input = Self.inputLine(prompt: TextWidth.printable(prompt), text: TextWidth.printable(text), width: width)
                var lines = [input]
                if let message {
                    lines.append(Styled("  " + TextWidth.printable(message), dim: true).render(width: width, colors: session.terminal.style.colors))
                }
                session.draw(lines, cursor: (0, TextWidth.of(input)))
            }
            redraw()
            while true {
                var keys: [Key] = []
                switch session.next(timeoutMilliseconds: decoder.isPending ? KeyDecoder.escapeTimeout : nil) {
                case .input(let bytes):
                    for byte in bytes {
                        keys += decoder.feed(byte)
                    }
                case .timeout:
                    keys = decoder.timeout()
                case .resize:
                    redraw()
                    continue
                case .signal(let signalNumber):
                    throw TerminalUIError.interrupted(signal: signalNumber)
                case .closed:
                    throw TerminalUIError.interrupted(signal: SIGHUP)
                }
                guard !keys.isEmpty else {
                    continue
                }
                for key in keys {
                    switch key {
                    case .enter:
                        if let refusal = validate(text) {
                            message = refusal
                        } else {
                            message = nil
                            redraw()
                            session.commit()
                            return text
                        }
                    case .escape, .controlC:
                        throw TerminalUIError.canceled
                    case .backspace:
                        if !text.isEmpty {
                            text.removeLast()
                        }
                    case .controlU:
                        text = ""
                    case .controlW:
                        while text.last == " " {
                            text.removeLast()
                        }
                        while let last = text.last, last != " " {
                            _ = last
                            text.removeLast()
                        }
                    case .character(let character):
                        if TextWidth.printable(String(character)) == String(character) {
                            text.append(character)
                        }
                    default:
                        break
                    }
                }
                redraw()
            }
        }
    }

    /// The prompt and the text; when too wide, the text's end, after "...".
    static func inputLine(prompt: String, text: String, width: Int) -> String {
        let full = prompt + text
        if TextWidth.of(full) <= width {
            return full
        }
        let room = width - TextWidth.of(prompt) - 3
        guard room > 0 else {
            return TextWidth.cut(full, to: width)
        }
        var tail = ""
        var used = 0
        for character in text.reversed() {
            let columns = TextWidth.of(character)
            if used + columns > room {
                break
            }
            tail.insert(character, at: tail.startIndex)
            used += columns
        }
        return prompt + "..." + tail
    }

    /// Typed without echo, up to `maxBytes`; the caller zeroes the result (memset_s) after use.
    /// Backspace removes the last character, Control-U clears, Enter ends; Escape and
    /// Control-C cancel. Input already read or queued past the Enter (the line end of a paste)
    /// is zeroed and discarded, so it never reaches the next prompt. The prompt line then shows
    /// how many characters arrived.
    public static func secret(prompt: String, maxBytes: Int, on terminal: Terminal) throws -> [UInt8] {
        guard terminal.isInteractive else {
            throw TerminalUIError.notInteractive
        }
        let capacity = max(0, maxBytes)
        let buffer = UnsafeMutableBufferPointer<UInt8>.allocate(capacity: max(1, capacity))
        defer {
            _ = memset_s(buffer.baseAddress, buffer.count, 0, buffer.count)
            buffer.deallocate()
        }
        var count = 0
        let shownPrompt = TextWidth.printable(prompt)
        let mode: RawSession.Mode = terminal.style.cursorControl ? .raw : .line(echo: false)
        try RawSession.run(terminal, mode: mode) { session in
            defer {
                session.zeroInput()
            }
            let width = max(1, session.size().columns - 1)
            if terminal.style.cursorControl {
                session.draw([TextWidth.cut(shownPrompt, to: width)])
            } else {
                session.write(shownPrompt)
            }
            // After ESC: 1 waiting for the next byte, 2 inside a sequence (up to its final byte).
            var escape = 0
            reading: while true {
                let event = session.next(timeoutMilliseconds: escape == 1 ? KeyDecoder.escapeTimeout : nil)
                switch event {
                case .input(let bytes):
                    for byte in bytes {
                        if escape == 1 {
                            escape = byte == 0x5B || byte == 0x4F ? 2 : 0
                            continue
                        }
                        if escape == 2 {
                            if byte >= 0x40 && byte <= 0x7E {
                                escape = 0
                            }
                            continue
                        }
                        switch byte {
                        case 0x0D, 0x0A:
                            break reading
                        case 0x1B:
                            escape = 1
                        case 0x03:
                            count = 0
                            throw TerminalUIError.canceled
                        case 0x7F, 0x08:
                            // Back over a whole UTF-8 character: its continuation bytes, then
                            // its lead byte.
                            while count > 0 && buffer[count - 1] & 0xC0 == 0x80 {
                                count -= 1
                                buffer[count] = 0
                            }
                            if count > 0 {
                                count -= 1
                                buffer[count] = 0
                            }
                        case 0x15:
                            _ = memset_s(buffer.baseAddress, buffer.count, 0, buffer.count)
                            count = 0
                        case 0x00..<0x20:
                            break
                        default:
                            if count < capacity {
                                buffer[count] = byte
                                count += 1
                            }
                        }
                    }
                    session.zeroInput()
                case .timeout:
                    if escape == 1 {
                        count = 0
                        throw TerminalUIError.canceled
                    }
                case .resize:
                    continue
                case .signal(let signalNumber):
                    count = 0
                    if case .line = mode, signalNumber == SIGINT {
                        session.write("\n")
                        throw TerminalUIError.canceled
                    }
                    throw TerminalUIError.interrupted(signal: signalNumber)
                case .closed:
                    count = 0
                    if case .line = mode {
                        // Control-D: the end of input.
                        session.write("\n")
                        throw TerminalUIError.canceled
                    }
                    throw TerminalUIError.interrupted(signal: SIGHUP)
                }
            }
            session.zeroInput()
            session.flushInput()
            var characters = 0
            for index in 0..<count where buffer[index] & 0xC0 != 0x80 {
                characters += 1
            }
            let summary = "(\(characters) character\(characters == 1 ? "" : "s"))"
            if terminal.style.cursorControl {
                // The width now: the window may have narrowed while the secret was typed.
                session.draw([TextWidth.cut(shownPrompt + summary, to: max(1, session.size().columns - 1))])
                session.commit()
            } else {
                session.write(summary + "\n")
            }
        }
        return Array(UnsafeBufferPointer(rebasing: buffer[0..<count]))
    }
}
