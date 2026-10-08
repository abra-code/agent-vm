// Sources/agent-vm/LogOptions.swift
//
// What `box execlog` and `box netlog` share: the time window (--since, --until) and --kept,
// which reads the logs of a deleted box (`store logs`) in place of a box's.

import AgentVMKit
import ArgumentParser
import Foundation

struct LogOptions: ParsableArguments {
    @Option(name: .long, help: ArgumentHelp("Only entries at or after this: a time (2026-10-08, \"2026-10-08 10:11\", 2026-10-08T10:11:54Z) or how long ago (45s, 10m, 2h, 3d).", valueName: "time"))
    var since: String?

    @Option(name: .long, help: ArgumentHelp("Only entries before this; the same forms as --since.", valueName: "time"))
    var until: String?

    @Option(name: .long, help: ArgumentHelp("Only what is of this session (`agent-vm session list`): the programs it started, and the connections made from its start to its end.", valueName: "id"))
    var session: String?

    @Flag(name: .long, help: "The name is that of a deleted box's kept logs, as `agent-vm store logs` lists them.")
    var kept = false

    func validate() throws {
        _ = try window(hosts: [])
    }

    /// The window the options name, with `hosts` for the network log. With `root`, the store,
    /// --session is looked up there and its time is the window, narrowed by --since and --until.
    func window(hosts: [String], root: URL? = nil, now: Date = Date()) throws -> LogFilter {
        var filter = LogFilter(hosts: hosts)
        if let session, let root {
            let window = SessionActivity.window(of: try SessionStore(root: root).session(id: session).record, now: .distantFuture)
            filter.since = window.since
            filter.until = window.until == .distantFuture ? nil : window.until
        }
        let ofSession = filter
        for (option, text) in [("--since", since), ("--until", until)] {
            guard let text else {
                continue
            }
            guard let time = LogTime.parse(text, now: now) else {
                throw ValidationError("\(option) takes \(LogTime.help)")
            }
            if option == "--since" {
                filter.since = max(time, ofSession.since ?? time)
            } else {
                filter.until = min(time, ofSession.until ?? time)
            }
        }
        if let since = filter.since, let until = filter.until, until <= since {
            // The two options alone were checked without the session (`validate`): here it is
            // the session's time they leave nothing of.
            if let start = ofSession.since {
                throw ValidationError("nothing of the session's time, \(Output.time(start)) to \(ofSession.until.map(Output.time) ?? "now"), is left with that --since or --until")
            }
            throw ValidationError("--until is not after --since")
        }
        return filter
    }

    /// Whose logs a command reads: a box's, or with --kept a deleted box's.
    struct Source {
        /// "box dev1", or "the kept logs dev1-20261008-171154".
        var label: String
        var folder: URL
        /// Nil for kept logs.
        var box: Box?
        /// Kept logs are compressed: `folder` is then a folder made for this reading, with the
        /// logs expanded, to be removed after it.
        var temporary = false

        func discard() {
            if temporary {
                try? FileManager.default.removeItem(at: folder)
            }
        }

        var execLog: ExecLog {
            return ExecLog(url: folder.appendingPathComponent(box?.execLogURL.lastPathComponent ?? "exec.jsonl"))
        }

        var eventLog: BoxEventLog {
            return BoxEventLog(url: folder.appendingPathComponent(box?.eventsLogURL.lastPathComponent ?? "events.jsonl"))
        }

        var networkLog: NetworkLog {
            return NetworkLog(url: folder.appendingPathComponent(box?.networkLogURL.lastPathComponent ?? "network.jsonl"))
        }
    }

    func source(_ name: String, store: BoxStore) throws -> Source {
        if kept {
            let readable = try KeptLogs(root: store.root).readable(name)
            if readable.temporary {
                Self.removeWhenStopped(readable.folder)
            }
            return Source(label: "the kept logs \(name)", folder: readable.folder, box: nil, temporary: readable.temporary)
        }
        let box = try store.box(named: name)
        return Source(label: "box \(box.name)", folder: box.directory, box: box)
    }

    /// The watchers `removeWhenStopped` made, kept for as long as the command runs.
    nonisolated(unsafe) private static var stopWatchers: [DispatchSourceSignal] = []

    /// A command that is stopped while it prints (Control-C, or `| head` closing its pipe) never
    /// reaches its `discard()`, and the expanded logs would stay in the temporary folder: on
    /// such a signal `folder` is removed first, and the command then ends as the signal ends it.
    private static func removeWhenStopped(_ folder: URL) {
        for number in [SIGINT, SIGTERM, SIGHUP, SIGPIPE] {
            signal(number, SIG_IGN)
            let watcher = DispatchSource.makeSignalSource(signal: number, queue: .global())
            watcher.setEventHandler {
                try? FileManager.default.removeItem(at: folder)
                signal(number, SIG_DFL)
                kill(getpid(), number)
            }
            watcher.resume()
            stopWatchers.append(watcher)
        }
    }
}
