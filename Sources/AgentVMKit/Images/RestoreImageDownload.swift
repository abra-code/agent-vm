// Sources/AgentVMKit/Images/RestoreImageDownload.swift
//
// `image fetch-ipsw`: the latest macOS restore image this Mac supports, downloaded into the
// store's `Cache/ipsw/` so `image create --ipsw` has something to install. A restore image is
// about 20 GB, so the download resumes: bytes go to `<name>.part`, and a later run asks the
// server for the rest (an HTTP Range request, guarded by the file's ETag so a changed file
// starts over). The download refuses to start when it would leave less than
// `minimumFreeAfter` free on the volume (purgeable space not counted), and holds a lock so two runs never write one file. Only a
// complete file that Virtualization can load is renamed into place.

import Darwin
import Foundation
import Virtualization

public struct RestoreImageCache: Sendable {
    /// Free space a download must leave on the volume: macOS, the store's images and boxes,
    /// and swap all need room.
    public static let minimumFreeAfter: Int64 = 10 << 30

    public let directory: URL
    let root: URL

    public init(root: URL) {
        self.root = root
        directory = root.appendingPathComponent("Cache", isDirectory: true).appendingPathComponent("ipsw", isDirectory: true)
    }

    /// Where the restore image at `source` is kept: Apple's file name, which names the version
    /// and build. Only a plain `.ipsw` name is accepted.
    public func file(for source: URL) throws -> URL {
        let name = source.lastPathComponent
        guard name.hasSuffix(".ipsw"), name.count > 5, !name.hasPrefix("."),
              name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0)) }) else {
            throw AgentVMError.download(url: source.absoluteString, reason: "not a restore image (.ipsw) file name")
        }
        return directory.appendingPathComponent(name)
    }

    public func partialFile(for file: URL) -> URL {
        return URL(fileURLWithPath: file.path + ".part")
    }

    /// What the partial file was downloaded from, so a resume asks for the same file.
    func stateFile(for file: URL) -> URL {
        return URL(fileURLWithPath: file.path + ".part.json")
    }

    var lockPath: String {
        return directory.appendingPathComponent(".lock").path
    }

    /// The complete restore images here, each read by Virtualization (about a second each):
    /// newest macOS first, and those it cannot use last. Partial downloads are left out.
    public func images() async -> [CachedRestoreImage] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        var images: [CachedRestoreImage] = []
        for name in names where name.hasSuffix(".ipsw") && !name.hasPrefix(".") {
            let path = directory.appendingPathComponent(name)
            // A symbolic link to a restore image elsewhere counts, and Virtualization does not
            // follow links.
            let target = path.resolvingSymlinksInPath()
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: target.path),
                  attributes[.type] as? FileAttributeType == .typeRegular else {
                continue
            }
            var image = CachedRestoreImage(path: path, bytes: (attributes[.size] as? Int64) ?? 0)
            switch await RestoreImageDownload.verify(target) {
            case let .usable(info):
                image.info = info
            case let .notARestoreImage(reason), let .unchecked(reason):
                image.problem = reason
            }
            images.append(image)
        }
        return Self.newestFirst(images)
    }

    static func newestFirst(_ images: [CachedRestoreImage]) -> [CachedRestoreImage] {
        return images.sorted { a, b in
            switch (a.info, b.info) {
            case let (x?, y?) where x.version != y.version:
                return x.version.compare(y.version, options: .numeric) == .orderedDescending
            case let (x?, y?) where x.build != y.build:
                // A beta's build ends in a letter (26A5288a) and its number is larger than the
                // release's (26A428): of one version, the release comes first.
                let xBeta = x.build.last?.isLetter == true
                let yBeta = y.build.last?.isLetter == true
                if xBeta != yBeta {
                    return yBeta
                }
                // Numeric, so 26A1000 is newer than 26A999.
                return x.build.compare(y.build, options: .numeric) == .orderedDescending
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            default:
                return a.path.lastPathComponent < b.path.lastPathComponent
            }
        }
    }

    /// The restore image `image create --ipsw` names: `latest` (the newest usable one here), a
    /// path (with a "/", or starting with "~"), or a file name, looked for in the current
    /// directory and then here. Symbolic links are resolved: Virtualization does not follow them.
    public func resolve(_ value: String, currentDirectory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)) async throws -> URL {
        return try await unresolvedFile(value, currentDirectory: currentDirectory).resolvingSymlinksInPath()
    }

    private func unresolvedFile(_ value: String, currentDirectory: URL) async throws -> URL {
        if value == "latest" {
            guard let newest = await images().first(where: { $0.info != nil }) else {
                throw AgentVMError.virtualMachine(operation: "read restore image", message: "no usable restore image is downloaded in \(directory.path); `agent-vm image fetch-ipsw` downloads the latest, and `agent-vm image fetch-ipsw --list` shows what is there")
            }
            return newest.path
        }
        if value.contains("/") || value.hasPrefix("~") {
            return URL(fileURLWithPath: (value as NSString).expandingTildeInPath, relativeTo: currentDirectory).absoluteURL
        }
        let local = currentDirectory.appendingPathComponent(value)
        if !value.isEmpty, FileSystem.exists(local.path) {
            return local
        }
        let cached = directory.appendingPathComponent(value)
        if value.hasSuffix(".ipsw"), !value.hasPrefix("."), FileSystem.exists(cached.path) {
            return cached
        }
        throw AgentVMError.virtualMachine(operation: "read restore image", message: "\"\(value)\" is neither a file in the current directory nor a restore image downloaded in \(directory.path); `agent-vm image fetch-ipsw --list` shows the downloaded ones")
    }
}

