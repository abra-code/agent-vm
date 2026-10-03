// Sources/agent-vm/FetchIPSWCommand.swift
//
// `agent-vm image fetch-ipsw`: downloads the latest restore image this Mac supports into the
// store's Cache/ipsw/, resuming an earlier partial download (RestoreImageDownload). --list
// shows the restore images already downloaded, which `image create --ipsw` can name.

import AgentVMKit
import ArgumentParser
import Darwin
import Foundation

extension ImageCommand {
    struct FetchIPSW: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "fetch-ipsw",
            abstract: "Download the latest macOS restore image this Mac supports, for `image create --ipsw`.",
            discussion: """
                Asks Apple (through Virtualization) for the newest restore image this Mac can \
                run, and downloads it into Cache/ipsw/ in the store (about 27 GB). An \
                interrupted download (SIGINT, SIGTERM, a lost connection) keeps what it got, \
                and the next run resumes it. It refuses to start when less than 10 GB would \
                stay free. The file is checked to be a restore image Virtualization can load before it is put in \
                place. --check only says what would be downloaded, and whether it fits. --list \
                shows the restore images already downloaded, for `image create --ipsw`. With \
                --json, progress events go to stderr (step download) and the result to stdout.
                """)

        @Flag(name: .long, help: "Only show the restore image, what is already downloaded, and whether it fits; download nothing.")
        var check = false

        @Flag(name: .long, help: "Only list the restore images already downloaded, newest first, and which one `image create --ipsw latest` uses; no network.")
        var list = false

        @OptionGroup var options: StoreOptions

        func validate() throws {
            if list && check {
                throw ValidationError("give --list or --check, not both")
            }
        }

        struct Report: Encodable {
            var url: String
            /// As image records name them.
            var macOSVersion: String?
            var macOSBuild: String?
            /// The file's size, as the server gives it.
            var totalBytes: Int64?
            var path: String
            /// ready (downloaded and checked), partial (resumable), or missing.
            var state: String
            var partialBytes: Int64?
            /// --check: free space on the store's volume (purgeable space not counted), and
            /// whether the rest of the download fits with 10 GB to spare.
            var freeBytes: Int64?
            var fits: Bool?
            /// Without --check: whether this run downloaded anything.
            var downloaded: Bool?
        }

        @MainActor
        func run() async throws {
            let json = options.json
            let emit: @Sendable (ProgressEvent) -> Void = { Events.emit($0, json: json) }
            let cache = RestoreImageCache(root: SessionStore.defaultRoot())
            if list {
                try await ImageCommand.listIPSWs(cache, json: json)
                return
            }
            // Tests point this at a local server; the version is then read from the file.
            var latest: LatestRestoreImage
            if let override = ProcessInfo.processInfo.environment["AGENT_VM_IPSW_URL"], !override.isEmpty {
                // An address that cannot be read is refused too, not passed over for Apple's.
                guard let url = URL(string: override), RestoreImageDownload.isAcceptableSource(url) else {
                    throw ValidationError("AGENT_VM_IPSW_URL must be an https address, or an http one on this Mac (127.0.0.1)")
                }
                latest = LatestRestoreImage(url: url, version: "", build: "")
            } else {
                emit(ProgressEvent(.progress, "Asking Apple for the latest restore image this Mac supports", step: "resolve"))
                latest = try await LatestRestoreImage.fetch()
            }
            let file = try cache.file(for: latest.url)
            var report = Report(url: latest.url.absoluteString, macOSVersion: latest.version.isEmpty ? nil : latest.version,
                                macOSBuild: latest.build.isEmpty ? nil : latest.build, path: file.path, state: "missing")
            let ready = FileManager.default.fileExists(atPath: file.path)
            let remote = try await RestoreImageDownload.remote(latest.url)
            report.totalBytes = remote.length
            let partial = ready ? 0 : RestoreImageDownload.resumableBytes(file, url: latest.url, remote: remote, cache: cache)
            if ready {
                report.state = "ready"
            } else if partial > 0 {
                report.state = "partial"
                if check {
                    report.partialBytes = partial
                }
            }
            let size = remote.length.map { String(format: "%.1f GB", Double($0) / 1_000_000_000) } ?? "size unknown"
            let name = report.macOSVersion.map { "macOS \($0) (\(report.macOSBuild ?? "?"))" } ?? latest.url.lastPathComponent
            if check {
                report.freeBytes = HostFacts.freeBytes(nearest: cache.directory, includingPurgeable: false)
                if let free = report.freeBytes, let length = remote.length {
                    report.fits = ready || free - (length - partial) >= RestoreImageCache.minimumFreeAfter
                }
                if json {
                    try Output.json(report)
                    return
                }
                print("Latest restore image: \(name), \(size)")
                print("    \(report.url)")
                print("    \(file.path): \(ready ? "downloaded" : partial > 0 ? "\(partial * 100 / max(remote.length ?? 1, 1))% downloaded, resumable" : "not downloaded")")
                if let free = report.freeBytes, !ready {
                    print("    \(String(format: "%.1f GB", Double(free) / 1_000_000_000)) free: \(report.fits == true ? "it fits" : "not enough; at least 10 GB must stay free after the download")")
                }
                return
            }
            if ready {
                report.downloaded = false
                emit(ProgressEvent(.log, "\(name) is already downloaded: \(file.path)"))
            } else {
                let start = remote.length.map { Double(partial) / Double(max($0, 1)) } ?? 0
                emit(ProgressEvent(.progress, partial > 0 ? "Resuming the download of \(name), \(size)" : "Downloading \(name), \(size)", step: "download", fraction: start))
                let signals = BuildCancellation.watchingSignals()
                defer { signals.stop() }
                let meter = Meter(emit: emit)
                do {
                    try await RestoreImageDownload.download(latest.url, to: file, cache: cache, remote: remote,
                                                            cancellation: signals.cancellation) { done, total in
                        meter.update(done, total)
                    }
                } catch let AgentVMError.canceled(signal) {
                    let text = "Download stopped: \(AgentVMError.canceled(signal: signal)); what was downloaded is kept, and `agent-vm image fetch-ipsw` resumes it"
                    if json {
                        Events.emit(ProgressEvent(.notice, text), json: true)
                    } else {
                        Stderr.write((text + "\n"))
                    }
                    throw ExitCode(128 + signal)
                }
                report.downloaded = true
            }
            // Also for a file already here: it may have been put in place just before a crash
            // stopped the check.
            emit(ProgressEvent(.progress, "Checking the restore image", step: "check"))
            switch await RestoreImageDownload.verify(file) {
            case let .usable(info):
                report.macOSVersion = info.version
                report.macOSBuild = info.build
            case let .notARestoreImage(reason):
                // Never left for image create to fail on.
                try? FileManager.default.removeItem(at: file)
                throw AgentVMError.download(url: report.url, reason: "the downloaded file is not a restore image this Mac can use (\(reason)); it was deleted, and the next run downloads it again")
            case let .unchecked(reason):
                throw AgentVMError.download(url: report.url, reason: "the downloaded file could not be checked (\(reason)); it is kept at \(file.path), and the next run checks it again")
            }
            report.state = "ready"
            if json {
                try Output.json(report)
                return
            }
            print("Restore image ready: \(file.path)")
            print("  create an image with: agent-vm image create <name> --ipsw \(file.lastPathComponent)")
        }
    }

    /// One entry of `fetch-ipsw --list --json`.
    struct CachedIPSW: Encodable {
        var name: String
        var path: String
        var bytes: Int64
        var macOSVersion: String?
        var macOSBuild: String?
        /// The one `image create --ipsw latest` uses.
        var latest: Bool
        /// Why Virtualization cannot use the file.
        var problem: String?
    }

    @MainActor
    static func listIPSWs(_ cache: RestoreImageCache, json: Bool) async throws {
        let images = await cache.images()
        // Newest first, so the first usable one is what `--ipsw latest` picks.
        let latest = images.first(where: { $0.info != nil })?.path
        if json {
            try Output.json(images.map {
                CachedIPSW(name: $0.path.lastPathComponent, path: $0.path.path, bytes: $0.bytes, macOSVersion: $0.info?.version,
                       macOSBuild: $0.info?.build, latest: $0.path == latest, problem: $0.problem)
            })
            return
        }
        if images.isEmpty {
            print("No restore image is downloaded in \(cache.directory.path); `agent-vm image fetch-ipsw` downloads the latest.")
            return
        }
        print("Restore images in \(cache.directory.path), newest first:")
        for image in images {
            let name = image.path.lastPathComponent
            if let info = image.info {
                let size = String(format: "%.1f GB", Double(image.bytes) / 1_000_000_000)
                print("  \(name): macOS \(info.version) (\(info.build)), \(size)\(image.path == latest ? ", latest" : "")")
            } else {
                print("  \(name): cannot be used: \(image.problem ?? "unknown reason")")
            }
        }
        if latest != nil {
            print("Create an image with: agent-vm image create <name> --ipsw latest (or one of the names above)")
        }
    }

    /// Download progress as events: one per whole percent.
    final class Meter: @unchecked Sendable {
        private let lock = NSLock()
        private var percent = -1
        private let emit: @Sendable (ProgressEvent) -> Void

        init(emit: @escaping @Sendable (ProgressEvent) -> Void) {
            self.emit = emit
        }

        func update(_ done: Int64, _ total: Int64?) {
            guard let total, total > 0 else {
                return
            }
            let now = Int(done * 100 / total)
            lock.lock()
            let changed = now != percent
            percent = now
            lock.unlock()
            if changed {
                let text = String(format: "  %d%% (%.1f of %.1f GB)", now, Double(done) / 1_000_000_000, Double(total) / 1_000_000_000)
                emit(ProgressEvent(.progress, text, step: "download", fraction: Double(done) / Double(total)))
            }
        }
    }
}
