// Sources/agent-vm/StartProgress.swift
//
// The time passing while connect starts a box, which takes 20-30 seconds of macOS booting with
// nothing to report in between. With cursor control, one line is redrawn each second:
// "Starting box dev1  12 s (usually about 29 s)", the estimate from the box's last boot; when
// the start ends it becomes "Starting box dev1" again, so the scrollback reads as before.
// Without cursor control (TERM=dumb) a plain line every 10 seconds.

import AgentVMKit
import Darwin
import Foundation
import TerminalUI

final class StartProgress {
    private let box: String
    /// Seconds the box's last start took; nil for a box that never started.
    private let estimate: Int?
    private let terminal: Terminal
    private let live: Bool
    private let began = ContinuousClock.now
    /// The seconds last shown; the next plain line's seconds without cursor control.
    private var shown = -1
    private var nextPlain = 10
    private var lineOpen = false
    /// "Starting box dev1" was written as a line of its own (before a note); the counting
    /// line then shows only the seconds, under it.
    private var headed = false

    init(box: String, estimate: Int?, terminal: Terminal) {
        self.box = box
        self.estimate = estimate
        self.terminal = terminal
        live = terminal.style.cursorControl
    }

    var elapsedSeconds: Int64 {
        return (ContinuousClock.now - began).components.seconds
    }

    func begin() {
        if live {
            draw()
        } else {
            print("Starting box \(box)" + (estimate.map { " (usually about \($0) s)" } ?? ""))
        }
    }

    /// At every poll of the start.
    func tick() {
        let seconds = Int(elapsedSeconds)
        if live {
            if seconds != shown {
                draw()
            }
        } else if seconds >= nextPlain {
            print("  \(seconds) s")
            nextPlain += 10
        }
    }

    /// A line of its own while the start goes on ("waiting for the box to stop"), under the
    /// "Starting box dev1" heading; the counting line goes on below it.
    func note(_ line: String) {
        if live && lineOpen {
            terminal.write(headed ? "\r\u{1B}[K" : "\r\u{1B}[KStarting box \(box)\n")
            headed = true
            lineOpen = false
        }
        print(line)
        if live {
            draw()
        }
    }

    /// The start is over (done or failed): the line reads "Starting box dev1".
    func end() {
        guard live && lineOpen else {
            return
        }
        // Erased first and written whole: nothing is redrawn after it, so it may wrap on a
        // narrow window, and the name stays whole in the scrollback. Under a heading already
        // written, the counting line only goes.
        terminal.write(headed ? "\r\u{1B}[K" : "\r\u{1B}[KStarting box \(box)\n")
        lineOpen = false
    }

    private func draw() {
        let seconds = Int(elapsedSeconds)
        shown = seconds
        var text = headed ? "  \(seconds) s" : "Starting box \(box)  \(seconds) s"
        if let estimate {
            text += " (usually about \(estimate) s)"
        }
        // What print wrote before goes out first.
        fflush(stdout)
        terminal.write("\r" + cut(text) + "\u{1B}[K")
        lineOpen = true
    }

    /// Short enough never to wrap, which would break the redraw (box names are ASCII).
    private func cut(_ text: String) -> String {
        return String(text.prefix(max(1, terminal.size().columns - 1)))
    }
}
