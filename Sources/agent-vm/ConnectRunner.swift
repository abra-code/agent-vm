// Sources/agent-vm/ConnectRunner.swift
//
// The work of `agent-vm connect` (avm). Checks come in a fixed order, so the same mistake
// always gives the same status: the options (ArgumentParser, 64), then what the command line
// names (the box, the agent), then the folder, then what there is to offer, then the terminal.
// Then the box is chosen (or taken): an existing one, or a new one from an image, temporary or
// kept. What to run is chosen (or taken; ConnectAgents), the questions asked (an agent's
// secret, its hosts), the steps planned (ConnectPlanner), and each performed with a line
// saying so: create a new box, start the box when it is not running, check the agent is
// installed, share the folder, snapshot it when shared read-write, run the session as a child
// `agent-vm exec --tty` (SessionChild), stop and delete a temporary box, then report what
// changed and keep or undo it (ConnectReport). connect stops and deletes only the temporary box
// it created in this run.

import AgentVMKit
import Darwin
import Foundation
import TerminalUI

/// Why connect ends before or instead of a session; each says what to do about it.
enum ConnectError: Error, CustomStringConvertible {
    /// A picker was needed and stdin or stdout is not a terminal.
    case pickerNeedsTerminal(name: String)
    /// The launch picker was needed and stdin or stdout is not a terminal.
    case launchNeedsTerminal
    /// --agent names no usable agent.
    case unknownAgent(id: String, known: [String], problem: AgentCatalog.Problem?, name: String)
    /// The agent's command is not in the box.
    case agentNotInstalled(agent: AgentEntry, box: Box, name: String)
    /// A session was asked for and stdin or stdout is not a terminal.
    case sessionNeedsTerminal
    /// No box and no usable image to offer.
    case nothingToOffer
    /// No VM slot for the start; the running boxes are named.
    case noFreeSlot(String)
    /// --refresh: the image's tools update failed; the image is as it was.
    case refreshFailed(image: String, message: String, status: Int32)
    /// The image's guest daemon cannot run a terminal session.
    case imageNeedsUpdate(String)
    /// A named temporary box that is not running.
    case temporaryNotRunning(box: String, name: String)
    /// The folder cannot be shared.
    case unsuitableFolder(AgentVMError)
    /// The box's supervisor refused the share (another folder is in use there).
    case shareRefused(message: String, box: String)
    /// No snapshot could be taken, and the person did not go on without one.
    case noSnapshot(project: String)
    /// Escape or Control-C in a picker or a question.
    case canceled
    /// A signal ended a picker or a question.
    case interrupted(Int32)
    /// Anything else, with the library's message.
    case failed(Error)

    var description: String {
        switch self {
        case let .pickerNeedsTerminal(name):
            let words = name == "avm" ? "avm" : "agent-vm connect"
            return "choosing needs a terminal; name a box (\(words) <box>) or an image (\(words) new <image>); \(words) list shows them"
        case .launchNeedsTerminal:
            return "choosing what to run needs a terminal; name it: --agent <id>, --shell, or a command after --"
        case let .unknownAgent(id, known, problem, name):
            let words = name == "avm" ? "avm" : "agent-vm connect"
            if let problem {
                return "agent \(id) cannot be used: \(problem.path): \(problem.reason)"
            }
            return "no agent \(id); \(words) agents lists them\(known.isEmpty ? "" : ": " + known.joined(separator: ", "))"
        case let .agentNotInstalled(agent, box, name):
            let words = name == "avm" ? "avm" : "agent-vm connect"
            var text = "\(agent.name) (\(agent.command[0])) is not installed in box \(box.name) (image \(box.record.image)); use an image built with Recipes/agent-clis, or install it in a kept box (\(words) \(box.name) --shell"
            if let install = agent.install {
                text += ", then \(install)"
            }
            text += ")\nwhen it is installed outside the login shell's PATH, run it by its path: \(words) \(box.name) -- /path/to/\(agent.command[0])"
            return text
        case .sessionNeedsTerminal:
            return "the session runs on this terminal, and stdin or stdout is not one; from a script use agent-vm exec --box <box> -- <program>"
        case .nothingToOffer:
            return "no boxes and no ready images; build an image first (agent-vm image create, see the README)"
        case let .noFreeSlot(message):
            return message
        case let .refreshFailed(image, _, status) where status > 128:
            // A cancel: the update said so itself.
            return "the tools update of image \(image) was canceled: the image is as it was, and no box was made"
        case let .refreshFailed(image, message, _):
            // The update's own words (they begin with "Error:"), then what it means here.
            let said = message.trimmingCharacters(in: .whitespacesAndNewlines)
            return "\(said.isEmpty ? "the tools update of image \(image) failed" : said)\nimage \(image) is as it was, and no box was made; without --refresh the box is made from it as it is"
        case let .imageNeedsUpdate(image):
            return "image \(image)'s agent-vm-guest cannot run terminal sessions; update it with agent-vm image update \(image) --guest"
        case let .temporaryNotRunning(box, name):
            let words = name == "avm" ? "avm" : "agent-vm connect"
            return "box \(box) is a temporary box that is not running, so it is not started again; make a new one with \(words) new <image>"
        case let .unsuitableFolder(error):
            return "\(error); share another folder with --project, or none with --no-project"
        case let .shareRefused(message, box):
            // A second line: a session left running (a terminal window closed without ending
            // it, for example) is found in the exec log.
            return "\(message)\nprograms with no end recorded in agent-vm box execlog \(box) may still be running"
        case let .noSnapshot(project):
            return "nothing was run: no snapshot of \(ConnectRunner.tilde(project)); --no-snapshot runs without one"
        case .canceled, .interrupted:
            return ""
        case let .failed(error):
            return "\(error)"
        }
    }

