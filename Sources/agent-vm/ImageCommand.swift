// Sources/agent-vm/ImageCommand.swift
//
// `agent-vm image ...`: golden images, the installed and set-up macOS guests that boxes will
// be cloned from.

import AgentVMKit
import ArgumentParser
import Foundation

struct ImageCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "image",
        abstract: "Build and manage golden macOS images.",
        discussion: """
            An image is macOS installed from a restore image (.ipsw) and set up with no clicks: \
            macOS 27's guest provisioning creates an administrator account, logs it in \
            automatically and turns on Remote Login. agent-vm then installs its guest daemon \
            (agent-vm-guest, found next to agent-vm), checks it over vsock, turns Remote Login \
            off again and shuts the guest down. Starting virtual machines needs the binaries \
            built by Scripts/build.sh (see `agent-vm doctor`).
            """,
        subcommands: [Create.self, List.self, Delete.self]
    )

    struct Create: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Install macOS from a restore image and set it up, with no clicks.")

        @Argument(help: "Name of the new image (lower-case letters, digits, \".\", \"_\", \"-\").")
        var name: String

        @Option(name: .long, help: "The macOS restore image (.ipsw) to install.")
        var ipsw: String

        @Option(name: .long, help: "Virtual CPUs.")
        var cpus = ImageBuildOptions.defaultCPUCount

        @Option(name: .customLong("memory-gb"), help: "Memory in GB.")
        var memoryGB = Int(ImageBuildOptions.defaultMemoryBytes >> 30)

        @Option(name: .customLong("disk-gb"), help: "Disk size in GB (a sparse file; it takes only what the guest writes).")
        var diskGB = Int(ImageBuildOptions.defaultDiskBytes >> 30)

        @Option(name: .long, help: "Account name created in the guest.")
        var user = "agent"

        @Option(name: .customLong("guest-daemon"), help: "The agent-vm-guest executable to install (default: the one next to agent-vm).")
        var guestDaemon: String?

        @OptionGroup var options: StoreOptions

        func validate() throws {
            guard cpus > 0, memoryGB > 0, diskGB > 0 else {
                throw ValidationError("--cpus, --memory-gb and --disk-gb must be positive")
            }
            guard cpus <= 256, memoryGB <= 4096, diskGB <= 65536 else {
                throw ValidationError("--cpus, --memory-gb or --disk-gb is far beyond what any Mac offers")
            }
        }

        @MainActor
        func run() async throws {
            let json = options.json
            let builder = ImageBuilder(store: options.imageStore) { line in
                // With --json, progress goes to stderr so stdout holds only the record.
                if json {
                    FileHandle.standardError.write(Data((line + "\n").utf8))
                } else {
                    print(line)
                }
            }
            let buildOptions = ImageBuildOptions(
                name: name,
                restoreImage: URL(fileURLWithPath: (ipsw as NSString).expandingTildeInPath),
                cpuCount: cpus,
                memoryBytes: UInt64(memoryGB) << 30,
                diskBytes: UInt64(diskGB) << 30,
                userName: user,
                askpassProgram: try AskpassEntry.executablePath(),
                guestDaemon: try guestDaemonURL())
            let image = try await builder.build(buildOptions)
            if json {
                try Output.json(image.record)
                return
            }
            print("Image \(image.name) is ready: \(image.directory.path)")
        }

        private func guestDaemonURL() throws -> URL {
            if let guestDaemon {
                return URL(fileURLWithPath: (guestDaemon as NSString).expandingTildeInPath)
            }
            return URL(fileURLWithPath: try AskpassEntry.executablePath()).deletingLastPathComponent().appendingPathComponent("agent-vm-guest")
        }
    }

    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List images.")

        @OptionGroup var options: StoreOptions

        func run() throws {
            let (images, problems) = try options.imageStore.list()
            for problem in problems {
                FileHandle.standardError.write(Data("warning: \(problem)\n".utf8))
            }
            if options.json {
                try Output.json(images.map(\.record))
                return
            }
            if images.isEmpty {
                print("No images.")
                return
            }
            for image in images {
                let record = image.record
                let state = record.state.rawValue.padding(toLength: 12, withPad: " ", startingAt: 0)
                print("\(record.name)  \(state)  macOS \(record.macOSVersion) (\(record.macOSBuild))  \(record.cpuCount) CPUs  \(record.memoryBytes >> 30) GB  created \(Output.time(record.createdAt))")
                if let failure = record.failure {
                    print("    failed: \(failure)")
                }
            }
        }
    }

    struct Delete: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Delete an image and its disk. Refused while another agent-vm process uses it.")

        @Argument(help: "The image name.")
        var name: String

        @OptionGroup var options: StoreOptions

        func run() throws {
            try options.imageStore.delete(named: name)
            if !options.json {
                print("Deleted image \(name)")
            }
        }
    }
}

/// agent-vm doubles as ssh's askpass program while an image is built (see GuestSSH).
enum AskpassEntry {
    /// Answers ssh and exits when this process was started as askpass; returns otherwise.
    static func handleIfAskpass() {
        switch GuestSSH.askpassAnswer(arguments: CommandLine.arguments, environment: ProcessInfo.processInfo.environment) {
        case .notAskpass:
            return
        case .refuse:
            exit(1)
        case let .password(password):
            FileHandle.standardOutput.write(Data((password + "\n").utf8))
            exit(0)
        }
    }

    /// This executable's absolute path, for SSH_ASKPASS.
    static func executablePath() throws -> String {
        guard let url = Bundle.main.executableURL else {
            throw AgentVMError.system(operation: "find the agent-vm executable", code: ENOENT)
        }
        return url.resolvingSymlinksInPath().path
    }
}
