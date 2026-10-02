// Sources/AgentVMKit/Images/ImageUpdate.swift
//
// `agent-vm image update`: brings a ready image up to date in place. macOS takes the update
// `softwareupdate` offers within its major version (measured on a macOS 27.0 guest: 27.0.1 in
// about 14 minutes, unattended, with the account's password on standard input; the guest
// restarts by itself, its daemon answers again on the new build, and Full Disk Access for the
// daemon is kept). Tools are refreshed by the `update` steps of the recipes the image keeps.
//
// The update never touches the image's own files until it has succeeded. It boots a
// copy-on-write copy of the disk and the auxiliary storage in `Images/<name>/Update/`; when
// every step and check passed and the guest shut down, the folder is renamed to
// `Update.commit` (one atomic step) and its files take the image's files' place
// (`ImageStore.settle`, which also finishes a commit that a killed agent-vm left halfway). A
// failure, a cancel or a kill before that rename leaves the image as it was, still ready.
// The image stays usable meanwhile: boxes and images can be cloned from it while its copy is
// updated (they get the image as it was), since only the making of the copy and the final
// moves hold the image's own lock.
//
// A macOS update rewrites about 15 GB of the disk (measured), which the image then no longer
// shares with boxes and images cloned from it earlier.

import Darwin
import Foundation
import Virtualization

public struct ImageUpdateOptions: Sendable {
    public var name: String
    /// Install the macOS update Apple offers, and the Command Line Tools' when the image has them.
    public var macOS: Bool
    /// Run the `update` steps of the recipes the image keeps.
    public var tools: Bool
    /// New values for the recipes' parameters (`--set`), recorded with the image.
    public var parameters: [String: String]
    /// The agent-vm-guest to put in the image when it has another one (nil: leave the image's).
    public var guestDaemon: URL?

    public init(name: String, macOS: Bool, tools: Bool, parameters: [String: String] = [:], guestDaemon: URL? = nil) {
        self.name = name
        self.macOS = macOS
        self.tools = tools
        self.parameters = parameters
        self.guestDaemon = guestDaemon
    }
}

/// What `image update` did to one image.
public struct ImageUpdateResult: Sendable {
    public var image: GoldenImage
    /// Whether the image's disk changed (its `revision` went up).
    public var changed: Bool
    /// The build before a macOS update, when one was installed.
    public var previousMacOSBuild: String?
    /// The names of the recipes whose update steps ran.
    public var recipes: [String]
    /// The image's agent-vm-guest version before it was replaced, when it was.
    public var previousGuestVersion: String?
}

/// A macOS update as `softwareupdate --list` offers it.
public struct MacOSUpdate: Equatable, Sendable {
    public var label: String
    public var version: String
    public var build: String

    /// The newest macOS update of `major` in `softwareupdate --list` output, which lists
    /// entries as "* Label: macOS 27.0.1-26A434" (a release name may follow "macOS"). Updates
    /// to another major version are left alone: they are a new image's job.
    public static func offered(inListOutput output: String, major: Int) -> MacOSUpdate? {
        let updates = output.split(whereSeparator: \.isNewline).compactMap { line -> MacOSUpdate? in
            let text = line.trimmingCharacters(in: .whitespaces)
            guard text.hasPrefix("* Label: macOS ") else {
                return nil
            }
            let label = String(text.dropFirst("* Label: ".count))
            guard let last = label.split(separator: " ").last else {
                return nil
            }
            let parts = last.split(separator: "-", maxSplits: 1)
            guard parts.count == 2, parts[0].first?.isNumber == true, parts[0].allSatisfy({ $0.isNumber || $0 == "." }),
                  !parts[1].isEmpty, parts[1].allSatisfy({ $0.isLetter || $0.isNumber }) else {
                return nil
            }
            return MacOSUpdate(label: label, version: String(parts[0]), build: String(parts[1]))
        }
        return updates.filter { numbers($0.version).first == major }
            .max { numbers($0.version).lexicographicallyPrecedes(numbers($1.version)) }
    }

    static func numbers(_ version: String) -> [Int] {
        return version.split(separator: ".").compactMap { Int($0) }
    }