    var status: Int32 {
        switch self {
        case .pickerNeedsTerminal, .sessionNeedsTerminal, .launchNeedsTerminal, .unknownAgent:
            return 64
        case .canceled:
            return 130
        case .noFreeSlot:
            return AgentVMError.noFreeVMSlotStatus
        case let .refreshFailed(_, _, status):
            // A cancel of the update (Control-C reaches it too) ends connect the same way.
            return status > 128 ? status : 1
        case let .interrupted(signal):
            return 128 + signal
        case let .failed(error):
            if case AgentVMError.noFreeVMSlot? = error as? AgentVMError {
                return AgentVMError.noFreeVMSlotStatus
            }
            return 1
        default:
            return 1
        }
    }
}

struct ConnectRunner {
    var options: ConnectOptions
    var root: URL
    /// "avm" or "agent-vm connect": the prefix of messages and the words in hints.
    var invokedAs: String
    /// `connect new`: the new box; nil for `connect to`.
    var newBox: NewBox?

    /// What `connect new` names: the image, the kept box's name (nil: temporary), and the new
    /// box's rules, CPUs and memory.
    struct NewBox {
        var image: String
        var name: String?
        var allow: [String]
        var cpus: Int?
        var memoryBytes: UInt64?
        /// Update the image's tools first (--refresh).
        var refresh = false
    }

    /// Where the session runs.
    enum Place {
        case existing(Box, BoxStatus)
        /// A new box from `image`; `name` nil: temporary.
        case new(image: GoldenImage, name: String?)
    }

    var boxStore: BoxStore {
        return BoxStore(root: root)
    }

    var imageStore: ImageStore {
        return ImageStore(root: root)
    }

    /// Connects and exits with the session's status, or with the status of what stopped it.
    func run(boxName: String?) -> Never {
        let status: Int32
        do {
            status = try connect(boxName: boxName)
        } catch let error as ConnectError {
            say(error)
            status = error.status
        } catch let error as TerminalUIError {
            let mapped = Self.connectError(error)
            say(mapped)
            status = mapped.status
        } catch {
            let wrapped = ConnectError.failed(error)
            say(wrapped)
            status = wrapped.status
        }
        exit(status)
    }

