// Sources/TerminalUI/Picker.swift
//
// A list to choose one row from, drawn inline under the cursor (never the alternate screen, so
// the scrollback keeps what came before) and erased when done. Rows sit in titled sections and
// have aligned columns and a note; disabled rows are shown but never chosen. Typing filters,
// arrows move, Enter chooses, Escape clears the filter and then quits. Without cursor control
// (TERM=dumb) it is a numbered menu read as a line.
//
// PickerModel (the filter, the selection, scrolling) and PickerView (the lines for a model at a
// size) know nothing of the terminal, so both are tested without one.

import Darwin
import Foundation

public struct PickerRow: Equatable, Sendable {
    public var id: String
    /// Aligned across all rows.
    public var columns: [String]
    /// After the columns, dimmed.
    public var note: String?
    /// False: shown dimmed (or with its note in parentheses, without colors), never chosen.
    public var enabled: Bool

    public init(id: String, columns: [String], note: String? = nil, enabled: Bool = true) {
        self.id = id
        self.columns = columns
        self.note = note
        self.enabled = enabled
    }
}

public struct PickerSection: Equatable, Sendable {
    public var title: String?
    public var rows: [PickerRow]

    public init(title: String?, rows: [PickerRow]) {
        self.title = title
        self.rows = rows
    }
}

public struct Picker: Sendable {
    public let title: String
    public let sections: [PickerSection]
    public let selected: String?

    public init(title: String, sections: [PickerSection], selected: String? = nil) {
        self.title = title
        self.sections = sections
        self.selected = selected
    }

    /// The chosen row's id. Its lines are erased before it returns or throws.
    public func run(on terminal: Terminal) throws -> String {
        guard terminal.isInteractive else {
            throw TerminalUIError.notInteractive
        }
        if !terminal.style.cursorControl {
            return try NumberedMenu(title: title, sections: sections, selected: selected).run(on: terminal)
        }
        return try RawSession.run(terminal) { session in
            var model = PickerModel(sections: sections, selected: selected)
            var decoder = KeyDecoder()
            var height = 3
            func redraw() {
                let size = session.size()
                height = PickerView.listHeight(rows: size.rows, filtering: !model.filter.isEmpty)
                model.settleWindow(height: height)
                session.draw(PickerView.lines(title: title, model: model, rows: size.rows, columns: size.columns,
                                              colors: terminal.style.colors), hideCursor: true)
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
                    switch model.handle(key, visibleHeight: height) {
                    case .continuing:
                        break
                    case .chosen(let id):
                        return id
                    case .canceled:
                        throw TerminalUIError.canceled
                    }
                }
                redraw()
            }
        }
    }
}

/// The filter, the selection and the scroll position; no terminal.
struct PickerModel {
    enum Item: Equatable {
        case title(String)
        case row(PickerRow)
    }

    enum Outcome: Equatable {
        case continuing
        case chosen(String)
        case canceled
    }

    let sections: [PickerSection]
    private(set) var filter = ""
    private(set) var selectedID: String?
    /// The first shown item drawn (scrolling).
    private(set) var offset = 0
    /// What the filter lets through, section titles included.
    private(set) var shown: [Item] = []

    init(sections: [PickerSection], selected: String?) {
        self.sections = sections
        shown = Self.items(sections, filter: "")
        let rows = shown.compactMap(\.row)
        if let selected, rows.contains(where: { $0.id == selected && $0.enabled }) {
            selectedID = selected
        } else {
            selectedID = rows.first(where: \.enabled)?.id
        }
    }

    /// Every row of every section, whether the filter shows it or not.
    var allRows: [PickerRow] {
        return sections.flatMap(\.rows)
    }

    var selectedIndex: Int? {
        guard let selectedID else {
            return nil
        }
        return shown.firstIndex { $0.row?.id == selectedID }
    }

    mutating func handle(_ key: Key, visibleHeight: Int) -> Outcome {
        switch key {
        case .up:
            move(from: selectedIndex, by: -1)
        case .down:
            move(from: selectedIndex, by: 1)
        case .pageUp:
            page(by: -max(1, visibleHeight))
        case .pageDown:
            page(by: max(1, visibleHeight))
        case .home:
            select(shown.indices.first { isEnabledRow($0) })
        case .end:
            select(shown.indices.last { isEnabledRow($0) })
        case .enter:
            if let index = selectedIndex, isEnabledRow(index), let id = selectedID {
                return .chosen(id)
            }
        case .escape:
            if filter.isEmpty {
                return .canceled
            }
            setFilter("")
        case .controlC:
            return .canceled
        case .controlD:
            if filter.isEmpty {
                return .canceled
            }
        case .backspace:
            if !filter.isEmpty {
                var text = filter
                text.removeLast()
                setFilter(text)
            }
        case .controlU:
            setFilter("")
        case .controlW:
            var text = filter
            while text.last == " " {
                text.removeLast()
            }
            while let last = text.last, last != " " {
                _ = last
                text.removeLast()
            }
            setFilter(text)
        case .character(let character):
            // Printable text only: a control character decoded from UTF-8 (C1) is not typed.
            if TextWidth.printable(String(character)) == String(character) {
                setFilter(filter + String(character))
            }
        case .tab, .left, .right, .delete:
            break
        }
        return .continuing
    }