    /// Installs `label` and restarts, as an administrator named on the command line whose
    /// password is read from standard input (Apple silicon asks for a volume owner).
    static func installRequest(label: String, user: String) -> GuestRequest {
        return GuestRequest(op: .exec, argv: ["/usr/sbin/softwareupdate", "--install", label, "--restart", "--agree-to-license",
                                              "--user", user, "--stdinpass", "--verbose"], cwd: "/", user: "root")
    }

    static var listRequest: GuestRequest {
        return GuestRequest(op: .exec, argv: ["/bin/sh", "-c", "/usr/sbin/softwareupdate --list 2>&1"], cwd: "/", user: "root")
    }

    static var versionRequest: GuestRequest {
        return GuestRequest(op: .exec, argv: ["/bin/sh", "-c", "/usr/bin/sw_vers -productVersion && /usr/bin/sw_vers -buildVersion"], cwd: "/")
    }
}

/// softwareupdate redraws one line, "Downloading: 42.10%", with carriage returns, so the log
/// would stay silent for minutes. This reads the percentage out of the stream and says when it
/// reaches the next ten.
final class DownloadPercent: @unchecked Sendable {
    private let lock = NSLock()
    private var recent: [UInt8] = []
    private var reported = -10

    /// The percentage to report, when `bytes` brought it into a ten not reported yet.
    func add(_ bytes: [UInt8]) -> Int? {
        lock.lock()
        defer { lock.unlock() }
        recent.append(contentsOf: bytes)
        if recent.count > 256 {
            recent.removeFirst(recent.count - 256)
        }
        // The last "Downloading: <number>%" that arrived whole.
        let pieces = String(decoding: recent, as: UTF8.self).components(separatedBy: "Downloading: ").dropFirst()
        guard let value = pieces.reversed().lazy.compactMap({ piece -> Double? in
            guard let end = piece.firstIndex(of: "%") else {
                return nil
            }
            return Double(piece[..<end])
        }).first, value >= 0 else {
            return nil
        }
        // Capped first: "inf" and "1e400" are numbers too, and Int() traps on them.
        let percent = Int(min(100, value))
        guard percent / 10 > reported / 10 else {
            return nil
        }
        reported = percent
        return percent
    }
}

extension ImageBuilder {
    /// Free space on the Mac an update is refused below: a macOS update rewrites about 15 GB.
    static let minimumFreeBytesForMacOSUpdate: Int64 = 20 << 30
    static let minimumFreeBytesForToolsUpdate: Int64 = 5 << 30
    /// How long the download and preparation may go without any output, and how long the
    /// restart may take to bring the new build up (measured: 2 minutes).
    static let macOSUpdateSilenceSeconds = 3600
    static let macOSRestartTimeout: Duration = .seconds(2700)
    /// How long a finished update waits for the image's lock before it gives up.
    static let commitPatience: Duration = .seconds(120)
    /// How long the second boot of a replaced guest daemon waits for a virtual machine slot.
    static let slotPatience: Duration = .seconds(900)

    /// One recipe the image keeps, ready to run its update steps, or only its checks.
    struct ToolsPlan {
        /// Its place in the record's `recipes`.
        var index: Int
        var recipe: ImageRecipe
        /// It has no update steps: its checks run after the others' updates, since those
        /// can change what it installed (Homebrew's upgrade reaches Node and Python).
        var checksOnly = false
    }

    /// What `update` would refuse without booting anything: no such image, one that is not
    /// ready, a kept recipe that no longer loads, a `--set` no recipe with update steps takes.
    /// For a command that updates several images, so the last one's mistake does not surface
    /// after the first took its minutes.
    public func checkUpdate(_ options: ImageUpdateOptions) throws {
        let image = try updatableImage(named: options.name, operation: "update")
        if options.tools {
            _ = try toolsPlans(image, set: options.parameters)
        }
    }