    /// `connect list`: what the picker would offer, and the choice remembered for the folder.
    func list(json: Bool, project path: String?) throws {
        var project: String?
        var problem: String?
        do {
            project = try ProjectShare.validated(path ?? FileManager.default.currentDirectoryPath, storeRoot: root)
        } catch let error as AgentVMError {
            guard case let .unsuitableProject(_, reason) = error else {
                throw error
            }
            problem = reason
        }
        BoxCommand.GC.collect(boxStore)
        let offers = try self.offers()
        let images = try imageOffers()
        let remembered = project.flatMap { ConnectChoices(store: root).choice(for: $0) }
        if json {
            try Output.json(ConnectPickers.ListJSON(project: project, projectProblem: problem, remembered: remembered,
                                                    boxes: offers.map(ConnectPickers.BoxEntry.init),
                                                    images: images.map(ConnectPickers.ImageEntry.init)))
            return
        }
        for line in ConnectPickers.listLines(offers, images: images, project: project, projectProblem: problem, remembered: remembered) {
            print(line)
        }
    }

    private func connect(boxName: String?) throws -> Int32 {
        let terminal = Terminal()
        // What the command line names: the box, or the image and the new box's name.
        var named: Box?
        if let boxName {
            let box = try boxStore.box(named: boxName)
            if box.record.disposable == true && !box.isRunning {
                throw ConnectError.temporaryNotRunning(box: box.name, name: invokedAs)
            }
            named = box
        }
        var namedImage: GoldenImage?
        if let newBox {
            let image = try imageStore.image(named: newBox.image)
            try Self.checkUsable(image)
            if let name = newBox.name, (try? boxStore.box(named: name)) != nil {
                throw AgentVMError.boxExists(name)
            }
            // Rules and packs checked before anything is made.
            let network = BoxNetwork(mode: .allowlist, allow: newBox.allow)
            _ = try CompiledPolicy(network, packs: try NetworkPacks.needed(for: network, store: root))
            namedImage = image
        }
        let catalog = AgentCatalog.load(store: root)
        var namedAgent: AgentEntry?
        if let id = options.agent {
            guard let agent = catalog.entry(id: id) else {
                if catalog.problems[id] == nil {
                    // An unusable built-in file or user folder may be why: said above the error.
                    warnAbout(catalog)
                }
                throw ConnectError.unknownAgent(id: id, known: catalog.entries.map(\.id), problem: catalog.problems[id], name: invokedAs)
            }
            namedAgent = agent
        }
        let project = try resolveProject(terminal)
        BoxCommand.GC.collect(boxStore)
        let choices = ConnectChoices(store: root)
        let remembered = project.flatMap { choices.choice(for: $0) }
        if options.namedLaunch == nil && namedAgent == nil {
            warnAbout(catalog)
        }

        boxes: while true {
            var place: Place
            let chosenInPicker: Bool
            if let named {
                place = .existing(named, BoxStatus.of(named))
                chosenInPicker = false
            } else if let namedImage {
                place = .new(image: namedImage, name: newBox?.name)
                chosenInPicker = false
            } else {
                guard let chosen = try choosePlace(project: project, remembered: remembered, terminal: terminal) else {
                    continue
                }
                place = chosen
                chosenInPicker = true
            }
            // A new temporary box's name, chosen once and free now.
            var temporaryName: String?
            if case .new(let image, nil) = place {
                temporaryName = try freeTemporaryName(image: image.name)
            }

            // What to run; an agent found missing after it was chosen in the launch picker
            // shows that picker again, with what the probe found.
            var probed: Set<String>?
            while true {
                let boxName: String
                let temporary: Bool
                var runningBox: Box?
                switch place {
                case let .existing(box, status):
                    boxName = box.name
                    temporary = box.record.disposable == true
                    runningBox = status.state == .running ? box : nil
                case let .new(_, name):
                    boxName = name ?? temporaryName ?? ""
                    temporary = name == nil
                }
                let (launch, launchChosenInPicker) = try chooseLaunch(boxName: boxName, temporary: temporary, runningBox: runningBox,
                                                                      catalog: catalog, namedAgent: namedAgent,
                                                                      remembered: remembered?.launch, probed: &probed, terminal: terminal)
                if !options.dryRun && !terminal.isInteractive {
                    throw ConnectError.sessionNeedsTerminal
                }
                let target: ConnectTarget
                var existing: Box?
                switch place {
                case let .existing(box, _):
                    target = .box(box.name)
                    existing = box
                case let .new(image, name):
                    target = name.map { .newKept(image: image.name, name: $0) } ?? .newTemporary(image: image.name)
                }
                let request = ConnectRequest(target: target, launch: launch, project: project, readOnly: options.readOnly,
                                             snapshot: !options.noSnapshot, secrets: options.secrets, env: options.env,
                                             extraAllow: newBox?.allow ?? [], cpus: newBox?.cpus, memoryBytes: newBox?.memoryBytes,
                                             refresh: newBox?.refresh ?? false)
                var (facts, secretEntries) = try self.facts(for: launch, box: existing, running: runningBox != nil, probed: probed)
                facts.temporaryName = temporaryName
                let steps = ConnectPlanner.steps(for: request, facts: facts)
                if options.dryRun {
                    print("\(invokedAs) would:")
                    for step in steps {
                        print("  " + step.text)
                    }
                    return 0
                }
                do {
                    // The questions first (a secret, the hosts); then the steps again, with
                    // what the answers changed.
                    let answered = try ask(steps, launch: launch, facts: facts, secretEntries: secretEntries, boxName: boxName, terminal: terminal)
                    let rest = ConnectPlanner.steps(for: request, facts: answered).filter { !$0.isQuestion }
                    return try perform(rest, existing: existing, request: request, remembered: remembered, terminal: terminal)
                } catch let error as ConnectError {
                    switch error {
                    case .agentNotInstalled where launchChosenInPicker:
                        say(error)
                        // A kept box made meanwhile is an existing box now; a temporary one
                        // was deleted, and is made again.
                        if let box = try? boxStore.box(named: boxName) {
                            place = .existing(box, BoxStatus.of(box))
                        }
                        probed = nil
                        continue
                    case .shareRefused where chosenInPicker, .noFreeSlot where chosenInPicker:
                        // Another box may do; the list again, with the reason above it.
                        say(error)
                        continue boxes
                    default:
                        throw error
                    }
                } catch AgentVMError.boxDisposed(let name) where chosenInPicker {
                    BoxCommand.GC.collect(boxStore)
                    say(ConnectError.failed(AgentVMError.boxDisposed(name)))
                    continue boxes
                }
            }
        }
    }

