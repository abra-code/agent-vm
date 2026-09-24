// Sources/AgentVMKit/AgentVMError.swift
//
// Every failure the library reports. Messages are written for the person at the terminal:
// they say what was refused or what failed, and what to do about it where there is an answer.

import Darwin

public enum AgentVMError: Error, Equatable, CustomStringConvertible {
    /// A system call failed; `operation` names what was being attempted.
    case system(operation: String, code: Int32)
    /// The project path is not usable for a session (missing, not a folder, or too broad).
    case unsuitableProject(path: String, reason: String)
    /// The project and the session store are on different volumes, so an instant snapshot is impossible.
    case differentVolume(project: String, store: String)
    /// Another session on the same project is still active.
    case sessionAlreadyActive(project: String, id: String)
    /// A session id that does not have the form this tool generates.
    case invalidSessionID(String)
    case sessionNotFound(String)
    /// The requested operation does not apply to a session in this state.
    case wrongSessionState(id: String, state: String, operation: String)
    /// The project folder changed identity since the session started (moved to another volume, or gone).
    case projectMissing(path: String)
    /// A session record on disk could not be read or written.
    case corruptSessionRecord(path: String, reason: String)
    /// An image name that is not lower-case letters, digits, ".", "_" or "-".
    case invalidImageName(String)
    case imageExists(name: String, state: String)
    case imageNotFound(String)
    /// Another agent-vm process holds the image's lock (it is being built or used).
    case imageBusy(String)
    /// The operation needs the image in another state.
    case wrongImageState(name: String, state: String, operation: String)
    /// An image record on disk could not be read or written.
    case corruptImageRecord(path: String, reason: String)
    /// A guest account name macOS would not accept, or one it reserves.
    case invalidUserName(String)
    /// This Mac or this binary cannot do what was asked (entitlement, free space).
    case hostNotReady(String)
    /// An image recipe that cannot be used as it is.
    case invalidRecipe(path: String, reason: String)
    /// A network rule that is not a host, wildcard, host:port or known pack.
    case invalidNetworkRule(String, reason: String)
    case boxExists(String)
    case boxNotFound(String)
    /// The box's supervisor runs; stop the box first.
    case boxRunning(String)
    case boxNotRunning(String)
    /// Virtualization refused or failed an operation; `message` is its explanation.
    case virtualMachine(operation: String, message: String)
    /// The guest did not become reachable, or stopped answering.
    case guestUnreachable(String)
    /// The guest daemon turned a request down (unknown account, program not found, ...).
    case guestRefused(String)
    /// The box's supervisor turned a control request down; the message is complete as is.
    case supervisorRefused(String)
    /// A command run in the guest failed.
    case guestCommandFailed(command: String, status: Int32, output: String)

    public var description: String {
        switch self {
        case let .system(operation, code):
            return "\(operation) failed: \(String(cString: strerror(code))) (errno \(code))"
        case let .unsuitableProject(path, reason):
            return "cannot use \(path) as a project: \(reason)"
        case let .differentVolume(project, store):
            return "\(project) is on a different volume than the session store \(store); an instant snapshot needs both on the same APFS volume. Set AGENT_VM_HOME to a folder on the project's volume."
        case let .sessionAlreadyActive(project, id):
            return "session \(id) is still active for \(project); end it with `agent-vm session end \(id)` or discard it first"
        case let .invalidSessionID(id):
            return "\(id) is not a session id (expected the form YYYYMMDD-HHMMSS-xxxx)"
        case let .sessionNotFound(id):
            return "no session \(id); `agent-vm session list` shows the existing ones"
        case let .wrongSessionState(id, state, operation):
            return "cannot \(operation) session \(id): it is \(state)"
        case let .projectMissing(path):
            return "the project folder \(path) is missing or was moved to another volume since the session started"
        case let .corruptSessionRecord(path, reason):
            return "session record \(path) is unusable: \(reason)"
        case let .invalidImageName(name):
            return "\(name) is not a usable image name (lower-case letters, digits, \".\", \"_\" and \"-\", starting with a letter or digit, at most 63)"
        case let .imageExists(name, state):
            return "image \(name) already exists (\(state)); delete it first with `agent-vm image delete \(name)`"
        case let .imageNotFound(name):
            return "no image \(name); `agent-vm image list` shows the existing ones"
        case let .imageBusy(name):
            return "image \(name) is in use by another agent-vm process"
        case let .wrongImageState(name, state, operation):
            return "cannot \(operation) image \(name): it is \(state)"
        case let .corruptImageRecord(path, reason):
            return "image record \(path) is unusable: \(reason)"
        case let .invalidUserName(name):
            return "\(name) is not a usable account name (lower-case letters, digits and \"_\", starting with a letter; not a name macOS reserves)"
        case let .hostNotReady(reason):
            return "cannot build here: \(reason)"
        case let .invalidRecipe(path, reason):
            return "recipe \(path): \(reason)"
        case let .invalidNetworkRule(rule, reason):
            return "\(rule) is not a usable network rule: \(reason)"
        case let .boxExists(name):
            return "box \(name) already exists; delete it first with `agent-vm box delete \(name)`"
        case let .boxNotFound(name):
            return "no box \(name); `agent-vm box list` shows the existing ones"
        case let .boxRunning(name):
            return "box \(name) is running; stop it first with `agent-vm box stop \(name)`"
        case let .boxNotRunning(name):
            return "box \(name) is not running; start it with `agent-vm box start \(name)`"
        case let .virtualMachine(operation, message):
            return "\(operation) failed: \(message)"
        case let .guestUnreachable(reason):
            return "the guest is unreachable: \(reason)"
        case let .guestRefused(reason):
            return "the guest refused: \(reason)"
        case let .supervisorRefused(message):
            return message
        case let .guestCommandFailed(command, status, output):
            let detail = output.isEmpty ? "" : ": \(output)"
            return "`\(command)` failed in the guest (status \(status))\(detail)"
        }
    }
}