    /// Updates a ready image in place (see the top of this file). Returns the image as it is
    /// now; `changed` is false when there was nothing to update, and the image is untouched.
    public func update(_ options: ImageUpdateOptions) async throws -> ImageUpdateResult {
        var image = try updatableImage(named: options.name, operation: "update")
        subject = image.name
        // Held throughout: one command changes an image at a time.
        guard let changeLock = try store.tryLockForChange(image) else {
            throw AgentVMError.imageBusy(image.name)
        }
        defer { changeLock.release() }
        // The image's own lock is held only while the copy is made, and again while it is put
        // in place: in between, boxes can be made from the image as it is.
        // A box being cloned from the image holds it for a moment: wait for that.
        var cloning: ImageStore.Lock? = try await lockToCommit(image)
        defer { cloning?.release() }
        // Before the free space is measured: an update that was killed may have left gigabytes
        // in `Update/`. The record is read again under the lock.
        image = try store.settle(image, updating: true)
        guard image.record.state == .ready else {
            throw AgentVMError.wrongImageState(name: image.name, state: image.record.state.rawValue, operation: "update")
        }
        try Self.checkHost(HostFacts.current(storeRoot: store.root),
                           minimumFree: options.macOS ? Self.minimumFreeBytesForMacOSUpdate : Self.minimumFreeBytesForToolsUpdate)
        // A macOS update is given the account's password, minutes in.
        if options.macOS {
            try image.requireAccountPassword(keychain: store.passwords)
        }
        // Read before anything boots: a recipe that no longer loads, or a --set no recipe
        // takes, fails in a second.
        let plans = try options.tools ? toolsPlans(image, set: options.parameters) : []
        if let guestDaemon = options.guestDaemon, access(guestDaemon.path, X_OK) != 0 {
            throw AgentVMError.hostNotReady("the guest daemon \(guestDaemon.path) is missing; Scripts/build.sh builds it next to agent-vm")
        }
        if !options.tools, let name = options.parameters.keys.sorted().first {
            throw AgentVMError.invalidRecipe(path: image.recipesURL.path, reason: "--set \(name) changes a recipe's parameter; it needs the tools update (add --tools, or leave out --macos and --guest)")
        }

        let work = image.updateURL
        do {
            try FileSystem.makeDirectories(work.path)
            try BoxStore.cloneFile(image.diskURL, to: work.appendingPathComponent(ImageStore.diskName))
            try BoxStore.cloneFile(image.auxiliaryStorageURL, to: work.appendingPathComponent(ImageStore.auxiliaryStorageName))
        } catch {
            try? FileSystem.removeTree(work.path)
            throw error
        }
        cloning?.release()
        cloning = nil
        var record = image.record
        let began = ContinuousClock.now
        var changed = false
        var previousBuild: String?
        var updatedRecipes: [String] = []
        var previousGuest: String?
        do {
            let files = MachineFiles(name: image.name, directory: image.directory, disk: work.appendingPathComponent(ImageStore.diskName),
                                     auxiliaryStorage: work.appendingPathComponent(ImageStore.auxiliaryStorageName),
                                     hardwareModel: image.hardwareModelURL, machineIdentifier: image.machineIdentifierURL)
            let auxiliaryStorage = VZMacAuxiliaryStorage(url: files.auxiliaryStorage)
            let machine = MacMachine(configuration: try spec(image).configuration(for: files, auxiliaryStorage: auxiliaryStorage))
            try checkCanceled()
            progress("boot", "Booting a copy of \(image.name)\(image.record.updateSeconds.map { " (the last update took \(Int($0.rounded())) s)" } ?? "")",
                     expectedSeconds: image.record.updateSeconds)
            try await machine.start(provisioning: nil)
            do {
                let hello = try await waitForDaemon(machine, attempts: 180)
                log("  agent-vm-guest \(hello.version ?? "?") answers over vsock")
                if options.macOS {
                    if let installed = try await updateMacOS(machine, image: image) {
                        previousBuild = record.macOSBuild
                        record.macOSVersion = installed.version
                        record.macOSBuild = installed.build
                        changed = true
                    }
                    if let label = try await updateCommandLineTools(machine, installed: record.commandLineTools) {
                        record.commandLineTools = label
                        changed = true
                    }
                }
                let updates = plans.filter { !$0.checksOnly }
                for (position, plan) in updates.enumerated() {
                    try await runUpdate(plan.recipe, machine: machine, boxUser: record.userName, position: (position + 1, updates.count))
                    record.recipes?[plan.index].parameters = plan.recipe.parameterValues.isEmpty ? nil : plan.recipe.parameterValues
                    updatedRecipes.append(plan.recipe.name)
                    changed = true
                }
                // Every other recipe's checks, once all updates ran: an update that breaks
                // what another recipe installed fails here, and is not kept.
                let checked = plans.filter(\.checksOnly)
                for (position, plan) in checked.enumerated() {
                    progress("tools-check", "Checking \(plan.recipe.name) (\(position + 1) of \(checked.count))\(plan.recipe.description.map { ": \($0)" } ?? "")",
                             index: position + 1, count: checked.count)
                    try await runSteps([], checks: plan.recipe.checks, variables: plan.recipe.variables, machine: machine, boxUser: record.userName)
                }
                // Last, so macOS and the recipes were updated under the daemon that was there.
                var replaced: (digest: String, requirement: String?, replaced: Bool)?
                if let guestDaemon = options.guestDaemon {
                    replaced = try await replaceGuestDaemon(guestDaemon, machine: machine)
                }
                if changed, replaced?.replaced != true {
                    // An update can change what macOS grants the daemon; boxes need to know.
                    record.fullDiskAccess = try await probedFullDiskAccess(machine, record: record, image: image.name)
                }
                try await shutDownAfterUpdate(machine)
                if let replaced, replaced.replaced {
                    previousGuest = record.guestVersion ?? "?"
                    record = try await checkReplacedGuestDaemon(files, image: image, record: record, digest: replaced.digest, requirement: replaced.requirement)
                    changed = true
                }
            } catch {
                let error = canceledError(error)
                await stopAfterFailure(machine)
                throw error
            }
            let now = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
            // What this run looked at, and how long a run without a macOS install takes.
            // Of a tools update only, and not one that also replaced the daemon (a second boot,
            // and maybe a wait for a slot): the time a client shows before a wait it chose.
            let seconds = options.tools && previousBuild == nil && previousGuest == nil ? Self.seconds(ContinuousClock.now - began).rounded() : nil
            func stamp(_ record: inout ImageRecord) {
                if options.macOS {
                    record.macOSCheckedAt = now
                }
                if options.tools {
                    record.toolsCheckedAt = now
                }
                if let seconds {
                    record.updateSeconds = seconds
                }
            }
            guard changed else {
                try FileSystem.removeTree(work.path)
                log("Nothing to update in \(image.name)")
                // Only the record, when this run looked at macOS or the tools: the image's
                // files are as they were.
                if options.macOS || options.tools {
                    let lock = try await lockToCommit(image)
                    defer { lock.release() }
                    image = try store.update(try store.image(named: image.name)) { stamp(&$0) }
                }
                return ImageUpdateResult(image: image, changed: false, previousMacOSBuild: nil, recipes: [], previousGuestVersion: nil)
            }
            progress("commit", "Putting the updated disk in place")
            let own = (record.recipes ?? []).filter { $0.inheritedFrom == nil }
            if !own.isEmpty {
                record.recipe = ImageRecord.RecipeInfo.combined(own)
            }
            record.revision = (record.revision ?? 0) + 1
            record.updatedAt = now
            stamp(&record)
            let lock = try await lockToCommit(image)
            defer { lock.release() }
            try store.commitUpdate(image, record: record)
        } catch {
            // Nothing of the image itself was touched: it stays ready, as it was.
            try? FileSystem.removeTree(work.path)
            // Past the rename the update is decided: the next command on the image finishes it.
            if FileSystem.exists(image.updateCommitURL.path) {
                notice("  note: the update succeeded but could not be put in place (\(error)); the next agent-vm command that uses \(image.name) finishes it")
            } else {
                log("  \(image.name) is unchanged")
            }
            throw error
        }
        image = try store.image(named: image.name)
        return ImageUpdateResult(image: image, changed: true, previousMacOSBuild: previousBuild, recipes: updatedRecipes, previousGuestVersion: previousGuest)
    }

