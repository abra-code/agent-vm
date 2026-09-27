// Sources/agent-vm/ConnectAgents.swift
//
// connect's agents: what to run (the launch picker, or what the command line says), what is
// known before planning (the box's rules, the secrets in the Keychain, which agents a running
// box has), the questions asked before anything starts (set a missing secret now, allow the
// agent's hosts in the box), and `connect agents`, the catalog with each secret's state. A
// secret typed here goes from the terminal to the Keychain as bytes, never into an argument, a
// file or the output; the session's exec reads it from the Keychain itself (--secret).

import AgentVMKit
import Darwin
import Foundation
import TerminalUI

extension ConnectRunner {
    /// The row id of "Go on without" in the secret offer; no secret can be named so.
    private static let withoutSecret = " without"

    // MARK: - What to run

    /// What the command line says to run, else the launch picker's choice (true: chosen in the
    /// picker). The picker is skipped when the catalog has no agent. For a running box the
    /// agents it lacks are found first (`probed`, kept between rounds) and cannot be chosen; a
    /// dry run asks nothing of the box.
    func chooseLaunch(box: Box, running: Bool, catalog: AgentCatalog, namedAgent: AgentEntry?, remembered: String?,
                      probed: inout Set<String>?, terminal: Terminal) throws -> (ConnectLaunch, Bool) {
        if let launch = options.namedLaunch {
            return (launch, false)
        }
        if let namedAgent {
            return (.agent(namedAgent), false)
        }
        if catalog.entries.isEmpty {
            return (.shell, false)
        }
        guard terminal.isInteractive else {
            throw ConnectError.launchNeedsTerminal
        }
        if probed == nil && running && !options.dryRun {
            var commands: [String] = []
            for agent in catalog.entries where !commands.contains(agent.command[0]) {
                commands.append(agent.command[0])
            }
            probed = AgentProbe.run(box: box, commands: commands)
        }
        let setSecrets = try? SecretStore().list().map(\.name)
        let (sections, selected) = ConnectPickers.launchSections(catalog.entries, setSecrets: setSecrets, installed: probed,
                                                                 remembered: remembered)
        let kind = box.record.disposable == true ? "temporary" : "kept"
        let id = try Picker(title: "Run in box \(box.name) (\(kind))", sections: sections, selected: selected).run(on: terminal)
        guard id != AgentCatalog.shellID, let agent = catalog.entry(id: id) else {
            print("Login shell")
            return (.shell, true)
        }
        print(agent.name)
        return (.agent(agent), true)
    }

    /// What the planner needs to know about an agent's box and secrets, and the Keychain's
    /// entries (whether each is readable without macOS asking).
    func facts(for launch: ConnectLaunch, box: Box, running: Bool, probed: Set<String>?) throws -> (ConnectFacts, [SecretStore.Entry]) {
        var facts = ConnectFacts(boxRunning: running, ownPid: getpid())
        guard case .agent(let agent) = launch else {
            return (facts, [])
        }
        // The record again: an earlier round may have changed its rules.
        let network = try boxStore.box(named: box.name).record.effectiveNetwork
        switch network.mode {
        case .allowlist:
            facts.boxRules = network.allow
        case .off where !agent.allow.isEmpty:
            warn("box \(box.name)'s network is off, so \(agent.name) cannot reach \(agent.allow.joined(separator: ", ")); agent-vm box network \(box.name) --net allowlist --allow <rule> opens it")
        default:
            break
        }
        var entries: [SecretStore.Entry] = []
        if !agent.secrets.isEmpty {
            do {
                entries = try SecretStore().list()
                facts.setSecrets = entries.map(\.name)
            } catch {
                warn("cannot list the secrets in the Keychain (\(error)); \(agent.name) gets none of its own, only those given with --secret")
                facts.secretsListed = false
            }
        }
        facts.probed = probed
        return (facts, entries)
    }

    // MARK: - Questions before the steps

