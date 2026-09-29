// Sources/AgentVMKit/Jobs/JobLog.swift
//
// A job's log is its command's stderr under --json: progress events, one JSON object per line
// (Docs/progress-events.md), and when the command fails, agent-vm's "Error: ..." message last,
// possibly over several lines (a recipe step's output). Anything else (a warning, a crash
// report) is kept as a plain line.

import Darwin
import Foundation

public struct JobLog: Sendable {
    /// How much of a log's end `job list` reads: its last events are what it shows.
    public static let tailBytes = 1 << 20

    public var events: [ProgressEvent] = []
    /// The error's lines, "Error: " taken off the first.
    public var errorLines: [String] = []
    /// Lines that are neither events nor the error.
    public var otherLines: [String] = []

    public var lastProgress: ProgressEvent? {
        return events.last { $0.event == .progress }
    }

    public var lastNotice: String? {
        return events.last { $0.event == .notice }?.message
    }

    /// The error as agent-vm wrote it; without an "Error:" line, the last plain lines (a crash
    /// leaves no error of agent-vm's own); nil when there is neither.
    public var error: String? {
        var lines = errorLines.isEmpty ? Array(otherLines.suffix(20)) : errorLines
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
            lines.removeLast()
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    public init() {}

    /// The log at `path`: all of it, or only its last `limit` bytes (from the first whole
    /// line). A missing log is an empty one.
    public static func read(_ path: String, limit: Int? = nil) -> JobLog {
        let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            return JobLog()
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var data: Data
        if let limit {
            let size = (try? handle.seekToEnd()) ?? 0
            let start = size > UInt64(limit) ? size - UInt64(limit) : 0
            try? handle.seek(toOffset: start)
            data = (try? handle.readToEnd()) ?? Data()
            if start > 0 {
                // The first line is most likely cut; it is dropped rather than misread.
                if let newline = data.firstIndex(of: UInt8(ascii: "\n")) {
                    data = data[data.index(after: newline)...]
                } else {
                    data = Data()
                }
            }
        } else {
            data = (try? handle.readToEnd()) ?? Data()
        }
        return parse(String(decoding: data, as: UTF8.self))
    }

    public static func parse(_ text: String) -> JobLog {
        var log = JobLog()
        let decoder = JSONDecoder()
        for line in text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if !log.errorLines.isEmpty {
                log.errorLines.append(line)
            } else if line.hasPrefix("Error: ") {
                log.errorLines.append(String(line.dropFirst("Error: ".count)))
            } else if line.hasPrefix("{"), let event = try? decoder.decode(ProgressEvent.self, from: Data(line.utf8)) {
                log.events.append(event)
            } else if !line.trimmingCharacters(in: .whitespaces).isEmpty {
                log.otherLines.append(line)
            }
        }
        return log
    }
}
