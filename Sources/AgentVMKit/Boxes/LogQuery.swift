// Sources/AgentVMKit/Boxes/LogQuery.swift
//
// Asking a box's logs a question: the times `--since` and `--until` take, the hosts `--host`
// names, and the network log summed up by host (`box netlog --summary`), which is where data
// leaving a box shows: the bytes sent to each host.

import Foundation

/// A time as `--since` and `--until` take it.
public enum LogTime {
    /// "10m", "2h", "3d", "45s": that long before `now`. Otherwise a moment: ISO 8601
    /// ("2026-10-08T10:11:54Z"), or in this Mac's time zone "2026-10-08 10:11:54",
    /// "2026-10-08 10:11" or "2026-10-08" (the start of that day). Nil for anything else.
    public static func parse(_ text: String, now: Date = Date(), timeZone: TimeZone = .current) -> Date? {
        if let unit = text.last, let seconds = ["s": 1.0, "m": 60.0, "h": 3600.0, "d": 86400.0][unit],
           let count = Int(text.dropLast()), count >= 0, text.dropLast().allSatisfy(\.isNumber) {
            return now.addingTimeInterval(-Double(count) * seconds)
        }
        // The shape and the numbers are checked here: Foundation's parsers take more than these
        // forms (text after an ISO time, hour 25, February 30, "2026/10/08", a space for a
        // digit), and its date formatter refuses a local time that a clock change skips.
        let withZone = text.range(of: #"^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]+)?(Z|[+-][0-9]{2}(:?[0-9]{2})?)\z"#,
                                  options: .regularExpression) != nil
        guard withZone || text.range(of: #"^[0-9]{4}-[0-9]{2}-[0-9]{2}( [0-9]{2}:[0-9]{2}(:[0-9]{2})?)?\z"#, options: .regularExpression) != nil else {
            return nil
        }
        // Both forms are ASCII with their numbers at the same places.
        let digits = Array(text.utf8)
        func number(_ start: Int, _ length: Int) -> Int {
            return digits.count >= start + length ? digits[start..<(start + length)].reduce(0) { $0 * 10 + Int($1) - 48 } : 0
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? timeZone
        let (year, month, day) = (number(0, 4), number(5, 2), number(8, 2))
        guard (1...12).contains(month), number(11, 2) < 24, number(14, 2) < 60, number(17, 2) < 60,
              let first = calendar.date(from: DateComponents(year: year, month: month, day: 1)),
              let days = calendar.range(of: .day, in: .month, for: first), days.contains(day) else {
            return nil
        }
        calendar.timeZone = timeZone
        if withZone {
            return try? Date(text, strategy: .iso8601)
        }
        // A local time that a clock change skips (in some zones the start of a day) is the
        // next time there is.
        return DateComponents(calendar: calendar, timeZone: timeZone, year: year, month: month, day: day, hour: number(11, 2),
                              minute: number(14, 2), second: number(17, 2)).date
    }

    /// What a value that `parse` refuses is told.
    public static let help = "a time (2026-10-08, \"2026-10-08 10:11\", 2026-10-08T10:11:54Z) or how long ago (45s, 10m, 2h, 3d)"
}

/// The entries of a log that a question is about: a time window, and for the network log hosts.
public struct LogFilter: Sendable, Equatable {
    /// At or after this time.
    public var since: Date?
    /// Before this time.
    public var until: Date?
    /// Host names, compared without regard to case: a name, or "*.example.com" for the names
    /// under one (not example.com itself). Empty: every host.
    public var hosts: [String]

    public init(since: Date? = nil, until: Date? = nil, hosts: [String] = []) {
        self.since = since
        self.until = until
        self.hosts = hosts.map { $0.lowercased() }
    }

    /// Whether `text` is a host `hosts` can hold: a name, or "*." and a name. A "*" anywhere
    /// else would be compared as part of a name, which no host has.
    public static func isHostPattern(_ text: String) -> Bool {
        let name = text.hasPrefix("*.") ? text.dropFirst(2) : Substring(text)
        return !name.isEmpty && !name.contains("*") && !name.contains(where: \.isWhitespace)
    }

    public var isEmpty: Bool {
        return since == nil && until == nil && hosts.isEmpty
    }

    public func accepts(time: Date) -> Bool {
        if let since, time < since {
            return false
        }
        if let until, time >= until {
            return false
        }
        return true
    }

    public func accepts(host: String) -> Bool {
        guard !hosts.isEmpty else {
            return true
        }
        let name = host.lowercased()
        return hosts.contains { pattern in
            pattern.hasPrefix("*.") ? name.hasSuffix(pattern.dropFirst()) && name.count > pattern.count - 1 : name == pattern
        }
    }

    public func accepts(_ entry: NetworkLog.Entry) -> Bool {
        return accepts(time: entry.time) && accepts(host: entry.host)
    }

    public func accepts(_ record: ExecLog.Record) -> Bool {
        return accepts(time: record.started)
    }
}

/// A network log by host and port.
public struct NetworkSummary: Encodable, Equatable, Sendable {
    public struct Host: Encodable, Equatable, Sendable {
        public var host: String
        public var port: Int
        /// Allowed connections that were made.
        public var connections: Int
        /// Requests the rules refused.
        public var refused: Int
        /// Allowed requests that could not be resolved or connected.
        public var failed: Int
        /// What the box sent and received over the allowed connections, as far as logged: a
        /// connection that is still open, or whose end was not logged, counts with the bytes of
        /// its last line.
        public var bytesUp: Int
        public var bytesDown: Int
        public var first: Date
        public var last: Date
        /// The rules and packs that allowed its connections, in the order first seen.
        public var rules: [String]
    }

    /// The most bytes sent first; among equals the most refusals, then by name.
    public var hosts: [Host]
    public var connections: Int
    public var refused: Int
    public var failed: Int
    public var bytesUp: Int
    public var bytesDown: Int

    public init(_ entries: [NetworkLog.Entry]) {
        var byKey: [String: Host] = [:]
        for entry in entries {
            let name = entry.host.lowercased()
            let key = "\(name):\(entry.port)"
            var host = byKey[key] ?? Host(host: name, port: entry.port, connections: 0, refused: 0, failed: 0, bytesUp: 0, bytesDown: 0,
                                         first: entry.time, last: entry.time, rules: [])
            switch entry.decision {
            case .allowed:
                host.connections += 1
                host.bytesUp += max(0, entry.bytesUp ?? 0)
                host.bytesDown += max(0, entry.bytesDown ?? 0)
            case .denied:
                host.refused += 1
            case .failed:
                host.failed += 1
            }
            host.first = min(host.first, entry.time)
            host.last = max(host.last, entry.time)
            if let rule = entry.rule, !host.rules.contains(rule) {
                host.rules.append(rule)
            }
            byKey[key] = host
        }
        hosts = byKey.values.sorted { first, second in
            if first.bytesUp != second.bytesUp {
                return first.bytesUp > second.bytesUp
            }
            if first.refused != second.refused {
                return first.refused > second.refused
            }
            return (first.host, first.port) < (second.host, second.port)
        }
        connections = hosts.reduce(0) { $0 + $1.connections }
        refused = hosts.reduce(0) { $0 + $1.refused }
        failed = hosts.reduce(0) { $0 + $1.failed }
        bytesUp = hosts.reduce(0) { $0 + $1.bytesUp }
        bytesDown = hosts.reduce(0) { $0 + $1.bytesDown }
    }
}
