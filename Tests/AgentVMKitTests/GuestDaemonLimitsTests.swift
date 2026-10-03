// Tests/AgentVMKitTests/GuestDaemonLimitsTests.swift
//
// The guest daemon against what it is not meant to get: frames of the wrong size, requests that
// are not requests, more relay connections than it serves, and connections from inside the box
// without end. The real GuestServer serves one side of a socket pair (GuestPair).

import Darwin
import Foundation
import Testing
@testable import AgentVMKit

@Suite struct GuestDaemonLimitsTests {
    /// Signal and resize frames of the wrong size, and signals the host may not send, change
    /// nothing: the program runs on, takes its input and ends by itself.
    @Test func framesOfTheWrongSizeAreIgnored() throws {
        let pair = try GuestPair()
        let session = try ExecSession(descriptor: pair.client, request: GuestRequest(op: .exec, argv: ["/bin/cat"]))
        for payload in [[], [0, 0, 15], [0, 0, 0, 0, 15], [0, 0, 0, 0], [0xff, 0xff, 0xff, 0xff], [0, 0, 0, 11], [0x7f, 0xff, 0xff, 0xff]] as [[UInt8]] {
            try session.channel.send(Frame(.signal, payload))
        }
        // No terminal here, so every resize is ignored; the sizes are what a reader must survive.
        for payload in [[], [0, 24, 0, 80, 1], [0, 24, 0], [0, 24, 0, 80], [UInt8](repeating: 0xff, count: 8)] as [[UInt8]] {
            try session.channel.send(Frame(.resize, payload))
        }
        try session.sendStdin(Array("still here".utf8))
        try session.sendStdinEnd()
        var output = ""
        let report = try session.run(stdout: { output += String(decoding: $0, as: UTF8.self) }, stderr: { _ in })
        #expect(report == ExitReport(status: 0))
        #expect(output == "still here")
    }

    /// A frame only a guest sends is a broken host: the program is hung up, as when the host
    /// goes away.
    @Test(arguments: [FrameType.request, .response, .stdout, .stderr, .exit, .notice])
    func aFrameOnlyAGuestSendsHangsTheProgramUp(type: FrameType) throws {
        let pair = try GuestPair()
        let session = try ExecSession(descriptor: pair.client, request: GuestRequest(op: .exec, argv: ["/bin/sleep", "30"]))
        try session.channel.send(Frame(type, Array("{}".utf8)))
        // The daemon shuts the connection, so the exit report may or may not arrive; either
        // way the run ends and the program is gone well before its 30 seconds.
        let report = try? session.run(stdout: { _ in }, stderr: { _ in })
        #expect(report == nil || report == ExitReport(signal: SIGHUP))
        #expect(pair.serverDone.wait(timeout: .now() + 10) == .success)
        #expect(kill(session.pid, 0) != 0 && errno == ESRCH)
    }

