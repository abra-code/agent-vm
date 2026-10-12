// Tests/TerminalUITests/ChecklistTests.swift
//
// The checklist: what its keys do to the marks, its lines at a window size (a box before each
// row that can be marked, the details of the row under the cursor, what Enter would do), and a
// run on a pseudo-terminal.

import Darwin
import Foundation
import Testing
@testable import TerminalUI

@Suite struct ChecklistTests {
    let list = Checklist(name: "Product", title: "what changed in ~/src/app", summary: ["3 added, 1 modified", "  warning: one"],
                         rows: [PickerRow(id: "hook", columns: ["HIGH", "added", ".git/hooks/pre-commit"]),
                                PickerRow(id: "inner", columns: ["medium", "added", "new/run"], note: "goes with new/", enabled: false),
                                PickerRow(id: "a", columns: ["", "modified", "a.txt"]),
                                PickerRow(id: "new", columns: ["", "added", "new/"], note: "2 entries inside")],
                         details: ["hook": [".git/hooks/pre-commit", "git hook: runs on the next git operation", "third", "fourth"]],
                         words: Checklist.Words(action: "undo", rest: "keep"))

    func model() -> PickerModel {
        return PickerModel(sections: [PickerSection(title: nil, rows: list.rows)], selected: nil)
    }

    func lines(_ model: PickerModel, marks: Set<String> = [], rows: Int = 24, columns: Int = 100, colors: Bool = false) -> [String] {
        return ChecklistView.lines(list, model: model, marks: marks, rows: rows, columns: columns, colors: colors)
    }

    @Test func spaceMarksTheRowUnderTheCursor() {
        var model = model()
        var marks = Set<String>()
        #expect(Checklist.handle(.character(" "), model: &model, marks: &marks, visibleHeight: 5) == .continuing)
        #expect(marks == ["hook"])
        // Down skips the row that cannot be marked.
        _ = Checklist.handle(.down, model: &model, marks: &marks, visibleHeight: 5)
        _ = Checklist.handle(.character(" "), model: &model, marks: &marks, visibleHeight: 5)
        #expect(marks == ["hook", "a"])
        // Space again takes the mark off.
        _ = Checklist.handle(.character(" "), model: &model, marks: &marks, visibleHeight: 5)
        #expect(marks == ["hook"])
    }

    @Test func allAndNone() {
        var model = model()
        var marks = Set<String>()
        for key: Character in ["a", "u", "A"] {
            marks = []
            _ = Checklist.handle(.character(key), model: &model, marks: &marks, visibleHeight: 5)
            // Every row that can be marked, never the disabled one.
            #expect(marks == ["hook", "a", "new"])
        }
        _ = Checklist.handle(.character("n"), model: &model, marks: &marks, visibleHeight: 5)
        #expect(marks.isEmpty)
    }

    @Test func otherTextDoesNothingAndNeverFilters() {
        var model = model()
        var marks = Set<String>()
        for key in [Key.character("x"), .character("k"), .tab, .backspace, .controlU, .controlW] {
            #expect(Checklist.handle(key, model: &model, marks: &marks, visibleHeight: 5) == .continuing)
        }
        #expect(marks.isEmpty)
        #expect(model.filter.isEmpty)
        #expect(model.shown.count == 4)
    }

    @Test func enterEndsAndEscapeCancels() {
        var model = model()
        var marks: Set<String> = ["a"]
        #expect(Checklist.handle(.enter, model: &model, marks: &marks, visibleHeight: 5) == .chosen("hook"))
        #expect(Checklist.handle(.escape, model: &model, marks: &marks, visibleHeight: 5) == .canceled)
        #expect(Checklist.handle(.controlC, model: &model, marks: &marks, visibleHeight: 5) == .canceled)
        #expect(marks == ["a"])
    }

    @Test func theLinesShowBoxesDetailsAndWhatEnterDoes() {
        let drawn = lines(model(), marks: ["a"])
        #expect(drawn.count == 24)
        #expect(drawn[0] == "  Product  what changed in ~/src/app")
        #expect(drawn[1] == "  3 added, 1 modified")
        #expect(drawn[2] == "    warning: one")
        #expect(drawn[3] == "")
        #expect(drawn[4] == "  > [ ] HIGH    added     .git/hooks/pre-commit")
        // No box for the row that goes with its folder.
        #expect(drawn[5] == "        medium  added     new/run                (goes with new/)")
        #expect(drawn[6] == "    [x]         modified  a.txt")
        #expect(drawn[7] == "    [ ]         added     new/                   2 entries inside")
        // The details of the row under the cursor: three lines at most, in their own place.
        #expect(Array(drawn[19...21]) == ["  .git/hooks/pre-commit", "  git hook: runs on the next git operation", "  third"])
        #expect(drawn[23] == "  Space mark to undo   a all   n none   Enter undo 1, keep 2   Esc keep all")
        // A row without details leaves the place empty, and nothing moves.
        var moved = model()
        var marks = Set<String>()
        _ = Checklist.handle(.down, model: &moved, marks: &marks, visibleHeight: 5)
        let after = lines(moved)
        #expect(Array(after[19...21]) == ["", "", ""])
        #expect(after[23].hasSuffix("Enter keep all   Esc keep all"))
        #expect(lines(model(), marks: ["hook", "a", "new"])[23].contains("Enter undo all 3   Esc"))
    }

