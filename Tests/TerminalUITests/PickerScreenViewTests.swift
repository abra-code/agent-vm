// Tests/TerminalUITests/PickerScreenViewTests.swift
//
// The lines of a picker that has the whole window: one for each row of the window and none
// reaching the last column, the banner only where it leaves room for rows, the setting with
// every value and the chosen one marked, the filter on the title's line, and the keys last.

import Testing
@testable import TerminalUI

@Suite struct PickerScreenViewTests {
    let sections = [
        PickerSection(title: "Running", rows: [
            PickerRow(id: "dev1", columns: ["dev1", "dev-agents", "running"], note: "project ~/src/app"),
            PickerRow(id: "s3", columns: ["s3", "dev-acp", "running"], note: "unresponsive", enabled: false),
        ]),
        PickerSection(title: "Stopped", rows: [PickerRow(id: "try1", columns: ["try1", "dev", "stopped"])]),
    ]
    let screen = PickerScreen(banner: ["#   #", " # # ", "  #  "], name: "Product", context: "project ~/src/app")
    let setting = PickerSetting(label: "snapshot", values: ["whole folder", "git folders only", "none"], index: 1, note: "what is copied",
                                details: ["all of it", "the git folders", "nothing"])

    func model(setting: PickerSetting? = nil) -> PickerModel {
        return PickerModel(sections: sections, selected: nil, setting: setting)
    }

    func lines(_ model: PickerModel, rows: Int = 30, columns: Int = 80, colors: Bool = false) -> [String] {
        return PickerScreenView.lines(title: "Choose a box", screen: screen, model: model, rows: rows, columns: columns, colors: colors)
    }

    @Test func oneLineForEachRowAndNoneReachesTheLastColumn() {
        for rows in [1, 5, 12, 24, 50] {
            for columns in [10, 33, 57, 80, 200] {
                for colors in [false, true] {
                    let drawn = lines(model(setting: setting), rows: rows, columns: columns, colors: colors)
                    // A window too small for the fixed lines shows what fits of them.
                    #expect(drawn.count <= rows)
                    if rows >= 24 {
                        #expect(drawn.count == rows)
                    }
                    for line in drawn {
                        #expect(TextWidth.of(RawSession.visible(line)) <= columns - 1, "\(rows) x \(columns): \(line)")
                    }
                }
            }
        }
    }

    @Test func theBannerIsShownOnlyWithRoomForRows() {
        let fixed = screen.banner.count + 3 + 2 + 4 + 2
        let roomy = PickerScreenView.layout(screen, rows: fixed + PickerScreenView.rowsBesideBanner, columns: 80, setting: setting)
        #expect(roomy == PickerScreenView.Layout(banner: true, listHeight: PickerScreenView.rowsBesideBanner))
        // One row less: the banner goes, and its lines are the list's.
        let tight = PickerScreenView.layout(screen, rows: fixed + PickerScreenView.rowsBesideBanner - 1, columns: 80, setting: setting)
        #expect(!tight.banner)
        #expect(tight.listHeight == PickerScreenView.rowsBesideBanner - 1 + screen.banner.count + 1)
        // A window narrower than the art.
        #expect(!PickerScreenView.layout(screen, rows: 50, columns: 5, setting: nil).banner)
        // Never fewer than three lines of rows.
        #expect(PickerScreenView.layout(screen, rows: 4, columns: 80, setting: setting).listHeight == 3)
    }

    @Test func theBannerIsCenteredAsABlock() {
        let drawn = lines(model(), rows: 30, columns: 80)
        #expect(drawn[0] == "")
        // 79 columns, art 5 wide: 37 spaces before each line, whatever its own length.
        #expect(drawn[1] == String(repeating: " ", count: 37) + "#   #")
        #expect(drawn[2] == String(repeating: " ", count: 37) + " # # ")
        #expect(drawn[4].trimmingCharacters(in: .whitespaces) == "project ~/src/app")
        // In a small window the name and the context take one line.
        let small = lines(model(), rows: 12, columns: 80)
        #expect(small[0].trimmingCharacters(in: .whitespaces) == "Product  project ~/src/app")
        #expect(!small.contains { $0.contains("#") })
    }