    /// The box list: an existing box, or a new temporary or kept box (then the image list, and
    /// for a kept box its name). Nil: choose again.
    private func choosePlace(project: String?, remembered: ConnectChoice?, terminal: Terminal) throws -> Place? {
        let offers = try self.offers()
        let images = try imageOffers()
        let usable = images.filter { $0.reason == nil }
        if offers.isEmpty && usable.isEmpty {
            throw ConnectError.nothingToOffer
        }
        guard terminal.isInteractive else {
            for line in ConnectPickers.listLines(offers, images: images, project: project, projectProblem: nil, remembered: remembered) {
                print(line)
            }
            throw ConnectError.pickerNeedsTerminal(name: invokedAs)
        }
        let (sections, selected) = ConnectPickers.boxSections(offers, newBoxes: !usable.isEmpty, project: project, remembered: remembered)
        let title = "AgentVM - " + (project.map { "project " + Self.tilde($0) } ?? "no folder shared")
        let id = try Picker(title: title, sections: sections, selected: selected).run(on: terminal)
        switch id {
        case ConnectPickers.newTemporaryID, ConnectPickers.newKeptID:
            // Escape in the image list or at the name goes back to the box list.
            do {
                return try chooseNewBox(temporary: id == ConnectPickers.newTemporaryID, project: project, remembered: remembered,
                                        terminal: terminal)
            } catch TerminalUIError.canceled {
                return nil
            }
        default:
            guard let offer = offers.first(where: { $0.box.name == id }) else {
                return nil
            }
            print("Box \(offer.box.name)")
            return .existing(offer.box, offer.status)
        }
    }

