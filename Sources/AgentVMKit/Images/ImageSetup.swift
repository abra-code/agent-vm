// Sources/AgentVMKit/Images/ImageSetup.swift
//
// One-time steps on an image that only a person can do, in the guest's own interface, with
// the image's screen in an interactive window (`agent-vm image setup`). Boxes cloned
// afterwards inherit them. The main one: Full Disk Access for agent-vm-guest. Everything exec
// runs is started by the daemon, so macOS asks on its behalf before a program opens the guest
// account's Desktop, Documents or Downloads, and nobody sees that prompt in a box: the program
// just waits. Apple's zero-click setup has no privacy settings, and the permission database is
// protected even from root, so the grant takes a person, once per image.
//
// Also here: the guest's desktop is kept from locking (no screen saver, no display sleep, no
// screen lock), which every new image gets too, so a window on it never asks for the password.

import AppKit
import Foundation
import Virtualization

extension ImageBuilder {
    /// A file only a process with Full Disk Access can read: trying never prompts.
    static let fullDiskAccessProbe = "/Library/Application Support/com.apple.TCC/TCC.db"
    /// System Settings, Privacy & Security, Full Disk Access.
    static let fullDiskAccessSettings = "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles"

    /// Boots a ready image with its screen in an interactive window, turns off everything that
    /// would lock the screen, opens Full Disk Access in System Settings with agent-vm-guest shown
    /// in Finder, watches for the grant, and shuts the image down when the window is closed (or
    /// on SIGINT or SIGTERM). The result is recorded in image.json.
    public func setUp(named name: String) async throws -> GoldenImage {
        var image = try store.image(named: name)
        subject = image.name
        guard image.record.state == .ready else {
            throw AgentVMError.wrongImageState(name: image.name, state: image.record.state.rawValue, operation: "set up")
        }
        guard BoxViewer.canShowWindows else {
            throw AgentVMError.hostNotReady("image setup shows the image's screen, so it needs a login session on this Mac (not SSH)")
        }
        try Self.checkHost(HostFacts.current(storeRoot: store.root), minimumFree: Self.minimumFreeBytesToUpdate)
        guard let lock = try store.tryLock(image) else {
            throw AgentVMError.imageBusy(image.name)
        }
        defer { lock.release() }
        guard let changeLock = try store.tryLockForChange(image) else {
            throw AgentVMError.imageBusy(image.name)
        }
        defer { changeLock.release() }
        // `updating`: this command holds the update lock itself, so an `Update/` folder is a killed
        // update's leftover.
        image = try store.settle(image, updating: true)
        let password = try String(contentsOf: image.passwordURL, encoding: .utf8)

        let auxiliaryStorage = VZMacAuxiliaryStorage(url: image.auxiliaryStorageURL)
        let machine = MacMachine(configuration: try spec(image).configuration(for: image.machineFiles, auxiliaryStorage: auxiliaryStorage))
        // Control-C (or SIGTERM) at any point ends the setup at the next step, with a clean
        // shutdown: killed, the process would take the image's VM down mid-write.
        let done = SetupDone()
        var sources: [DispatchSourceSignal] = []
        for signalNumber in [SIGINT, SIGTERM] {
            signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
            source.setEventHandler {
                done.finish()
            }
            source.resume()
            sources.append(source)
        }
        defer {
            for source in sources {
                source.cancel()
            }
            for signalNumber in [SIGINT, SIGTERM] {
                signal(signalNumber, SIG_DFL)
            }
        }
        progress("boot", "Booting \(image.name)")
        try await machine.start(provisioning: nil)
        let granted: Bool
        do {
            let hello = try await waitForDaemon(machine, attempts: 180)
            log("  agent-vm-guest \(hello.version ?? "?") answers")
            try await keepDesktopUnlocked(machine, user: image.record.userName, password: password)
            if done.isFinished {
                log("  Stopped before the window opened")
                granted = (try? await hasFullDiskAccess(machine)) == true
            } else {
                granted = try await grantFullDiskAccess(machine, image: image, password: password, done: done)
            }
            if machine.isRunning {
                try await shutDown(machine)
            } else if let failure = machine.failure {
                throw AgentVMError.guestUnreachable("the guest stopped during setup: \(failure)")
            } else {
                log("  The guest shut itself down")
            }
        } catch {
            if machine.isRunning {
                try? await machine.forceStop()
            }
            throw error
        }
        image = try store.update(image) { record in
            record.fullDiskAccess = ImageRecord.FullDiskAccess(granted: granted, guestDigest: record.guestDigest, guestRequirement: record.guestRequirement,
                                                              checkedAt: Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down)))
        }
        return image
    }

    /// The window part: shows the screen, opens the settings, and waits for the window to close.
    private func grantFullDiskAccess(_ machine: MacMachine, image: GoldenImage, password: String, done: SetupDone) async throws -> Bool {
        let viewer = BoxViewer(name: "image \(image.name)", machine: machine, password: password,
                               note: "Full Disk Access for agent-vm-guest: in Settings, drag agent-vm-guest from the Finder window into the list (or use +), turn it on, and use Type Password when asked. Close this window when done.",
                               onClose: { done.finish() }, log: { [weak self] in self?.log($0) })
        viewer.show(interactive: true)

        var granted = try await hasFullDiskAccess(machine)
        if granted {
            // Still the step that waits on the window, so a program can say so.
            progress("full-disk-access", "  agent-vm-guest already has Full Disk Access; close the window when done")
            viewer.setNote("agent-vm-guest has Full Disk Access. Do any other one-time steps, then close this window.")
        } else {
            let uid = try await userID(machine, user: image.record.userName)
            // Settings in the desktop session, and the daemon in Finder, ready to drag.
            for (what, target) in [("System Settings", [Self.fullDiskAccessSettings]), ("Finder", ["-R", GuestDaemon.executablePath])] {
                let opened = try await guestCapture(machine, GuestRequest(op: .exec, argv: ["/bin/launchctl", "asuser", uid, "/usr/bin/sudo", "-u", image.record.userName,
                                                                             "/usr/bin/open"] + target, cwd: "/", user: "root"))
                if opened.report != ExitReport(status: 0) {
                    notice("  note: could not open \(what) in the guest: \(opened.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
                }
            }
            progress("full-disk-access", "  Waiting for Full Disk Access for agent-vm-guest (close the window to stop)")
        }
        while !done.isFinished {
            try await Task.sleep(for: .seconds(2))
            // A guest shut down from its own menu ends the setup too (nothing else would).
            guard machine.isRunning else {
                break
            }
            // A probe that fails (a guest restarting, a slow answer) is tried again, not fatal:
            // failing here would pull the plug on what the person did in the guest.
            if !granted, !done.isFinished, (try? await hasFullDiskAccess(machine)) == true {
                granted = true
                log("  Full Disk Access granted")
                viewer.setNote("Full Disk Access granted. Do any other one-time steps, then close this window.")
            }
        }
        // A last look: the grant may have come in the final seconds.
        if !granted, machine.isRunning {
            granted = try await hasFullDiskAccess(machine)
        }
        log(granted ? "  agent-vm-guest has Full Disk Access" : "  agent-vm-guest still has no Full Disk Access")
        withExtendedLifetime(viewer) {}
        return granted
    }

    /// Probes Full Disk Access for the running daemon and records it for `digest` and
    /// `requirement` (the daemon's). A grant lost to a new daemon is said so: macOS ties it to
    /// the daemon's designated code requirement, which only a Developer ID keeps across builds.
    func recordFullDiskAccess(_ image: GoldenImage, machine: MacMachine, digest: String?, requirement: String?) async throws -> GoldenImage {
        let granted = try await hasFullDiskAccess(machine)
        if !granted, let previous = image.record.fullDiskAccess, previous.granted, previous.guestDigest != digest {
            let keep = requirement.map(CodeSignature.namesASigner) == true ? "" : "; a daemon signed with a Developer ID (Scripts/build.sh --identity) keeps it across updates"
            notice("  note: Full Disk Access was granted to the previous agent-vm-guest, not to this one (macOS ties it to the daemon's code signature); run `agent-vm image setup \(image.name)` to grant it again\(keep)")
        }
        return try store.update(image) { record in
            record.fullDiskAccess = ImageRecord.FullDiskAccess(granted: granted, guestDigest: digest, guestRequirement: requirement,
                                                              checkedAt: Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down)))
        }
    }

    /// Whether agent-vm-guest may read a file only Full Disk Access opens (never prompts).
    func hasFullDiskAccess(_ machine: MacMachine) async throws -> Bool {
        let probe = try await guestCapture(machine, GuestRequest(op: .exec, argv: ["/usr/bin/head", "-c", "16", Self.fullDiskAccessProbe], cwd: "/", user: "root"))
        return probe.report == ExitReport(status: 0)
    }

    /// No screen saver, no display sleep and no screen lock for the box user (GuestDesktop).
    func keepDesktopUnlocked(_ machine: MacMachine, user: String, password: String) async throws {
        let note = try await GuestDesktop.keepUnlocked(user: user, password: password, run: guestRunner(machine))
        if let note {
            notice("  note: \(note)")
        } else {
            log("  Screen lock, screen saver and display sleep off")
        }
    }

    /// The image's name as its wallpaper, and hidden widgets (GuestDesktop.prepare); boxes
    /// cloned from it start that way. `features`: what the running agent-vm-guest announced.
    /// An older daemon sets no wallpaper, without a note: every caller either replaces it next
    /// (`image create --from`) or already runs this agent-vm's (`image create`, `update-guest`).
    /// Only looks: a failure is logged, never fails the build or update.
    func prepareDesktop(_ image: GoldenImage, machine: MacMachine, features: [String]?) async {
        let features = features ?? []
        do {
            var shown = image.record
            shown.name = shownName ?? shown.name
            let png = features.contains(GuestFeature.wallpaper) ? try GuestWallpaper.png(for: shown) : nil
            let lines = try await GuestDesktop.prepare(user: image.record.userName, png: png,
                                                       features: features, widgetsOnce: false, run: guestRunner(machine))
            for line in lines {
                log("  \(line)")
            }
        } catch {
            // After a cancel the build stops at its next step; this is not worth a notice.
            if cancellation?.isCanceled != true {
                notice("  note: could not set up the desktop's wallpaper and widgets: \(error)")
            }
        }
    }

    /// Guest requests on this machine, with stdin, for GuestDesktop.
    func guestRunner(_ machine: MacMachine) -> GuestDesktop.Run {
        return { [self] request, input in
            try await withGuest(machine, Self.describe(request)) { descriptor in
                try GuestClient.capture(descriptor, request, input: input)
            }
        }
    }

    private func userID(_ machine: MacMachine, user: String) async throws -> String {
        return try await GuestDesktop.userID(user, run: guestRunner(machine))
    }
}

/// Set once, by the window closing or a signal; read on the main actor.
@MainActor
private final class SetupDone {
    private(set) var isFinished = false

    func finish() {
        isFinished = true
    }
}