    /// Asks the questions among `steps` (a secret to set, rules to allow), and whether a secret
    /// another build stored should be stored again; the facts as the answers changed them.
    func ask(_ steps: [ConnectStep], launch: ConnectLaunch, facts: ConnectFacts, secretEntries: [SecretStore.Entry], box: Box,
             terminal: Terminal) throws -> ConnectFacts {
        guard case .agent(let agent) = launch else {
            return facts
        }
        var answered = facts
        var stored: Set<String> = []
        for step in steps {
            switch step {
            case .offerSecret:
                if let name = try offerSecret(agent, terminal: terminal) {
                    answered.setSecrets.append(name)
                    stored.insert(name)
                }
            case let .askRules(_, rules):
                if try askRules(rules, agent: agent, box: box, terminal: terminal) {
                    answered.boxRules = nil
                }
            default:
                break
            }
        }
        // The secret that will be passed, when another build of agent-vm stored it: macOS asks
        // on this Mac's screen before exec reads it, which nobody sees over SSH.
        if answered.secretsListed, let secret = agent.secrets.first(where: { answered.setSecrets.contains($0.name) }),
           !stored.contains(secret.name), secretEntries.first(where: { $0.name == secret.name })?.readable == false {
            print("\(secret.name) was stored by another build of agent-vm, so macOS will ask on this Mac's screen before this one reads it (choose Always Allow).")
            if try Confirm("Store it again now instead?", defaultAnswer: false).run(on: terminal) {
                _ = try storeSecret(secret.name, terminal: terminal)
            }
        }
        return answered
    }

    /// The offer when none of the agent's secrets is set: set one now, or go on without. The
    /// name stored, or nil.
    private func offerSecret(_ agent: AgentEntry, terminal: Terminal) throws -> String? {
        var rows = agent.secrets.map { PickerRow(id: $0.name, columns: ["Set \($0.name) now"], note: $0.label) }
        rows.append(PickerRow(id: Self.withoutSecret, columns: ["Go on without"], note: agent.login == nil ? nil : "log in inside the box"))
        let picker = Picker(title: "\(agent.name) signs in with one of these; none is set yet",
                            sections: [PickerSection(title: nil, rows: rows)], selected: nil)
        while true {
            let id = try picker.run(on: terminal)
            guard id != Self.withoutSecret else {
                if let login = agent.login {
                    print(login)
                }
                return nil
            }
            if try storeSecret(id, terminal: terminal) {
                return id
            }
        }
    }

    /// Reads a value without echo and stores it as secret `name`; asks again after a value the
    /// Keychain refuses. False when the person pressed Escape (back to the offer).
    private func storeSecret(_ name: String, terminal: Terminal) throws -> Bool {
        let store = SecretStore()
        while true {
            var bytes: [UInt8]
            do {
                bytes = try LineInput.secret(prompt: "Value of \(name): ", maxBytes: SecretStore.maxValueBytes, on: terminal)
            } catch TerminalUIError.canceled {
                return false
            }
            let result: Result<Void, Error> = bytes.withUnsafeMutableBytes { raw in
                // No copy of the value: the Data points into the buffer zeroed below.
                let value = raw.baseAddress.map { Data(bytesNoCopy: $0, count: raw.count, deallocator: .none) } ?? Data()
                return Result { try store.set(name, value: value) }
            }
            bytes.withUnsafeMutableBytes { raw in
                if let base = raw.baseAddress {
                    _ = memset_s(base, raw.count, 0, raw.count)
                }
            }
            switch result {
            case .success:
                print("Stored secret \(name) in the Keychain")
                return true
            case .failure(let error):
                print("\(error)")
            }
        }
    }

    /// Asks to add `rules` to the box's allowlist; true when they were added.
    private func askRules(_ rules: [String], agent: AgentEntry, box: Box, terminal: Terminal) throws -> Bool {
        print("\(agent.name) needs \(rules.joined(separator: ", ")), which box \(box.name) does not allow.")
        guard try Confirm(rules.count == 1 ? "Allow it?" : "Allow them?", defaultAnswer: true).run(on: terminal) else {
            print("Not allowed: its connections will be refused (agent-vm box netlog \(box.name) --denied lists them)")
            return false
        }
        var network = try boxStore.box(named: box.name).record.effectiveNetwork
        for rule in rules where !network.allow.contains(rule) {
            network.allow.append(rule)
        }
        let updated = try boxStore.updateNetwork(named: box.name, to: network)
        if updated.isRunning {
            let response = try ControlClient.request(.reload, path: updated.controlSocketPath)
            guard response.ok else {
                throw AgentVMError.supervisorRefused(response.error ?? "the supervisor did not reload the rules")
            }
        }
        print("Box \(box.name) now allows \(rules.joined(separator: ", "))")
        return true
    }

