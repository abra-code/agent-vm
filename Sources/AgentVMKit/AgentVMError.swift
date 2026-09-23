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
        }
    }
}
