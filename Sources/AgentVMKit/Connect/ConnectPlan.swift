// Sources/AgentVMKit/Connect/ConnectPlan.swift
//
// What `agent-vm connect` (avm) does once the choices are made, as data: the steps in order
// (start the box, share the folder, run the session), so `--dry-run` prints exactly what a run
// performs, and tests check the steps without a box. The session itself is `agent-vm exec --tty`
// run as a child; the program goes through the account's login shell, so ~/.zprofile applies as
// it does in `box shell`.

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
}

/// The choices, made on the command line or in the pickers.
public struct ConnectRequest: Equatable, Sendable {
    public var target: ConnectTarget
    public var launch: ConnectLaunch
    /// The canonical folder to share; nil: none (--no-project).
    public var project: String?
    public var readOnly: Bool
    /// The person's --secret specs, passed on to exec.
    public var secrets: [String]
    /// The person's --env specs, passed on to exec.
    public var env: [String]

    public init(target: ConnectTarget, launch: ConnectLaunch, project: String?, readOnly: Bool = false,
                secrets: [String] = [], env: [String] = []) {
        self.target = target
        self.launch = launch
        self.project = project
        self.readOnly = readOnly
        self.secrets = secrets
        self.env = env
    }
}

/// What connect found out before planning.
public struct ConnectFacts: Equatable, Sendable {
    /// The existing box runs and its guest daemon answers.
    public var boxRunning: Bool
    /// connect's own process id.
    public var ownPid: Int32

    public init(boxRunning: Bool, ownPid: Int32) {
        self.boxRunning = boxRunning
        self.ownPid = ownPid
    }
}

public enum ConnectStep: Equatable, Sendable {
    /// Start the box (a box that is starting or stopping is waited for); `ownerPid` stops it
    /// when that process exits.
    case start(box: String, ownerPid: Int32?)
    /// Share the folder into the running box.
    case share(box: String, project: String, readOnly: Bool)
    /// Run the session: agent-vm with these arguments, on this terminal.
    case run(arguments: [String])

    /// The step for a person (the lines of --dry-run).
    public var text: String {
        switch self {
        case let .start(box, ownerPid):
            if let ownerPid {
                return "start box \(box), stopping it when process \(ownerPid) exits"
            }
            return "start box \(box)"
        case let .share(_, project, readOnly):
            return "share \(project) (\(readOnly ? "read only" : "read-write"))"
        case let .run(arguments):
            return "run: agent-vm \(ConnectPlanner.shellQuoted(arguments))"
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
            if !facts.boxRunning {
                // An existing box is never given connect as its owner: another client using it
                // would lose it when this connect exits.
                steps.append(.start(box: name, ownerPid: nil))
            }
            if let project = request.project {
                steps.append(.share(box: name, project: project, readOnly: request.readOnly))
            }
            steps.append(.run(arguments: childArguments(box: name, project: request.project, readOnly: request.readOnly,
                                                        secrets: request.secrets, env: request.env, argv: launchArgv(request.launch))))
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
