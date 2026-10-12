// Sources/TerminalUI/Checklist.swift
//
// A list to mark rows in, on the whole window (the terminal's alternate screen): what a
// session changed, say, with the entries to undo marked. Space marks the row under the cursor,
// `a` marks every row and `n` none, Enter ends with the marks, Escape ends without any. Under
// the rows are a few lines about the row under the cursor (long ones wrapped), and on the last line the keys with
// what Enter would do now. Disabled rows are shown and cannot be marked.
//
// It needs cursor control: without it (TERM=dumb) the caller asks its question another way.
// ChecklistView (the lines for a model and marks at a size) knows nothing of the terminal.

import Darwin
import Foundation

public struct Checklist: Sendable {
    /// The words of the last line.
    public struct Words: Equatable, Sendable {
        /// What Enter does to the marked rows: "undo".
        public var action: String
        /// What happens to the rows not marked: "keep".
        public var rest: String

        public init(action: String, rest: String) {
            self.action = action
            self.rest = rest
        }
    }

    /// The product's name, first on the first line.
    public let name: String
    public let title: String
    /// Lines under the title.
    public let summary: [String]
    public let rows: [PickerRow]
    /// Lines about a row, by its id, shown while the cursor is on it.
    public let details: [String: [String]]
    public let words: Words

    public init(name: String, title: String, summary: [String] = [], rows: [PickerRow], details: [String: [String]] = [:], words: Words) {
        self.name = name
        self.title = title
        self.summary = summary
        self.rows = rows
        self.details = details
        self.words = words
    }

    /// The ids of the rows marked when Enter was pressed (none: nothing marked). Escape,
    /// Control-C and Control-D throw `canceled`. The screen is left before it returns or throws.
    public func run(on terminal: Terminal) throws -> Set<String> {
        guard terminal.isInteractive, terminal.style.cursorControl else {
            throw TerminalUIError.notInteractive
        }
        return try RawSession.run(terminal, alternateScreen: true) { session in
            var model = PickerModel(sections: [PickerSection(title: nil, rows: rows)], selected: nil)
            var marks = Set<String>()
            var decoder = KeyDecoder()
            var height = 3
            func redraw() {
                let size = session.size()
                height = ChecklistView.listHeight(self, rows: size.rows)
                model.settleWindow(height: height)
                session.drawScreen(ChecklistView.lines(self, model: model, marks: marks, rows: size.rows, columns: size.columns,
                                                       colors: terminal.style.colors))
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
                    switch Self.handle(key, model: &model, marks: &marks, visibleHeight: height) {
                    case .continuing:
                        break
                    case .chosen:
                        return marks
                    case .canceled:
                        throw TerminalUIError.canceled
                    }
                }
                redraw()
            }
        }
    }

    /// One key: Space, `a` (or `u`) and `n` change the marks, other text does nothing (there is
    /// no filter), and the rest is the list's (arrows, pages, Enter, Escape).
    static func handle(_ key: Key, model: inout PickerModel, marks: inout Set<String>, visibleHeight: Int) -> PickerModel.Outcome {
        guard case .character(let character) = key else {
            if key == .tab || key == .backspace || key == .controlU || key == .controlW {
                return .continuing
            }
            return model.handle(key, visibleHeight: visibleHeight)
        }
        switch character {
        case " ":
            if let id = model.selectedID {
                if marks.contains(id) {
                    marks.remove(id)
                } else {
                    marks.insert(id)
                }
            }
        case "a", "A", "u", "U":
            marks = Set(model.allRows.filter(\.enabled).map(\.id))
        case "n", "N":
            marks = []
        default:
            break
        }
        return .continuing
    }
}

/// The lines of a checklist: exactly as many as the window has rows.
///
///     Name  title
///     summary ...
///
///     > [x] row
///       [ ] row
///
///     about the row under the cursor (three lines)
///
///     Space mark   a all   n none   Enter undo 2, keep 5   Esc keep all
enum ChecklistView {
    /// Lines about the row under the cursor.
    static let detailHeight = 3

    /// At most this many lines of summary; a line says how many more there are.
    static let summaryLimit = 4

    static func summaryLines(_ list: Checklist) -> [String] {
        guard list.summary.count > summaryLimit else {
            return list.summary
        }
        return Array(list.summary.prefix(summaryLimit - 1)) + ["... and \(list.summary.count - summaryLimit + 1) more lines"]
    }

    static func listHeight(_ list: Checklist, rows: Int) -> Int {
        // The title, the summary, a blank line; the rows; a blank line, the details, a blank
        // line, the keys.
        return max(3, rows - 1 - summaryLines(list).count - 1 - 1 - detailHeight - 1 - 1)
    }

    /// The keys, and what Enter does with the marks as they are.
    static func keysLine(_ list: Checklist, marked: Int, markable: Int) -> Styled {
        let enter: String
        if marked == 0 {
            enter = "\(list.words.rest) all"
        } else if marked == markable {
            enter = "\(list.words.action) all \(marked)"
        } else {
            enter = "\(list.words.action) \(marked), \(list.words.rest) \(markable - marked)"
        }
        let keys = [("Space", "mark to \(list.words.action)"), ("a", "all"), ("n", "none"), ("Enter", enter), ("Esc", "\(list.words.rest) all")]
        var line = Styled("  ")
        for (index, (key, does)) in keys.enumerated() {
            if index > 0 {
                line.append("   ")
            }
            line.append(key, bold: true)
            line.append(" " + does, dim: true)
        }
        return line
    }

    /// `text` in lines of at most `width` columns, broken at spaces; a word longer than a line
    /// is left whole (and cut when drawn).
    static func wrapped(_ text: String, width: Int) -> [String] {
        var lines: [String] = []
        var line = ""
        for word in text.split(separator: " ", omittingEmptySubsequences: false) {
            if !line.isEmpty && TextWidth.of(line) + 1 + TextWidth.of(String(word)) > width {
                lines.append(line)
                line = String(word)
            } else {
                line += (line.isEmpty ? "" : " ") + word
            }
        }
        lines.append(line)
        return lines
    }

    static func lines(_ list: Checklist, model: PickerModel, marks: Set<String>, rows: Int, columns: Int, colors: Bool) -> [String] {
        let width = max(1, columns - 1)
        var lines: [Styled] = []
        var title = Styled("  " + TextWidth.printable(list.name), bold: true)
        title.append("  " + TextWidth.printable(list.title), bold: true)
        lines.append(title)
        lines += summaryLines(list).map { Styled("  " + TextWidth.printable($0)) }
        lines.append(Styled(""))
        let height = listHeight(list, rows: rows)
        var shown = PickerView.listLines(model, height: height, colors: colors, marks: marks)
        while shown.count < height {
            shown.append(Styled(""))
        }
        lines += shown
        lines.append(Styled(""))
        var details = (model.selectedID.flatMap { list.details[$0] } ?? []).flatMap { wrapped(TextWidth.printable($0), width: width - 2) }
            .prefix(detailHeight).map { Styled("  " + $0, dim: true) }
        while details.count < detailHeight {
            details.append(Styled(""))
        }
        lines += details
        lines.append(Styled(""))
        let markable = model.allRows.filter(\.enabled).count
        lines.append(keysLine(list, marked: marks.count, markable: markable))
        return Array(lines.map { $0.render(width: width, colors: colors) }.prefix(max(1, rows)))
    }
}
