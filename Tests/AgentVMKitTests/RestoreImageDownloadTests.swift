// Tests/AgentVMKitTests/RestoreImageDownloadTests.swift
//
// The restore image download against a local HTTP server that serves byte ranges, can cut a
// transfer off partway, change its ETag, or ignore ranges: resuming, starting over, and the
// refusals (space, a second download, names). No real restore image is involved.

import Darwin
import Foundation
import Testing
@testable import AgentVMKit

/// A tiny HTTP/1.1 server for one file: HEAD and GET, with `Range: bytes=N-`.
final class RangeServer: @unchecked Sendable {
    let port: UInt16
    private let listener: Int32
    private let lock = NSLock()
    private var heads: [String] = []
    private let body: Data
    /// Settings a test may change between requests.
    var etag: String? = "\"v1\""
    var cutAfter: Int?
    var ignoreRanges = false
    var sendLength = true

    init(body: Data) throws {
        self.body = body
        let listener = socket(AF_INET, SOCK_STREAM, 0)
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        var one: Int32 = 1
        setsockopt(listener, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        let ok = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(listener, $0, length) == 0 && listen(listener, 8) == 0 && getsockname(listener, $0, &length) == 0
            }
        }
        guard ok else {
            throw AgentVMError.system(operation: "range server", code: errno)
        }
        port = UInt16(bigEndian: address.sin_port)
        self.listener = listener
        Thread.detachNewThread { [self] in
            while true {
                let client = accept(listener, nil, nil)
                if client < 0 {
                    return
                }
                var one: Int32 = 1
                setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
                serve(client)
                close(client)
            }
        }
    }

    var url: URL {
        return URL(string: "http://127.0.0.1:\(port)/UniversalMac_99.0_99A1_Restore.ipsw")!
    }

    var requests: [String] {
        lock.lock()
        defer { lock.unlock() }
        return heads
    }

    private func serve(_ client: Int32) {
        var head = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while !head.contains(Data("\r\n\r\n".utf8)) {
            let count = read(client, &buffer, buffer.count)
            if count <= 0 {
                return
            }
            head.append(contentsOf: buffer[0..<count])
        }
        let text = String(decoding: head, as: UTF8.self)
        lock.lock()
        heads.append(text)
        let etag = self.etag
        let cutAfter = self.cutAfter
        let ignoreRanges = self.ignoreRanges
        let sendLength = self.sendLength
        lock.unlock()
        var start = 0
        if !ignoreRanges, let line = text.components(separatedBy: "\r\n").first(where: { $0.lowercased().hasPrefix("range: bytes=") }) {
            start = Int(line.dropFirst("range: bytes=".count).split(separator: "-").first ?? "0") ?? 0
        }
        var lines = [start > 0 ? "HTTP/1.1 206 Partial Content" : "HTTP/1.1 200 OK", "Connection: close", "Accept-Ranges: bytes"]
        if sendLength {
            lines.append("Content-Length: \(body.count - start)")
        }
        if start > 0 {
            lines.append("Content-Range: bytes \(start)-\(body.count - 1)/\(body.count)")
        }
        if let etag {
            lines.append("ETag: \(etag)")
        }
        write(client, Data((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8))
        guard text.hasPrefix("GET ") else {
            return
        }
        var payload = body.subdata(in: start..<body.count)
        if let cutAfter, cutAfter < payload.count {
            payload = payload.prefix(cutAfter)
            write(client, payload)
            // URLSession drops bytes it has not handed over yet when the connection is lost:
            // let them arrive before the cut, so the partial length is known.
            usleep(300_000)
            return
        }
        write(client, payload)
    }

    private func write(_ client: Int32, _ data: Data) {
        data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let written = Darwin.write(client, raw.baseAddress! + offset, raw.count - offset)
                if written <= 0 {
                    return
                }
                offset += written
            }
        }
    }

    func set(_ change: (RangeServer) -> Void) {
        lock.lock()
        change(self)
        lock.unlock()
    }

    deinit {
        close(listener)
    }
}

@Suite struct RestoreImageDownloadTests {
    let body = Data((0..<300_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })

