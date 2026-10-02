// Sources/AgentVMKit/Connect/ConnectPlan.swift
//
// What `agent-vm connect` (avm) does once the choices are made, as data: the steps in order
// (ask about the person's own agent entry before its first run,
// offer to set an agent's secret, ask to allow its hosts, create a new box, start the box,
// check the agent is installed, share the folder, snapshot it, run the session, stop and
// delete a temporary box, report what changed), so
// `--dry-run` prints exactly what a run performs, and tests check the steps without a box. The
// session itself is `agent-vm exec --tty` run as a child; the program goes through the
// account's login shell, so ~/.zprofile applies as it does in `box shell`.

import Foundation

/// The box a session runs in.
public enum ConnectTarget: Equatable, Sendable {
    /// An existing box.
    case box(String)
    /// A new box from the image, owned by connect and deleted when the session ends.
    case newTemporary(image: String)
    /// A new box from the image, kept under this name.
    case newKept(image: String, name: String)
}

/// What runs in the box.
public enum ConnectLaunch: Equatable, Sendable {
    /// The account's login shell.
    case shell
    /// A command and its arguments, through the login shell.
    case command([String])
    /// An agent from the catalog, through the login shell, with its variables and secret.
    case agent(AgentEntry)
}

/// The choices, made on the command line or in the pickers.
public struct ConnectRequest: Equatable, Sendable {
    public var target: ConnectTarget
    public var launch: ConnectLaunch
    /// The canonical folder to share; nil: none (--no-project).
    public var project: String?
    public var readOnly: Bool
    /// Snapshot the folder before the session and report on it afterwards; only for a folder
    /// shared read-write.
    public var snapshot: Bool
    /// The person's --secret specs, passed on to exec.
    public var secrets: [String]
    /// The person's --env specs, passed on to exec.
    public var env: [String]
    /// A new box's rules besides the agent's (--allow).
    public var extraAllow: [String]
    /// A new box's CPUs and memory; nil: the image's.
    public var cpus: Int?
    public var memoryBytes: UInt64?
    /// Update the image's tools before a new box is made from it (--refresh).
    public var refresh: Bool

    public init(target: ConnectTarget, launch: ConnectLaunch, project: String?, readOnly: Bool = false, snapshot: Bool = false,
                secrets: [String] = [], env: [String] = [], extraAllow: [String] = [], cpus: Int? = nil, memoryBytes: UInt64? = nil,
                refresh: Bool = false) {
        self.refresh = refresh
        self.target = target
        self.launch = launch
        self.project = project
        self.readOnly = readOnly
        self.snapshot = snapshot
        self.secrets = secrets
        self.env = env
        self.extraAllow = extraAllow
        self.cpus = cpus
        self.memoryBytes = memoryBytes
    }
}

/// What connect found out before planning.
public struct ConnectFacts: Equatable, Sendable {
    /// The existing box runs and its guest daemon answers.
    public var boxRunning: Bool
    /// The box's rules when its network is in allowlist mode; nil in any other mode.
    public var boxRules: [String]?
    /// Secret names in the Keychain.
    public var setSecrets: [String]
    /// False when the Keychain could not be listed: nothing is offered, and no secret is passed
    /// for an agent.
    public var secretsListed: Bool
    /// The commands a probe found before the launch picker; nil when none ran.
    public var probed: Set<String>?
    /// connect's own process id.
    public var ownPid: Int32
    /// The name for a new temporary box (temporaryName, chosen free).
    public var temporaryName: String?
    /// False for one of the person's own agent entries they have not agreed to run yet, as the
    /// file is now.
    public var agentAgreed: Bool

    public init(boxRunning: Bool, boxRules: [String]? = nil, setSecrets: [String] = [], secretsListed: Bool = true,
                probed: Set<String>? = nil, ownPid: Int32, temporaryName: String? = nil, agentAgreed: Bool = true) {
        self.boxRunning = boxRunning
        self.boxRules = boxRules
        self.setSecrets = setSecrets
        self.secretsListed = secretsListed
        self.probed = probed
        self.ownPid = ownPid
        self.temporaryName = temporaryName
        self.agentAgreed = agentAgreed
    }
}

public enum ConnectStep: Equatable, Sendable {
    /// One of the person's own agent entries, not agreed to yet: show what it runs, the hosts
    /// it allows and the secrets it is handed, and ask. No ends the run.
    case askAgent(id: String, path: String)
    /// None of the agent's secrets is set: offer to set one (in the Keychain) or go on without.
    case offerSecret(agent: String, secrets: [String])
    /// The box's allowlist lacks rules the agent needs: ask to add them.
    case askRules(box: String, rules: [String])
    /// Create the box from the image, with these rules; a temporary one is deleted after the
    /// session.
    case create(box: String, image: String, allow: [String], temporary: Bool, cpus: Int?, memoryBytes: UInt64?)
    /// Start the box (a box that is starting or stopping is waited for); `ownerPid` stops it
    /// when that process exits.
    case start(box: String, ownerPid: Int32?)
    /// Check that the agent's command is installed in the box.
    case probe(box: String, command: String)
    /// Share the folder into the running box.
    case share(box: String, project: String, readOnly: Bool)
    /// Snapshot the folder (a session in the store), so what the session changes can be undone.
    case snapshot(project: String)
    /// Run the session: agent-vm with these arguments, on this terminal.
    case run(arguments: [String])
    /// Stop the temporary box connect created, and delete it.
    case stopAndDelete(box: String)
    /// Report what changed in the folder since the snapshot, then keep it or undo it.
    case report(project: String)

