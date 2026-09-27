// Sources/agent-vm/StatusCommand.swift
//
// `agent-vm status`: a quick summary of the store and of what runs. Every image with its state
// and what it lacks, every box with its state (and, while it runs, its supervisor's process id,
// the process that owns it, its shared project and how many programs run in it), and how many
// virtual machines run on this Mac. It measures nothing (`image info` and `box info` give the
// space on disk) and changes nothing: unlike `box list` it runs no `box gc`.

import AgentVMKit
import ArgumentParser
import Foundation

struct StatusCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Show a quick summary of images, boxes and what runs.",
        discussion: """
            One line per image (its state, its macOS, the image it was built from, and what it \
            lacks) and per box (its state and image, and while it runs its supervisor's process \
            id, its owner, its project and how many programs run in it), then how many virtual \
            machines run on this Mac. It measures no disk and deletes nothing. With --json: \
            `images` and `boxes`, each entry as `image list --json` and `box list --json` give \
            it, and `runningVMs` (`count`, left out when processes cannot be listed, and \
            `limit`, the macOS guests that can run at once).
            """)

    @OptionGroup var options: StoreOptions

    struct Summary: Encodable {
        var images: [ImageCommand.List.Entry]
        var boxes: [BoxCommand.List.Entry]
        var runningVMs: RunningVMs

        struct RunningVMs: Encodable {
            var count: Int?
            var limit: Int
        }
    }

    func run() throws {
        let (images, imageProblems) = try options.imageStore.list()
        let (boxes, boxProblems) = try options.boxStore.list()
        for problem in imageProblems + boxProblems {
            FileHandle.standardError.write(Data("warning: \(problem)\n".utf8))
        }
        let summary = Summary(
            images: images.map { ImageCommand.List.Entry(record: $0.record, path: $0.directory.path) },
            boxes: boxes.map { BoxCommand.List.Entry($0) },
            runningVMs: .init(count: HostFacts.countVirtualMachineProcesses(), limit: HostReport.macOSGuestLimit))
        if options.json {
            try Output.json(summary)
            return
        }
        for line in Self.lines(summary) {
            print(line)
        }
    }

    /// The summary for a person, one line per image and box, names in a column.
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
            lines.append(line)
        }
        lines.append(summary.boxes.isEmpty ? "Boxes: none" : "Boxes:")
        for entry in summary.boxes {
            let status = entry.status
            var line = "  \(column(entry.box.name, width))  \(column(status.state.rawValue, 12))  image \(entry.box.image)"
            if entry.box.disposable == true {
                line += "  disposable"
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
        let limit = summary.runningVMs.limit
        if let count = summary.runningVMs.count {
            lines.append("Virtual machines running on this Mac (any application): \(count); at most \(limit) macOS guests at once")
        } else {
            lines.append("Virtual machines running on this Mac: could not be counted; at most \(limit) macOS guests at once")
        }
        return lines
    }
}
