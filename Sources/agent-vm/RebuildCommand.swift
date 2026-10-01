// Sources/agent-vm/RebuildCommand.swift
//
// `agent-vm image rebuild`: builds an image again under its own name, from a fresh start and
// the recipes it keeps (ImageRebuild). The old image stays usable until the new one takes its
// place.

import AgentVMKit
import ArgumentParser
import Foundation

extension ImageCommand {
    struct Rebuild: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "rebuild",
            abstract: "Build an image again from a fresh start and the recipes it keeps, under the same name.",
            discussion: """
                For what `image update` does not do in place: a new major macOS, a new Xcode, \
                a base image that moved on, or a disk that gathered many updates. The new image \
                is built beside the old one (as <image>.rebuild) with everything `image create` \
                does, and takes its place in one step only when it is ready: until then the \
                old image stays ready and boxes can be made from it, and a failure or a cancel \
                leaves it as it was. With --ipsw, macOS is installed from the restore image and \
                every recipe that ran on the image's disk runs again, in order, so an image \
                built in layers comes back as one image; its Full Disk Access must be granted \
                again (`image setup`). With --from, the recipes the base does not already hold \
                run on a clone of it. With neither, the image it was built from is the base. \
                Recipes run with the parameters the image recorded; --set changes one. An \
                input is read from where it was when the image was built; --input names \
                another file (a new Xcode, say), and must be given when that file is gone or \
                the image was built before agent-vm 0.5.6. CPUs, memory, disk size and the \
                account are the old image's. Boxes made from the image before keep what they \
                have; `box list` says "needs recreate" for them. With --json: the new image's \
                record. SIGINT or SIGTERM stops the build at the next safe point; agent-vm \
                exits with 128 + the signal.
                """)

        @Argument(help: "The image to rebuild.")
        var name: String

        @Option(name: .long, help: ArgumentHelp("Install macOS from this restore image and run every recipe again (as `image create --ipsw`: a path, a downloaded file's name, or latest).", valueName: "path|name|latest"))
        var ipsw: String?

        @Option(name: .long, help: "A ready image to start from (default: the image this one was built from).")
        var from: String?

        @Option(name: .customLong("input"), help: ArgumentHelp("A file for a recipe's input, instead of the one the image was built with (repeatable).", valueName: "name=path"))
        var inputs: [String] = []

        @Option(name: .customLong("set"), help: ArgumentHelp("A new value for a recipe's parameter, instead of the recorded one (repeatable).", valueName: "name=value"))
        var settings: [String] = []

        @OptionGroup var options: StoreOptions

        func validate() throws {
            if ipsw != nil && from != nil {
                throw ValidationError("give either --ipsw (install macOS) or --from (start from a ready image), not both")
            }
            for pair in inputs + settings where !pair.contains("=") || pair.hasPrefix("=") {
                throw ValidationError("\(pair): give name=value")
            }
        }

        @MainActor
        func run() async throws {
            let json = options.json
            let builder = ImageBuilder(store: options.imageStore, events: Events.handler(json: json))
            var rebuild = ImageRebuildOptions(
                name: name, base: from, inputs: try Create.pairs(inputs, option: "--input"),
                parameters: try Create.pairs(settings, option: "--set"),
                guestDaemon: try ImageCommand.localGuestDaemon(), askpassProgram: try AskpassEntry.executablePath())
            // The image first: a mistyped name should not be answered with a missing restore image.
            _ = try options.imageStore.image(named: name)
            if let ipsw {
                rebuild.restoreImage = try await RestoreImageCache(root: SessionStore.defaultRoot()).resolve(ipsw)
            }
            // Checked before anything is built: a recipe that no longer loads, or an input
            // whose file is gone, fails in a second.
            _ = try builder.rebuildPlan(rebuild)
            let signals = BuildCancellation.watchingSignals()
            defer { signals.stop() }
            builder.cancellation = signals.cancellation
            let buildName = ImageStore.rebuildName(for: name)
            let image: GoldenImage
            do {
                image = try await builder.rebuild(rebuild)
            } catch let AgentVMError.canceled(signal) {
                Self.report("Image \(name) is unchanged: \(AgentVMError.canceled(signal: signal)); what was built stays in \(buildName): the next rebuild removes it (or, when it was finished, puts it in place), and so does `agent-vm image delete \(buildName)`", json: json)
                throw ExitCode(128 + signal)
            } catch {
                // Not after a refusal: nothing was built then, or what was built is finished
                // and the builder said so.
                var refused = false
                if case AgentVMError.imageExists = error {
                    refused = true
                    Self.report("An image named \(buildName) is in the way: a rebuild builds under that name. If it is not one you made, delete it: `agent-vm image delete \(buildName)`", json: json)
                }
                if case AgentVMError.imageBusy = error {
                    refused = true
                }
                if !refused, FileManager.default.fileExists(atPath: options.imageStore.imagesDirectory.appendingPathComponent(buildName).path) {
                    Self.report("Image \(name) is unchanged; what was built is in \(buildName) (`agent-vm image list` says why it failed), and the next rebuild removes it", json: json)
                }
                throw error
            }
            if json {
                try Output.json(image.record)
                return
            }
            print(Self.summary(image.record))
        }

        private static func report(_ text: String, json: Bool) {
            if json {
                Events.emit(ProgressEvent(.notice, text, image: nil), json: true)
            } else {
                FileHandle.standardError.write(Data((text + "\n").utf8))
            }
        }

        /// For a person: what the image is now, and what is left to do.
        static func summary(_ record: ImageRecord) -> String {
            var text = "Image \(record.name) is rebuilt: macOS \(record.macOSVersion) (\(record.macOSBuild))"
            let recipes = (record.recipes ?? []).compactMap(\.name)
            if !recipes.isEmpty {
                text += ", recipes \(recipes.joined(separator: ", "))"
            }
            text += ". Boxes made from it before need `agent-vm box recreate`."
            if record.needs.contains(where: { $0.kind == .fullDiskAccess }) {
                text += " Full Disk Access for its guest daemon is to be granted: `agent-vm image setup \(record.name)`."
            }
            return text
        }
    }
}
