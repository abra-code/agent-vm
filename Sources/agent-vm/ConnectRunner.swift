// Sources/agent-vm/ConnectRunner.swift
//
// The work of `agent-vm connect` (avm). Checks come in a fixed order, so the same mistake
// always gives the same status: the options (ArgumentParser, 64), then what the command line
// names (the box), then the folder, then what there is to offer, then the terminal. Then the
// box is chosen (or taken), the steps planned (ConnectPlanner), and each performed with a line
// saying so: start the box when it is not running, share the folder, run the session as a
// child `agent-vm exec --tty` (SessionChild). connect never stops or deletes a box.

import AgentVMKit
import Darwin
import Foundation
import TerminalUI

/// Why connect ends before or instead of a session; each says what to do about it.
enum ConnectError: Error, CustomStringConvertible {
    /// A picker was needed and stdin or stdout is not a terminal.
    case pickerNeedsTerminal(name: String)
    /// A session was asked for and stdin or stdout is not a terminal.
    case sessionNeedsTerminal
    /// No box at all to offer.
    case nothingToOffer
    /// A named temporary box that is not running.
    case temporaryNotRunning(box: String, name: String)
    /// The folder cannot be shared.
    case unsuitableFolder(AgentVMError)
    /// The box's supervisor refused the share (another folder is in use there).
    case shareRefused(String)
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
        case .sessionNeedsTerminal:
            return "the session runs on this terminal, and stdin or stdout is not one; from a script use agent-vm exec --box <box> -- <program>"
        case .nothingToOffer:
            return "no boxes to connect to; create one with agent-vm box create <name> --image <image>"
        case let .temporaryNotRunning(box, name):
            return "box \(box) is a temporary box that is not running, so it is not started again; choose another box (\(name) list shows them)"
        case let .unsuitableFolder(error):
            return "\(error); share another folder with --project, or none with --no-project"
        case let .shareRefused(message):
            return message
        case .canceled, .interrupted:
            return ""
        case let .failed(error):
            return "\(error)"
        }
    }

    var status: Int32 {
        switch self {
        case .pickerNeedsTerminal, .sessionNeedsTerminal:
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

    private var boxStore: BoxStore {
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
        let project = try resolveProject(terminal)
        BoxCommand.GC.collect(boxStore)
        let choices = ConnectChoices(store: root)
        let remembered = project.flatMap { choices.choice(for: $0) }

        while true {
            let box: Box
            let status: BoxStatus
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
            if !options.dryRun && !terminal.isInteractive {
                throw ConnectError.sessionNeedsTerminal
            }

            let request = ConnectRequest(target: .box(box.name), launch: options.launch, project: project,
                                         secrets: options.secrets, env: options.env)
            let steps = ConnectPlanner.steps(for: request, facts: ConnectFacts(boxRunning: status.state == .running, ownPid: getpid()))
            if options.dryRun {
                print("\(invokedAs) would:")
                for step in steps {
                    print("  " + step.text)
                }
                return 0
            }
            do {
                return try perform(steps, box: box, request: request, remembered: remembered, terminal: terminal)
            } catch let error as ConnectError where chosenInPicker {
                // A refused share: another box may do; the list again, with the reason above it.
                guard case .shareRefused = error else {
                    throw error
                }
                say(error)
            } catch AgentVMError.boxDisposed(let name) where chosenInPicker {
                BoxCommand.GC.collect(boxStore)
                say(ConnectError.failed(AgentVMError.boxDisposed(name)))
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
                    throw ConnectError.shareRefused(response.error ?? "box \(box.name) did not share \(project)")
                }
            case let .run(arguments):
                if let project = request.project {
                    remember(box: box.name, launch: request.launch, project: project, previous: remembered)
                }
                switch request.launch {
                case .shell:
                    print("Login shell in box \(box.name); exit it to come back here")
                case .command(let words):
                    print("Running \(ConnectPlanner.shellQuoted(words)) in box \(box.name)")
                }
                let outcome: SessionChild.Outcome
                do {
                    outcome = try SessionChild.run(executable: try AskpassEntry.executablePath(), arguments: arguments)
                } catch {
                    throw ConnectError.failed(error)
                }
                return afterSession(outcome, box: box, terminal: terminal)
            }
        }
        return 0
    }

    /// The terminal as it was (SessionChild put its settings back); the kept box's reminder.
    private func afterSession(_ outcome: SessionChild.Outcome, box: Box, terminal: Terminal) -> Int32 {
        if terminal.style.cursorControl {
            // Attributes off, the cursor shown. When the child did not end normally, also the
            // modes a full-screen program may have left on: mouse reports, bracketed paste,
            // kitty keyboard flags. Never "leave the alternate screen": when not in it, some
            // terminals move the cursor.
            var text = "\u{1B}[0m\u{1B}[?25h"
            if outcome.status == ExecRunner.ownFailureStatus || outcome.status >= 128 {
                text += "\u{1B}[?1000l\u{1B}[?1002l\u{1B}[?1003l\u{1B}[?1006l\u{1B}[?2004l\u{1B}[<u"
            }
            terminal.write(text)
        }
        if let signal = outcome.signal {
            // The terminal closed or the session was ended from outside: no one to talk to.
            return 128 + signal
        }
        if box.record.disposable != true {
            print("Box \(box.name) keeps running; stop it with: agent-vm box stop \(box.name)")
        }
        return outcome.status
    }

    /// Right before the session, so one that ends with a closed terminal is remembered too. A
    /// command run leaves the remembered launch as it was.
    private func remember(box: String, launch: ConnectLaunch, project: String, previous: ConnectChoice?) {
        let launchID: String?
        switch launch {
        case .shell:
            launchID = "shell"
        case .command:
            launchID = previous?.launch
        }
        do {
            try ConnectChoices(store: root).remember(ConnectChoice(target: .box, box: box, launch: launchID, readOnly: false), for: project)
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

    private func say(_ error: ConnectError) {
        let text = error.description
        if !text.isEmpty {
            FileHandle.standardError.write(Data("\(invokedAs): \(text)\n".utf8))
        }
    }

    private func warn(_ text: String) {
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
