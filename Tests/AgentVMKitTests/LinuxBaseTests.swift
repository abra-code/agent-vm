// Tests/AgentVMKitTests/LinuxBaseTests.swift
//
// Where a Linux image's base comes from and what is trusted: the checksum list's reading, the
// cache against a local HTTP server that serves a folder (the list, the image, a manifest) and
// can redirect, damage or withhold each, and the unpacking of the disk from the archive. No
// real cloud image is involved.

import CryptoKit
import Darwin
import Foundation
import Testing
@testable import AgentVMKit

@Suite struct LinuxBaseTests {
    static let digestA = String(repeating: "ab", count: 64)
    static let digestB = String(repeating: "cd", count: 64)

    @Test func theListIsParsedInBothForms() throws {
        let list = """
            \(Self.digestB)  debian-13-generic-arm64.tar.xz
            \(Self.digestA)  debian-13-genericcloud-arm64.tar.xz
            \(Self.digestB) *other.raw
            """
        #expect(try LinuxBase.digest(for: "debian-13-genericcloud-arm64.tar.xz", inList: list) == Self.digestA)
        #expect(try LinuxBase.digest(for: "other.raw", inList: list) == Self.digestB)
        // Upper-case digits are the same digest.
        #expect(try LinuxBase.digest(for: "f", inList: "\(Self.digestA.uppercased())  f\n") == Self.digestA)
        // A name that only ends like the file is another file.
        #expect(try LinuxBase.digest(for: "cloud-arm64.tar.xz", inList: list + "\n\(Self.digestB)  cloud-arm64.tar.xz") == Self.digestB)
    }

    @Test func aListWithoutTheFileIsRefused() {
        #expect(throws: LinuxBase.ListProblem("the checksum list does not name f.tar.xz")) {
            _ = try LinuxBase.digest(for: "f.tar.xz", inList: "\(Self.digestA)  g.tar.xz\n")
        }
        #expect(throws: LinuxBase.ListProblem("the checksum list does not name f")) {
            _ = try LinuxBase.digest(for: "f", inList: "<html>404</html>")
        }
        #expect(throws: LinuxBase.ListProblem("the checksum list names f twice")) {
            _ = try LinuxBase.digest(for: "f", inList: "\(Self.digestA)  f\n\(Self.digestB)  f\n")
        }
    }

    @Test func aDigestOfAnotherLengthIsRefused() {
        let problem = LinuxBase.ListProblem("the checksum list's line for f does not start with a SHA-512 (128 hexadecimal digits)")
        for digest in [String(Self.digestA.dropLast()), Self.digestA + "0", String(repeating: "0", count: 64), String(repeating: "zz", count: 64)] {
            #expect(throws: problem, "\(digest.count) characters") {
                _ = try LinuxBase.digest(for: "f", inList: "\(digest)  f\n")
            }
        }
    }

    @Test func anOversizedListIsRefused() {
        let filler = String(repeating: "\(Self.digestB)  other\n", count: 600)
        #expect(filler.utf8.count > LinuxBase.listLimit)
        #expect(throws: LinuxBase.ListProblem("the checksum list is larger than 64 KB")) {
            _ = try LinuxBase.digest(for: "f", inList: filler + "\(Self.digestA)  f\n")
        }
    }

    @Test func debianMeansTheNewest() throws {
        #expect(try LinuxBase.named("debian-13").id == "debian-13")
        #expect(try LinuxBase.named("debian").id == LinuxBase.known.first { $0.distribution == "debian" }?.id)
        #expect(try LinuxBase.named("ubuntu-26.04").name == "Ubuntu 26.04")
        #expect(try LinuxBase.named("ubuntu").id == "ubuntu-26.04")
        #expect(throws: AgentVMError.linuxBase("--linux nope: this agent-vm knows debian-13, ubuntu-26.04 (debian or ubuntu alone means its newest)")) {
            _ = try LinuxBase.named("nope")
        }
        // What was typed is shown made printable, and cut.
        #expect(throws: AgentVMError.self) { _ = try LinuxBase.named("x\u{1B}[2J") }
        // The list and the image are asked for from one HTTPS folder of the distribution's own.
        for base in LinuxBase.known {
            #expect(base.folder.scheme == "https" && base.folder.absoluteString.hasSuffix("/"), "\(base.id)")
        }
    }

    @Test func theManifestsBuildIsTakenAsAToken() {
        func manifest(_ version: String) -> Data {
            return Data(#"{"apiVersion":"v1","kind":"List","items":[{"kind":"Build","metadata":{"labels":{"cloud.debian.org/version":"\#(version)","debian.org/arch":"arm64"}}}]}"#.utf8)
        }
        #expect(LinuxBaseCache.build(inManifest: manifest("20261001-2618")) == "20261001-2618")
        #expect(LinuxBaseCache.build(inManifest: manifest("two words")) == nil)
        #expect(LinuxBaseCache.build(inManifest: manifest(String(repeating: "9", count: 40))) == nil)
        #expect(LinuxBaseCache.build(inManifest: Data("not json".utf8)) == nil)
        #expect(LinuxBaseCache.build(inManifest: Data(#"{"items":[]}"#.utf8)) == nil)
    }
}

