// Sources/TerminalUI/Picker.swift
//
// A list to choose one row from, drawn inline under the cursor (so the scrollback keeps what
// came before) and erased when done. Rows sit in titled sections and
// have aligned columns and a note; disabled rows are shown but never chosen. Typing filters,
// arrows move, Enter chooses, Escape clears the filter and then quits. Without cursor control
// (TERM=dumb) it is a numbered menu read as a line.
//
// A picker may carry one setting: a line under the title that names it and its value, which Tab
// changes to the next of its values. It is what the choice is made with, not a row.
//
// A picker given a screen (PickerScreen) takes the whole window instead, on the terminal's
// alternate screen: a banner at the top, the title, the setting as a section of its own with
// every value shown, the rows, and the keys on the last line. What was on the terminal comes
// back when it is done.
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

/// A setting shown under a picker's title: `label: value`. With more than one value, Tab goes
/// to the next one; with one, the line only says how things are.
public struct PickerSetting: Equatable, Sendable {
    public var label: String
    public var values: [String]
    /// The value shown, an index into `values`.
    public private(set) var index: Int
    /// What the setting is about, after its name on a picker's screen.
    public var note: String?
    /// What each value means, shown under the values on a picker's screen; empty, or one for
    /// each value.
    public var details: [String]

    public init(label: String, values: [String], index: Int = 0, note: String? = nil, details: [String] = []) {
        self.label = label
        self.values = values
        self.index = values.indices.contains(index) ? index : 0
        self.note = note
        self.details = details
    }

    var detail: String? {
        return details.indices.contains(index) ? details[index] : nil
    }

    var canChange: Bool {
        return values.count > 1
    }

    var value: String {
        return values.isEmpty ? "" : values[index]
    }

    mutating func next() {
        if canChange {
            index = (index + 1) % values.count
        }
    }
}

/// What a picker that takes the whole window shows around its rows.
public struct PickerScreen: Equatable, Sendable {
    /// Lines of art at the top, centered; left out when the window is too small for them.
    public var banner: [String]
    /// The product's name, on the first line when the banner is left out.
    public var name: String
    /// A line under the banner: what the choice is for.
    public var context: String?
    /// What Escape does, for the line of keys: "quit" or "back".
    public var escape: String

    public init(banner: [String], name: String, context: String? = nil, escape: String = "quit") {
        self.banner = banner
        self.name = name
        self.context = context
        self.escape = escape
    }
}

public struct Picker: Sendable {
    public let title: String
    public let sections: [PickerSection]
    public let selected: String?
    public let setting: PickerSetting?
    /// Not nil: the picker takes the whole window (with cursor control; the numbered menu of
    /// TERM=dumb is the same either way).
    public let screen: PickerScreen?

    public init(title: String, sections: [PickerSection], selected: String? = nil, setting: PickerSetting? = nil,
                screen: PickerScreen? = nil) {
        self.title = title
        self.sections = sections
        self.selected = selected
        self.setting = setting
        self.screen = screen
    }

    /// The chosen row's id. Its lines are erased before it returns or throws.
    public func run(on terminal: Terminal) throws -> String {
        return try choose(on: terminal).id
    }

