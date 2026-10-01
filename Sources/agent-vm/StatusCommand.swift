// Sources/agent-vm/StatusCommand.swift
//
// `agent-vm status`: a quick summary of the store and of what runs. Every image with its state
// and what it lacks, every box with its state (and, while it runs, its supervisor's process id,
// the process that owns it, its shared project and how many programs run in it), and how many
// virtual machines run on this Mac, and the jobs that run, wait, or ended in the last hour. It
// asks Apple for nothing unless told to (--check-updates), measures nothing (`image info` and `box info` give the space on disk) and changes nothing:
// unlike `box list` it runs no `box gc`, and unlike `job list` it removes no old job.

import AgentVMKit
import ArgumentParser
import Foundation

struct StatusCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Show a quick summary of images, boxes and what runs.",
        discussion: """
            One line per image (its state, its macOS, the image it was built from, and what it \
            lacks) and per box (its state and image, and while it runs its supervisor's process \
            id, its owner, its project and how many programs run in it), then the jobs that \
            run or wait and those that ended in the last hour (`job list` has the rest), then \
            how many virtual machines run on this Mac. It measures no disk and deletes \
            nothing. With --json: `images`, `boxes` and `jobs`, each entry as `image list \
            --json`, `box list --json` and `job list --json` give it (`jobsError` says why \
            when the jobs could not be listed, rather than `jobs` being taken for none), and \
            `runningVMs` (`count`, left out when processes cannot be listed, and `limit`, the \
            macOS guests that can run at once). --check-updates asks Apple for the newest \
            macOS this Mac's virtual machines can run (the lookup of `image fetch-ipsw \
            --check`; it needs the internet) and keeps the answer in the store; from then on \
            `status` and `image list` name, without a network, each ready image that is \
            behind it within its major version (`macOSUpdate` with `version`, `build` and \
            `checkedAt` in the image's --json entry, `newestMacOS` in the summary, and \
            `newestMacOSError` when the lookup failed). An image whose own `image update \
            --macos` asked Apple later is not named. Nothing is installed: `image update \
            <image> --macos` does that.
            """)

    @Flag(name: .customLong("check-updates"), help: "Ask Apple for the newest macOS first, and keep the answer for later `status` and `image list` runs.")
    var checkUpdates = false

    @OptionGroup var options: StoreOptions

    struct Summary: Encodable {
        var images: [ImageCommand.List.Entry]
        var boxes: [BoxCommand.List.Entry]
        var jobs: [Job]
        /// Why the jobs could not be listed; absent when they were.
        var jobsError: String?
        var runningVMs: RunningVMs
        /// The newest macOS for this Mac's virtual machines, as Apple last said; absent when
        /// it was never asked.
        var newestMacOS: NewestMacOS?
        /// --check-updates: why Apple could not be asked.
        var newestMacOSError: String?

        struct RunningVMs: Encodable {
            var count: Int?
            var limit: Int
        }
    }

    @MainActor
    func run() async throws {
        let root = options.imageStore.root
        var newestError: String?
        if checkUpdates {
            // A failed lookup leaves the rest of the summary standing, with what was kept.
            do {
                _ = try await NewestMacOS.check(root: root)
            } catch {
                newestError = "\(error)"
                Stderr.write("warning: cannot check for the newest macOS: \(error)\n")
            }
        }
        let newest = NewestMacOS.read(root: root)
        let (images, imageProblems) = try options.imageStore.list()
        let (boxes, boxProblems) = try options.boxStore.list()
        // Jobs that cannot be listed leave the rest of the summary standing.
        var jobs: [Job] = []
        var jobProblems: [String] = []
        var jobsError: String?
        do {
            (jobs, jobProblems) = try options.jobStore.list(endedWithin: Self.recentJobSeconds)
        } catch {
            jobsError = "\(error)"
            jobProblems = ["cannot list the jobs: \(error)"]
        }
        for problem in imageProblems + boxProblems + jobProblems {
            Stderr.write("warning: \(problem)\n")
        }
        let summary = Summary(
            images: images.map { ImageCommand.List.Entry(record: $0.record, path: $0.directory.path, updating: $0.record.state == .ready && options.imageStore.isBeingChanged($0), macOSUpdate: newest?.update(for: $0.record)) },
            boxes: boxes.map { box in BoxCommand.List.Entry(box, image: images.first { $0.name == box.record.image }?.record) },
            jobs: jobs,
            jobsError: jobsError,
            runningVMs: .init(count: HostFacts.countVirtualMachineProcesses(), limit: HostReport.macOSGuestLimit),
            newestMacOS: newest, newestMacOSError: newestError)
        if options.json {
            try Output.json(summary)
            return
        }
        for line in Self.lines(summary) {
            print(line)
        }
    }

    /// Finished jobs stay in the summary this long: a client polling it sees every job end.
    static let recentJobSeconds: TimeInterval = 3600

    /// The summary for a person, one line per image and box, names in a column, then the
    /// jobs (only when there are any), as `job list` shows them.
    static func lines(_ summary: Summary) -> [String] {
        let width = (summary.images.map(\.record.name) + summary.boxes.map(\.box.name)).map(\.count).max() ?? 0
        func column(_ text: String, _ size: Int) -> String {
            text.count >= size ? text : text.padding(toLength: size, withPad: " ", startingAt: 0)
        }
        var lines: [String] = []
        lines.append(summary.images.isEmpty ? "Images: none" : "Images:")
        for entry in summary.images {
            let record = entry.record
            var line = "  \(column(record.name, width))  \(column(record.state.rawValue, 12))  macOS \(record.macOSVersion) (\(record.macOSBuild))"
            if let base = record.derivedFrom {
                line += "  from \(base.image)"
            }
            let needs = record.needs.map { need -> String in
                switch need.kind {
                case .guestUpdate: return "guest update"
                case .fullDiskAccess: return "Full Disk Access"
                }
            }
            if !needs.isEmpty {
                line += "  needs \(needs.joined(separator: ", "))"
            }
            if entry.updating {
                line += "  being updated"
            }
            if let update = entry.macOSUpdate {
                line += "  macOS \(update.version) available"
            }
            lines.append(line)
        }
        lines.append(summary.boxes.isEmpty ? "Boxes: none" : "Boxes:")
        for entry in summary.boxes {
            let status = entry.status
            var line = "  \(column(entry.box.name, width))  \(column(status.state.rawValue, 12))  image \(entry.box.image)"
            if entry.box.disposable == true {
                line += "  disposable"
            }
            if entry.needs.contains(where: { $0.kind == .recreate }) {
                line += "  needs recreate"
            }
            if status.state != .stopped {
                if let pid = status.pid {
                    line += "  pid \(pid)"
                }
                if let owner = status.ownerPid {
                    line += "  owner \(owner)"
                }
                if let project = status.project {
                    line += "  project \(project)\(status.projectReadOnly == true ? " (read only)" : "")"
                }
                if let execs = status.activeExecs, execs > 0 {
                    line += "  \(execs) program\(execs == 1 ? "" : "s")"
                }
                if status.statusError != nil {
                    line += "  (its supervisor does not answer; `agent-vm box status \(entry.box.name)` says why)"
                }
            }
            lines.append(line)
        }
        if !summary.jobs.isEmpty {
            lines.append("Jobs:")
            for job in summary.jobs {
                lines += JobCommand.List.lines(job).map { "  " + $0 }
            }
        }
        if let newest = summary.newestMacOS {
            let behind = summary.images.filter { $0.macOSUpdate != nil }.map(\.record.name)
            var line = "Newest macOS: \(newest.version) (\(newest.build)), asked \(Output.time(newest.checkedAt))"
            if !behind.isEmpty {
                line += "; install with `agent-vm image update \(behind.joined(separator: " ")) --macos` (about 15 minutes\(behind.count > 1 ? " each" : ""))"
            }
            lines.append(line)
        }
        let limit = summary.runningVMs.limit
        if let count = summary.runningVMs.count {
            lines.append("Virtual machines running on this Mac (any application): \(count); at most \(limit) macOS guests at once")
        } else {
            lines.append("Virtual machines running on this Mac: could not be counted; at most \(limit) macOS guests at once")
        }
        return lines
    }
}