    /// The image's own lock, for making the update's copy and for putting the finished update
    /// in place: a box or an image being cloned from it holds the lock for a moment, so this
    /// waits up to `commitPatience`.
    private func lockToCommit(_ image: GoldenImage) async throws -> ImageStore.Lock {
        let deadline = ContinuousClock.now + Self.commitPatience
        while true {
            if let lock = try store.tryLock(image) {
                return lock
            }
            guard ContinuousClock.now < deadline else {
                throw AgentVMError.imageBusy(image.name)
            }
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    /// Whether agent-vm-guest has Full Disk Access now, as the record keeps it; a grant the
    /// record had and the guest lost is a notice.
    private func probedFullDiskAccess(_ machine: MacMachine, record: ImageRecord, image: String) async throws -> ImageRecord.FullDiskAccess {
        let granted = try await hasFullDiskAccess(machine)
        if !granted, record.fullDiskAccess?.granted == true {
            notice("  note: agent-vm-guest lost Full Disk Access in the update (macOS ties it to the daemon's code signature; one signed with a Developer ID keeps it); run `agent-vm image setup \(image)` to grant it again")
        }
        return ImageRecord.FullDiskAccess(granted: granted, guestDigest: record.guestDigest, guestRequirement: record.guestRequirement,
                                          checkedAt: Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down)))
    }