    /// The tools update of an image a new box is about to be made from, when asked for.
    case refresh(image: String)

    /// A question asked before the other steps (they are planned again with its answer).
    public var isQuestion: Bool {
        switch self {
        case .askAgent, .offerSecret, .askRules:
            return true
        default:
            return false
        }
    }

    /// The step for a person (the lines of --dry-run).
    public var text: String {
        switch self {
        case let .askAgent(id, path):
            return "ask whether to run your own agent \(id) (\(path)), not agreed to yet: its command, hosts and secrets are shown first"
        case let .offerSecret(_, secrets):
            return "offer to set one of: \(secrets.joined(separator: ", "))"
        case let .askRules(box, rules):
            return "ask to allow \(rules.joined(separator: ", ")) in box \(box)"
        case let .create(box, image, allow, temporary, cpus, memoryBytes):
            var text = "create box \(box) from image \(image)" + (temporary ? " (temporary)" : "")
            if let cpus {
                text += ", \(cpus) CPUs"
            }
            if let memoryBytes {
                text += ", \(memoryBytes >> 30) GB"
            }
            if !allow.isEmpty {
                text += ", allowing " + allow.joined(separator: ", ")
            }
            return text
        case let .refresh(image):
            return "update the tools of image \(image): agent-vm image update \(image) --tools"
        case let .stopAndDelete(box):
            return "stop and delete box \(box)"
        case let .probe(_, command):
            return "check that \(command) is installed in the box"
        case let .start(box, ownerPid):
            if let ownerPid {
                return "start box \(box), stopping it when process \(ownerPid) exits"
            }
            return "start box \(box)"
        case let .share(_, project, readOnly):
            return "share \(project) (\(readOnly ? "read only" : "read-write"))"
        case let .snapshot(project):
            return "snapshot \(project)"
        case let .run(arguments):
            return "run: agent-vm \(ConnectPlanner.shellQuoted(arguments))"
        case let .report(project):
            return "report what changed in \(project), then keep or undo it"
        }
    }
}

public enum ConnectPlanner {
    /// A command run through the account's login shell: `$0` and `$@` reach exec untouched,
    /// whatever quotes or spaces they hold. The guest daemon sets SHELL from the account.
    public static let loginWrapper = ["/bin/sh", "-c", "exec \"$SHELL\" -l -c 'exec \"$0\" \"$@\"' \"$@\"", "sh"]

    /// The steps for `request`, in order.
    public static func steps(for request: ConnectRequest, facts: ConnectFacts) -> [ConnectStep] {
        let name: String
        var image: String?
        var temporary = false
        switch request.target {
        case .box(let box):
            name = box
        case .newTemporary(let from):
            name = facts.temporaryName ?? temporaryName(image: from, random: 0)
            image = from
            temporary = true
        case let .newKept(from, box):
            name = box
            image = from
        }
        var steps: [ConnectStep] = []
        var secrets = request.secrets
        var env = request.env
        var allow = request.extraAllow
        if case .agent(let agent) = request.launch {
            // The variables the person's --env and --secret set (NAME or NAME=...).
            func variable(_ spec: String) -> Substring {
                return spec.prefix { $0 != "=" }
            }
            // Before anything of the entry's is used: the next questions are already its own.
            if agent.source == .user && !facts.agentAgreed {
                steps.append(.askAgent(id: agent.id, path: agent.path))
            }
            let personal = Set((request.env + request.secrets).map(variable))
            let secret = facts.secretsListed ? AgentCatalog.secretArguments(for: agent, set: facts.setSecrets) : []
            let givenByPerson = agent.secrets.contains { personal.contains(Substring($0.env)) }
            if agent.secretsNeeded == .one && facts.secretsListed && secret.isEmpty && !givenByPerson {
                steps.append(.offerSecret(agent: agent.name, secrets: agent.secrets.map(\.name)))
            }
            // A new box gets the agent's rules when it is created; an existing one is asked.
            if image == nil, let rules = facts.boxRules {
                let missing = AgentCatalog.missingRules(for: agent, in: rules)
                if !missing.isEmpty {
                    steps.append(.askRules(box: name, rules: missing))
                }
            }
            allow = agent.allow + allow.filter { !agent.allow.contains($0) }
            // The agent's own first, so the person's --env or --secret for the same variable
            // comes later and wins. exec puts every --secret over every --env, so the agent's
            // secret is left out when the person's option sets its variable.
            secrets = secret.filter { !personal.contains(variable($0)) } + secrets
            env = AgentCatalog.envArguments(for: agent) + env
        }
        if let image {
            if request.refresh {
                steps.append(.refresh(image: image))
            }
            steps.append(.create(box: name, image: image, allow: allow, temporary: temporary, cpus: request.cpus,
                                 memoryBytes: request.memoryBytes))
            // Only a temporary box connect made gets connect as its owner: it stops when this
            // connect exits, however it exits.
            steps.append(.start(box: name, ownerPid: temporary ? facts.ownPid : nil))
        } else if !facts.boxRunning {
            // An existing box is never given connect as its owner: another client using it
            // would lose it when this connect exits.
            steps.append(.start(box: name, ownerPid: nil))
        }
        if case .agent(let agent) = request.launch, image != nil || facts.probed == nil, let command = agent.command.first {
            steps.append(.probe(box: name, command: command))
        }
        // A folder shared read only cannot change, so it gets no snapshot.
        let snapshot = request.snapshot && !request.readOnly ? request.project : nil
        if let project = request.project {
            steps.append(.share(box: name, project: project, readOnly: request.readOnly))
        }
        if let snapshot {
            steps.append(.snapshot(project: snapshot))
        }
        steps.append(.run(arguments: childArguments(box: name, project: request.project, readOnly: request.readOnly,
                                                    secrets: secrets, env: env, argv: launchArgv(request.launch))))
        // Stopped before the report: nothing in the box can change the folder during an undo,
        // and the report is final.
        if temporary {
            steps.append(.stopAndDelete(box: name))
        }
        if let snapshot {
            steps.append(.report(project: snapshot))
        }
        return steps
    }