/// A restore image downloaded into the cache.
public struct CachedRestoreImage: Sendable {
    public var path: URL
    public var bytes: Int64
    /// What Virtualization read from the file; nil when it cannot use it, and `problem` says why.
    public var info: RestoreImage.Info?
    public var problem: String?

    public init(path: URL, bytes: Int64, info: RestoreImage.Info? = nil, problem: String? = nil) {
        self.path = path
        self.bytes = bytes
        self.info = info
        self.problem = problem
    }
}

/// The latest restore image Apple offers for this Mac.
public struct LatestRestoreImage: Sendable {
    public var url: URL
    public var version: String
    public var build: String

    public init(url: URL, version: String, build: String) {
        self.url = url
        self.version = version
        self.build = build
    }

    public static func fetch() async throws -> LatestRestoreImage {
        // Without the entitlement Virtualization fails the lookup with an error that does not say
        // why ("Installation service returned an unexpected error").
        if HostFacts.ownVirtualizationEntitlement() == false {
            throw AgentVMError.download(url: "the list of restore images", reason: "this agent-vm binary lacks the com.apple.security.virtualization entitlement, without which Virtualization refuses the lookup; build it with Scripts/build.sh")
        }
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<LatestRestoreImage, Error>) in
            VZMacOSRestoreImage.fetchLatestSupported { result in
                continuation.resume(with: Result {
                    // Not Sendable: read what is needed here.
                    let image = try result.get()
                    let os = image.operatingSystemVersion
                    let version = os.patchVersion == 0 ? "\(os.majorVersion).\(os.minorVersion)" : "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
                    return LatestRestoreImage(url: image.url, version: version, build: image.buildVersion)
                }.mapError { error in
                    AgentVMError.download(url: "the list of restore images", reason: error.localizedDescription)
                })
            }
        }
    }
}

public enum RestoreImageDownload {
    /// What the server says about the file.
    public struct Remote: Sendable, Equatable {
        public var length: Int64?
        public var etag: String?
    }

    struct State: Codable, Equatable {
        var url: String
        var etag: String?
        var length: Int64?
    }

