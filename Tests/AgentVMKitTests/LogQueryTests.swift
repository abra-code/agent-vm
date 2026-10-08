// Tests/AgentVMKitTests/LogQueryTests.swift
//
// The questions `box execlog` and `box netlog` take: the times of --since and --until, the
// hosts of --host, the summary by host, and the exec log read across its two files.

import Foundation
import Testing
@testable import AgentVMKit

@Suite struct LogQueryTests {
    static let utc = TimeZone(identifier: "UTC")!
    static let now = Date(timeIntervalSince1970: 1_790_000_000)

    static func entry(_ host: String, _ decision: NetworkLog.Decision, at seconds: TimeInterval, port: Int = 443, up: Int? = nil,
                      down: Int? = nil, rule: String? = nil) -> NetworkLog.Entry {
        return NetworkLog.Entry(time: now.addingTimeInterval(seconds), method: "CONNECT", host: host, port: port, decision: decision,
                                rule: rule, bytesUp: up, bytesDown: down)
    }

    @Test func timesAreAMomentOrHowLongAgo() throws {
        #expect(LogTime.parse("45s", now: Self.now) == Self.now.addingTimeInterval(-45))
        #expect(LogTime.parse("10m", now: Self.now) == Self.now.addingTimeInterval(-600))
        #expect(LogTime.parse("2h", now: Self.now) == Self.now.addingTimeInterval(-7200))
        #expect(LogTime.parse("3d", now: Self.now) == Self.now.addingTimeInterval(-3 * 86400))
        #expect(LogTime.parse("0m", now: Self.now) == Self.now)
        let moment = try Date("2026-10-08T10:11:54Z", strategy: .iso8601)
        #expect(LogTime.parse("2026-10-08T10:11:54Z") == moment)
        #expect(LogTime.parse("2026-10-08 10:11:54", timeZone: Self.utc) == moment)
        #expect(LogTime.parse("2026-10-08 10:11", timeZone: Self.utc) == moment.addingTimeInterval(-54))
        #expect(LogTime.parse("2026-10-08", timeZone: Self.utc) == (try Date("2026-10-08T00:00:00Z", strategy: .iso8601)))
        // A zone other than UTC moves a local time, and not one that names its own.
        let plusTwo = try #require(TimeZone(secondsFromGMT: 7200))
        #expect(LogTime.parse("2026-10-08 12:11:54", timeZone: plusTwo) == moment)
        #expect(LogTime.parse("2026-10-08T10:11:54Z", timeZone: plusTwo) == moment)
        #expect(moment.timeIntervalSince1970 == 1_791_454_314)
        #expect(LogTime.parse("2026-10-08T12:11:54+02:00") == moment)
        #expect(LogTime.parse("2026-10-08T10:11:54.250Z") == moment.addingTimeInterval(0.25))
        for text in ["", "m", "-5m", "5", "5w", "1.5h", "ten minutes", "2026-13-01", "2026-10-08 25:00", "2026-10-08 10:11:54 extra", "10:11", "٣m",
                     // What Foundation's own parsers would take.
                     "2026-10-08T10:11:54Z extra", "2026-10-08T25:11:54Z", "2026-02-30T10:11:54Z", "2026-10-08T10:11:60Z", "2026-10-08T10:11:54",
                     "2026-10-08T10:11:54GMT", "2026-02-30", "2026/10/08", "2026.10.08", " 026-10-08", "2026-10- 8", "2026-10-08  1:11",
                     "2026-10-08 10.11", "2026-10-08 10:11Z", "2026-10-08\n"] {
            #expect(LogTime.parse(text, now: Self.now, timeZone: Self.utc) == nil, "\(text)")
        }
        #expect(LogTime.parse("2028-02-29", timeZone: Self.utc) == (try Date("2028-02-29T00:00:00Z", strategy: .iso8601)))
        // A local time that a clock change skips is the next time there is: in Cairo the day
        // of the change starts at 1:00, and in Los Angeles 2:30 that night is 3:30.
        let cairo = try #require(TimeZone(identifier: "Africa/Cairo"))
        #expect(LogTime.parse("2026-04-24", timeZone: cairo) == (try Date("2026-04-23T22:00:00Z", strategy: .iso8601)))
        let losAngeles = try #require(TimeZone(identifier: "America/Los_Angeles"))
        #expect(LogTime.parse("2026-03-08 02:30", timeZone: losAngeles) == (try Date("2026-03-08T10:30:00Z", strategy: .iso8601)))
        #expect(LogTime.parse("2026-11-01 01:30", timeZone: losAngeles) == (try Date("2026-11-01T08:30:00Z", strategy: .iso8601)))
    }

    @Test func theWindowTakesItsStartAndNotItsEnd() {
        let filter = LogFilter(since: Self.now, until: Self.now.addingTimeInterval(60))
        #expect(!filter.accepts(time: Self.now.addingTimeInterval(-1)))
        #expect(filter.accepts(time: Self.now))
        #expect(filter.accepts(time: Self.now.addingTimeInterval(59)))
        #expect(!filter.accepts(time: Self.now.addingTimeInterval(60)))
        #expect(LogFilter().isEmpty && LogFilter().accepts(time: .distantPast))
        #expect(!LogFilter(hosts: ["x"]).isEmpty)
    }