    /// The chosen row's id, and the index of the setting's value when it was chosen (nil
    /// without a setting). Its lines are erased (or its screen left) before it returns or
    /// throws.
    public func choose(on terminal: Terminal) throws -> (id: String, setting: Int?) {
        guard terminal.isInteractive else {
            throw TerminalUIError.notInteractive
        }
        if !terminal.style.cursorControl {
            return try NumberedMenu(title: title, sections: sections, selected: selected, setting: setting).run(on: terminal)
        }
        return try RawSession.run(terminal, alternateScreen: screen != nil) { session in
            var model = PickerModel(sections: sections, selected: selected, setting: setting)
            var decoder = KeyDecoder()
            var height = 3
            func redraw() {
                let size = session.size()
                if let screen {
                    height = PickerScreenView.layout(screen, rows: size.rows, columns: size.columns, setting: model.setting).listHeight
                    model.settleWindow(height: height)
                    session.drawScreen(PickerScreenView.lines(title: title, screen: screen, model: model, rows: size.rows,
                                                              columns: size.columns, colors: terminal.style.colors))
                    return
                }
                height = PickerView.listHeight(rows: size.rows, filtering: !model.filter.isEmpty, setting: model.setting != nil)
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
                        return (id, model.setting?.index)
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
    private(set) var setting: PickerSetting?

    init(sections: [PickerSection], selected: String?, setting: PickerSetting? = nil) {
        self.sections = sections
        self.setting = setting
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
        case .tab:
            setting?.next()
        case .left, .right, .delete:
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
    static func listHeight(rows: Int, filtering: Bool, setting: Bool = false) -> Int {
        return max(3, rows - 2 - 1 - (filtering ? 1 : 0) - (setting ? 1 : 0))
    }

    /// The setting's line: its name and value, and how to change it when it can be.
    static func settingLine(_ setting: PickerSetting) -> Styled {
        var line = Styled("  " + TextWidth.printable(setting.label) + ": " + TextWidth.printable(setting.value))
        if setting.canChange {
            line.append("  Tab changes", dim: true)
        }
        return line
    }

    static func lines(title: String, model: PickerModel, rows: Int, columns: Int, colors: Bool) -> [String] {
        let width = max(1, columns - 1)
        var lines: [String] = []
        var titleLine = Styled(TextWidth.printable(title), bold: true)
        if TextWidth.of(titleLine.text) + TextWidth.of(hint) <= width {
            titleLine.append(hint, dim: true)
        }
        lines.append(titleLine.render(width: width, colors: colors))
        if let setting = model.setting {
            lines.append(settingLine(setting).render(width: width, colors: colors))
        }
        if !model.filter.isEmpty {
            lines.append(Styled("  filter: " + TextWidth.printable(model.filter)).render(width: width, colors: colors))
        }
        if model.shown.isEmpty {
            lines.append(Styled("  no match", dim: true).render(width: width, colors: colors))
            return lines
        }

        let height = listHeight(rows: rows, filtering: !model.filter.isEmpty, setting: model.setting != nil)
        return lines + listLines(model, height: height, colors: colors).map { $0.render(width: width, colors: colors) }
    }

    /// The widest each column is in any row: columns line up across every row, so they do not
    /// move while filtering.
    static func columnWidths(_ rows: [PickerRow]) -> [Int] {
        let columnCount = rows.map(\.columns.count).max() ?? 0
        var widths = [Int](repeating: 0, count: columnCount)
        for row in rows {
            for (index, column) in row.columns.enumerated() {
                widths[index] = max(widths[index], TextWidth.of(TextWidth.printable(column)))
            }
        }
        return widths
    }

    /// The shown items that fit `height` lines around the selection, with lines saying how many
    /// more there are above and below.
    /// With `marks` (a checklist), each row that can be chosen starts with a box, marked or not.
    static func listLines(_ model: PickerModel, height: Int, colors: Bool, marks: Set<String>? = nil) -> [Styled] {
        let columnWidths = columnWidths(model.allRows)
        let window = PickerModel.window(total: model.shown.count, height: height, selected: model.selectedIndex,
                                        offset: model.offset, shown: model.shown)
        var lines: [Styled] = []
        if window.above {
            lines.append(Styled("  ... \(window.offset) more above", dim: true))
        }
        for item in model.shown[window.offset..<(window.offset + window.count)] {
            switch item {
            case .title(let title):
                lines.append(Styled("  " + TextWidth.printable(title), bold: true))
            case .row(let row):
                lines.append(rowLine(row, selected: row.id == model.selectedID, columnWidths: columnWidths, colors: colors,
                                     mark: marks.map { $0.contains(row.id) }))
            }
        }
        if window.below {
            let more = model.shown.count - window.offset - window.count
            lines.append(Styled("  ... \(more) more below", dim: true))
        }
        return lines
    }

    /// `mark` not nil: the row is in a checklist, and starts with "[x] " or "[ ] " (spaces for
    /// a row that cannot be marked).
    static func rowLine(_ row: PickerRow, selected: Bool, columnWidths: [Int], colors: Bool, mark: Bool? = nil) -> Styled {
        var line = Styled(selected ? "  > " : "    ")
        if let mark {
            line.append(!row.enabled ? "    " : mark ? "[x] " : "[ ] ", bold: mark && row.enabled)
        }
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

/// The lines of a picker that has the whole window: exactly as many as the window has rows.
///
///     (the banner, centered, or the name alone in a small window)
///     (the context, centered)
///
///     Title   type to filter
///
///     Setting  what it is about
///       [value]  value  value   Tab changes
///       what the value means
///
///     rows ...
///
///     Up/Down move   Enter choose   ...
enum PickerScreenView {
    struct Layout: Equatable {
        /// The banner fits, with room left for rows.
        var banner: Bool
        /// Lines for the rows.
        var listHeight: Int
    }

    /// Rows a list should have before the banner may take lines from it.
    static let rowsBesideBanner = 6

    /// Lines above the rows, and the two below them (a blank one and the keys).
    private static func fixedLines(_ screen: PickerScreen, banner: Bool, setting: PickerSetting?) -> Int {
        // With the banner: a blank line, the art, the context, a blank line. Without: the name
        // and the context on one line, a blank line.
        let top = banner ? screen.banner.count + 3 : 2
        // The title (with the filter) and a blank line; the setting's name, values, meaning and
        // a blank line.
        return top + 2 + (setting == nil ? 0 : 4) + 2
    }

    static func layout(_ screen: PickerScreen, rows: Int, columns: Int, setting: PickerSetting?) -> Layout {
        let width = max(1, columns - 1)
        let bannerWidth = screen.banner.map { TextWidth.of($0) }.max() ?? 0
        let left = rows - fixedLines(screen, banner: true, setting: setting)
        if !screen.banner.isEmpty && bannerWidth <= width && left >= rowsBesideBanner {
            return Layout(banner: true, listHeight: left)
        }
        return Layout(banner: false, listHeight: max(3, rows - fixedLines(screen, banner: false, setting: setting)))
    }

    /// The setting's values, the chosen one in brackets (and reverse video, with colors).
    static func valuesLine(_ setting: PickerSetting) -> Styled {
        var line = Styled("    ")
        guard setting.canChange else {
            line.append(TextWidth.printable(setting.value))
            return line
        }
        for (index, value) in setting.values.enumerated() {
            if index > 0 {
                line.append("  ")
            }
            if index == setting.index {
                line.append("[" + TextWidth.printable(value) + "]", bold: true, reverse: true)
            } else {
                line.append(" " + TextWidth.printable(value) + " ")
            }
        }
        line.append("   Tab changes", dim: true)
        return line
    }

    /// The keys, on the last line.
    static func keysLine(setting: PickerSetting?, escape: String, filtering: Bool) -> Styled {
        var keys = [("Up/Down", "move"), ("Enter", "choose")]
        if let setting, setting.canChange {
            keys.append(("Tab", TextWidth.printable(setting.label)))
        }
        keys.append(("Esc", filtering ? "clear the filter" : escape))
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

    static func lines(title: String, screen: PickerScreen, model: PickerModel, rows: Int, columns: Int, colors: Bool) -> [String] {
        let width = max(1, columns - 1)
        let layout = layout(screen, rows: rows, columns: columns, setting: model.setting)

        // The part under the banner, as a block: the title, the setting, the rows, the keys.
        // The filter has its place on the title's line, so that typing moves nothing.
        var titleLine = Styled("  " + TextWidth.printable(title), bold: true)
        if model.filter.isEmpty {
            titleLine.append("   type to filter", dim: true)
        } else {
            titleLine.append("   filter: " + TextWidth.printable(model.filter))
        }
        var body: [Styled] = [titleLine, Styled("")]
        if let setting = model.setting {
            let label = TextWidth.printable(setting.label)
            var name = Styled("  " + label.prefix(1).uppercased() + label.dropFirst(), bold: true)
            if let note = setting.note {
                name.append("  " + TextWidth.printable(note), dim: true)
            }
            body += [name, valuesLine(setting), Styled("    " + TextWidth.printable(setting.detail ?? ""), dim: true), Styled("")]
        }
        var list = model.shown.isEmpty ? [Styled("  no match", dim: true)] : PickerView.listLines(model, height: layout.listHeight, colors: colors)
        while list.count < layout.listHeight {
            list.append(Styled(""))
        }
        body += list
        body += [Styled(""), keysLine(setting: model.setting, escape: screen.escape, filtering: !model.filter.isEmpty)]

        // As wide as its widest line could be with any filter and any value, so that the block
        // stays where it is while typing; in the middle of the window.
        let columnWidths = PickerView.columnWidths(model.allRows)
        var natural = model.allRows.map { TextWidth.of(PickerView.rowLine($0, selected: false, columnWidths: columnWidths, colors: colors).text) }.max() ?? 0
        natural = max(natural, body.prefix(body.count - list.count - 2).map { TextWidth.of($0.text) }.max() ?? 0)
        natural = max(natural, TextWidth.of(keysLine(setting: model.setting, escape: "clear the filter", filtering: false).text))
        if let setting = model.setting {
            natural = max(natural, setting.details.map { 4 + TextWidth.of(TextWidth.printable($0)) }.max() ?? 0)
        }
        // Without the banner the name and the context are the block's first line.
        var name = Styled("  " + TextWidth.printable(screen.name), bold: true)
        if let context = screen.context {
            name.append("  " + TextWidth.printable(context), dim: true)
        }
        let bannerWidth = screen.banner.map { TextWidth.of($0) }.max() ?? 0
        let bodyWidth = min(width, max(natural, layout.banner ? bannerWidth : TextWidth.of(name.text)))
        let margin = String(repeating: " ", count: (width - bodyWidth) / 2)

        func centered(_ line: Styled) -> String {
            let space = max(0, (width - TextWidth.of(line.text)) / 2)
            return String(repeating: " ", count: space) + line.render(width: width - space, colors: colors)
        }
        var lines: [String] = []
        if layout.banner {
            lines.append("")
            // As a block, so that lines of different lengths keep their columns.
            let space = String(repeating: " ", count: max(0, (width - bannerWidth) / 2))
            lines += screen.banner.map { space + Styled($0, bold: true).render(width: width - space.count, colors: colors) }
            lines.append(centered(Styled(TextWidth.printable(screen.context ?? ""), dim: true)))
            lines.append("")
        } else {
            lines.append(margin + name.render(width: bodyWidth, colors: colors))
            lines.append("")
        }
        lines += body.map { margin + $0.render(width: bodyWidth, colors: colors) }
        // A window too small for it all loses its last lines, never scrolls.
        return Array(lines.prefix(max(1, rows)))
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
/// q or the end of input quits. A line with a Tab in it changes the setting.
struct NumberedMenu {
    let title: String
    let sections: [PickerSection]
    let selected: String?
    var setting: PickerSetting?

    func run(on terminal: Terminal) throws -> (id: String, setting: Int?) {
        return try RawSession.run(terminal, mode: .line(echo: true)) { session in
            let model = PickerModel(sections: sections, selected: selected)
            var setting = setting
            var numbers: [String: Int] = [:]
            var byNumber: [Int: String] = [:]
            for row in model.allRows where row.enabled {
                numbers[row.id] = numbers.count + 1
                byNumber[numbers.count] = row.id
            }
            var filter = ""
            while true {
                session.write(Self.menu(title: title, sections: sections, filter: filter, numbers: numbers,
                                        columns: session.size().columns, setting: setting).joined(separator: "\n") + "\n")
                let enterPart = model.selectedID.flatMap { numbers[$0] }.map { "Enter for \($0), " } ?? ""
                let range = numbers.isEmpty ? "" : numbers.count == 1 ? "Choose 1 " : "Choose 1-\(numbers.count) "
                let settingPart = setting?.canChange == true ? "Tab then Enter changes \(TextWidth.printable(setting?.label ?? "")), " : ""
                session.write("\(range)(\(enterPart)text to filter, \(settingPart)q to quit): ")
                let line = try LineReader.readLine(session)
                if line.contains("\t"), setting?.canChange == true {
                    setting?.next()
                    continue
                }
                let answer = line.trimmingCharacters(in: .whitespaces)
                if answer.isEmpty {
                    if let id = model.selectedID {
                        return (id, setting?.index)
                    }
                    continue
                }
                if answer.lowercased() == "q" {
                    throw TerminalUIError.canceled
                }
                if let number = Int(answer), let id = byNumber[number] {
                    return (id, setting?.index)
                }
                filter = answer
            }
        }
    }

    static func menu(title: String, sections: [PickerSection], filter: String, numbers: [String: Int], columns: Int,
                     setting: PickerSetting? = nil) -> [String] {
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
        if let setting {
            lines.append(TextWidth.cut("  " + TextWidth.printable(setting.label) + ": " + TextWidth.printable(setting.value), to: width))
        }
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