    /// A temporary box's name: "avm-", the image's name cut so the whole fits 63 characters,
    /// "-", and six hex digits of `random`.
    public static func temporaryName(image: String, random: UInt32) -> String {
        return "avm-" + String(image.prefix(52)) + "-" + String(format: "%06x", random & 0xFF_FFFF)
    }

    /// A name to suggest for a kept box: the folder's last component in the box-name alphabet
    /// (lower case; every run of other characters one "-"; no "-", "." or "_" at either end; at
    /// most 59 characters, leaving room for a suffix), else the image's name plus "-box"; then
    /// "-2", "-3" and so on while `existing` has it.
    public static func suggestedBoxName(project: String?, image: String, existing: Set<String>) -> String {
        var base = ""
        if let project {
            var previousDash = false
            for character in (project as NSString).lastPathComponent.lowercased() {
                if character.isASCII && (character.isLetter || character.isNumber || "._-".contains(character)) {
                    base.append(character)
                    previousDash = false
                } else if !previousDash {
                    base.append("-")
                    previousDash = true
                }
            }
            base = String(base.drop { "-._".contains($0) }.reversed().drop { "-._".contains($0) }.reversed())
            base = String(base.prefix(59))
            base = String(base.reversed().drop { "-._".contains($0) }.reversed())
        }
        if base.isEmpty {
            base = String(image.prefix(59 - 4)) + "-box"
        }
        var name = base
        var suffix = 2
        while existing.contains(name) {
            name = "\(base)-\(suffix)"
            suffix += 1
        }
        return name
    }

    /// agent-vm's arguments for the session child.
    public static func childArguments(box: String, project: String?, readOnly: Bool, secrets: [String], env: [String],
                                      argv: [String]) -> [String] {
        var arguments = ["exec", "--tty", "--box", box]
        if let project {
            arguments += ["--project", project]
            if readOnly {
                arguments.append("--read-only")
            }
        }
        for secret in secrets {
            arguments += ["--secret", secret]
        }
        for entry in env {
            arguments += ["--env", entry]
        }
        return arguments + ["--"] + argv
    }

    /// The program run in the box: the login shell, exactly as `box shell` runs it, or a
    /// command through it.
    public static func launchArgv(_ launch: ConnectLaunch) -> [String] {
        switch launch {
        case .shell:
            return ["/bin/sh", "-c", "exec \"$SHELL\" -l"]
        case .command(let words):
            return loginWrapper + words
        case .agent(let agent):
            guard let setup = agent.setup else {
                return loginWrapper + agent.command
            }
            // The setup, then the agent in its place: $0 and $@ are the agent's words.
            return loginWrapper + ["/bin/sh", "-c", setup + "\nexec \"$0\" \"$@\""] + agent.command
        }
    }

    /// Words as a shell would take them back: anything but letters, digits and @%+=:,./_-
    /// single-quoted.
    public static func shellQuoted(_ words: [String]) -> String {
        let plain = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789@%+=:,./_-")
        return words.map { word in
            if !word.isEmpty && word.allSatisfy({ plain.contains($0) }) {
                return word
            }
            return "'" + word.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }.joined(separator: " ")
    }
}