    @Test func hostsAreNamesOrTheNamesUnderOne() {
        let filter = LogFilter(hosts: ["API.example.com", "*.github.com"])
        #expect(filter.accepts(host: "api.example.com") && filter.accepts(host: "Api.Example.COM"))
        #expect(!filter.accepts(host: "example.com") && !filter.accepts(host: "xapi.example.com"))
        #expect(filter.accepts(host: "api.github.com") && filter.accepts(host: "a.b.github.com"))
        #expect(!filter.accepts(host: "github.com") && !filter.accepts(host: "evilgithub.com") && !filter.accepts(host: ".github.com.evil"))
        #expect(LogFilter().accepts(host: "anything"))
        for pattern in ["a.example", "*.example.com", "localhost", "10.0.0.1"] {
            #expect(LogFilter.isHostPattern(pattern), "\(pattern)")
        }
        for pattern in ["", "*", "*.", "*github.com", "a.*.com", "a b", "*.*.com"] {
            #expect(!LogFilter.isHostPattern(pattern), "\(pattern)")
        }
        // An entry must pass both.
        let window = LogFilter(since: Self.now, hosts: ["a.example"])
        #expect(window.accepts(Self.entry("a.example", .allowed, at: 1)))
        #expect(!window.accepts(Self.entry("a.example", .allowed, at: -1)))
        #expect(!window.accepts(Self.entry("b.example", .allowed, at: 1)))
    }

    @Test func theSummaryAddsUpByHostAndPort() {
        let sums = NetworkSummary([
            Self.entry("small.example", .allowed, at: 0, up: 10, down: 1000, rule: "public"),
            Self.entry("Big.example", .allowed, at: 5, up: 4000, down: 20, rule: "pack:x"),
            Self.entry("big.example", .allowed, at: 9, up: 1000, down: 30, rule: "big.example"),
            Self.entry("big.example", .allowed, at: 7, port: 8443, up: 1, down: 1, rule: "pack:x"),
            Self.entry("big.example", .denied, at: 2),
            Self.entry("open.example", .allowed, at: 3),
            Self.entry("no.example", .denied, at: 4),
            Self.entry("no.example", .denied, at: 6),
            Self.entry("down.example", .failed, at: 8, rule: "public"),
        ])
        #expect(sums.hosts.map { "\($0.host):\($0.port)" } == ["big.example:443", "small.example:443", "big.example:8443", "no.example:443", "down.example:443", "open.example:443"])
        let big = sums.hosts[0]
        #expect(big.connections == 2 && big.refused == 1 && big.failed == 0 && big.bytesUp == 5000 && big.bytesDown == 50)
        #expect(big.first == Self.now.addingTimeInterval(2) && big.last == Self.now.addingTimeInterval(9))
        #expect(big.rules == ["pack:x", "big.example"])
        #expect(sums.hosts[3].refused == 2 && sums.hosts[3].connections == 0 && sums.hosts[3].rules.isEmpty)
        #expect(sums.hosts[4].failed == 1 && sums.hosts[4].rules == ["public"])
        // A connection without bytes yet is still a connection.
        #expect(sums.hosts[5].connections == 1 && sums.hosts[5].bytesUp == 0)
        #expect(sums.connections == 5 && sums.refused == 3 && sums.failed == 1 && sums.bytesUp == 5011 && sums.bytesDown == 1051)
        let empty = NetworkSummary([])
        #expect(empty.hosts.isEmpty && empty.connections == 0 && empty.bytesUp == 0)
    }

    @Test func theExecLogIsReadAcrossBothFilesAndFiltered() throws {
        let scratch = try Scratch()
        let url = scratch.root.appendingPathComponent("exec.jsonl")
        // A small limit: a later program's start moves the earlier ones into the .1 file.
        let log = ExecLog(url: url, maxBytes: 300)
        var ids: [String] = []
        for index in 0..<4 {
            let id = "id\(index)"
            ids.append(id)
            #expect(log.append(ExecLog.Entry(id: id, event: .start, time: Self.now.addingTimeInterval(Double(index) * 100), argv: ["/bin/echo", String(index)], user: "agent")) == nil)
        }
        // An end written after the move still finds its start.
        #expect(log.append(ExecLog.Entry(id: "id0", event: .end, time: Self.now.addingTimeInterval(500), status: 7, seconds: 1)) == nil)
        #expect(FileManager.default.fileExists(atPath: url.path + ".1"))
        let all = log.records()
        #expect(all.map(\.id) == ids)
        #expect(all[0].status == 7)
        #expect(log.records(last: 2).map(\.id) == ["id2", "id3"])
        let window = LogFilter(since: Self.now.addingTimeInterval(100), until: Self.now.addingTimeInterval(300))
        #expect(log.records(matching: window.accepts).map(\.id) == ["id1", "id2"])
        // The last N of those that match, not those of the last N that match.
        #expect(log.records(last: 1, matching: window.accepts).map(\.id) == ["id2"])
        #expect(ExecLog(url: scratch.root.appendingPathComponent("none.jsonl")).records().isEmpty)
    }
}
