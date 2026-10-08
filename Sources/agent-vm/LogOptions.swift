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

    @Flag(name: .long, help: "The name is that of a deleted box's kept logs, as `agent-vm store logs` lists them.")
    var kept = false

    func validate() throws {
        _ = try window(hosts: [])
    }

    /// The window the options name, with `hosts` for the network log.
    func window(hosts: [String], now: Date = Date()) throws -> LogFilter {
        var filter = LogFilter(hosts: hosts)
        for (option, text) in [("--since", since), ("--until", until)] {
            guard let text else {
                continue
            }
            guard let time = LogTime.parse(text, now: now) else {
                throw ValidationError("\(option) takes \(LogTime.help)")
            }
            if option == "--since" {
                filter.since = time
            } else {
                filter.until = time
            }
        }
        if let since = filter.since, let until = filter.until, until <= since {
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

        var execLog: ExecLog {
            return ExecLog(url: folder.appendingPathComponent(box?.execLogURL.lastPathComponent ?? "exec.jsonl"))
        }

        var networkLog: NetworkLog {
            return NetworkLog(url: folder.appendingPathComponent(box?.networkLogURL.lastPathComponent ?? "network.jsonl"))
        }
    }

    func source(_ name: String, store: BoxStore) throws -> Source {
        if kept {
            return Source(label: "the kept logs \(name)", folder: try KeptLogs(root: store.root).folder(of: name), box: nil)
        }
        let box = try store.box(named: name)
        return Source(label: "box \(box.name)", folder: box.directory, box: box)
    }
}