    /// Positions the window of `height` lines so the selection is inside it. Lines saying how
    /// many more there are take the place of the first or last item.
    mutating func settleWindow(height: Int) {
        let window = Self.window(total: shown.count, height: height, selected: selectedIndex, offset: offset, shown: shown)
        offset = window.offset
    }

    /// The items drawn for `height` lines at `offset`, and whether lines for more above and
    /// below take the first and last places.
    static func window(total: Int, height: Int, selected: Int?, offset: Int, shown: [Item])
        -> (offset: Int, count: Int, above: Bool, below: Bool) {
        let height = max(3, height)
        if total <= height {
            return (0, total, false, false)
        }
        // Never past the start that fills the window to the last item (the window may have
        // grown since `offset` was settled).
        var start = min(max(0, offset), total - height + 1)
        func room(_ start: Int) -> (count: Int, above: Bool, below: Bool) {
            let above = start > 0
            var count = height - (above ? 1 : 0)
            let below = start + count < total
            if below {
                count -= 1
            }
            return (max(1, count), above, below)
        }
        if let selected {
            if selected < start {
                start = selected
                // The row's section title too, when it fits.
                if selected > 0, case .title = shown[selected - 1] {
                    start = selected - 1
                }
            }
            while selected >= start + room(start).count {
                start += 1
            }
        }
        let (count, above, below) = room(start)
        return (start, count, above, below)
    }

    private func isEnabledRow(_ index: Int) -> Bool {
        if case .row(let row) = shown[index] {
            return row.enabled
        }
        return false
    }

    private mutating func select(_ index: Int?) {
        if let index, case .row(let row) = shown[index] {
            selectedID = row.id
        }
    }

    private mutating func move(from index: Int?, by step: Int) {
        guard let index else {
            select(shown.indices.first { isEnabledRow($0) })
            return
        }
        var next = index + step
        while next >= 0 && next < shown.count {
            if isEnabledRow(next) {
                select(next)
                return
            }
            next += step
        }
    }

    private mutating func page(by step: Int) {
        guard let index = selectedIndex else {
            move(from: nil, by: step)
            return
        }
        let target = min(max(0, index + step), shown.count - 1)
        let direction = step > 0 ? 1 : -1
        // The first enabled row at or past the target; else the farthest one before it.
        var next = target
        while next >= 0 && next < shown.count {
            if isEnabledRow(next) {
                select(next)
                return
            }
            next += direction
        }
        next = target
        while next != index {
            if isEnabledRow(next) {
                select(next)
                return
            }
            next -= direction
        }
    }

    private mutating func setFilter(_ text: String) {
        filter = text
        shown = Self.items(sections, filter: text)
        offset = 0
        if selectedIndex.map({ isEnabledRow($0) }) != true {
            selectedID = nil
            select(shown.indices.first { isEnabledRow($0) })
        }
    }

    /// The rows every word of `filter` is found in (case-insensitively, in the columns and the
    /// note), with the titles of the sections that keep a row.
    static func items(_ sections: [PickerSection], filter: String) -> [Item] {
        let words = filter.lowercased().split(separator: " ")
        var items: [Item] = []
        for section in sections {
            let rows = section.rows.filter { row in
                let text = (row.columns + [row.note ?? ""]).joined(separator: " ").lowercased()
                return words.allSatisfy { text.contains($0) }
            }
            guard !rows.isEmpty else {
                continue
            }
            if let title = section.title {
                items.append(.title(title))
            }
            items += rows.map { .row($0) }
        }
        return items
    }
}

extension PickerModel.Item {
    var row: PickerRow? {
        if case .row(let row) = self {
            return row
        }
        return nil
    }
}

/// The lines of a picker for a model at a window size; no terminal.
enum PickerView {
    static let hint = "  type to filter, arrows, Enter; Esc quits"

