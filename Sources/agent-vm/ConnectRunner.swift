// Sources/agent-vm/ConnectRunner.swift
//
// The work of `agent-vm connect` (avm). Checks come in a fixed order, so the same mistake
// always gives the same status: the options (ArgumentParser, 64), then what the command line
// names (the box, the agent), then the folder, then what there is to offer, then the terminal.
// Then the box is chosen (or taken), what to run is chosen (or taken; ConnectAgents), the
// questions asked (an agent's secret, its hosts), the steps planned (ConnectPlanner), and each
// performed with a line saying so: start the box when it is not running, check the agent is
// installed, share the folder, snapshot it when shared read-write, run the session as a child
// `agent-vm exec --tty` (SessionChild), then report what changed and keep or undo it
// (ConnectReport). connect never stops or deletes a box.

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
    /// No box at all to offer.
    case nothingToOffer
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
            return "choosing needs a terminal; name a box (\(words) <box>); \(words) list shows them"
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
            return "no boxes to connect to; create one with agent-vm box create <name> --image <image>"
        case let .temporaryNotRunning(box, name):
            return "box \(box) is a temporary box that is not running, so it is not started again; choose another box (\(name) list shows them)"
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

    var boxStore: BoxStore {
        return BoxStore(root: root)
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
        let remembered = project.flatMap { ConnectChoices(store: root).choice(for: $0) }
        if json {
            try Output.json(ConnectPickers.ListJSON(project: project, projectProblem: problem, remembered: remembered,
                                                    boxes: offers.map(ConnectPickers.BoxEntry.init)))
            return
        }
        for line in ConnectPickers.listLines(offers, project: project, projectProblem: problem, remembered: remembered) {
            print(line)
        }
    }

    private func connect(boxName: String?) throws -> Int32 {
        let terminal = Terminal()
        // What the command line names.
        var named: Box?
        if let boxName {
            let box = try boxStore.box(named: boxName)
            if box.record.disposable == true && !box.isRunning {
                throw ConnectError.temporaryNotRunning(box: box.name, name: invokedAs)
            }
            named = box
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
            let box: Box
            var status: BoxStatus
            let chosenInPicker: Bool
            if let named {
                box = named
                status = BoxStatus.of(box)
                chosenInPicker = false
            } else {
                let offers = try self.offers()
                if offers.isEmpty {
                    throw ConnectError.nothingToOffer
                }
                guard terminal.isInteractive else {
                    for line in ConnectPickers.listLines(offers, project: project, projectProblem: nil, remembered: remembered) {
                        print(line)
                    }
                    throw ConnectError.pickerNeedsTerminal(name: invokedAs)
                }
                let (sections, selected) = ConnectPickers.boxSections(offers, project: project, remembered: remembered)
                let title = "AgentVM - " + (project.map { "project " + Self.tilde($0) } ?? "no folder shared")
                let id = try Picker(title: title, sections: sections, selected: selected).run(on: terminal)
                guard let offer = offers.first(where: { $0.box.name == id }) else {
                    continue
                }
                print("Box \(offer.box.name)")
                box = offer.box
                status = offer.status
                chosenInPicker = true
            }

            // What to run; an agent found missing after it was chosen in the launch picker
            // shows that picker again, with what the probe found.
            var probed: Set<String>?
            while true {
                let (launch, launchChosenInPicker) = try chooseLaunch(box: box, running: status.state == .running, catalog: catalog,
                                                                      namedAgent: namedAgent, remembered: remembered?.launch,
                                                                      probed: &probed, terminal: terminal)
                if !options.dryRun && !terminal.isInteractive {
                    throw ConnectError.sessionNeedsTerminal
                }
                let request = ConnectRequest(target: .box(box.name), launch: launch, project: project, readOnly: options.readOnly,
                                             snapshot: !options.noSnapshot, secrets: options.secrets, env: options.env)
                let (facts, secretEntries) = try self.facts(for: launch, box: box, running: status.state == .running, probed: probed)
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
                    let answered = try ask(steps, launch: launch, facts: facts, secretEntries: secretEntries, box: box, terminal: terminal)
                    let rest = ConnectPlanner.steps(for: request, facts: answered).filter { !$0.isQuestion }
                    return try perform(rest, box: box, request: request, remembered: remembered, terminal: terminal)
                } catch let error as ConnectError {
                    switch error {
                    case .agentNotInstalled where launchChosenInPicker:
                        say(error)
                        status = BoxStatus.of(box)
                        probed = nil
                        continue
                    case .shareRefused where chosenInPicker:
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

    private func perform(_ steps: [ConnectStep], box: Box, request: ConnectRequest, remembered: ConnectChoice?, terminal: Terminal) throws -> Int32 {
        let sessions = SessionStore(root: root)
        var session: Session?
        var outcome: SessionChild.Outcome?
        for step in steps {
            switch step {
            case let .start(name, ownerPid):
                print("Starting box \(name)")
                let clock = ContinuousClock()
                let began = clock.now
                do {
                    _ = try BoxLauncher.start(box, executable: try AskpassEntry.executablePath(), ownerPid: ownerPid) { state in
                        if state == ControlResponse.State.stopping.rawValue {
                            print("  waiting for the box to stop")
                        }
                    }
                } catch AgentVMError.boxDisposed(let name) {
                    throw AgentVMError.boxDisposed(name)
                } catch {
                    throw ConnectError.failed(error)
                }
                print("Box \(name) is running (\((clock.now - began).components.seconds) s)")
            case let .probe(_, command):
                guard case .agent(let agent) = request.launch else {
                    continue
                }
                // A probe that fails (an old guest, no answer) says nothing: exec reports 127
                // if the command is missing.
                if let found = AgentProbe.run(box: box, commands: [command]), !found.contains(command) {
                    throw ConnectError.agentNotInstalled(agent: agent, box: box, name: invokedAs)
                }
            case .offerSecret, .askRules:
                // Asked before the steps (ask).
                continue
            case let .share(_, project, readOnly):
                print("Sharing \(Self.tilde(project)) (\(readOnly ? "read only" : "read-write"))")
                let response: ControlResponse
                do {
                    response = try ControlClient.request(ControlRequest(op: .share, path: project, readOnly: readOnly),
                                                         path: box.controlSocketPath, timeout: ControlClient.shareTimeout)
                } catch {
                    throw ConnectError.failed(error)
                }
                guard response.ok else {
                    throw ConnectError.shareRefused(message: response.error ?? "box \(box.name) did not share \(project)", box: box.name)
                }
            case let .snapshot(project):
                let (taken, signal) = try snapshot(project, store: sessions, terminal: terminal)
                session = taken
                if let signal {
                    return 128 + signal
                }
            case let .run(arguments):
                if let project = request.project {
                    remember(box: box.name, launch: request.launch, project: project, readOnly: request.readOnly, previous: remembered)
                }
                switch request.launch {
                case .shell:
                    print("Login shell in box \(box.name); exit it to come back here")
                case .command(let words):
                    print("Running \(ConnectPlanner.shellQuoted(words)) in box \(box.name)")
                case .agent(let agent):
                    print("\(agent.name) in box \(box.name); exit it to come back here")
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
                    // The terminal closed or the session was ended from outside: no one to talk
                    // to. The session is ended, kept for undo.
                    if let session {
                        ConnectReport.end(session, store: sessions, warn: warn)
                    }
                    return 128 + signal
                }
                outcome = ended
            case .report:
                guard let session else {
                    // The person went on without a snapshot.
                    continue
                }
                if let signal = ConnectReport.run(session: session, store: sessions, box: box, terminal: terminal, warn: warn) {
                    return 128 + signal
                }
            }
        }
        if box.record.disposable != true {
            print("Box \(box.name) keeps running; stop it with: agent-vm box stop \(box.name)")
        }
        return outcome?.status ?? 0
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
    /// command run leaves the remembered launch as it was.
    private func remember(box: String, launch: ConnectLaunch, project: String, readOnly: Bool, previous: ConnectChoice?) {
        let launchID: String?
        switch launch {
        case .shell:
            launchID = "shell"
        case .command:
            launchID = previous?.launch
        case .agent(let agent):
            launchID = agent.id
        }
        do {
            try ConnectChoices(store: root).remember(ConnectChoice(target: .box, box: box, launch: launchID, readOnly: readOnly), for: project)
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
            FileHandle.standardError.write(Data(lines.joined().utf8))
        }
    }

    func warn(_ text: String) {
        FileHandle.standardError.write(Data("\(invokedAs): warning: \(text)\n".utf8))
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