    /// A HEAD request: length and ETag.
    public static func remote(_ url: URL, session: URLSession = .shared) async throws -> Remote {
        var request = URLRequest(url: url, timeoutInterval: 60)
        request.httpMethod = "HEAD"
        let response: URLResponse
        do {
            (_, response) = try await session.data(for: request)
        } catch {
            throw AgentVMError.download(url: url.absoluteString, reason: error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw AgentVMError.download(url: url.absoluteString, reason: "the server answered \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        // A length that is not a positive number is no length: the sums below are done with it.
        let length = http.value(forHTTPHeaderField: "Content-Length").flatMap { Int64($0) }.flatMap { $0 > 0 ? $0 : nil }
        return Remote(length: length, etag: http.value(forHTTPHeaderField: "ETag"))
    }

    /// Whether a restore image may be fetched from `url` when the address is not Apple's own
    /// answer but was given (AGENT_VM_IPSW_URL, which the tests point at a local server): over
    /// HTTPS, or from this Mac itself. A restore image is trusted for where it came from, so
    /// it is not asked for over a connection anyone on the way can rewrite. (Only the address
    /// given is checked: where a server redirects to is not.)
    public static func isAcceptableSource(_ url: URL) -> Bool {
        let host = (url.host ?? "").lowercased()
        switch url.scheme?.lowercased() {
        case "https":
            return !host.isEmpty
        case "http":
            return ["127.0.0.1", "localhost", "::1", "[::1]"].contains(host)
        default:
            return false
        }
    }

    /// Bytes already in the partial file for `url` (0 when there is none, or it is for
    /// another file and will be started over).
    public static func resumableBytes(_ file: URL, url: URL, remote: Remote, cache: RestoreImageCache) -> Int64 {
        let part = cache.partialFile(for: file)
        guard let state = try? JSONDecoder().decode(State.self, from: Data(contentsOf: cache.stateFile(for: file))),
              state == State(url: url.absoluteString, etag: remote.etag, length: remote.length),
              let size = (try? FileManager.default.attributesOfItem(atPath: part.path))?[.size] as? Int64,
              remote.length.map({ size <= $0 }) ?? true else {
            return 0
        }
        return size
    }

    /// Downloads `url` into `file` (through its `.part`), resuming what an earlier run left.
    /// `progress` gets the bytes so far and the total. Refuses when the volume would keep less
    /// than `minimumFreeAfter`, or another agent-vm is downloading. On cancel the partial file
    /// stays for the next run. Does not check that the result is a restore image.
    public static func download(_ url: URL, to file: URL, cache: RestoreImageCache, remote: Remote,
                                minimumFreeAfter: Int64 = RestoreImageCache.minimumFreeAfter,
                                cancellation: BuildCancellation? = nil,
                                progress: @escaping @Sendable (Int64, Int64?) -> Void) async throws {
        try StoreRoot.prepare(cache.root)
        try FileSystem.makeDirectories(cache.directory.path)
        guard let lock = try FolderLock.tryAcquire(cache.lockPath) else {
            throw AgentVMError.download(url: url.absoluteString, reason: "another agent-vm is downloading a restore image into \(cache.directory.path)")
        }
        defer { lock.release() }
        guard let length = remote.length else {
            throw AgentVMError.download(url: url.absoluteString, reason: "the server did not say how large the file is, so there is no telling whether it fits")
        }
        let part = cache.partialFile(for: file)
        var offset = resumableBytes(file, url: url, remote: remote, cache: cache)
        let needed = length - offset
        // What is free now: purgeable space is freed only when macOS decides to.
        guard let free = HostFacts.freeBytes(nearest: cache.directory, includingPurgeable: false) else {
            throw AgentVMError.download(url: url.absoluteString, reason: "the free space on the volume of \(cache.directory.path) could not be read, so there is no telling whether it fits")
        }
        if free - needed < minimumFreeAfter {
            throw AgentVMError.download(url: url.absoluteString, reason: "it needs \(Self.gigabytes(needed)) more and the volume has \(Self.gigabytes(free)) free; at least \(Self.gigabytes(minimumFreeAfter)) must stay free. Free some space and run it again (what was downloaded is kept)")
        }
        // Partial downloads of other (older) restore images would never be finished.
        removeOtherPartials(keeping: file, cache: cache)
        if offset == 0 {
            try? FileManager.default.removeItem(at: part)
            let state = State(url: url.absoluteString, etag: remote.etag, length: remote.length)
            try JSONEncoder().encode(state).write(to: cache.stateFile(for: file), options: .atomic)
            guard FileManager.default.createFile(atPath: part.path, contents: nil) else {
                throw AgentVMError.system(operation: "create \(part.path)", code: errno)
            }
        }
        if offset < length {
            offset = try await Transfer.run(url, into: part, from: offset, etag: remote.etag, length: length, cancellation: cancellation, progress: progress)
        }
        guard offset == length else {
            throw AgentVMError.download(url: url.absoluteString, reason: "got \(offset) of \(length) bytes; run it again to resume")
        }
        guard rename(part.path, file.path) == 0 else {
            throw AgentVMError.system(operation: "rename \(part.path) to \(file.path)", code: errno)
        }
        try? FileManager.default.removeItem(at: cache.stateFile(for: file))
    }

    /// Deletes `*.ipsw.part` files (and their state) other than `file`'s. Complete restore
    /// images stay: an image may still be created from an older one.
    static func removeOtherPartials(keeping file: URL, cache: RestoreImageCache) {
        let keep = cache.partialFile(for: file).lastPathComponent
        let names = (try? FileManager.default.contentsOfDirectory(atPath: cache.directory.path)) ?? []
        for name in names where (name.hasSuffix(".ipsw.part") || name.hasSuffix(".ipsw.part.json")) && name != keep && name != keep + ".json" {
            try? FileManager.default.removeItem(at: cache.directory.appendingPathComponent(name))
        }
    }

    /// What Virtualization makes of a downloaded file.
    public enum Verdict: Sendable {
        case usable(RestoreImage.Info)
        /// The file is not a restore image (or a damaged one): Virtualization said so.
        case notARestoreImage(String)
        /// It could not be checked, for another reason (Virtualization unavailable, say).
        case unchecked(String)
    }

    /// Loads `file` as a restore image. Only Virtualization's own verdict on the file
    /// (VZError restoreImageLoadFailed or invalidRestoreImage) counts as "not a restore image".
    public static func verify(_ file: URL) async -> Verdict {
        return await withCheckedContinuation { (continuation: CheckedContinuation<Verdict, Never>) in
            VZMacOSRestoreImage.load(from: file) { result in
                switch result {
                case let .success(image):
                    do {
                        continuation.resume(returning: .usable(try RestoreImage.info(from: image, url: file)))
                    } catch {
                        continuation.resume(returning: .unchecked("\(error)"))
                    }
                case let .failure(error):
                    let code = (error as NSError).domain == VZErrorDomain ? (error as NSError).code : 0
                    if code == VZError.Code.restoreImageLoadFailed.rawValue || code == VZError.Code.invalidRestoreImage.rawValue {
                        continuation.resume(returning: .notARestoreImage(error.localizedDescription))
                    } else {
                        continuation.resume(returning: .unchecked(error.localizedDescription))
                    }
                }
            }
        }
    }

    static func gigabytes(_ bytes: Int64) -> String {
        return String(format: "%.1f GB", Double(bytes) / 1_000_000_000)
    }
}

/// One GET, appending to the partial file as data arrives (URLSession's download tasks keep
/// their resume data in memory only, so an interrupted run could not resume).
private final class Transfer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let handle: FileHandle
    private let url: URL
    private let length: Int64
    /// The ETag the HEAD gave; a GET naming another means the file changed in between.
    private let etag: String?
    private let progress: @Sendable (Int64, Int64?) -> Void
    private var offset: Int64
    private var failure: Error?
    private var continuation: CheckedContinuation<Int64, Error>?
    /// How the task ended, when it ended before `continuation` was set: a task canceled
    /// before it is resumed (a signal that came first) completes at once, without resume().
    private var outcome: Result<Int64, Error>?

    private init(url: URL, handle: FileHandle, offset: Int64, length: Int64, etag: String?, progress: @escaping @Sendable (Int64, Int64?) -> Void) {
        self.url = url
        self.etag = etag
        self.handle = handle
        self.offset = offset
        self.length = length
        self.progress = progress
    }

    /// Returns the partial file's size when the transfer ended.
    static func run(_ url: URL, into part: URL, from offset: Int64, etag: String?, length: Int64,
                    cancellation: BuildCancellation?, progress: @escaping @Sendable (Int64, Int64?) -> Void) async throws -> Int64 {
        let handle: FileHandle
        do {
            handle = try FileHandle(forWritingTo: part)
            try handle.truncate(atOffset: UInt64(offset))
        } catch {
            throw AgentVMError.system(operation: "open \(part.path)", code: FileSystem.posixCode(error))
        }
        defer { try? handle.close() }
        let transfer = Transfer(url: url, handle: handle, offset: offset, length: length, etag: etag, progress: progress)
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 120
        configuration.timeoutIntervalForResource = 7 * 24 * 3600
        let session = URLSession(configuration: configuration, delegate: transfer, delegateQueue: queue)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url)
        if offset > 0 {
            request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range")
            // A file changed since the partial download began is sent whole (200) instead.
            if let etag {
                request.setValue(etag, forHTTPHeaderField: "If-Range")
            }
        }
        let task = session.dataTask(with: request)
        let key = cancellation?.whenCanceled { task.cancel() }
        defer {
            if let key {
                cancellation?.remove(key)
            }
        }
        progress(offset, length)
        let result: Int64 = try await withCheckedThrowingContinuation { continuation in
            transfer.lock.lock()
            if let outcome = transfer.outcome {
                transfer.lock.unlock()
                continuation.resume(with: outcome)
                return
            }
            transfer.continuation = continuation
            transfer.lock.unlock()
            task.resume()
        }
        if let signal = cancellation?.signal {
            throw AgentVMError.canceled(signal: signal)
        }
        return result
    }

    private func fail(_ error: Error, _ task: URLSessionTask) {
        lock.lock()
        if failure == nil {
            failure = error
        }
        lock.unlock()
        task.cancel()
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse else {
            fail(AgentVMError.download(url: url.absoluteString, reason: "not an HTTP answer"), dataTask)
            completionHandler(.cancel)
            return
        }
        // The file the HEAD described, still: Apple's CDN answers a range of a changed file
        // without a word (it ignores a stale If-Range). The next run's HEAD starts it over.
        if let etag, let served = http.value(forHTTPHeaderField: "ETag"), served != etag {
            fail(AgentVMError.download(url: url.absoluteString, reason: "the file changed on the server during the download; run it again to start over"), dataTask)
            completionHandler(.cancel)
            return
        }
        switch http.statusCode {
        case 206:
            // The server must continue exactly where the partial file ends, in a file of the
            // announced length.
            let range = http.value(forHTTPHeaderField: "Content-Range") ?? ""
            guard range.hasPrefix("bytes \(offset)-"), range.hasSuffix("/\(length)") else {
                fail(AgentVMError.download(url: url.absoluteString, reason: "the server resumed at the wrong place (\(range))"), dataTask)
                completionHandler(.cancel)
                return
            }
        case 200:
            // The whole file: the server ignored the range, or the file changed. Start over.
            guard http.expectedContentLength == length else {
                fail(AgentVMError.download(url: url.absoluteString, reason: "the server now sends \(http.expectedContentLength) bytes, not \(length); run it again to start over"), dataTask)
                completionHandler(.cancel)
                return
            }
            if offset > 0 {
                do {
                    try handle.truncate(atOffset: 0)
                } catch {
                    fail(error, dataTask)
                    completionHandler(.cancel)
                    return
                }
                offset = 0
            }
        default:
            fail(AgentVMError.download(url: url.absoluteString, reason: "the server answered \(http.statusCode)"), dataTask)
            completionHandler(.cancel)
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        // Data already queued when fail() canceled the task still arrives: written after a
        // rejected or half-written chunk, it would land in that chunk's place.
        lock.lock()
        let failed = failure != nil
        lock.unlock()
        if failed {
            return
        }
        guard offset + Int64(data.count) <= length else {
            fail(AgentVMError.download(url: url.absoluteString, reason: "the server sent more than the \(length) bytes it announced"), dataTask)
            return
        }
        do {
            try handle.write(contentsOf: data)
        } catch {
            fail(AgentVMError.system(operation: "write the restore image", code: FileSystem.posixCode(error)), dataTask)
            return
        }
        offset += Int64(data.count)
        progress(offset, length)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let outcome: Result<Int64, Error>
        if let failure {
            outcome = .failure(failure)
        } else if let error, (error as? URLError)?.code != .cancelled {
            outcome = .failure(AgentVMError.download(url: url.absoluteString, reason: "\(error.localizedDescription); run it again to resume"))
        } else {
            // Done, or canceled (the caller reports the cancel).
            outcome = .success(offset)
        }
        let continuation = self.continuation
        self.continuation = nil
        if continuation == nil {
            self.outcome = outcome
        }
        lock.unlock()
        continuation?.resume(with: outcome)
    }
}
