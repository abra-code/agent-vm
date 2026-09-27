// Tests/TerminalUITests/PickerViewTests.swift
//
// The picker's lines for a model at a window size: alignment, never reaching the last column,
// cutting, wide characters, the scroll lines, the plain style, and rows after narrowing.

import Testing
@testable import TerminalUI

@Suite struct PickerViewTests {
    let sections = [
        PickerSection(title: "Running", rows: [
            PickerRow(id: "dev1", columns: ["dev1", "dev-agents", "running"], note: "project ~/src/app"),
            PickerRow(id: "s3", columns: ["s3", "dev-acp", "running"], note: "unresponsive", enabled: false),
            PickerRow(id: "long", columns: ["avm-dev-agents-3f2a91", "dev", "running"], note: "temporary, ends with process 4711"),
        ]),
        PickerSection(title: "Stopped", rows: [PickerRow(id: "try1", columns: ["try1", "dev", "stopped"])]),
    ]

    func lines(_ model: PickerModel? = nil, rows: Int = 24, columns: Int = 80, colors: Bool = false) -> [String] {
        return PickerView.lines(title: "AgentVM - project ~/src/app", model: model ?? PickerModel(sections: sections, selected: nil),
                                rows: rows, columns: columns, colors: colors)
    }

    @Test func columnsAreAligned() {
        let drawn = lines(columns: 100)
        #expect(drawn[0].hasPrefix("AgentVM - project ~/src/app  type to filter"))
        #expect(drawn[1] == "  Running")
        #expect(drawn[2] == "  > dev1                   dev-agents  running  project ~/src/app")
        #expect(drawn[3] == "    s3                     dev-acp     running  (unresponsive)")
        #expect(drawn[4] == "    avm-dev-agents-3f2a91  dev         running  temporary, ends with process 4711")
        #expect(drawn[5] == "  Stopped")
        #expect(drawn[6] == "    try1                   dev         stopped")
    }

    @Test func linesNeverReachTheLastColumn() {
        for columns in [10, 20, 33, 40, 57, 80] {
            for colors in [false, true] {
                for line in lines(columns: columns, colors: colors) {
                    #expect(TextWidth.of(RawSession.visible(line)) <= columns - 1, "\(columns): \(line)")
                }
            }
        }
    }

    @Test func cutTextsEndInThreeDots() {
        let drawn = lines(columns: 40)
        #expect(drawn[4] == "    avm-dev-agents-3f2a91  dev      ...")
        // The hint goes when it does not fit.
        #expect(drawn[0] == "AgentVM - project ~/src/app")
        // Styled lines are cut on their visible text.
        let colored = lines(columns: 40, colors: true)
        #expect(RawSession.visible(colored[4]) == drawn[4])
    }

    @Test func wideCharactersCountTwo() {
        let wide = [PickerSection(title: nil, rows: [
            PickerRow(id: "a", columns: ["\u{65E5}\u{672C}", "x"]),
            PickerRow(id: "b", columns: ["abcde", "y"]),
        ])]
        let drawn = PickerView.lines(title: "t", model: PickerModel(sections: wide, selected: nil), rows: 24, columns: 80, colors: false)
        #expect(drawn[1] == "  > \u{65E5}\u{672C}   x")
        #expect(drawn[2] == "    abcde  y")
    }

    @Test func scrollLinesSayHowManyMore() {
        let rows = (0..<30).map { PickerRow(id: "r\($0)", columns: ["row \($0)"]) }
        var model = PickerModel(sections: [PickerSection(title: nil, rows: rows)], selected: "r15")
        // 12 rows: a block of at most 10 lines, the title and 9 for the list.
        let height = PickerView.listHeight(rows: 12, filtering: false)
        #expect(height == 9)
        model.settleWindow(height: height)
        let drawn = lines(model, rows: 12)
        #expect(drawn.count == 10)
        #expect(drawn[1].hasPrefix("  ... ") && drawn[1].hasSuffix(" more above"))
        #expect(drawn[9].hasPrefix("  ... ") && drawn[9].hasSuffix(" more below"))
        #expect(drawn.contains("  > row 15"))
        let above = Int(drawn[1].split(separator: " ")[1])!
        let below = Int(drawn[9].split(separator: " ")[1])!
        #expect(above + 7 + below == 30)
    }

    @Test func withoutColorsNothingIsStyled() {
        for line in lines(colors: false) {
            #expect(!line.contains("\u{1B}["))
        }
        let colored = lines(colors: true)
        #expect(colored[2].contains("\u{1B}[7m"))
        #expect(colored[3].contains("\u{1B}[2m"))
        #expect(!colored[3].contains("(unresponsive)"))
        #expect(colored.allSatisfy { !$0.contains("\u{1B}[") || $0.hasSuffix("\u{1B}[0m") })
    }

    @Test func aFilterLineAndNoMatch() {
        var model = PickerModel(sections: sections, selected: nil)
        for character in "zz" {
            _ = model.handle(.character(character), visibleHeight: 10)
        }
        let drawn = lines(model)
        #expect(drawn.count == 3)
        #expect(drawn[1] == "  filter: zz")
        #expect(drawn[2] == "  no match")
    }

    @Test func controlCharactersInRowsAreNotWritten() {
        let hostile = [PickerSection(title: "a\u{1B}]0;x\u{07}", rows: [PickerRow(id: "a", columns: ["p\u{1B}[2J"], note: "n\nm")])]
        let drawn = PickerView.lines(title: "t\r", model: PickerModel(sections: hostile, selected: nil), rows: 24, columns: 80, colors: false)
        #expect(drawn.allSatisfy { !$0.unicodeScalars.contains { $0.value < 0x20 } })
    }

    @Test func physicalLinesAfterNarrowing() {
        #expect(PickerView.physicalLines([70, 10], columns: 40) == 3)
        #expect(PickerView.physicalLines([0, 40, 41], columns: 40) == 4)
    }
}