    /// Lines for the rows at most: the block is at most the window's rows minus 2, and at least
    /// 3 lines of rows.
    static func listHeight(rows: Int, filtering: Bool) -> Int {
        return max(3, rows - 2 - 1 - (filtering ? 1 : 0))
    }

    static func lines(title: String, model: PickerModel, rows: Int, columns: Int, colors: Bool) -> [String] {
        let width = max(1, columns - 1)
        var lines: [String] = []
        var titleLine = Styled(TextWidth.printable(title), bold: true)
        if TextWidth.of(titleLine.text) + TextWidth.of(hint) <= width {
            titleLine.append(hint, dim: true)
        }
        lines.append(titleLine.render(width: width, colors: colors))
        if !model.filter.isEmpty {
            lines.append(Styled("  filter: " + TextWidth.printable(model.filter)).render(width: width, colors: colors))
        }
        if model.shown.isEmpty {
            lines.append(Styled("  no match", dim: true).render(width: width, colors: colors))
            return lines
        }

        // Columns line up across every row, so they do not move while filtering.
        let allRows = model.allRows
        let columnCount = allRows.map(\.columns.count).max() ?? 0
        var columnWidths = [Int](repeating: 0, count: columnCount)
        for row in allRows {
            for (index, column) in row.columns.enumerated() {
                columnWidths[index] = max(columnWidths[index], TextWidth.of(TextWidth.printable(column)))
            }
        }

        let height = listHeight(rows: rows, filtering: !model.filter.isEmpty)
        let window = PickerModel.window(total: model.shown.count, height: height, selected: model.selectedIndex,
                                        offset: model.offset, shown: model.shown)
        if window.above {
            lines.append(Styled("  ... \(window.offset) more above", dim: true).render(width: width, colors: colors))
        }
        for item in model.shown[window.offset..<(window.offset + window.count)] {
            switch item {
            case .title(let title):
                lines.append(Styled("  " + TextWidth.printable(title), bold: true).render(width: width, colors: colors))
            case .row(let row):
                lines.append(rowLine(row, selected: row.id == model.selectedID, columnWidths: columnWidths, colors: colors)
                    .render(width: width, colors: colors))
            }
        }
        if window.below {
            let more = model.shown.count - window.offset - window.count
            lines.append(Styled("  ... \(more) more below", dim: true).render(width: width, colors: colors))
        }
        return lines
    }

    static func rowLine(_ row: PickerRow, selected: Bool, columnWidths: [Int], colors: Bool) -> Styled {
        var line = Styled(selected ? "  > " : "    ")
        var text = ""
        for (index, column) in row.columns.enumerated() {
            let value = TextWidth.printable(column)
            let isLast = index == row.columns.count - 1 && row.note == nil
            text += value
            if !isLast {
                text += String(repeating: " ", count: columnWidths[index] - TextWidth.of(value) + 2)
            }
        }
        line.append(text, dim: !row.enabled, reverse: selected)
        if let note = row.note.map(TextWidth.printable) {
            if colors {
                line.append(note, dim: true, reverse: selected)
            } else {
                line.append(row.enabled ? note : "(\(note))")
            }
        } else if !row.enabled && !colors {
            line.append("(not available)")
        }
        return line
    }

    /// Rows each line takes after the window changed to `columns` (see RawSession).
    static func physicalLines(_ widths: [Int], columns: Int) -> Int {
        return RawSession.physicalLines(widths, columns: columns)
    }
}

/// A line of text in runs with attributes, cut to a width as a whole.
struct Styled {
    struct Run {
        var text: String
        var bold = false
        var dim = false
        var reverse = false
    }

    private(set) var runs: [Run] = []

    init(_ text: String, bold: Bool = false, dim: Bool = false, reverse: Bool = false) {
        append(text, bold: bold, dim: dim, reverse: reverse)
    }

    var text: String {
        return runs.map(\.text).joined()
    }

    mutating func append(_ text: String, bold: Bool = false, dim: Bool = false, reverse: Bool = false) {
        runs.append(Run(text: text, bold: bold, dim: dim, reverse: reverse))
    }

