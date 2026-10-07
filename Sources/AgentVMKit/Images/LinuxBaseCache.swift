// Sources/AgentVMKit/Images/LinuxBaseCache.swift
//
// A distribution's cloud image, fetched into the store's `Cache/linux/` and checked before it
// is used:
//
// - The checksum list is asked for at every `image create --linux`, over HTTPS from the
//   distribution's own host. A redirect of the list is refused: the list is what the image is
//   trusted by, and it is taken from one place only.
// - The image may come from a mirror. Its SHA-512 is computed over the finished file (a
//   resumed download has no hash of the bytes already on disk) and must be the list's before
//   the file gets its name.
// - A cached file is hashed again each time it is used (a fifth of a GB: about a second), and
//   used when the list names that digest; else the new image is downloaded in its place.
// - When the list cannot be fetched, a cached file that still has the digest it was checked
//   with is used, and a notice says so.
//
//   Cache/linux/<file>               the image
//   Cache/linux/<file>.json          where it came from, its SHA-512, when
//   Cache/linux/<file>.partial       a download in progress (and <file>.partial.json)

import CryptoKit
import Darwin
import Foundation

public struct LinuxBaseCache: Sendable {
    /// Free space a download must leave on the volume.
    public static let minimumFreeAfter: Int64 = 6 << 30

    /// Replaces the folder a release's files are fetched from; the tests point it at a local
    /// server. HTTPS, or HTTP from this Mac itself.
    public static let folderVariable = "AGENT_VM_LINUX_IMAGE_URL"

    public let directory: URL
    let root: URL
    /// The folder to fetch from in place of the release's own (`folderVariable`).
    var folderOverride: URL?
    var minimumFree = LinuxBaseCache.minimumFreeAfter

    public init(root: URL, environment: [String: String] = ProcessInfo.processInfo.environment) throws {
        self.root = root
        directory = root.appendingPathComponent("Cache", isDirectory: true).appendingPathComponent("linux", isDirectory: true)
        if let value = environment[Self.folderVariable], !value.isEmpty {
            guard let url = URL(string: value.hasSuffix("/") ? value : value + "/"), ResumableDownload.isAcceptableSource(url) else {
                throw AgentVMError.linuxBase("\(Self.folderVariable) must be an https address, or an http one on this Mac (127.0.0.1)")
            }
            folderOverride = url
        }
    }

    /// What `resolve` found or fetched.
    public struct Resolved: Sendable, Equatable {
        public var file: URL
        public var sha512: String
        /// Where it was downloaded from; nil for a file the person gave.
        public var url: String?
        /// The distribution's name for this build of the image, when it publishes one.
        public var build: String?
        /// Whether this run downloaded it.
        public var downloaded: Bool
    }

    /// What is kept beside a cached image.
    struct Note: Codable, Equatable {
        var url: String
        var sha512: String
        var bytes: Int64
        var fetchedAt: Date
        var build: String?
    }

    /// What `resolve` reports as it goes.
    public enum Step: Sendable {
        case checkingList(host: String)
        case reusing(file: String)
        case downloading(file: String, bytes: Int64, total: Int64?)
        case hashing(file: String)
        /// The list could not be asked for; a checked copy is used.
        case offline(reason: String, file: String, checkedAt: Date)
    }

    func noteFile(_ file: URL) -> URL {
        return URL(fileURLWithPath: file.path + ".json")
    }

    func folder(of base: LinuxBase) -> URL {
        return folderOverride ?? base.folder
    }

