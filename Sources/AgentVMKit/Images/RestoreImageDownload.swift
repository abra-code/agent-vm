// Sources/AgentVMKit/Images/RestoreImageDownload.swift
//
// `image fetch-ipsw`: the latest macOS restore image this Mac supports, downloaded into the
// store's `Cache/ipsw/` so `image create --ipsw` has something to install. A restore image is
// about 20 GB, so the download resumes (ResumableDownload): bytes go to `<name>.part`, and a
// later run asks the server for the rest. The download refuses to start when it would leave
// less than `minimumFreeAfter` free on the volume (purgeable space not counted), and holds a
// lock so two runs never write one file. Only a complete file that Virtualization can load is
// renamed into place.

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
    public typealias Remote = ResumableDownload.Remote
    typealias State = ResumableDownload.State

    /// A HEAD request: length and ETag.
    public static func remote(_ url: URL, session: URLSession = .shared) async throws -> Remote {
        return try await ResumableDownload.remote(url, session: session)
    }

    /// Whether a restore image may be fetched from `url` when the address is not Apple's own
    /// answer but was given (AGENT_VM_IPSW_URL, which the tests point at a local server): over
    /// HTTPS, or from this Mac itself (ResumableDownload.isAcceptableSource).
    public static func isAcceptableSource(_ url: URL) -> Bool {
        return ResumableDownload.isAcceptableSource(url)
    }

    static func place(_ file: URL, cache: RestoreImageCache) -> ResumableDownload.Place {
        return ResumableDownload.Place(root: cache.root, directory: cache.directory, lockPath: cache.lockPath, file: file,
                                       part: cache.partialFile(for: file), stateFile: cache.stateFile(for: file), noun: "restore image")
    }

    /// Bytes already in the partial file for `url` (0 when there is none, or it is for
    /// another file and will be started over).
    public static func resumableBytes(_ file: URL, url: URL, remote: Remote, cache: RestoreImageCache) -> Int64 {
        return ResumableDownload.resumableBytes(place(file, cache: cache), url: url, remote: remote)
    }

    /// Downloads `url` into `file` (through its `.part`), resuming what an earlier run left.
    /// `progress` gets the bytes so far and the total. Refuses when the volume would keep less
    /// than `minimumFreeAfter`, or another agent-vm is downloading. On cancel the partial file
    /// stays for the next run. Does not check that the result is a restore image.
    public static func download(_ url: URL, to file: URL, cache: RestoreImageCache, remote: Remote,
                                minimumFreeAfter: Int64 = RestoreImageCache.minimumFreeAfter,
                                cancellation: BuildCancellation? = nil,
                                progress: @escaping @Sendable (Int64, Int64?) -> Void) async throws {
        try await ResumableDownload.download(url, place: place(file, cache: cache), remote: remote, minimumFreeAfter: minimumFreeAfter,
                                             cancellation: cancellation, prepare: {
            // Partial downloads of other (older) restore images would never be finished.
            removeOtherPartials(keeping: file, cache: cache)
        }, progress: progress)
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
        return ResumableDownload.gigabytes(bytes)
    }
}
