// Sources/AgentVMKit/Images/ResumableDownload.swift
//
// A large file fetched over HTTP so that an interrupted run loses nothing: bytes go to a
// partial file, and a later run asks the server for the rest (a Range request, guarded by the
// file's ETag so a changed file starts over). A lock keeps two runs from writing one file, and
// a download that would leave too little free space does not start. What the file is, and
// whether it is good, is the caller's to check before it trusts the result (a restore image is
// loaded by Virtualization, a Linux cloud image is checked against its distribution's list).

import Darwin
import Foundation

public enum ResumableDownload {
    /// What the server says about the file.
    public struct Remote: Sendable, Equatable {
        public var length: Int64?
        public var etag: String?
    }

    /// What a partial file was downloaded from, kept beside it.
    struct State: Codable, Equatable {
        var url: String
        var etag: String?
        var length: Int64?
    }

    /// Where a download lives while it runs and when it is done.
    struct Place: Sendable {
        /// The store root (made private before anything is written) and the folder in it.
        var root: URL
        var directory: URL
        var lockPath: String
        /// The finished file, the partial file, and what the partial file was downloaded from.
        var file: URL
        var part: URL
        var stateFile: URL
        /// What is downloaded, in messages: "restore image".
        var noun: String
    }

    /// A HEAD request: length and ETag.
    public static func remote(_ url: URL, session: URLSession = .shared) async throws -> Remote {
        return try await head(url, session: session).remote
    }

    /// A HEAD request: length and ETag, and the address that answered after any redirects, so
    /// a download can ask the same server again.
    static func head(_ url: URL, session: URLSession = .shared) async throws -> (remote: Remote, answered: URL) {
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
        return (Remote(length: length, etag: http.value(forHTTPHeaderField: "ETag")), http.url ?? url)
    }

    /// Whether a file may be fetched from `url` when the address was given and is not the
    /// vendor's own answer (the variables the tests point at a local server): over HTTPS, or
    /// from this Mac itself. What is downloaded is trusted for where it came from, so it is not
    /// asked for over a connection anyone on the way can rewrite. (Only the address given is
    /// checked: where a server redirects to is not.)
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
    static func resumableBytes(_ place: Place, url: URL, remote: Remote) -> Int64 {
        guard let state = try? JSONDecoder().decode(State.self, from: Data(contentsOf: place.stateFile)),
              state == State(url: url.absoluteString, etag: remote.etag, length: remote.length),
              let size = (try? FileManager.default.attributesOfItem(atPath: place.part.path))?[.size] as? Int64,
              remote.length.map({ size <= $0 }) ?? true else {
            return 0
        }
        return size
    }

    /// Downloads `url` into `place.file` (through its partial file), resuming what an earlier
    /// run left. `progress` gets the bytes so far and the total. Refuses when the volume would
    /// keep less than `minimumFreeAfter`, or another agent-vm is downloading there. `prepare`
    /// runs once the download is sure to start. `finish` is given the complete partial file
    /// before it gets its name: throwing there keeps the name free (the partial file is the
    /// caller's to delete). On cancel the partial file stays for the next run.
    static func download(_ url: URL, place: Place, remote: Remote, minimumFreeAfter: Int64,
                         cancellation: BuildCancellation? = nil, prepare: () -> Void = {},
                         finish: @Sendable (URL) async throws -> Void = { _ in },
                         progress: @escaping @Sendable (Int64, Int64?) -> Void) async throws {
        try StoreRoot.prepare(place.root)
        try FileSystem.makeDirectories(place.directory.path)
        guard let lock = try FolderLock.tryAcquire(place.lockPath) else {
            throw AgentVMError.download(url: url.absoluteString, reason: "another agent-vm is downloading a \(place.noun) into \(place.directory.path)")
        }
        defer { lock.release() }
        guard let length = remote.length else {
            throw AgentVMError.download(url: url.absoluteString, reason: "the server did not say how large the file is, so there is no telling whether it fits")
        }
        let part = place.part
        var offset = resumableBytes(place, url: url, remote: remote)
        let needed = length - offset
        // What is free now: purgeable space is freed only when macOS decides to.
        guard let free = HostFacts.freeBytes(nearest: place.directory, includingPurgeable: false) else {
            throw AgentVMError.download(url: url.absoluteString, reason: "the free space on the volume of \(place.directory.path) could not be read, so there is no telling whether it fits")
        }
        if free - needed < minimumFreeAfter {
            throw AgentVMError.download(url: url.absoluteString, reason: "it needs \(Self.gigabytes(needed)) more and the volume has \(Self.gigabytes(free)) free; at least \(Self.gigabytes(minimumFreeAfter)) must stay free. Free some space and run it again (what was downloaded is kept)")
        }
        prepare()
        if offset == 0 {
            try? FileManager.default.removeItem(at: part)
            let state = State(url: url.absoluteString, etag: remote.etag, length: remote.length)
            try JSONEncoder().encode(state).write(to: place.stateFile, options: .atomic)
            guard FileManager.default.createFile(atPath: part.path, contents: nil) else {
                throw AgentVMError.system(operation: "create \(part.path)", code: errno)
            }
        }
        if offset < length {
            offset = try await Transfer.run(url, into: part, from: offset, etag: remote.etag, length: length, noun: place.noun, cancellation: cancellation, progress: progress)
        }
        guard offset == length else {
            throw AgentVMError.download(url: url.absoluteString, reason: "got \(offset) of \(length) bytes; run it again to resume")
        }
        try await finish(part)
        guard rename(part.path, place.file.path) == 0 else {
            throw AgentVMError.system(operation: "rename \(part.path) to \(place.file.path)", code: errno)
        }
        try? FileManager.default.removeItem(at: place.stateFile)
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
    private let noun: String
    private let progress: @Sendable (Int64, Int64?) -> Void
    private var offset: Int64
    private var failure: Error?
    private var continuation: CheckedContinuation<Int64, Error>?
    /// How the task ended, when it ended before `continuation` was set: a task canceled
    /// before it is resumed (a signal that came first) completes at once, without resume().
    private var outcome: Result<Int64, Error>?

    private init(url: URL, handle: FileHandle, offset: Int64, length: Int64, etag: String?, noun: String, progress: @escaping @Sendable (Int64, Int64?) -> Void) {
        self.url = url
        self.etag = etag
        self.noun = noun
        self.handle = handle
        self.offset = offset
        self.length = length
        self.progress = progress
    }

    /// Returns the partial file's size when the transfer ended.
    static func run(_ url: URL, into part: URL, from offset: Int64, etag: String?, length: Int64, noun: String,
                    cancellation: BuildCancellation?, progress: @escaping @Sendable (Int64, Int64?) -> Void) async throws -> Int64 {
        let handle: FileHandle
        do {
            handle = try FileHandle(forWritingTo: part)
            try handle.truncate(atOffset: UInt64(offset))
        } catch {
            throw AgentVMError.system(operation: "open \(part.path)", code: FileSystem.posixCode(error))
        }
        defer { try? handle.close() }
        let transfer = Transfer(url: url, handle: handle, offset: offset, length: length, etag: etag, noun: noun, progress: progress)
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
            fail(AgentVMError.system(operation: "write the \(noun)", code: FileSystem.posixCode(error)), dataTask)
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