    /// Before a launch picker: what is wrong with the catalog, once.
    func warnAbout(_ catalog: AgentCatalog) {
        if let problem = catalog.builtInProblem {
            warn("\(AgentCatalog.fileName) next to agent-vm cannot be used (\(problem.path): \(problem.reason)); Scripts/build.sh puts it there. Only your own agents, a login shell and commands are offered.")
        }
        if let problem = catalog.userFolderProblem {
            warn("\(problem.path): \(problem.reason)")
        }
        for (id, problem) in catalog.problems.sorted(by: { $0.key < $1.key }) {
            warn("agent \(id) cannot be used: \(problem.path): \(problem.reason)")
        }
    }

    // MARK: - connect agents

    /// The catalog, each agent's secrets with their state (set, asks: stored by another build,
    /// missing), and the user files that cannot be used. Fails (after the list) when the
    /// built-in file or the user folder cannot be used.
    func agents(json: Bool) throws {
        let catalog = AgentCatalog.load(store: root)
        var entries: [SecretStore.Entry]?
        do {
            entries = try SecretStore().list()
        } catch {
            warn("cannot list the secrets in the Keychain (\(error)); their state is unknown")
        }
        func state(_ secret: AgentEntry.Secret) -> String {
            guard let entries else {
                return "unknown"
            }
            guard let entry = entries.first(where: { $0.name == secret.name }) else {
                return "missing"
            }
            return entry.readable ? "set" : "asks"
        }
        if json {
            var list = catalog.entries.map { agent in
                AgentJSON(agent, secrets: agent.secrets.map { AgentJSON.SecretJSON($0, state: state($0)) })
            }
            for (id, problem) in catalog.problems.sorted(by: { $0.key < $1.key }) {
                list.append(AgentJSON(problem: problem, id: id))
            }
            try Output.json(list)
        } else {
            for agent in catalog.entries {
                var source = agent.source == .builtIn ? "built-in" : "yours, \(agent.path)"
                if agent.replacesBuiltIn {
                    source += ", replaces the built-in one"
                }
                print("\(agent.id)  \(agent.name)  (\(source))")
                var runs = "    runs: \(ConnectPlanner.shellQuoted(agent.command))"
                if !agent.allow.isEmpty {
                    runs += "    allows: \(agent.allow.joined(separator: ", "))"
                }
                print(runs)
                if !agent.secrets.isEmpty {
                    let which = agent.secretsNeeded == .one ? "one of" : "optional"
                    print("    secrets (\(which)): " + agent.secrets.map { "\($0.name) \(state($0))" }.joined(separator: "; "))
                }
                if let login = agent.login {
                    print("    \(login)")
                }
                if let note = agent.note {
                    print("    \(note)")
                }
            }
            for (id, problem) in catalog.problems.sorted(by: { $0.key < $1.key }) {
                print("\(id)  (yours, \(problem.path))")
                print("    cannot be used: \(problem.reason)")
            }
        }
        if let problem = catalog.builtInProblem {
            throw AgentVMError.invalidAgents(path: problem.path, reason: problem.reason)
        }
        if let problem = catalog.userFolderProblem {
            throw AgentVMError.invalidAgents(path: problem.path, reason: problem.reason)
        }
    }
}

/// One agent in `connect agents --json`, or a user file that cannot be used (then only `id`,
/// `source`, `path` and `problem`).
struct AgentJSON: Encodable {
    struct SecretJSON: Encodable {
        var env: String
        var secret: String?
        var label: String
        var state: String

        init(_ secret: AgentEntry.Secret, state: String) {
            env = secret.env
            self.secret = secret.secret
            label = secret.label
            self.state = state
        }
    }

    var id: String
    var name: String?
    var command: [String]?
    var allow: [String]?
    var secrets: [SecretJSON]?
    var secretsNeeded: String?
    var env: [String: String]?
    var login: String?
    var install: String?
    var note: String?
    var source: String
    var path: String
    var replacesBuiltIn: Bool?
    var problem: String?

    init(_ agent: AgentEntry, secrets: [SecretJSON]) {
        id = agent.id
        name = agent.name
        command = agent.command
        allow = agent.allow
        self.secrets = secrets
        secretsNeeded = agent.secretsNeeded.rawValue
        env = agent.env
        login = agent.login
        install = agent.install
        note = agent.note
        source = agent.source.rawValue
        path = agent.path
        replacesBuiltIn = agent.replacesBuiltIn ? true : nil
    }

    init(problem: AgentCatalog.Problem, id: String) {
        self.id = id
        source = AgentEntry.Source.user.rawValue
        path = problem.path
        self.problem = problem.reason
    }
}