    /// The checked cloud image of `base`: the cached one when it is still what the
    /// distribution publishes, else a fresh download.
    public func resolve(_ base: LinuxBase, cancellation: BuildCancellation? = nil,
                        progress: @escaping @Sendable (Step) -> Void) async throws -> Resolved {
        let folder = folder(of: base)
        let host = folder.host ?? folder.absoluteString
        let cached = directory.appendingPathComponent(base.file)
        let listURL = folder.appendingPathComponent(base.checksumList)
        progress(.checkingList(host: host))
        let list: String
        do {
            list = String(decoding: try await Self.fetchSmall(listURL, limit: LinuxBase.listLimit), as: UTF8.self)
        } catch {
            if let signal = cancellation?.signal {
                throw AgentVMError.canceled(signal: signal)
            }
            // Without the list nothing new can be trusted; a copy that is still what was
            // checked once can.
            if let note = try? SessionStore.decoder.decode(Note.self, from: Data(contentsOf: noteFile(cached))),
               FileSystem.exists(cached.path), try await Self.sha512(of: cached) == note.sha512 {
                progress(.offline(reason: "\(error)", file: base.file, checkedAt: note.fetchedAt))
                return Resolved(file: cached, sha512: note.sha512, url: note.url, build: note.build, downloaded: false)
            }
            throw AgentVMError.linuxBase("cannot ask \(host) for the image's checksum (\(error)), and no checked copy is cached; with a file of your own: --cloud-image <path>")
        }
        let expected: String
        do {
            expected = try LinuxBase.digest(for: base.file, inList: list)
        } catch {
            throw AgentVMError.linuxBase("\(listURL.absoluteString): \(error)")
        }
        try checkCanceled(cancellation)

        if FileSystem.exists(cached.path) {
            progress(.hashing(file: base.file))
            if try await Self.sha512(of: cached) == expected {
                let note = try? SessionStore.decoder.decode(Note.self, from: Data(contentsOf: noteFile(cached)))
                progress(.reusing(file: base.file))
                return Resolved(file: cached, sha512: expected, url: note?.sha512 == expected ? note?.url : nil,
                                build: note?.sha512 == expected ? note?.build : nil, downloaded: false)
            }
            // Damaged, or the distribution published a newer image under the same name.
            try? FileManager.default.removeItem(at: cached)
            try? FileManager.default.removeItem(at: noteFile(cached))
        }

        // Asked once, so the partial file and the transfer speak to the same server: the
        // distribution's host redirects to a mirror, and not always to the same one.
        let imageURL = folder.appendingPathComponent(base.file)
        let (remote, answered) = try await ResumableDownload.head(imageURL)
        let place = ResumableDownload.Place(root: root, directory: directory, lockPath: directory.appendingPathComponent(".lock").path, file: cached,
                                            part: URL(fileURLWithPath: cached.path + ".partial"),
                                            stateFile: URL(fileURLWithPath: cached.path + ".partial.json"), noun: "Linux cloud image")
        let name = base.file
        try await ResumableDownload.download(answered, place: place, remote: remote, minimumFreeAfter: minimumFree, cancellation: cancellation, finish: { part in
            progress(.hashing(file: name))
            let got = try await Self.sha512(of: part)
            guard got == expected else {
                try? FileManager.default.removeItem(at: part)
                try? FileManager.default.removeItem(at: place.stateFile)
                throw AgentVMError.linuxBase("the downloaded \(name) does not match \(host)'s checksum list (expected \(expected.prefix(12))..., got \(got.prefix(12))...); it was deleted. Try again")
            }
        }, progress: { bytes, total in
            progress(.downloading(file: name, bytes: bytes, total: total))
        })
        let build = await self.build(of: base, list: list)
        let bytes = ((try? FileManager.default.attributesOfItem(atPath: cached.path))?[.size] as? Int64) ?? 0
        let note = Note(url: answered.absoluteString, sha512: expected, bytes: bytes, fetchedAt: Date(), build: build)
        try? SessionStore.encoder.encode(note).write(to: noteFile(cached), options: .atomic)
        return Resolved(file: cached, sha512: expected, url: answered.absoluteString, build: build, downloaded: true)
    }