    /// The line cut to `width` columns (ending in "..." when cut), with SGR attributes when
    /// `colors`; every styled run ends with ESC[0m.
    func render(width: Int, colors: Bool) -> String {
        var remaining = width
        var cutRuns: [Run] = []
        if TextWidth.of(text) <= width {
            cutRuns = runs
        } else {
            remaining = width >= 4 ? width - 3 : width
            for run in runs {
                var kept = ""
                for character in run.text {
                    let columns = TextWidth.of(character)
                    if columns > remaining {
                        remaining = -1
                        break
                    }
                    kept.append(character)
                    remaining -= columns
                }
                var cut = run
                cut.text = kept
                cutRuns.append(cut)
                if remaining < 0 {
                    break
                }
            }
            if width >= 4, var last = cutRuns.popLast() {
                last.text += "..."
                cutRuns.append(last)
            }
        }
        var result = ""
        for run in cutRuns where !run.text.isEmpty {
            var codes: [String] = []
            if colors {
                if run.bold { codes.append("1") }
                if run.dim { codes.append("2") }
                if run.reverse { codes.append("7") }
            }
            if codes.isEmpty {
                result += run.text
            } else {
                result += "\u{1B}[" + codes.joined(separator: ";") + "m" + run.text + "\u{1B}[0m"
            }
        }
        return result
    }
}

/// The picker without cursor control: numbered lines and a line read with the terminal's own
/// editing. A number picks, Enter the preselected row, text filters (rows keep their numbers),
/// q or the end of input quits.
struct NumberedMenu {
    let title: String
    let sections: [PickerSection]
    let selected: String?

    func run(on terminal: Terminal) throws -> String {
        return try RawSession.run(terminal, mode: .line(echo: true)) { session in
            let model = PickerModel(sections: sections, selected: selected)
            var numbers: [String: Int] = [:]
            var byNumber: [Int: String] = [:]
            for row in model.allRows where row.enabled {
                numbers[row.id] = numbers.count + 1
                byNumber[numbers.count] = row.id
            }
            var filter = ""
            while true {
                session.write(Self.menu(title: title, sections: sections, filter: filter, numbers: numbers,
                                        columns: session.size().columns).joined(separator: "\n") + "\n")
                let enterPart = model.selectedID.flatMap { numbers[$0] }.map { "Enter for \($0), " } ?? ""
                let range = numbers.isEmpty ? "" : numbers.count == 1 ? "Choose 1 " : "Choose 1-\(numbers.count) "
                session.write("\(range)(\(enterPart)text to filter, q to quit): ")
                let answer = try LineReader.readLine(session).trimmingCharacters(in: .whitespaces)
                if answer.isEmpty {
                    if let id = model.selectedID {
                        return id
                    }
                    continue
                }
                if answer.lowercased() == "q" {
                    throw TerminalUIError.canceled
                }
                if let number = Int(answer), let id = byNumber[number] {
                    return id
                }
                filter = answer
            }
        }
    }

    static func menu(title: String, sections: [PickerSection], filter: String, numbers: [String: Int], columns: Int) -> [String] {
        let width = max(1, columns - 1)
        let items = PickerModel.items(sections, filter: filter)
        let allRows = sections.flatMap(\.rows)
        let columnCount = allRows.map(\.columns.count).max() ?? 0
        var columnWidths = [Int](repeating: 0, count: columnCount)
        for row in allRows {
            for (index, column) in row.columns.enumerated() {
                columnWidths[index] = max(columnWidths[index], TextWidth.of(TextWidth.printable(column)))
            }
        }
        let numberWidth = String(max(1, numbers.count)).count
        var lines = [TextWidth.cut(TextWidth.printable(title), to: width)]
        if items.isEmpty {
            lines.append("  no match")
        }
        for item in items {
            switch item {
            case .title(let title):
                lines.append(TextWidth.cut("  " + TextWidth.printable(title), to: width))
            case .row(let row):
                let label = numbers[row.id].map { String($0) + ")" } ?? ""
                let padded = String(repeating: " ", count: numberWidth + 1 - label.count) + label
                let body = PickerView.rowLine(row, selected: false, columnWidths: columnWidths, colors: false).text
                lines.append(TextWidth.cut("  " + padded + " " + body.dropFirst(4), to: width))
            }
        }
        return lines
    }
}

/// Reading a line in line mode, for the numbered menus and the line prompts.
enum LineReader {
    /// One line without its end. Control-C (SIGINT from the key) and the end of input cancel;
    /// other signals interrupt.
    static func readLine(_ session: RawSession) throws -> String {
        var bytes: [UInt8] = []
        while true {
            switch session.next(timeoutMilliseconds: nil) {
            case .input(let chunk):
                for byte in chunk {
                    if byte == 0x0A {
                        return String(decoding: bytes, as: UTF8.self)
                    }
                    bytes.append(byte)
                }
            case .timeout, .resize:
                continue
            case .signal(let signalNumber):
                if signalNumber == SIGINT {
                    session.write("\n")
                    throw TerminalUIError.canceled
                }
                throw TerminalUIError.interrupted(signal: signalNumber)
            case .closed:
                session.write("\n")
                throw TerminalUIError.canceled
            }
        }
    }
}