    /// The image list, and for a kept box its name. Nil: choose again.
    private func chooseNewBox(temporary: Bool, project: String?, remembered: ConnectChoice?, terminal: Terminal) throws -> Place? {
        let images = try imageOffers()
        let (imageSections, imageSelected) = ConnectPickers.imageSections(images, remembered: remembered?.image)
        let title = temporary ? "New temporary box (deleted when you leave) from an image" : "New kept box from an image"
        let name = try Picker(title: title, sections: imageSections, selected: imageSelected).run(on: terminal)
        guard let image = images.first(where: { $0.image.name == name })?.image else {
            return nil
        }
        print("Image \(image.name)")
        if temporary {
            return .new(image: image, name: nil)
        }
        let existing = Set(((try? boxStore.list().boxes) ?? []).map(\.name))
        let suggested = ConnectPlanner.suggestedBoxName(project: project, image: image.name, existing: existing)
        let boxName = try LineInput(prompt: "Name of the new box: ", initial: suggested) { name in
            guard ImageStore.isValidName(name) else {
                return "a box name is lower-case letters, digits, \".\", \"_\" and \"-\", starting with a letter or digit, at most 63"
            }
            return (try? boxStore.box(named: name)) == nil ? nil : "box \(name) already exists"
        }.run(on: terminal)
        return .new(image: image, name: boxName)
    }

    /// A new box can be made from `image`: it is ready, and its guest daemon runs terminal
    /// sessions.
    static func checkUsable(_ image: GoldenImage) throws {
        guard image.record.state == .ready else {
            throw AgentVMError.wrongImageState(name: image.name, state: image.record.state.rawValue, operation: "create a box from")
        }
        guard (image.record.guestFeatures ?? []).contains(GuestFeature.terminal) else {
            throw ConnectError.imageNeedsUpdate(image.name)
        }
    }

    /// A temporary box's name no box has: three tries with random hex.
    private func freeTemporaryName(image: String) throws -> String {
        let existing = Set(((try? boxStore.list().boxes) ?? []).map(\.name))
        for _ in 0..<3 {
            let name = ConnectPlanner.temporaryName(image: image, random: UInt32.random(in: 0...0xFF_FFFF))
            if !existing.contains(name) {
                return name
            }
        }
        throw AgentVMError.boxExists(ConnectPlanner.temporaryName(image: image, random: 0))
    }

    /// The ready images, each usable or with why not.
    private func imageOffers() throws -> [ConnectPickers.ImageOffer] {
        let (images, problems) = try imageStore.list()
        for problem in problems {
            warn(problem)
        }
        return images.filter { $0.record.state == .ready }.map { image in
            let terminal = (image.record.guestFeatures ?? []).contains(GuestFeature.terminal)
            return ConnectPickers.ImageOffer(image: image, reason: terminal ? nil : "needs agent-vm image update \(image.name) --guest")
        }
    }

    /// The message when no VM slot is free: the running boxes, and how to stop one.
    private func noSlotMessage() -> String {
        let limit = HostReport.macOSGuestLimit
        var running: [String] = []
        for box in ((try? boxStore.list().boxes) ?? []) where box.isRunning {
            let status = BoxStatus.of(box)
            var notes: [String] = []
            if let execs = status.activeExecs, execs > 0 {
                notes.append("\(execs) program\(execs == 1 ? "" : "s") running")
            }
            if let owner = status.ownerPid {
                notes.append("stops when process \(owner) exits")
            }
            running.append(box.name + (notes.isEmpty ? "" : " (" + notes.joined(separator: ", ") + ")"))
        }
        var text = "no free VM slot: macOS runs at most \(limit) macOS virtual machines at once; running now: "
        text += running.isEmpty ? "none of your boxes" : running.joined(separator: ", ")
        if running.count < limit {
            text += running.isEmpty ? ", so \(limit) in another application" : ", and \(limit - running.count) in another application"
        }
        return text + "; stop one (agent-vm box stop <name>) and try again"
    }

    /// The folder to share, canonical; nil with --no-project, or when the person agreed to go
    /// on without the current folder, which cannot be shared.
    private func resolveProject(_ terminal: Terminal) throws -> String? {
        if options.noProject {
            return nil
        }
        do {
            return try ProjectShare.validated(options.project ?? FileManager.default.currentDirectoryPath, storeRoot: root)
        } catch let error as AgentVMError {
            guard case let .unsuitableProject(path, reason) = error else {
                throw ConnectError.failed(error)
            }
            // Asked only for the current folder: a folder named with --project is what the
            // person wants shared, and nothing else will do.
            if options.project == nil && !options.dryRun && terminal.isInteractive {
                // The reason on a line of its own: the question stays short enough for its keys to
                // show on a narrow terminal.
                print("\(Self.tilde(path)) cannot be shared: \(reason)")
                if try Confirm("Connect without sharing a folder?", defaultAnswer: true).run(on: terminal) {
                    return nil
                }
            }
            throw ConnectError.unsuitableFolder(error)
        }
    }