    @Test func oneLineForEachRowAndNoneReachesTheLastColumn() {
        for rows in [1, 6, 12, 24, 60] {
            for columns in [10, 31, 80, 200] {
                for colors in [false, true] {
                    let drawn = lines(model(), marks: ["a"], rows: rows, columns: columns, colors: colors)
                    #expect(drawn.count <= rows)
                    if rows >= 12 {
                        #expect(drawn.count == rows)
                    }
                    for line in drawn {
                        #expect(TextWidth.of(RawSession.visible(line)) <= columns - 1, "\(rows) x \(columns): \(line)")
                    }
                }
            }
        }
    }

    @Test func longDetailsAreWrappedAtSpaces() {
        #expect(ChecklistView.wrapped("one two three four", width: 9) == ["one two", "three", "four"])
        #expect(ChecklistView.wrapped("short", width: 80) == ["short"])
        #expect(ChecklistView.wrapped("", width: 10) == [""])
        // A word longer than a line stays whole.
        #expect(ChecklistView.wrapped("a /very/long/path b", width: 6) == ["a", "/very/long/path", "b"])
        // In the window: the second detail line continues on the third.
        let drawn = lines(model(), columns: 31)
        #expect(Array(drawn[19...21]) == ["  .git/hooks/pre-commit", "  git hook: runs on the next", "  git operation"])
    }

    @Test func aLongSummaryIsCut() {
        let long = Checklist(name: "P", title: "t", summary: (1...9).map { "line \($0)" }, rows: list.rows, words: list.words)
        #expect(ChecklistView.summaryLines(long) == ["line 1", "line 2", "line 3", "... and 6 more lines"])
        #expect(ChecklistView.summaryLines(list) == list.summary)
    }
}

@Suite(.serialized) struct ChecklistTerminalTests {
    let list = Checklist(name: "Product", title: "what changed", rows: [PickerRow(id: "one", columns: ["one"]), PickerRow(id: "two", columns: ["two"])],
                         words: Checklist.Words(action: "undo", rest: "keep"))

    @Test func theMarksComeBackAndTheScreenIsLeft() throws {
        let pty = try PseudoTerminal()
        let before = pty.settings()
        let terminal = Terminal(input: pty.slave, output: pty.slave, environment: ["TERM": "xterm-256color"])
        let list = list
        let running = Running { try list.run(on: terminal) }
        #expect(pty.waitFor("Enter"))
        #expect(pty.text.hasPrefix(RawSession.enterAlternateScreen))
        pty.type("\u{1B}[B ")
        #expect(pty.waitFor("[x]"))
        pty.type("\r")
        #expect(try running.wait(pty) == ["two"])
        #expect(pty.text.hasSuffix(RawSession.leaveAlternateScreen))
        #expect(sameSettings(pty.settings(), before))
    }

    @Test func escapeCancelsAndEnterAloneMarksNothing() throws {
        for (keys, marks) in [("\u{1B}", nil), ("\r", Set<String>())] as [(String, Set<String>?)] {
            let pty = try PseudoTerminal()
            let terminal = Terminal(input: pty.slave, output: pty.slave, environment: ["TERM": "xterm-256color"])
            let list = list
            let running = Running { try list.run(on: terminal) }
            #expect(pty.waitFor("Enter"))
            pty.type(keys)
            if let marks {
                #expect(try running.wait(pty) == marks)
            } else {
                #expect(throws: TerminalUIError.canceled) { try running.wait(pty) }
            }
            #expect(pty.text.hasSuffix(RawSession.leaveAlternateScreen))
        }
    }

    @Test func withoutCursorControlItIsRefused() throws {
        let pty = try PseudoTerminal()
        let terminal = Terminal(input: pty.slave, output: pty.slave, environment: ["TERM": "dumb"])
        #expect(throws: TerminalUIError.notInteractive) { try list.run(on: terminal) }
    }
}