    /// Boots the updated copy once more, now under its new agent-vm-guest: checks that it
    /// answers with every feature this agent-vm knows, brings the desktop up to date, probes
    /// Full Disk Access, and shuts down. Returns the record with the new daemon in it.
    private func checkReplacedGuestDaemon(_ files: MachineFiles, image: GoldenImage, record: ImageRecord, digest: String, requirement: String?) async throws -> ImageRecord {
        var record = record
        try checkCanceled()
        progress("check-guest-daemon", "Booting again to check the new agent-vm-guest")
        // Between the two boots the update holds no virtual machine slot, and a box started
        // in that moment can take the last one: wait for a slot rather than lose the update.
        let deadline = ContinuousClock.now + Self.slotPatience
        var waiting = false
        var machine: MacMachine
        while true {
            // A new machine for every try: one that was refused is not started again.
            let auxiliaryStorage = VZMacAuxiliaryStorage(url: files.auxiliaryStorage)
            machine = MacMachine(configuration: try spec(image).configuration(for: files, auxiliaryStorage: auxiliaryStorage))
            do {
                try await machine.start(provisioning: nil)
                break
            } catch AgentVMError.noFreeVMSlot where ContinuousClock.now < deadline {
                if !waiting {
                    waiting = true
                    notice("  note: no free virtual machine slot for the second boot; waiting for one (up to \(Self.slotPatience.components.seconds / 60) minutes)")
                }
                try checkCanceled()
                try await Task.sleep(for: .seconds(5))
            }
        }
        do {
            let hello = try await waitForDaemon(machine, attempts: 180)
            let missing = GuestFeature.all.filter { !(hello.features ?? []).contains($0) }
            guard missing.isEmpty else {
                throw AgentVMError.guestCommandFailed(command: "hello", status: 0, output: "the new agent-vm-guest lacks \(missing.joined(separator: ", "))")
            }
            log("  agent-vm-guest \(hello.version ?? "?") answers (\((hello.features ?? []).joined(separator: ", ")))")
            await prepareDesktop(image, machine: machine, features: hello.features)
            record.guestVersion = hello.version
            record.guestProtocol = hello.v
            record.guestFeatures = hello.features
            // The grant is asked about before the record names the new daemon: it was the old one's.
            let had = record
            record.guestDigest = digest
            record.guestRequirement = requirement
            var access = try await probedFullDiskAccess(machine, record: had, image: image.name)
            access.guestDigest = digest
            access.guestRequirement = requirement
            record.fullDiskAccess = access
            try await shutDownAfterUpdate(machine)
            return record
        } catch {
            let error = canceledError(error)
            await stopAfterFailure(machine)
            throw error
        }
    }

    /// What a tools update runs: the image's recipes that have update steps, loaded from its
    /// `Recipes/` folder with the parameters it recorded and `set` over them (a name in `set`
    /// must be a parameter of one of them), and, when there is at least one, every other
    /// recipe that has checks, for its checks alone. Empty when no recipe has update steps.
    func toolsPlans(_ image: GoldenImage, set: [String: String]) throws -> [ToolsPlan] {
        var plans: [ToolsPlan] = []
        for (index, info) in (image.record.recipes ?? []).enumerated() {
            guard let folder = info.folder else {
                continue
            }
            let url = image.recipesURL.appendingPathComponent(folder, isDirectory: true).appendingPathComponent(ImageStore.recipeName)
            var recipe = try ImageRecipe.load(from: url)
            recipe.name = info.name ?? recipe.name
            guard !recipe.updateSteps.isEmpty else {
                if !recipe.checks.isEmpty {
                    plans.append(ToolsPlan(index: index, recipe: try recipe.bindingForUpdate(recorded: info.parameters ?? [:], set: [:]), checksOnly: true))
                }
                continue
            }
            plans.append(ToolsPlan(index: index, recipe: try recipe.bindingForUpdate(recorded: info.parameters ?? [:], set: set)))
        }
        let known = Set(plans.filter { !$0.checksOnly }.flatMap { $0.recipe.parameters.map(\.name) })
        if let name = set.keys.sorted().first(where: { !known.contains($0) }) {
            let reason = known.isEmpty
                ? "--set \(name): \(image.name) keeps no recipe with update steps"
                : "--set \(name): no recipe with update steps in \(image.name) has that parameter (they have: \(known.sorted().joined(separator: ", ")))"
            throw AgentVMError.invalidRecipe(path: image.recipesURL.path, reason: reason)
        }
        return plans.contains { !$0.checksOnly } ? plans : []
    }