    /// Every box with its status (one question per running box), as offered.
    private func offers() throws -> [ConnectPickers.Offer] {
        let (boxes, problems) = try boxStore.list()
        for problem in problems {
            warn(problem)
        }
        return ConnectPickers.offers(boxes.map { ($0, BoxStatus.of($0)) })
    }

    private func perform(_ steps: [ConnectStep], existing: Box?, request: ConnectRequest, remembered: ConnectChoice?,
                         terminal: Terminal) throws -> Int32 {
        let sessions = SessionStore(root: root)
        var box = existing
        // The temporary box this run created, until it is stopped and deleted; `started` once
        // its start succeeded.
        var temporary: Box?
        var started = false
        var session: Session?
        var outcome: SessionChild.Outcome?
        do {
            for step in steps {
                switch step {
                case let .refresh(image):
                    // Asked for by the person, so a failure stops here: the box they wanted
                    // is one with the tools updated.
                    // Signals are held meanwhile and passed on to the update (RefreshProgress),
                    // which shuts its virtual machine down and says so. Were connect to exit
                    // first, the update's next line would find its pipe closed and SIGPIPE
                    // would end it halfway.
                    let executable = try AskpassEntry.executablePath()
                    let (result, signal) = SignalHold.around {
                        try RefreshProgress.run(image: image, executable: executable, terminal: terminal)
                    }
                    let ended = try result.get()
                    if ended.status == AgentVMError.noFreeVMSlotStatus {
                        throw ConnectError.noFreeSlot(noSlotMessage())
                    }
                    guard ended.status == 0 else {
                        throw ConnectError.refreshFailed(image: image, message: ended.error, status: ended.status)
                    }
                    if let signal {
                        // The update was done before the signal could stop it: no box.
                        return 128 + signal
                    }
                case let .create(name, image, allow, isTemporary, cpus, memoryBytes):
                    print(isTemporary ? "Creating box \(name) from \(image) (temporary: deleted when you leave)" : "Creating box \(name) from \(image)")
                    let golden = try imageStore.image(named: image)
                    let created = try boxStore.create(name: name, from: golden, imageStore: imageStore, cpuCount: cpus, memoryBytes: memoryBytes,
                                                      network: BoxNetwork(mode: .allowlist, allow: allow), disposable: isTemporary)
                    box = created
                    if isTemporary {
                        temporary = created
                    }
                case let .start(name, ownerPid):
                    guard let current = box else {
                        continue
                    }
                    let shown = StartProgress(box: name, estimate: BoxLauncher.lastBootSeconds(of: current), terminal: terminal)
                    shown.begin()
                    do {
                        defer { shown.end() }
                        _ = try BoxLauncher.start(current, executable: try AskpassEntry.executablePath(), ownerPid: ownerPid,
                                                  tick: { shown.tick() }) { state in
                            if state == ControlResponse.State.stopping.rawValue {
                                shown.note("  waiting for the box to stop")
                            }
                        }
                    } catch AgentVMError.boxDisposed(let name) {
                        throw AgentVMError.boxDisposed(name)
                    } catch AgentVMError.noFreeVMSlot {
                        var message = noSlotMessage()
                        if case .newKept = request.target {
                            // Made in this run and kept, as a kept box is.
                            let words = invokedAs == "avm" ? "avm" : "agent-vm connect"
                            message += "\nbox \(name) was made and is kept: \(words) \(name) starts it later"
                        }
                        throw ConnectError.noFreeSlot(message)
                    } catch {
                        throw ConnectError.failed(error)
                    }
                    started = true
                    print("Box \(name) is running (\(shown.elapsedSeconds) s)")
                case let .probe(_, command):
                    guard case .agent(let agent) = request.launch, let current = box else {
                        continue
                    }
                    // A probe that fails (an old guest, no answer) says nothing: exec reports
                    // 127 if the command is missing.
                    if let found = AgentProbe.run(box: current, commands: [command]), !found.contains(command) {
                        throw ConnectError.agentNotInstalled(agent: agent, box: current, name: invokedAs)
                    }
                case .offerSecret, .askRules:
                    // Asked before the steps (ask).
                    continue
                case let .share(name, project, readOnly):
                    guard let current = box else {
                        continue
                    }
                    print("Sharing \(Self.tilde(project)) (\(readOnly ? "read only" : "read-write"))")
                    let response: ControlResponse
                    do {
                        response = try ControlClient.request(ControlRequest(op: .share, path: project, readOnly: readOnly),
                                                             path: current.controlSocketPath, timeout: ControlClient.shareTimeout)
                    } catch {
                        throw ConnectError.failed(error)
                    }
                    guard response.ok else {
                        throw ConnectError.shareRefused(message: response.error ?? "box \(name) did not share \(project)", box: name)
                    }
                case let .snapshot(project):
                    let (taken, signal) = try snapshot(project, store: sessions, terminal: terminal)
                    session = taken
                    if let signal {
                        // A temporary box is left to its owner lease: it stops when this exits.
                        return 128 + signal
                    }
                case let .run(arguments):
                    guard let current = box else {
                        continue
                    }
                    if let project = request.project {
                        remember(request: request, box: current.name, project: project, previous: remembered)
                    }
                    switch request.launch {
                    case .shell:
                        print("Login shell in box \(current.name); exit it to come back here")
                    case .command(let words):
                        print("Running \(ConnectPlanner.shellQuoted(words)) in box \(current.name)")
                    case .agent(let agent):
                        print("\(agent.name) in box \(current.name); exit it to come back here")
                    }
                    let ended: SessionChild.Outcome
                    do {
                        ended = try SessionChild.run(executable: try AskpassEntry.executablePath(), arguments: arguments)
                    } catch {
                        if let session {
                            ConnectReport.end(session, store: sessions, warn: warn)
                        }
                        throw ConnectError.failed(error)
                    }
                    restoreTerminal(after: ended, terminal: terminal)
                    if let signal = ended.signal {
                        // The terminal closed or the session was ended from outside: no one to
                        // talk to. The session is ended, kept for undo; a temporary box is left
                        // to its owner lease.
                        if let session {
                            ConnectReport.end(session, store: sessions, warn: warn)
                        }
                        return 128 + signal
                    }
                    outcome = ended
                case .stopAndDelete:
                    guard let current = temporary else {
                        continue
                    }
                    temporary = nil
                    if let signal = stopAndDelete(current) {
                        if let session {
                            ConnectReport.end(session, store: sessions, warn: warn)
                        }
                        return 128 + signal
                    }
                case .report:
                    guard let session, let current = box else {
                        // The person went on without a snapshot.
                        continue
                    }
                    if let signal = ConnectReport.run(session: session, store: sessions, box: current, terminal: terminal, warn: warn) {
                        return 128 + signal
                    }
                }
            }
        } catch {
            // A temporary box this run created goes with the failure: stopped and deleted once
            // it started; deleted when it never ran; left to its owner lease while a start that
            // failed may still be going (it stops when this exits, and box gc deletes it).
            if let current = temporary {
                if started {
                    _ = stopAndDelete(current)
                } else if !current.isRunning {
                    try? boxStore.delete(named: current.name)
                }
            }
            throw error
        }
        if let current = box, current.record.disposable != true {
            print("Box \(current.name) keeps running; stop it with: agent-vm box stop \(current.name)")
        }
        return outcome?.status ?? 0
    }