    func fixture() throws -> (Scratch, RangeServer, RestoreImageCache, URL) {
        let scratch = try Scratch()
        let server = try RangeServer(body: body)
        let cache = RestoreImageCache(root: scratch.root)
        let file = try cache.file(for: server.url)
        return (scratch, server, cache, file)
    }

    func download(_ server: RangeServer, _ file: URL, _ cache: RestoreImageCache, minimumFreeAfter: Int64 = 0) async throws {
        let remote = try await RestoreImageDownload.remote(server.url)
        try await RestoreImageDownload.download(server.url, to: file, cache: cache, remote: remote, minimumFreeAfter: minimumFreeAfter) { _, _ in }
    }

    @Test func downloadsIntoTheCache() async throws {
        let (_, server, cache, file) = try fixture()
        #expect(file.path.hasSuffix("/Cache/ipsw/UniversalMac_99.0_99A1_Restore.ipsw"))
        let remote = try await RestoreImageDownload.remote(server.url)
        #expect(remote == RestoreImageDownload.Remote(length: Int64(body.count), etag: "\"v1\""))
        let seen = Seen()
        try await RestoreImageDownload.download(server.url, to: file, cache: cache, remote: remote, minimumFreeAfter: 0) { done, total in
            seen.add(done, total)
        }
        #expect(try Data(contentsOf: file) == body)
        #expect(!FileManager.default.fileExists(atPath: cache.partialFile(for: file).path))
        #expect(!FileManager.default.fileExists(atPath: file.path + ".part.json"))
        #expect(seen.last == Int64(body.count))
        #expect(seen.total == Int64(body.count))
    }

    @Test func anInterruptedDownloadResumesWhereItStopped() async throws {
        let (_, server, cache, file) = try fixture()
        server.set { $0.cutAfter = 100_000 }
        await #expect(throws: AgentVMError.self) { try await download(server, file, cache) }
        let part = cache.partialFile(for: file)
        #expect(try Data(contentsOf: part) == body.prefix(100_000))
        let remote = try await RestoreImageDownload.remote(server.url)
        #expect(RestoreImageDownload.resumableBytes(file, url: server.url, remote: remote, cache: cache) == 100_000)

        server.set { $0.cutAfter = nil }
        try await download(server, file, cache)
        #expect(try Data(contentsOf: file) == body)
        let resumed = try #require(server.requests.last)
        #expect(resumed.contains("Range: bytes=100000-"))
        #expect(resumed.contains("If-Range: \"v1\""))
    }

    /// The file changed on the server (another ETag): the partial download is not trusted.
    @Test func aChangedFileStartsOver() async throws {
        let (_, server, cache, file) = try fixture()
        server.set { $0.cutAfter = 100_000 }
        await #expect(throws: AgentVMError.self) { try await download(server, file, cache) }
        server.set {
            $0.cutAfter = nil
            $0.etag = "\"v2\""
        }
        let remote = try await RestoreImageDownload.remote(server.url)
        #expect(RestoreImageDownload.resumableBytes(file, url: server.url, remote: remote, cache: cache) == 0)
        try await download(server, file, cache)
        #expect(try Data(contentsOf: file) == body)
        #expect(!(server.requests.last ?? "").contains("Range:"))
    }

    /// A server that answers a range with the whole file (200): written from the start.
    @Test func aServerIgnoringRangesIsReadFromTheStart() async throws {
        let (_, server, cache, file) = try fixture()
        server.set { $0.cutAfter = 50_000 }
        await #expect(throws: AgentVMError.self) { try await download(server, file, cache) }
        server.set {
            $0.cutAfter = nil
            $0.ignoreRanges = true
        }
        try await download(server, file, cache)
        #expect(try Data(contentsOf: file) == body)
        #expect((server.requests.last ?? "").contains("Range: bytes=50000-"))
    }

