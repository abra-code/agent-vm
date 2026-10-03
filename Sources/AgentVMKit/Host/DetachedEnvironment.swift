// Sources/AgentVMKit/Host/DetachedEnvironment.swift
//
// The environment of the processes agent-vm leaves running after the command that started
// them: a box's supervisor (days) and a job's runner (up to an hour). They used to inherit all
// of the caller's, so an API key exported in the shell that ran `box start` or `avm` stayed in
// a process for as long as the box ran, readable by whatever can read a process's environment.
// Neither needs it: what a program in a box is given comes from `exec`, each time. So they get
// what a program started at login would have, and agent-vm's own settings.

import Foundation

public enum DetachedEnvironment {
    /// What is passed on by name: who and where the user is, how text is encoded, and what
    /// macOS sets for every process of a login session.
    static let names: Set<String> = [
        "HOME", "USER", "LOGNAME", "SHELL", "PATH", "TMPDIR", "LANG", "TZ",
        "__CF_USER_TEXT_ENCODING", "__CFBundleIdentifier", "XPC_FLAGS", "XPC_SERVICE_NAME",
    ]

    /// And by prefix: agent-vm's own settings (the store, the files tests point it at), and the
    /// locale's parts.
    static let prefixes = ["AGENT_VM_", "LC_"]

    /// agent-vm's own names that are not settings: they tell an agent-vm that ssh started it
    /// to answer a password prompt, and are set for that one child only.
    static let dropped: Set<String> = [GuestSSH.askpassItemVariable, GuestSSH.askpassFileVariable]

    /// `environment` without what a detached process has no use for.
    public static func filtered(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        return environment.filter { name, _ in
            !dropped.contains(name) && (names.contains(name) || prefixes.contains { name.hasPrefix($0) })
        }
    }

    /// The same as `NAME=VALUE` strings, sorted, for posix_spawn.
    public static func list(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> [String] {
        return filtered(environment).sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
    }
}