/// A tiny HTTP/1.1 server for a folder of files: HEAD and GET, with `Range: bytes=N-`.
final class FolderServer: @unchecked Sendable {
    let port: UInt16
    private let listener: Int32
    private let lock = NSLock()
    private var files: [String: Data] = [:]
    private var redirects: [String: String] = [:]
    private var cuts: [String: Int] = [:]
    private var seen: [String] = []

    init() throws {
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
            throw AgentVMError.system(operation: "folder server", code: errno)
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

    deinit {
        close(listener)
    }

    /// The folder's address, ending with "/".
    var folder: URL {
        return URL(string: "http://127.0.0.1:\(port)/images/")!
    }

    func put(_ name: String, _ data: Data?) {
        lock.lock()
        files["/images/" + name] = data
        lock.unlock()
    }

    /// Answers requests for `name` with a redirect to `target` (nil: no longer).
    func redirect(_ name: String, to target: String?) {
        lock.lock()
        redirects["/images/" + name] = target
        lock.unlock()
    }

    /// Ends the next transfers of `name` after `bytes` bytes (nil: no longer).
    func cut(_ name: String, after bytes: Int?) {
        lock.lock()
        cuts["/images/" + name] = bytes
        lock.unlock()
    }

    /// The request lines so far ("GET /images/SHA512SUMS").
    var requests: [String] {
        lock.lock()
        defer { lock.unlock() }
        return seen
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
        let request = text.components(separatedBy: "\r\n").first?.split(separator: " ").prefix(2).joined(separator: " ") ?? ""
        let path = String(request.split(separator: " ").last ?? "")
        lock.lock()
        seen.append(request)
        let body = files[path]
        let target = redirects[path]
        let cut = cuts[path]
        lock.unlock()
        if let target {
            write(client, Data("HTTP/1.1 302 Found\r\nLocation: \(target)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8))
            return
        }
        guard let body else {
            write(client, Data("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8))
            return
        }
        var start = 0
        if let line = text.components(separatedBy: "\r\n").first(where: { $0.lowercased().hasPrefix("range: bytes=") }) {
            start = min(body.count, Int(line.dropFirst("range: bytes=".count).split(separator: "-").first ?? "0") ?? 0)
        }
        var lines = [start > 0 ? "HTTP/1.1 206 Partial Content" : "HTTP/1.1 200 OK", "Connection: close", "Accept-Ranges: bytes",
                     "Content-Length: \(body.count - start)", "ETag: \"\(body.count)-\(body.hashValue)\""]
        if start > 0 {
            lines.append("Content-Range: bytes \(start)-\(body.count - 1)/\(body.count)")
        }
        write(client, Data((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8))
        guard text.hasPrefix("GET ") else {
            return
        }
        var payload = body.subdata(in: start..<body.count)
        if let cut, cut < payload.count {
            payload = payload.prefix(cut)
            write(client, payload)
            // Let the bytes arrive before the connection is lost (see RangeServer).
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
}

@Suite struct LinuxBaseCacheTests {
    /// A made-up release served by `server`: an "image" of 300 KB, its list, and the cache.
    struct Fixture {
        let scratch: Scratch
        let server: FolderServer
        let base: LinuxBase
        let image: Data
        var cache: LinuxBaseCache

        init() throws {
            scratch = try Scratch()
            server = try FolderServer()
            base = LinuxBase(id: "test-1", name: "Test 1", distribution: "test", version: "1", folder: server.folder,
                             file: "test-1-arm64.tar.xz", checksumList: "SHA512SUMS", digest: .sha512, member: "disk.raw", manifest: "test-1-arm64.json")
            image = Data((0..<300_000).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ $0 / 251) })
            cache = try LinuxBaseCache(root: scratch.root.appendingPathComponent("store", isDirectory: true), environment: [:])
            cache.minimumFree = 0
            server.put(base.file, image)
            server.put(base.checksumList, Data("\(Self.sha512(image))  \(base.file)\n".utf8))
        }

        static func sha512(_ data: Data) -> String {
            return SHA512.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }

        var cached: URL { cache.directory.appendingPathComponent(base.file) }

        func resolve() async throws -> (LinuxBaseCache.Resolved, [String]) {
            let steps = Steps()
            let resolved = try await cache.resolve(base) { steps.add($0) }
            return (resolved, steps.names)
        }

        func gets(_ name: String) -> Int {
            return server.requests.filter { $0 == "GET /images/\(name)" }.count
        }
    }

    final class Steps: @unchecked Sendable {
        private let lock = NSLock()
        private var list: [String] = []

        func add(_ step: LinuxBaseCache.Step) {
            let name: String
            switch step {
            case .checkingList: name = "list"
            case .reusing: name = "reuse"
            case .downloading: name = "download"
            case .hashing: name = "hash"
            case .offline: name = "offline"
            }
            lock.lock()
            if list.last != name {
                list.append(name)
            }
            lock.unlock()
        }

        var names: [String] {
            lock.lock()
            defer { lock.unlock() }
            return list
        }
    }

    @Test func aGoodDownloadIsCachedAndReused() async throws {
        let fixture = try Fixture()
        let (first, steps) = try await fixture.resolve()
        #expect(first.downloaded && first.file == fixture.cached)
        #expect(first.sha512 == Fixture.sha512(fixture.image))
        #expect(first.url == fixture.server.folder.appendingPathComponent(fixture.base.file).absoluteString)
        #expect(steps == ["list", "download", "hash"])
        #expect(try Data(contentsOf: fixture.cached) == fixture.image)
        // Nothing of the download is left beside it but its note.
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.cache.directory.path).sorted() == [".lock", fixture.base.file, fixture.base.file + ".json"])

        // The second time: the list is asked for again, the file is read again, nothing is fetched.
        let (second, again) = try await fixture.resolve()
        #expect(!second.downloaded && second.sha512 == first.sha512 && second.url == first.url)
        #expect(again == ["list", "hash", "reuse"])
        #expect(fixture.gets(fixture.base.checksumList) == 2)
        #expect(fixture.gets(fixture.base.file) == 1)
    }

    @Test func aDamagedCacheIsDownloadedAgain() async throws {
        let fixture = try Fixture()
        _ = try await fixture.resolve()
        // One byte changed; the note beside it still names the good digest.
        var damaged = fixture.image
        damaged[1000] ^= 0xFF
        try damaged.write(to: fixture.cached)
        let (resolved, steps) = try await fixture.resolve()
        #expect(resolved.downloaded)
        #expect(steps == ["list", "hash", "download", "hash"])
        #expect(try Data(contentsOf: fixture.cached) == fixture.image)
        #expect(fixture.gets(fixture.base.file) == 2)
    }

    @Test func aNewerImageUnderTheSameNameReplacesTheCachedOne() async throws {
        let fixture = try Fixture()
        _ = try await fixture.resolve()
        let newer = Data(fixture.image.reversed())
        fixture.server.put(fixture.base.file, newer)
        fixture.server.put(fixture.base.checksumList, Data("\(Fixture.sha512(newer))  \(fixture.base.file)\n".utf8))
        let (resolved, _) = try await fixture.resolve()
        #expect(resolved.downloaded && resolved.sha512 == Fixture.sha512(newer))
        #expect(try Data(contentsOf: fixture.cached) == newer)
    }

    @Test func aResumedDownloadIsHashedWhole() async throws {
        let fixture = try Fixture()
        fixture.server.cut(fixture.base.file, after: 100_000)
        await #expect(throws: AgentVMError.self) { _ = try await fixture.resolve() }
        // The partial file stays for the next run, and the image has no name yet.
        let part = URL(fileURLWithPath: fixture.cached.path + ".partial")
        #expect(((try? FileManager.default.attributesOfItem(atPath: part.path))?[.size] as? Int) == 100_000)
        #expect(!FileSystem.exists(fixture.cached.path))
        fixture.server.cut(fixture.base.file, after: nil)
        let (resolved, _) = try await fixture.resolve()
        // The second transfer asked for the rest only, and the digest is of the whole file.
        #expect(resolved.downloaded && resolved.sha512 == Fixture.sha512(fixture.image))
        #expect(try Data(contentsOf: fixture.cached) == fixture.image)
        #expect(!FileSystem.exists(part.path))
    }

    @Test func aBadDigestIsDeletedAndRefused() async throws {
        let fixture = try Fixture()
        let wrong = String(repeating: "0f", count: 64)
        fixture.server.put(fixture.base.checksumList, Data("\(wrong)  \(fixture.base.file)\n".utf8))
        let expected = "the downloaded test-1-arm64.tar.xz does not match 127.0.0.1's checksum list (expected 0f0f0f0f0f0f..., got \(Fixture.sha512(fixture.image).prefix(12))...); it was deleted. Try again"
        await #expect(throws: AgentVMError.linuxBase(expected)) { _ = try await fixture.resolve() }
        // Nothing is kept: not under the image's name, and not as a partial file to resume.
        let left = try FileManager.default.contentsOfDirectory(atPath: fixture.cache.directory.path).filter { $0 != ".lock" }
        #expect(left.isEmpty)
    }

    @Test func theListIsNeverTakenFromAnotherHost() async throws {
        let fixture = try Fixture()
        // Another server has a list that would match; the distribution's host points there.
        let other = try FolderServer()
        other.put(fixture.base.checksumList, Data("\(Fixture.sha512(fixture.image))  \(fixture.base.file)\n".utf8))
        fixture.server.redirect(fixture.base.checksumList, to: other.folder.appendingPathComponent(fixture.base.checksumList).absoluteString)
        do {
            _ = try await fixture.resolve()
            Issue.record("a redirected list was used")
        } catch let AgentVMError.linuxBase(reason) {
            #expect(reason.hasPrefix("cannot ask 127.0.0.1 for the image's checksum (the server sent it elsewhere (302), and it is taken from 127.0.0.1 only)"))
            #expect(reason.hasSuffix("with a file of your own: --cloud-image <path>"))
        }
        #expect(other.requests.isEmpty)
        #expect(fixture.gets(fixture.base.file) == 0)
    }

    @Test func theImageMayBeRedirected() async throws {
        let fixture = try Fixture()
        let mirror = try FolderServer()
        mirror.put(fixture.base.file, fixture.image)
        let target = mirror.folder.appendingPathComponent(fixture.base.file).absoluteString
        fixture.server.redirect(fixture.base.file, to: target)
        let (resolved, _) = try await fixture.resolve()
        // Checked against the list all the same, and recorded with where it came from.
        #expect(resolved.downloaded && resolved.sha512 == Fixture.sha512(fixture.image) && resolved.url == target)
        // The transfer went to the mirror that answered, not through the redirect again.
        #expect(mirror.requests.contains("GET /images/\(fixture.base.file)"))
        #expect(fixture.gets(fixture.base.file) == 0)
    }

    @Test func withoutTheListACheckedCopyIsUsedWithANotice() async throws {
        let fixture = try Fixture()
        _ = try await fixture.resolve()
        fixture.server.put(fixture.base.checksumList, nil)
        let (resolved, steps) = try await fixture.resolve()
        #expect(!resolved.downloaded && resolved.sha512 == Fixture.sha512(fixture.image))
        #expect(steps == ["list", "offline"])
        // A copy that is no longer what was checked is not used.
        var damaged = fixture.image
        damaged[5] ^= 1
        try damaged.write(to: fixture.cached)
        await #expect(throws: AgentVMError.linuxBase("cannot ask 127.0.0.1 for the image's checksum (the server answered 404), and no checked copy is cached; with a file of your own: --cloud-image <path>")) {
            _ = try await fixture.resolve()
        }
        // And with no copy at all.
        try FileManager.default.removeItem(at: fixture.cached)
        await #expect(throws: AgentVMError.self) { _ = try await fixture.resolve() }
    }

    @Test func theBuildComesFromAManifestTheListNames() async throws {
        let fixture = try Fixture()
        let manifest = Data(#"{"items":[{"metadata":{"labels":{"cloud.debian.org/version":"20261001-2618"}}}]}"#.utf8)
        fixture.server.put("test-1-arm64.json", manifest)
        // Not in the list: not believed.
        #expect(try await fixture.resolve().0.build == nil)
        try FileManager.default.removeItem(at: fixture.cached)
        let list = "\(Fixture.sha512(fixture.image))  \(fixture.base.file)\n\(Fixture.sha512(manifest))  test-1-arm64.json\n"
        fixture.server.put(fixture.base.checksumList, Data(list.utf8))
        #expect(try await fixture.resolve().0.build == "20261001-2618")
        // Kept with the cached file, for the next image made from it.
        #expect(try await fixture.resolve().0.build == "20261001-2618")
    }

    @Test func aLocalFileIsHashedAndUsed() async throws {
        let fixture = try Fixture()
        // A raw disk: a partition table header in its second block.
        var disk = Data(count: 4096)
        disk.replaceSubrange(512..<520, with: Data("EFI PART".utf8))
        let file = fixture.scratch.root.appendingPathComponent("my.raw")
        try disk.write(to: file)
        let local = try await fixture.cache.local(file.path)
        #expect(local.sha512 == Fixture.sha512(disk) && local.url == nil && !local.downloaded && local.file.lastPathComponent == "my.raw")
        #expect(fixture.server.requests.isEmpty)
        await #expect(throws: AgentVMError.linuxBase("--cloud-image /no/such/file: no such file")) { _ = try await fixture.cache.local("/no/such/file") }
        // A file that is neither kind is refused before it is hashed.
        let text = fixture.scratch.root.appendingPathComponent("notes.txt")
        try Data("hello".utf8).write(to: text)
        await #expect(throws: AgentVMError.self) { _ = try await fixture.cache.local(text.path) }
    }

    @Test func theFolderCanBeReplacedOnlyBySomethingAsSafe() throws {
        let scratch = try Scratch()
        func cache(_ value: String) throws -> LinuxBaseCache {
            return try LinuxBaseCache(root: scratch.root, environment: [LinuxBaseCache.folderVariable: value])
        }
        #expect(try cache("https://mirror.example/images").folderOverride?.absoluteString == "https://mirror.example/images/")
        #expect(try cache("http://127.0.0.1:8080/x/").folderOverride?.absoluteString == "http://127.0.0.1:8080/x/")
        #expect(try cache("").folderOverride == nil)
        for bad in ["http://mirror.example/images/", "ftp://mirror.example/", "file:///tmp/"] {
            #expect(throws: AgentVMError.self, "\(bad)") { _ = try cache(bad) }
        }
    }
}

@Suite struct DiskUnpackTests {
    /// A 64 MiB "disk", mostly zeros, with a partition table header and data in three places,
    /// packed as `disk.raw` in a tar.xz archive.
    static func archive(in scratch: Scratch, member: String = "disk.raw") throws -> (archive: URL, disk: Data) {
        var disk = Data(count: 64 << 20)
        disk.replaceSubrange(512..<520, with: Data("EFI PART".utf8))
        disk.replaceSubrange((3 << 20)..<((3 << 20) + 5000), with: Data((0..<5000).map { UInt8(truncatingIfNeeded: $0) }))
        disk.replaceSubrange((disk.count - 100)..<disk.count, with: Data(repeating: 0x7E, count: 100))
        let folder = scratch.root.appendingPathComponent("pack", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try disk.write(to: folder.appendingPathComponent(member))
        let archive = scratch.root.appendingPathComponent("image.tar.xz")
        _ = try SeedDiskTests.run("/usr/bin/tar", ["-cJf", archive.path, "-C", folder.path, member])
        return (archive, disk)
    }

    static func allocated(_ url: URL) -> Int {
        var info = stat()
        return stat(url.path, &info) == 0 ? Int(info.st_blocks) * 512 : -1
    }

    @Test func aRawDiskInATarXzComesOutTheSame() throws {
        let scratch = try Scratch()
        let (archive, disk) = try Self.archive(in: scratch)
        #expect(try DiskUnpack.kind(of: archive) == .tarXZ)
        let output = scratch.root.appendingPathComponent("Disk.img")
        let size = try DiskUnpack.unpack(archive, member: "disk.raw", to: output, limit: 128 << 20)
        #expect(size == Int64(disk.count))
        #expect(try Data(contentsOf: output) == disk)
        // The blocks of zeros are holes: three blocks of 1 MiB hold data.
        #expect(Self.allocated(output) <= 16 << 20)
        // Only this user reads it.
        #expect(((try FileManager.default.attributesOfItem(atPath: output.path))[.posixPermissions] as? Int) == 0o600)
    }

    @Test func anArchiveWithoutTheMemberIsRefused() throws {
        let scratch = try Scratch()
        let (archive, _) = try Self.archive(in: scratch, member: "other.raw")
        let output = scratch.root.appendingPathComponent("Disk.img")
        #expect(throws: AgentVMError.self) {
            _ = try DiskUnpack.unpack(archive, member: "disk.raw", to: output, limit: 128 << 20)
        }
        #expect(!FileSystem.exists(output.path))
    }

    @Test func aDiskLargerThanTheImagesIsRefused() throws {
        let scratch = try Scratch()
        let (archive, _) = try Self.archive(in: scratch)
        let output = scratch.root.appendingPathComponent("Disk.img")
        #expect(throws: AgentVMError.virtualMachine(operation: "unpack \(archive.path)", message: "its disk is larger than the image's (0 GB); give a larger --disk-gb")) {
            _ = try DiskUnpack.unpack(archive, member: "disk.raw", to: output, limit: 32 << 20)
        }
        #expect(!FileSystem.exists(output.path))
    }

    @Test func aCancelRemovesThePartialDisk() throws {
        let scratch = try Scratch()
        let (archive, _) = try Self.archive(in: scratch)
        let output = scratch.root.appendingPathComponent("Disk.img")
        let cancellation = BuildCancellation()
        cancellation.cancel(signal: SIGINT)
        #expect(throws: AgentVMError.canceled(signal: SIGINT)) {
            _ = try DiskUnpack.unpack(archive, member: "disk.raw", to: output, limit: 128 << 20, cancellation: cancellation)
        }
        #expect(!FileSystem.exists(output.path))
    }

    @Test func aRawDiskIsCloned() throws {
        let scratch = try Scratch()
        var disk = Data(count: 1 << 20)
        disk.replaceSubrange(512..<520, with: Data("EFI PART".utf8))
        let source = scratch.root.appendingPathComponent("disk.raw")
        try disk.write(to: source)
        #expect(try DiskUnpack.kind(of: source) == .raw)
        let output = scratch.root.appendingPathComponent("Disk.img")
        #expect(try DiskUnpack.unpack(source, member: "disk.raw", to: output, limit: 2 << 20) == 1 << 20)
        #expect(try Data(contentsOf: output) == disk)
        // A clone has its source's permissions; the image's disk is this user's to write, and
        // nobody else's to read, whatever the file given was.
        let locked = scratch.root.appendingPathComponent("locked.raw")
        try disk.write(to: locked)
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: locked.path)
        let second = scratch.root.appendingPathComponent("Second.img")
        _ = try DiskUnpack.unpack(locked, member: "disk.raw", to: second, limit: 2 << 20)
        #expect(((try FileManager.default.attributesOfItem(atPath: second.path))[.posixPermissions] as? Int) == 0o600)
        #expect(truncate(second.path, 2 << 20) == 0)
        // A file that is neither is named for what it is not.
        let text = scratch.root.appendingPathComponent("x.tar.xz")
        try Data("plain text".utf8).write(to: text)
        #expect(throws: AgentVMError.virtualMachine(operation: "read \(text.path)", message: "it is neither an xz-compressed tar archive, a qcow2 disk image, nor a raw disk with a partition table")) {
            _ = try DiskUnpack.kind(of: text)
        }
    }
}