    /// A megabyte of nothing but nesting, the most a frame holds: an answer, not a crash.
    @Test(arguments: ["[", #"{"a":"#, #"{"v":1,"op":"exec","argv":["#, #"{"v":1,"op":"exec","env":{"a":"#])
    func aRequestOfNothingButNestingIsRefused(unit: String) throws {
        let pair = try GuestPair()
        let channel = FrameChannel(descriptor: pair.client)
        try channel.send(Frame(.request, Array(String(repeating: unit, count: GuestProtocol.maxPayload / unit.utf8.count).utf8)))
        let response = try channel.receive(.response, as: GuestResponse.self)
        #expect(!response.ok)
        #expect(pair.serverDone.wait(timeout: .now() + 10) == .success)
    }

    @Test(arguments: [
        "", "not JSON", "[]", "7", #"{"v":"1","op":"hello"}"#, #"{"op":"hello"}"#, #"{"v":1}"#, #"{"v":1,"op":"exec","argv":"/bin/ls"}"#,
        #"{"v":1,"op":"exec","argv":["/bin/ls"],"env":["A=1"]}"#, #"{"v":1,"op":"exec","argv":["/bin/ls"],"terminal":{"rows":-1,"columns":80}}"#,
        #"{"v":1,"op":"exec","argv":["/bin/ls"],"terminal":{"rows":70000,"columns":80}}"#, #"{"v":1,"op":"time-sync","epoch":"now"}"#,
        #"{"v":1,"op":"time-sync","epoch":1e400}"#, #"{"v":1,"op":"time-sync","epoch":-1}"#, #"{"v":1,"op":"time-sync"}"#,
        #"{"v":1,"op":"exec","argv":[""]}"#, #"{"v":1,"op":"exec","argv":["/bin/ls"],"user":""}"#,
    ])
    func aRequestThatIsNotOneGetsARefusal(payload: String) throws {
        let pair = try GuestPair(setClock: { _ in
            Issue.record("the clock was set")
            return 0
        })
        let channel = FrameChannel(descriptor: pair.client)
        try channel.send(Frame(.request, Array(payload.utf8)))
        let response = try channel.receive(.response, as: GuestResponse.self)
        #expect(!response.ok, "\(payload)")
        #expect(pair.serverDone.wait(timeout: .now() + 10) == .success)
    }

    /// A connection that does not open with a request frame is answered and closed.
    @Test(arguments: [FrameType.stdin, .signal, .exit, .response])
    func aConnectionMustOpenWithARequest(type: FrameType) throws {
        let pair = try GuestPair()
        let channel = FrameChannel(descriptor: pair.client)
        try channel.send(Frame(type, Array(#"{"v":1,"op":"hello"}"#.utf8)))
        let response = try channel.receive(.response, as: GuestResponse.self)
        #expect(!response.ok)
        #expect(pair.serverDone.wait(timeout: .now() + 10) == .success)
    }

    /// The end of an exec whose program left nobody behind signals nobody: the group's number
    /// may be another process's by the time a late kill would be sent.
    @Test func aFinishedProgramsGroupIsNotSignaled() throws {
        let pair = try GuestPair()
        let session = try ExecSession(descriptor: pair.client, request: GuestRequest(op: .exec, argv: ["/usr/bin/true"]))
        #expect(try session.run(stdout: { _ in }, stderr: { _ in }) == ExitReport(status: 0))
        #expect(pair.serverDone.wait(timeout: .now() + 10) == .success)
        // Nothing is left of the group, which is what the daemon looks at before any signal.
        #expect(kill(-session.pid, 0) != 0 && errno == ESRCH)
    }

    /// What the program left running is still hung up at the end, then killed.
    @Test func whatAProgramLeftRunningIsStillEnded() throws {
        let pair = try GuestPair()
        // The child ignores the hangup, so only the kill after the grace period ends it.
        let session = try ExecSession(descriptor: pair.client, request: GuestRequest(
            op: .exec, argv: ["/bin/sh", "-c", "trap '' HUP; /bin/sleep 30 >/dev/null 2>&1 & echo $!"]))
        var output = ""
        #expect(try session.run(stdout: { output += String(decoding: $0, as: UTF8.self) }, stderr: { _ in }) == ExitReport(status: 0))
        let child = try #require(Int32(output.trimmingCharacters(in: .whitespacesAndNewlines)))
        #expect(kill(child, 0) == 0)
        var gone = false
        for _ in 0..<80 where !gone {
            Thread.sleep(forTimeInterval: 0.1)
            gone = kill(child, 0) != 0 && errno == ESRCH
        }
        #expect(gone)
    }

    @Test func refusedConnectionsAreLoggedOnceAMinute() {
        var log = RefusalLog()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(log.line(cid: 3, now: start) == "refused a connection from CID 3")
        for second in 1..<60 {
            #expect(log.line(cid: 3, now: start.addingTimeInterval(Double(second))) == nil)
        }
        #expect(log.line(cid: 4, now: start.addingTimeInterval(60)) == "refused a connection from CID 4 (and 59 more since the last such line)")
        #expect(log.line(cid: 4, now: start.addingTimeInterval(61)) == nil)
        #expect(log.line(cid: 5, now: start.addingTimeInterval(500)) == "refused a connection from CID 5 (and 1 more since the last such line)")
        #expect(log.line(cid: 5, now: start.addingTimeInterval(900)) == "refused a connection from CID 5")
    }
}

/// The far ends of the relay's connections, kept open for the test's life.
private final class FarEnds: @unchecked Sendable {
    private let lock = NSLock()
    private var descriptors: [Int32] = []

    /// One end of a new socket pair; the other is kept here.
    func open() -> Int32 {
        var pair: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0 else {
            return -1
        }
        lock.lock()
        descriptors.append(pair[1])
        lock.unlock()
        return pair[0]
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return descriptors.count
    }

    /// Closes the ends whose connection the box's side has ended, as the host's proxy does.
    func closeEnded() {
        lock.lock()
        defer { lock.unlock() }
        descriptors.removeAll { descriptor in
            // What the box sent is read away first; 0 is then the end, -1 nothing yet.
            var buffer = [UInt8](repeating: 0, count: 4096)
            var got = recv(descriptor, &buffer, buffer.count, MSG_DONTWAIT)
            while got > 0 {
                got = recv(descriptor, &buffer, buffer.count, MSG_DONTWAIT)
            }
            guard got == 0 else {
                return false
            }
            close(descriptor)
            return true
        }
    }

    deinit {
        for descriptor in descriptors {
            close(descriptor)
        }
    }
}

@Suite struct GuestRelayTests {
    private static func connect(port: UInt16) -> Int32 {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard connected == 0 else {
            close(descriptor)
            return -1
        }
        return descriptor
    }

    /// Whether the relay closed `descriptor` within `milliseconds`.
    private static func isClosed(_ descriptor: Int32, within milliseconds: Int32) -> Bool {
        var watched = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
        guard poll(&watched, 1, milliseconds) > 0 else {
            return false
        }
        var byte: UInt8 = 0
        return recv(descriptor, &byte, 1, MSG_PEEK | MSG_DONTWAIT) <= 0
    }

    /// A box program that opens connections and holds them gets `maxConnections` of them: the
    /// rest are closed at once, and a place freed is a place again.
    @Test func connectionsPastTheLimitAreClosed() throws {
        // 1,000 held connections are three descriptors each in this one process.
        var limit = rlimit()
        getrlimit(RLIMIT_NOFILE, &limit)
        if limit.rlim_cur < 4096 {
            limit.rlim_cur = min(4096, limit.rlim_max)
            setrlimit(RLIMIT_NOFILE, &limit)
        }
        let far = FarEnds()
        let port = try GuestRelay.start(port: 0, connect: { far.open() })
        var clients: [Int32] = []
        defer {
            for client in clients {
                close(client)
            }
        }
        for _ in 0..<1000 {
            let client = Self.connect(port: port)
            // A full backlog may refuse one; that is a connection not held either.
            if client >= 0 {
                clients.append(client)
            }
        }
        #expect(clients.count > GuestRelay.maxConnections)
        // The relay takes them in the order they came.
        let held = clients.prefix(GuestRelay.maxConnections)
        for client in clients.dropFirst(GuestRelay.maxConnections) {
            #expect(Self.isClosed(client, within: 5000))
        }
        #expect(held.allSatisfy { !Self.isClosed($0, within: 0) })
        // Each far side is opened on its connection's own thread.
        for _ in 0..<50 where far.count < GuestRelay.maxConnections {
            Thread.sleep(forTimeInterval: 0.1)
        }
        #expect(far.count == GuestRelay.maxConnections)
        // Bytes still pass on a held one.
        var byte: UInt8 = 0x41
        #expect(write(clients[0], &byte, 1) == 1)

        // One leaves; the next one is served.
        close(clients.removeFirst())
        var served = false
        for _ in 0..<50 where !served {
            Thread.sleep(forTimeInterval: 0.05)
            far.closeEnded()
            let client = Self.connect(port: port)
            guard client >= 0 else {
                continue
            }
            if Self.isClosed(client, within: 100) {
                close(client)
            } else {
                clients.append(client)
                served = true
            }
        }
        #expect(served)
    }
}
