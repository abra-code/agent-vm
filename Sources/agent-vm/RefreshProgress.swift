// Sources/agent-vm/RefreshProgress.swift
//
// `avm new <image> --refresh`: the image's tools are updated before the box is made, by this
// agent-vm run as `image update <image> --tools --json`. Its progress events (one JSON object
// per line on its standard error) become one redrawn line that says what is happening, how
// far it is and how long it has taken: "Updating the tools of dev  41 s (usually about 85 s):
// recipe 2 of 3, [1/2] Node". Without cursor control (TERM=dumb) each step is a line of its own.

import AgentVMKit
import Darwin
import Foundation
import TerminalUI

final class RefreshProgress {
    private let image: String
    private let terminal: Terminal
    private let live: Bool
    private let began = ContinuousClock.now
    /// Seconds the image's last tools update took, from the first event.
    private var estimate: Int?
    /// What the update is doing now, and which recipe of how many.
    private var doing = "starting"
    private var recipe: String?
    private var shown = ""
    private var lineOpen = false

    init(image: String, terminal: Terminal) {
        self.image = image
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
            print("Updating the tools of \(image)")
        }
    }

    /// One line of the update's standard error: a progress event, or the text of its error.
    /// Returns the line when it is not an event (the error message, to show if the update fails).
    func take(_ line: String) -> String? {
        guard let data = line.data(using: .utf8), let event = try? JSONDecoder().decode(ProgressEvent.self, from: data) else {
            return line
        }
        // A day at most: a number from a damaged record must not trap the conversion.
        if let seconds = event.expectedSeconds, seconds >= 0, seconds < 86_400 {
            estimate = Int(seconds.rounded())
        }
        switch event.event {
        case .progress:
            if event.step == "tools-update", let index = event.index, let count = event.count {
                recipe = count > 1 ? "recipe \(index) of \(count), " : nil
            }
            doing = (event.step == "recipe-step" || event.step == "recipe-check" ? recipe ?? "" : "") + event.message
            if live {
                draw()
            } else {
                print("  \(event.message)")
            }
        case .notice:
            note("  " + event.message)
        case .log:
            break
        }
        return nil
    }

    /// Every fraction of a second while the update runs: the seconds move on.
    func tick() {
        if live {
            draw()
        }
    }

    /// A line of its own above the counting line.
    func note(_ line: String) {
        if live && lineOpen {
            terminal.write("\r\u{1B}[K")
            lineOpen = false
        }
        print(line)
        if live {
            // Erased above: drawn again even when its text is the same.
            shown = ""
            draw()
        }
    }

    /// The update is over: the counting line goes, and one line says how it went.
    func end(_ summary: String) {
        if live && lineOpen {
            terminal.write("\r\u{1B}[K")
            lineOpen = false
        }
        print(summary)
    }

    private func draw() {
        // The time before the step: a long step name is what a narrow window cuts off.
        var text = "Updating the tools of \(image)  \(elapsedSeconds) s"
        if let estimate {
            text += " (usually about \(estimate) s)"
        }
        text += ": \(doing)"
        guard text != shown else {
            return
        }
        shown = text
        // What print wrote before goes out first.
        fflush(stdout)
        // Short enough never to wrap, which would break the redraw.
        terminal.write("\r" + String(text.prefix(max(1, terminal.size().columns - 1))) + "\u{1B}[K")
        lineOpen = true
    }

    /// Runs `image update <image> --tools --json` with this executable and shows its progress.
    /// Returns the update's exit status and the text of its error, if it printed one.
    /// A SIGINT, SIGTERM, SIGHUP or SIGQUIT that reaches this process meanwhile is passed on
    /// to the update once (the caller holds them off for itself): the update does not get a
    /// terminal's Control-C by itself (measured), and it is the one that has a virtual machine
    /// to shut down. It then ends as canceled, with the image as it was.
    static func run(image: String, executable: String, terminal: Terminal) throws -> (status: Int32, error: String, seconds: Int64) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["image", "update", image, "--tools", "--json"]
        let events = Pipe()
        process.standardError = events
        process.standardOutput = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        let progress = RefreshProgress(image: image, terminal: terminal)
        progress.begin()
        // The lines are read on a thread of their own, so the seconds keep moving while the
        // update says nothing.
        let lock = NSLock()
        var pending: [String] = []
        var finished = false
        let reader = Thread {
            var buffer = Data()
            let handle = events.fileHandleForReading
            while true {
                let chunk = handle.availableData
                if chunk.isEmpty {
                    break
                }
                buffer.append(chunk)
                while let newline = buffer.firstIndex(of: 10) {
                    let line = String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self)
                    buffer.removeSubrange(buffer.startIndex...newline)
                    lock.lock()
                    pending.append(line)
                    lock.unlock()
                }
            }
            lock.lock()
            if !buffer.isEmpty {
                pending.append(String(decoding: buffer, as: UTF8.self))
            }
            finished = true
            lock.unlock()
        }
        do {
            try process.run()
        } catch {
            progress.end("Updating the tools of \(image) could not start")
            throw error
        }
        reader.start()
        // Watched with a kqueue, which records a signal whatever its action is.
        let signals = kqueue()
        if signals >= 0 {
            var changes = [SIGINT, SIGTERM, SIGHUP, SIGQUIT].map {
                kevent(ident: UInt($0), filter: Int16(EVFILT_SIGNAL), flags: UInt16(EV_ADD), fflags: 0, data: 0, udata: nil)
            }
            _ = kevent(signals, &changes, Int32(changes.count), nil, 0, nil)
        }
        defer {
            if signals >= 0 {
                close(signals)
            }
        }
        var passedOn = false
        var errorLines: [String] = []
        while true {
            if signals >= 0, !passedOn {
                var event = kevent(ident: 0, filter: 0, flags: 0, fflags: 0, data: 0, udata: nil)
                var zero = timespec(tv_sec: 0, tv_nsec: 0)
                if kevent(signals, nil, 0, &event, 1, &zero) > 0, process.isRunning {
                    passedOn = true
                    // The update acts on SIGINT and SIGTERM; a closed terminal is a SIGTERM to it.
                    kill(process.processIdentifier, Int32(event.ident) == SIGINT ? SIGINT : SIGTERM)
                    progress.note("  canceling the update (its virtual machine is shut down first)")
                }
            }
            lock.lock()
            let lines = pending
            pending = []
            let done = finished
            lock.unlock()
            for line in lines where !line.isEmpty {
                if let text = progress.take(line) {
                    errorLines.append(text)
                }
            }
            if done {
                break
            }
            progress.tick()
            usleep(200_000)
        }
        process.waitUntilExit()
        let seconds = progress.elapsedSeconds
        let status = process.terminationReason == .uncaughtSignal ? 128 + process.terminationStatus : process.terminationStatus
        progress.end(status == 0 ? "Updated the tools of \(image) (\(seconds) s)"
                        : status > 128 ? "Updating the tools of \(image) was canceled" : "Updating the tools of \(image) failed")
        return (status, errorLines.joined(separator: "\n"), seconds)
    }
}
