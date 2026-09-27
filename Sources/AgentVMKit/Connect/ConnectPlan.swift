// Sources/AgentVMKit/Connect/ConnectPlan.swift
//
// What `agent-vm connect` (avm) does once the choices are made, as data: the steps in order
// (offer to set an agent's secret, ask to allow its hosts, start the box, check the agent is
// installed, share the folder, snapshot it, run the session, report what changed), so
// `--dry-run` prints exactly what a run performs, and tests check the steps without a box. The
// session itself is `agent-vm exec --tty` run as a child; the program goes through the
// account's login shell, so ~/.zprofile applies as it does in `box shell`.

import Foundation

/// The box a session runs in.
public enum ConnectTarget: Equatable, Sendable {
    /// An existing box.
    case box(String)
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

    public init(target: ConnectTarget, launch: ConnectLaunch, project: String?, readOnly: Bool = false, snapshot: Bool = false,
                secrets: [String] = [], env: [String] = []) {
        self.target = target
        self.launch = launch
        self.project = project
        self.readOnly = readOnly
        self.snapshot = snapshot
        self.secrets = secrets
        self.env = env
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

    public init(boxRunning: Bool, boxRules: [String]? = nil, setSecrets: [String] = [], secretsListed: Bool = true,
                probed: Set<String>? = nil, ownPid: Int32) {
        self.boxRunning = boxRunning
        self.boxRules = boxRules
        self.setSecrets = setSecrets
        self.secretsListed = secretsListed
        self.probed = probed
        self.ownPid = ownPid
    }
}

public enum ConnectStep: Equatable, Sendable {
    /// None of the agent's secrets is set: offer to set one (in the Keychain) or go on without.
    case offerSecret(agent: String, secrets: [String])
    /// The box's allowlist lacks rules the agent needs: ask to add them.
    case askRules(box: String, rules: [String])
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
    /// Report what changed in the folder since the snapshot, then keep it or undo it.
    case report(project: String)

    /// A question asked before the other steps (they are planned again with its answer).
    public var isQuestion: Bool {
        switch self {
        case .offerSecret, .askRules:
            return true
        default:
            return false
        }
    }

    /// The step for a person (the lines of --dry-run).
    public var text: String {
        switch self {
        case let .offerSecret(_, secrets):
            return "offer to set one of: \(secrets.joined(separator: ", "))"
        case let .askRules(box, rules):
            return "ask to allow \(rules.joined(separator: ", ")) in box \(box)"
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
        switch request.target {
        case .box(let name):
            var steps: [ConnectStep] = []
            var secrets = request.secrets
            var env = request.env
            if case .agent(let agent) = request.launch {
                // The variables the person's --env and --secret set (NAME or NAME=...).
                func variable(_ spec: String) -> Substring {
                    return spec.prefix { $0 != "=" }
                }
                let personal = Set((request.env + request.secrets).map(variable))
                let secret = facts.secretsListed ? AgentCatalog.secretArguments(for: agent, set: facts.setSecrets) : []
                let givenByPerson = agent.secrets.contains { personal.contains(Substring($0.env)) }
                if agent.secretsNeeded == .one && facts.secretsListed && secret.isEmpty && !givenByPerson {
                    steps.append(.offerSecret(agent: agent.name, secrets: agent.secrets.map(\.name)))
                }
                if let rules = facts.boxRules {
                    let missing = AgentCatalog.missingRules(for: agent, in: rules)
                    if !missing.isEmpty {
                        steps.append(.askRules(box: name, rules: missing))
                    }
                }
                // The agent's own first, so the person's --env or --secret for the same variable
                // comes later and wins. exec puts every --secret over every --env, so the agent's
                // secret is left out when the person's option sets its variable.
                secrets = secret.filter { !personal.contains(variable($0)) } + secrets
                env = AgentCatalog.envArguments(for: agent) + env
            }
            if !facts.boxRunning {
                // An existing box is never given connect as its owner: another client using it
                // would lose it when this connect exits.
                steps.append(.start(box: name, ownerPid: nil))
            }
            if case .agent(let agent) = request.launch, facts.probed == nil, let command = agent.command.first {
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
            if let snapshot {
                steps.append(.report(project: snapshot))
            }
            return steps
        }
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
            return loginWrapper + agent.command
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