    /// Installs the macOS update Apple offers within the image's major version, and waits for
    /// the guest to come back on the new build. Returns the new version and build, or nil when
    /// none is offered.
    private func updateMacOS(_ machine: MacMachine, image: GoldenImage) async throws -> (version: String, build: String)? {
        let clock = ContinuousClock()
        let began = clock.now
        progress("macos-check", "Asking Apple for macOS updates")
        let listed = try await guestCapture(machine, MacOSUpdate.listRequest, readTimeout: 600)
        guard listed.report == ExitReport(status: 0) else {
            throw AgentVMError.guestCommandFailed(command: "softwareupdate --list", status: listed.report.shellStatus, output: String(listed.stdout.suffix(400)))
        }
        let before = try await macOSVersion(machine)
        guard let major = MacOSUpdate.numbers(before.version).first,
              let update = MacOSUpdate.offered(inListOutput: listed.stdout, major: major), update.build != before.build else {
            log("  macOS \(before.version) (\(before.build)) is the newest Apple offers")
            return nil
        }
        progress("macos-download", "Updating macOS \(before.version) (\(before.build)) to \(update.version) (\(update.build)): downloading and preparing")
        let password = try image.accountPassword(keychain: store.passwords)
        let label = "softwareupdate --install \(update.label)"
        let emit = LineEmitter(report: report, image: subject)
        let percent = DownloadPercent()
        let report = self.report
        let subject = self.subject
        emit.observer = { bytes in
            guard let reached = percent.add(bytes) else {
                return
            }
            // Past the download, softwareupdate stays in the nineties while it prepares.
            let text = reached >= 90 ? "  \(reached)%: downloaded; preparing the update (several minutes)" : "  \(reached)%"
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    report(ProgressEvent(.progress, text, step: "macos-download", fraction: Double(reached) / 100, image: subject))
                }
            }
        }
        do {
            let ended = try await runStreaming(machine, label, MacOSUpdate.installRequest(label: update.label, user: image.record.userName),
                                               input: Data((password.trimmingCharacters(in: .whitespacesAndNewlines) + "\n").utf8),
                                               readTimeout: Self.macOSUpdateSilenceSeconds, emit: emit)
            guard ended == ExitReport(status: 0) else {
                throw AgentVMError.guestCommandFailed(command: label, status: ended.shellStatus, output: String(emit.tail.suffix(800)))
            }
        } catch let error as AgentVMError {
            if case .guestCommandFailed = error {
                throw error
            }
            if Self.isCancel(error) {
                throw error
            }
            // The restart can take the connection before the exit status arrives: whether the
            // update went in is decided by the build the guest comes back with.
            emit.flush()
            log("  the connection ended while softwareupdate ran (\(error)); waiting for the guest")
        }
        progress("macos-restart", "Restarting to install (a few minutes)")
        let deadline = clock.now + Self.macOSRestartTimeout
        var after = before
        while after.build == before.build {
            try checkCanceled()
            guard clock.now < deadline else {
                throw AgentVMError.guestUnreachable("the guest did not come back on macOS \(update.build) within \(Self.macOSRestartTimeout); softwareupdate said:\n\(String(emit.tail.suffix(800)))")
            }
            // An update may shut the guest down instead of restarting it.
            if !machine.isRunning {
                if let failure = machine.failure {
                    throw AgentVMError.virtualMachine(operation: "install the macOS update", message: failure)
                }
                log("  the guest shut down; starting it again")
                try await machine.start(provisioning: nil)
            }
            try await Task.sleep(for: .seconds(5))
            if let now = try? await macOSVersion(machine, quiet: true) {
                after = now
            }
        }
        // Once more through the usual door: the clock is set, and the daemon is known to answer.
        _ = try await waitForDaemon(machine, attempts: 180)
        log("  macOS \(after.version) (\(after.build)) installed in \(Int(Self.seconds(clock.now - began))) s")
        return after
    }

    /// The guest's macOS version and build. `quiet`: one attempt, for a guest that may be
    /// restarting.
    private func macOSVersion(_ machine: MacMachine, quiet: Bool = false) async throws -> (version: String, build: String) {
        let request = MacOSUpdate.versionRequest
        let result = try await withGuest(machine, "sw_vers", readTimeout: 15, redeliver: !quiet) { try GuestClient.capture($0, request) }
        let lines = result.stdout.split(whereSeparator: \.isNewline).map(String.init)
        // Recorded in the image and shown by every list: only what a version and a build look like.
        guard result.report == ExitReport(status: 0), lines.count == 2, lines.allSatisfy({ Printable.isToken($0) }) else {
            throw AgentVMError.guestCommandFailed(command: "sw_vers", status: result.report.shellStatus, output: result.stdout + result.stderr)
        }
        return (lines[0], lines[1])
    }

    /// Installs a newer Command Line Tools package when the image has the tools and Apple
    /// offers one; returns its label.
    private func updateCommandLineTools(_ machine: MacMachine, installed: String?) async throws -> String? {
        guard let installed else {
            return nil
        }
        let listed = try await guestCapture(machine, MacOSUpdate.listRequest, readTimeout: 600)
        guard listed.report == ExitReport(status: 0), let label = CommandLineTools.label(fromListOutput: listed.stdout), label != installed else {
            return nil
        }
        progress("command-line-tools", "Updating the Command Line Tools: \(label)")
        let result = try await guestCapture(machine, CommandLineTools.installRequest(label: label), readTimeout: 1800)
        guard result.report == ExitReport(status: 0) else {
            throw AgentVMError.guestCommandFailed(command: "softwareupdate --install \(label)", status: result.report.shellStatus,
                                                  output: String((result.stdout + result.stderr).suffix(400)))
        }
        let verified = try await guestCapture(machine, CommandLineTools.verifyRequest)
        guard verified.report == ExitReport(status: 0) else {
            throw AgentVMError.guestCommandFailed(command: "check the Command Line Tools", status: verified.report.shellStatus,
                                                  output: (verified.stderr + verified.stdout).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return label
    }

    /// One recipe's update steps, then its checks.
    private func runUpdate(_ recipe: ImageRecipe, machine: MacMachine, boxUser: String, position: (index: Int, count: Int)) async throws {
        let clock = ContinuousClock()
        let began = clock.now
        progress("tools-update", "Updating \(recipe.name) (\(position.index) of \(position.count))\(recipe.description.map { ": \($0)" } ?? "")",
                 index: position.index, count: position.count)
        if !recipe.parameterValues.isEmpty {
            log("  parameters: \(recipe.parameterValues.keys.sorted().map { "\($0)=\(recipe.parameterValues[$0] ?? "")" }.joined(separator: ", "))")
        }
        try await runSteps(recipe.updateSteps, checks: recipe.checks, variables: recipe.variables, machine: machine, boxUser: boxUser, kind: "update step")
        log("  \(recipe.name) updated in \(Int(Self.seconds(clock.now - began))) s")
    }

    /// Shuts the updated guest down. A macOS 27 guest sometimes restarts instead of powering
    /// off: one that answers again is asked again, rather than losing the whole update.
    private func shutDownAfterUpdate(_ machine: MacMachine) async throws {
        let attempts = 3
        for attempt in 1...attempts {
            do {
                try await shutDown(machine)
                return
            } catch let AgentVMError.guestUnreachable(reason) {
                guard attempt < attempts, machine.isRunning, cancellation?.isCanceled != true else {
                    throw AgentVMError.guestUnreachable(reason)
                }
                notice("  note: the guest did not power off (\(reason)); waiting for it to answer and asking again")
                do {
                    _ = try await waitForDaemon(machine, attempts: 180)
                } catch AgentVMError.guestUnreachable where !machine.isRunning && machine.failure == nil && cancellation?.isCanceled != true {
                    // It powered off after all, only later than `shutDown` waits.
                    return
                }
            }
        }
    }
}