    /// A cloud image file the person gave (`--cloud-image`): trusted because they supplied it,
    /// as a restore image is; its SHA-512 goes into the record.
    public func local(_ path: String, currentDirectory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)) async throws -> Resolved {
        let file = URL(fileURLWithPath: (path as NSString).expandingTildeInPath, relativeTo: currentDirectory).absoluteURL.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: file.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            throw AgentVMError.linuxBase("--cloud-image \(path): no such file")
        }
        _ = try DiskUnpack.kind(of: file)
        return Resolved(file: file, sha512: try await Self.sha512(of: file), url: nil, build: nil, downloaded: false)
    }

    private func checkCanceled(_ cancellation: BuildCancellation?) throws {
        if let signal = cancellation?.signal {
            throw AgentVMError.canceled(signal: signal)
        }
    }

    /// The distribution's name for this build of the image, from the small file beside it.
    /// Only for showing: nil whenever the file is missing, does not match the list, or does not
    /// say it in so many words.
    func build(of base: LinuxBase, list: String) async -> String? {
        guard let manifest = base.manifest, let expected = try? LinuxBase.digest(for: manifest, inList: list),
              let data = try? await Self.fetchSmall(folder(of: base).appendingPathComponent(manifest), limit: Self.manifestLimit, redirects: true),
              SHA512.hash(data: data).map({ String(format: "%02x", $0) }).joined() == expected else {
            return nil
        }
        return Self.build(inManifest: data)
    }

    static let manifestLimit = 1 << 20

    /// Debian's manifest: a list of items, each with `metadata.labels`; the build is the label
    /// `cloud.debian.org/version` ("20261001-2618"). Taken only as a short token.
    static func build(inManifest data: Data) -> String? {
        struct Manifest: Decodable {
            struct Item: Decodable {
                struct Metadata: Decodable {
                    var labels: [String: String]?
                }
                var metadata: Metadata?
            }
            var items: [Item]?
        }
        guard let manifest = try? JSONDecoder().decode(Manifest.self, from: data) else {
            return nil
        }
        let version = manifest.items?.lazy.compactMap { $0.metadata?.labels?["cloud.debian.org/version"] }.first
        return version.flatMap { Printable.isToken($0) ? $0 : nil }
    }

    /// The SHA-512 of a file, read in pieces, off the caller's actor.
    static func sha512(of file: URL) async throws -> String {
        return try await Task.detached {
            let handle: FileHandle
            do {
                handle = try FileHandle(forReadingFrom: file)
            } catch {
                throw AgentVMError.system(operation: "read \(file.path)", code: FileSystem.posixCode(error))
            }
            defer { try? handle.close() }
            var hasher = SHA512()
            while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty {
                hasher.update(data: chunk)
            }
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        }.value
    }

    /// Why a small file could not be fetched, in a few words.
    struct FetchProblem: Error, CustomStringConvertible {
        var description: String
    }

    /// A small file over HTTP: at most `limit` bytes, and, unless `redirects`, from the server
    /// asked and no other.
    static func fetchSmall(_ url: URL, limit: Int, redirects: Bool = false) async throws -> Data {
        guard ResumableDownload.isAcceptableSource(url) else {
            throw FetchProblem(description: "\(url.absoluteString) is neither https nor on this Mac")
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        let delegate = SmallFetch(redirects: redirects)
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await session.bytes(from: url)
        } catch {
            throw FetchProblem(description: error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw FetchProblem(description: "not an HTTP answer")
        }
        if (300..<400).contains(http.statusCode) {
            throw FetchProblem(description: "the server sent it elsewhere (\(http.statusCode)), and it is taken from \(url.host ?? "this server") only")
        }
        guard http.statusCode == 200 else {
            throw FetchProblem(description: "the server answered \(http.statusCode)")
        }
        var data = Data()
        do {
            for try await byte in bytes {
                guard data.count < limit else {
                    throw FetchProblem(description: "it is larger than \(limit >> 10) KB")
                }
                data.append(byte)
            }
        } catch let problem as FetchProblem {
            throw problem
        } catch {
            throw FetchProblem(description: error.localizedDescription)
        }
        return data
    }

    /// Refuses redirects when asked to: the answer is then the redirect itself.
    private final class SmallFetch: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        let redirects: Bool

        init(redirects: Bool) {
            self.redirects = redirects
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
            completionHandler(redirects ? request : nil)
        }
    }
}