    /// Stops the temporary box and deletes it, with signals held; a signal that arrived
    /// meanwhile comes back. A box that stopped on its own (the guest shut down) counts as
    /// stopped.
    private func stopAndDelete(_ box: Box) -> Int32? {
        print("Stopping box \(box.name) (temporary)")
        let clock = ContinuousClock()
        let began = clock.now
        let (result, signal) = SignalHold.around { () -> Void in
            do {
                try BoxLauncher.stop(box)
            } catch AgentVMError.boxNotRunning {
            }
            do {
                try boxStore.delete(named: box.name)
            } catch AgentVMError.boxNotFound {
                // Stopped, it had a tombstone: another client's box gc deleted it meanwhile.
            }
        }
        switch result {
        case .success:
            print("  stopped and deleted (\((clock.now - began).components.seconds) s)")
        case .failure(let error):
            warn("could not stop and delete box \(box.name): \(error); it stops when this \(invokedAs) exits, and agent-vm box gc deletes it")
        }
        return signal
    }

    /// Takes the snapshot, with signals held. When it cannot be taken, says why and asks
    /// whether to go on without one (the session is nil then); no is `noSnapshot`. A signal
    /// during the step comes back with it, the session already ended.
    private func snapshot(_ project: String, store: SessionStore, terminal: Terminal) throws -> (Session?, Int32?) {
        let (result, signal) = SignalHold.around { try store.start(project: project) }
        switch result {
        case .success(let session):
            print("Snapshot of \(Self.tilde(project)) taken (session \(session.id))")
            if let signal {
                ConnectReport.end(session, store: store, warn: warn)
                return (session, signal)
            }
            return (session, nil)
        case .failure(let error):
            if let signal {
                return (nil, signal)
            }
            let question: Confirm
            switch error {
            case AgentVMError.sessionAlreadyActive(_, let id):
                print("Session \(id) is already active for \(Self.tilde(project)) (another avm, or an application using agent-vm); its snapshot covers this run too.")
                question = Confirm("Go on without a new snapshot?", defaultAnswer: true)
            case AgentVMError.differentVolume:
                print("\(Self.tilde(project)) is on another volume than the agent-vm store, so no snapshot can be taken and nothing can be undone.")
                question = Confirm("Go on without a snapshot?", defaultAnswer: false)
            default:
                print("No snapshot: \(error).")
                question = Confirm("Go on without a snapshot?", defaultAnswer: false)
            }
            guard try question.run(on: terminal) else {
                throw ConnectError.noSnapshot(project: project)
            }
            return (nil, nil)
        }
    }