    @Test func theSettingShowsEveryValueAndMarksTheChosenOne() {
        let drawn = lines(model(setting: setting)).map { $0.trimmingCharacters(in: .whitespaces) }
        #expect(drawn.contains("Snapshot  what is copied"))
        #expect(drawn.contains("whole folder   [git folders only]   none    Tab changes"))
        #expect(drawn.contains("the git folders"))
        #expect(drawn.last == "Up/Down move   Enter choose   Tab snapshot   Esc quit")
        // With colors the chosen value is in reverse video as well.
        let colored = lines(model(setting: setting), colors: true)
        #expect(colored.contains { $0.contains("\u{1B}[1;7m[git folders only]\u{1B}[0m") })
        // Tab goes to the next value, and its meaning follows.
        var changed = model(setting: setting)
        _ = changed.handle(.tab, visibleHeight: 5)
        let after = lines(changed).map { $0.trimmingCharacters(in: .whitespaces) }
        #expect(after.contains("whole folder    git folders only   [none]   Tab changes"))
        #expect(after.contains("nothing"))
    }

    @Test func aSettingWithOneValueOnlySaysIt() {
        let named = PickerSetting(label: "snapshot", values: ["none (--no-snapshot)"], details: ["nothing"])
        let drawn = lines(model(setting: named)).map { $0.trimmingCharacters(in: .whitespaces) }
        #expect(drawn.contains("none (--no-snapshot)"))
        #expect(!drawn.contains { $0.contains("Tab") })
    }

    @Test func theFilterIsOnTheTitlesLineAndMovesNothing() {
        var filtered = model(setting: setting)
        let before = lines(filtered)
        #expect(before.contains { $0.hasSuffix("Choose a box   type to filter") })
        _ = filtered.handle(.character("y"), visibleHeight: 5)
        let after = lines(filtered)
        #expect(after.contains { $0.hasSuffix("Choose a box   filter: y") })
        #expect(after.count == before.count)
        // The block starts at the same column with fewer rows shown.
        let margin: (String) -> Int = { $0.prefix { $0 == " " }.count }
        #expect(margin(after.first { $0.contains("Choose a box") }!) == margin(before.first { $0.contains("Choose a box") }!))
        #expect(after.last?.hasSuffix("Esc clear the filter") == true)
        #expect(after.contains { $0.contains("> try1") })
        #expect(!after.contains { $0.contains("dev1") })
        // Nothing matches.
        _ = filtered.handle(.character("q"), visibleHeight: 5)
        #expect(lines(filtered).contains { $0.hasSuffix("  no match") })
    }

    @Test func withoutTheBannerTheContextIsCutOnlyByTheWindow() {
        var long = screen
        long.context = "project ~/src/" + String(repeating: "a", count: 60)
        let drawn = PickerScreenView.lines(title: "Choose a box", screen: long, model: model(), rows: 12, columns: 120, colors: false)
        #expect(drawn[0].hasSuffix("Product  " + long.context!))
        let narrow = PickerScreenView.lines(title: "Choose a box", screen: long, model: model(), rows: 12, columns: 40, colors: false)
        #expect(narrow[0].hasSuffix("..."))
        #expect(TextWidth.of(narrow[0]) <= 39)
    }

    @Test func whatEscapeDoesIsSaid() {
        var back = screen
        back.escape = "back"
        let drawn = PickerScreenView.lines(title: "Images", screen: back, model: model(), rows: 24, columns: 80, colors: false)
        #expect(drawn.last?.hasSuffix("Up/Down move   Enter choose   Esc back") == true)
    }

    @Test func withoutColorsNothingIsStyled() {
        for line in lines(model(setting: setting)) {
            #expect(!line.contains("\u{1B}"))
        }
    }
}
