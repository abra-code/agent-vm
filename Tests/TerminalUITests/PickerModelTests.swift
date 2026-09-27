// Tests/TerminalUITests/PickerModelTests.swift
//
// The picker's filter, selection and scrolling, without a terminal.

import Testing
@testable import TerminalUI

@Suite struct PickerModelTests {
    let sections = [
        PickerSection(title: "Running", rows: [
            PickerRow(id: "dev1", columns: ["dev1", "dev-agents", "running"], note: "project ~/src/app"),
            PickerRow(id: "s3", columns: ["s3", "dev-acp", "running"], note: "unresponsive", enabled: false),
            PickerRow(id: "tmp", columns: ["avm-dev-3f2a91", "dev-agents", "running"], note: "temporary"),
        ]),
        PickerSection(title: "Stopped", rows: [
            PickerRow(id: "try1", columns: ["try1", "dev", "stopped"]),
            PickerRow(id: "Work", columns: ["Work", "Dev-Agents", "stopped"]),
        ]),
    ]

    func model(selected: String? = nil) -> PickerModel {
        return PickerModel(sections: sections, selected: selected)
    }

    func type(_ text: String, into model: inout PickerModel) {
        for character in text {
            _ = model.handle(.character(character), visibleHeight: 10)
        }
    }

    @Test func selectionStartsAtThePreselectedRow() {
        #expect(model(selected: "try1").selectedID == "try1")
        #expect(model().selectedID == "dev1")
        #expect(model(selected: "gone").selectedID == "dev1")
    }

    @Test func selectionStartsAtTheFirstEnabledRowWhenThePreselectedIsDisabled() {
        #expect(model(selected: "s3").selectedID == "dev1")
        let first = PickerModel(sections: [PickerSection(title: nil, rows: [
            PickerRow(id: "a", columns: ["a"], enabled: false),
            PickerRow(id: "b", columns: ["b"]),
        ])], selected: nil)
        #expect(first.selectedID == "b")
    }

    @Test func movesSkipDisabledRowsAndTitles() {
        var model = model()
        _ = model.handle(.down, visibleHeight: 10)
        #expect(model.selectedID == "tmp")
        _ = model.handle(.down, visibleHeight: 10)
        #expect(model.selectedID == "try1")
        _ = model.handle(.up, visibleHeight: 10)
        _ = model.handle(.up, visibleHeight: 10)
        #expect(model.selectedID == "dev1")
        // No wrap at either end.
        _ = model.handle(.up, visibleHeight: 10)
        #expect(model.selectedID == "dev1")
        _ = model.handle(.end, visibleHeight: 10)
        _ = model.handle(.down, visibleHeight: 10)
        #expect(model.selectedID == "Work")
    }

    @Test func filterWordsMustAllMatchCaseInsensitively() {
        var model = model()
        type("AGENTS stop", into: &model)
        #expect(model.shown == [.title("Stopped"), .row(sections[1].rows[1])])
        #expect(model.selectedID == "Work")
        var byNote = self.model()
        type("src", into: &byNote)
        #expect(byNote.shown.compactMap(\.row).map(\.id) == ["dev1"])
    }

    @Test func emptySectionsLoseTheirTitle() {
        var model = model()
        type("try", into: &model)
        #expect(model.shown == [.title("Stopped"), .row(sections[1].rows[0])])
        type("zzz", into: &model)
        #expect(model.shown.isEmpty)
        #expect(model.selectedID == nil)
    }

    @Test func aFilterKeepsTheSelectionWhenStillShown() {
        var model = model(selected: "tmp")
        type("dev-agents", into: &model)
        #expect(model.selectedID == "tmp")
        var other = self.model(selected: "try1")
        type("temporary", into: &other)
        #expect(other.selectedID == "tmp")
    }

    @Test func escapeClearsTheFilterThenCancels() {
        var model = model()
        type("try", into: &model)
        #expect(model.handle(.escape, visibleHeight: 10) == .continuing)
        #expect(model.filter.isEmpty)
        #expect(model.shown.count == 7)
        #expect(model.handle(.escape, visibleHeight: 10) == .canceled)
        var fresh = self.model()
        #expect(fresh.handle(.controlC, visibleHeight: 10) == .canceled)
    }

    @Test func enterDoesNothingWithoutAShownRow() {
        var model = model()
        type("zzz", into: &model)
        #expect(model.handle(.enter, visibleHeight: 10) == .continuing)
        var chosen = self.model()
        _ = chosen.handle(.down, visibleHeight: 10)
        #expect(chosen.handle(.enter, visibleHeight: 10) == .chosen("tmp"))
        let disabledOnly = PickerModel(sections: [PickerSection(title: nil, rows: [PickerRow(id: "a", columns: ["a"], enabled: false)])],
                                       selected: "a")
        var copy = disabledOnly
        #expect(copy.handle(.enter, visibleHeight: 10) == .continuing)
    }