    /// A signal that came before the transfer started: the task is canceled before it is
    /// resumed, completes at once, and the download ends as canceled rather than waiting.
    @Test func aDownloadCanceledBeforeItStartsEnds() async throws {
        let (_, server, cache, file) = try fixture()
        let remote = try await RestoreImageDownload.remote(server.url)
        let cancellation = BuildCancellation()
        cancellation.cancel(signal: SIGINT)
        await #expect(throws: AgentVMError.canceled(signal: SIGINT)) {
            try await RestoreImageDownload.download(server.url, to: file, cache: cache, remote: remote, minimumFreeAfter: 0,
                                                    cancellation: cancellation) { _, _ in }
        }
        #expect(FileManager.default.fileExists(atPath: cache.partialFile(for: file).path))
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    /// The file changed between the HEAD and the GET: refused, nothing kept that the next
    /// run would resume.
    @Test func aFileChangingDuringTheDownloadIsRefused() async throws {
        let (_, server, cache, file) = try fixture()
        let remote = try await RestoreImageDownload.remote(server.url)
        server.set { $0.etag = "\"v2\"" }
        do {
            try await RestoreImageDownload.download(server.url, to: file, cache: cache, remote: remote, minimumFreeAfter: 0) { _, _ in }
            Issue.record("a changed file was downloaded")
        } catch let AgentVMError.download(_, reason) {
            #expect(reason.contains("changed on the server"), "\(reason)")
        }
        let now = try await RestoreImageDownload.remote(server.url)
        #expect(RestoreImageDownload.resumableBytes(file, url: server.url, remote: now, cache: cache) == 0)
        try await download(server, file, cache)
        #expect(try Data(contentsOf: file) == body)
    }

    /// Starting another restore image removes older partial downloads, never complete files.
    @Test func olderPartialDownloadsAreRemoved() async throws {
        let (_, server, cache, file) = try fixture()
        try FileSystem.makeDirectories(cache.directory.path)
        let old = cache.directory.appendingPathComponent("UniversalMac_98.0_98A1_Restore.ipsw")
        try Data("old".utf8).write(to: URL(fileURLWithPath: old.path + ".part"))
        try Data("{}".utf8).write(to: URL(fileURLWithPath: old.path + ".part.json"))
        let complete = cache.directory.appendingPathComponent("UniversalMac_97.0_97A1_Restore.ipsw")
        try Data("done".utf8).write(to: complete)
        try await download(server, file, cache)
        let names = try FileManager.default.contentsOfDirectory(atPath: cache.directory.path).filter { !$0.hasPrefix(".") }.sorted()
        #expect(names == ["UniversalMac_97.0_97A1_Restore.ipsw", "UniversalMac_99.0_99A1_Restore.ipsw"])
    }

    @Test func refusals() async throws {
        let (_, server, cache, file) = try fixture()
        // Not enough space left afterwards: nothing is downloaded.
        do {
            try await download(server, file, cache, minimumFreeAfter: Int64.max / 2)
            Issue.record("the space check passed")
        } catch let AgentVMError.download(_, reason) {
            #expect(reason.contains("must stay free"), "\(reason)")
        }
        #expect(server.requests.allSatisfy { $0.hasPrefix("HEAD ") })

        // Another download holds the lock.
        try FileSystem.makeDirectories(cache.directory.path)
        let lock = try #require(try FolderLock.tryAcquire(cache.lockPath))
        do {
            try await download(server, file, cache)
            Issue.record("a second download ran")
        } catch let AgentVMError.download(_, reason) {
            #expect(reason.contains("another agent-vm is downloading"))
        }
        lock.release()

        // No length: no telling whether it fits.
        server.set { $0.sendLength = false }
        do {
            try await download(server, file, cache)
            Issue.record("a download of unknown size ran")
        } catch let AgentVMError.download(_, reason) {
            #expect(reason.contains("did not say how large"))
        }

        for name in ["x.dmg", ".ipsw", "..ipsw", "a b.ipsw", "evil%2F.ipsw"] {
            #expect(throws: AgentVMError.self) { try cache.file(for: URL(string: "https://example.com/\(name.replacingOccurrences(of: " ", with: "%20"))")!) }
        }
    }
}

/// Progress seen by a download.
final class Seen: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [(Int64, Int64?)] = []

    func add(_ done: Int64, _ total: Int64?) {
        lock.lock()
        values.append((done, total))
        lock.unlock()
    }

    var last: Int64? {
        lock.lock()
        defer { lock.unlock() }
        return values.last?.0
    }

    var total: Int64? {
        lock.lock()
        defer { lock.unlock() }
        return values.last?.1
    }
}