    /// The terminal as it was (SessionChild put its settings back).
    private func restoreTerminal(after outcome: SessionChild.Outcome, terminal: Terminal) {
        guard terminal.style.cursorControl else {
            return
        }
        // Attributes off, the cursor shown. When the child did not end normally, also the
        // modes a full-screen program may have left on: mouse reports, bracketed paste, kitty
        // keyboard flags. Never "leave the alternate screen": when not in it, some terminals
        // move the cursor.
        var text = "\u{1B}[0m\u{1B}[?25h"
        if outcome.status == ExecRunner.ownFailureStatus || outcome.status >= 128 {
            text += "\u{1B}[?1000l\u{1B}[?1002l\u{1B}[?1003l\u{1B}[?1006l\u{1B}[?2004l\u{1B}[<u"
        }
        terminal.write(text)
    }

    /// Right before the session, so one that ends with a closed terminal is remembered too. A
    /// command run leaves the remembered launch as it was. A temporary box is remembered as
    /// its image, a kept box by its name.
    private func remember(request: ConnectRequest, box: String, project: String, previous: ConnectChoice?) {
        let launchID: String?
        switch request.launch {
        case .shell:
            launchID = "shell"
        case .command:
            launchID = previous?.launch
        case .agent(let agent):
            launchID = agent.id
        }
        let choice: ConnectChoice
        if case .newTemporary(let image) = request.target {
            choice = ConnectChoice(target: .temporary, image: image, launch: launchID, readOnly: request.readOnly)
        } else {
            choice = ConnectChoice(target: .box, box: box, launch: launchID, readOnly: request.readOnly)
        }
        do {
            try ConnectChoices(store: root).remember(choice, for: project)
        } catch {
            warn("cannot remember this choice: \(error)")
        }
    }

    static func connectError(_ error: TerminalUIError) -> ConnectError {
        switch error {
        case .notInteractive:
            return .sessionNeedsTerminal
        case .canceled:
            return .canceled
        case .interrupted(let signal):
            return .interrupted(signal)
        }
    }

    /// Each line of the error's text, prefixed with the name connect was started as.
    func say(_ error: ConnectError) {
        let text = error.description
        if !text.isEmpty {
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map { "\(invokedAs): \($0)\n" }
            Stderr.write(lines.joined())
        }
    }

    func warn(_ text: String) {
        Stderr.write("\(invokedAs): warning: \(text)\n")
    }

    /// `path` with the home folder as "~".
    static func tilde(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path == home {
            return "~"
        }
        if path.hasPrefix(home + "/") {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }
}