    @Test func controlDCancelsOnlyWithAnEmptyFilter() {
        var model = model()
        type("d", into: &model)
        #expect(model.handle(.controlD, visibleHeight: 10) == .continuing)
        _ = model.handle(.controlU, visibleHeight: 10)
        #expect(model.handle(.controlD, visibleHeight: 10) == .canceled)
    }

    @Test func backspaceRemovesAWholeCharacter() {
        var model = model()
        type("de\u{0301}", into: &model)
        #expect(model.filter == "d\u{00E9}")
        _ = model.handle(.backspace, visibleHeight: 10)
        #expect(model.filter == "d")
        #expect(model.filter.unicodeScalars.count == 1)
    }

    @Test func controlWRemovesTheLastWord() {
        var model = model()
        type("dev stop  ", into: &model)
        _ = model.handle(.controlW, visibleHeight: 10)
        #expect(model.filter == "dev ")
        _ = model.handle(.controlW, visibleHeight: 10)
        #expect(model.filter == "")
    }

    @Test func pagesAndEnds() {
        let rows = (0..<30).map { PickerRow(id: "r\($0)", columns: ["row \($0)"], enabled: $0 != 10 && $0 != 29) }
        var model = PickerModel(sections: [PickerSection(title: "All", rows: rows)], selected: nil)
        #expect(model.selectedID == "r0")
        _ = model.handle(.pageDown, visibleHeight: 10)
        // Item 11 is row 10 (the title is item 0), disabled: the next enabled row downwards.
        #expect(model.selectedID == "r11")
        _ = model.handle(.pageDown, visibleHeight: 10)
        #expect(model.selectedID == "r21")
        _ = model.handle(.pageDown, visibleHeight: 100)
        #expect(model.selectedID == "r28")
        _ = model.handle(.pageUp, visibleHeight: 18)
        // From item 29 to item 11, row 10, disabled: the next enabled row upwards.
        #expect(model.selectedID == "r9")
        _ = model.handle(.pageUp, visibleHeight: 100)
        #expect(model.selectedID == "r0")
        _ = model.handle(.end, visibleHeight: 10)
        #expect(model.selectedID == "r28")
        _ = model.handle(.home, visibleHeight: 10)
        #expect(model.selectedID == "r0")
    }

    @Test func theWindowKeepsTheSelectionInside() {
        let rows = (0..<30).map { PickerRow(id: "r\($0)", columns: ["row \($0)"]) }
        var model = PickerModel(sections: [PickerSection(title: "All", rows: rows)], selected: nil)
        model.settleWindow(height: 8)
        #expect(model.offset == 0)
        for _ in 0..<12 {
            _ = model.handle(.down, visibleHeight: 8)
            model.settleWindow(height: 8)
            let window = PickerModel.window(total: model.shown.count, height: 8, selected: model.selectedIndex,
                                            offset: model.offset, shown: model.shown)
            let index = model.selectedIndex!
            #expect(index >= window.offset && index < window.offset + window.count)
            #expect(window.count + (window.above ? 1 : 0) + (window.below ? 1 : 0) == 8)
        }
        _ = model.handle(.home, visibleHeight: 8)
        model.settleWindow(height: 8)
        // Back at the top, the section title shows again.
        #expect(model.offset == 0)
    }

    @Test func aTallerWindowAfterScrollingStaysInsideTheItems() {
        let rows = (0..<20).map { PickerRow(id: "r\($0)", columns: ["row \($0)"]) }
        for total in 4...20 {
            for selected in 0..<total {
                for offset in 0..<total {
                    for height in 3..<total {
                        let shown = rows[0..<total].map { PickerModel.Item.row($0) }
                        let window = PickerModel.window(total: total, height: height, selected: selected, offset: offset, shown: shown)
                        #expect(window.offset + window.count <= total, "\(total) \(selected) \(offset) \(height)")
                        #expect(selected >= window.offset && selected < window.offset + window.count)
                        #expect(window.count + (window.above ? 1 : 0) + (window.below ? 1 : 0) == height)
                    }
                }
            }
        }
        // Scrolled to the end, then the window grows (a resize): the lines stay in range.
        var model = PickerModel(sections: [PickerSection(title: nil, rows: rows)], selected: "r19")
        model.settleWindow(height: 10)
        #expect(model.offset > 0)
        model.settleWindow(height: 15)
        let drawn = PickerView.lines(title: "t", model: model, rows: 18, columns: 80, colors: false)
        #expect(drawn.count == 16)
        #expect(drawn.last == "  > row 19")
    }
}
