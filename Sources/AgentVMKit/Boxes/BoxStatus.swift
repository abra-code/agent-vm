// Sources/AgentVMKit/Boxes/BoxStatus.swift
//
// What `box status` and `box list` say about a box, without side effects: a stopped box is
// read from its folder, a running one is asked through its supervisor's control socket.
// Nothing is started, stopped or waited for.

import Darwin
import Foundation

public struct BoxStatus: Encodable, Equatable, Sendable {
    public enum State: String, Codable, Sendable {
        /// No supervisor holds the box.
        case stopped
        /// The supervisor runs; the guest daemon has not answered yet.
        case starting
        /// The guest daemon answers; exec works.
        case ready
        /// Shutting down.
        case stopping
        /// Something holds the box's lock but does not answer on the control socket: a
        /// supervisor that is wedged or speaks another control protocol, or a moment in which
        /// another agent-vm command (delete, network) holds the lock. `statusError` says which.
        case unresponsive
    }

    public var state: State
    /// The supervisor's process id, agent-vm version and executable, and when it started.
    /// Version, path and start are missing from supervisors older than 0.1.6.
    public var pid: Int32?
    public var supervisorVersion: String?
    public var supervisorPath: String?
    public var startedAt: Date?
    /// The project shared into the box, if any.
    public var project: String?
    public var projectReadOnly: Bool?
    /// Programs run by exec or box shell right now, from any client (supervisors from 0.1.6).
    public var activeExecs: Int?
    /// The guest daemon of the running box, once it answered.
    public var guestVersion: String?
    public var guestFeatures: [String]?
    /// Why the state is unresponsive.
    public var statusError: String?

    public init(state: State, pid: Int32? = nil, supervisorVersion: String? = nil, supervisorPath: String? = nil,
                startedAt: Date? = nil, project: String? = nil, projectReadOnly: Bool? = nil, activeExecs: Int? = nil,
                guestVersion: String? = nil, guestFeatures: [String]? = nil, statusError: String? = nil) {
        self.state = state
        self.pid = pid
        self.supervisorVersion = supervisorVersion
        self.supervisorPath = supervisorPath
        self.startedAt = startedAt
        self.project = project
        self.projectReadOnly = projectReadOnly
        self.activeExecs = activeExecs
        self.guestVersion = guestVersion
        self.guestFeatures = guestFeatures
        self.statusError = statusError
    }

    public static let stopped = BoxStatus(state: .stopped)

    /// How long a status question waits for the supervisor's answer. The supervisor answers
    /// status on its own thread without touching the VM, so a slow answer means a wedged one.
    public static let answerTimeout = 5

    /// The box's status as of now. A socket that is not there yet (a supervisor starting up)
    /// is retried for up to `connectWait`.
    public static func of(_ box: Box, connectWait: Duration = .seconds(2)) -> BoxStatus {
        guard box.isRunning else {
            return .stopped
        }
        let deadline = ContinuousClock.now + connectWait
        var lastError: Error?
        while true {
            do {
                let response = try ControlClient.request(ControlRequest(op: .status), path: box.controlSocketPath, timeout: answerTimeout)
                return from(response)
            } catch {
                lastError = error
            }
            // Only a missing or refused socket can be a supervisor still binding it; a
            // timeout or a broken answer will not improve by asking again.
            guard Self.isNotListening(lastError), ContinuousClock.now < deadline, box.isRunning else {
                break
            }
            usleep(100_000)
        }
        guard box.isRunning else {
            return .stopped
        }
        return BoxStatus(state: .unresponsive, statusError: lastError.map { "\($0)" } ?? "no answer")
    }

    /// A supervisor's answer as a status.
    static func from(_ response: ControlResponse) -> BoxStatus {
        guard response.ok, let state = response.state else {
            return BoxStatus(state: .unresponsive, pid: response.pid, statusError: response.error ?? "the supervisor sent no state")
        }
        let mapped: State
        switch state {
        case .starting: mapped = .starting
        case .ready: mapped = .ready
        case .stopping: mapped = .stopping
        }
        return BoxStatus(state: mapped, pid: response.pid, supervisorVersion: response.supervisorVersion, supervisorPath: response.supervisorPath,
                         startedAt: response.startedAt, project: response.project, projectReadOnly: response.projectReadOnly,
                         activeExecs: response.activeExecs, guestVersion: response.guestVersion,
                         guestFeatures: mapped == .ready ? response.guestFeatures : nil)
    }

    private static func isNotListening(_ error: Error?) -> Bool {
        guard case let AgentVMError.system(_, code)? = error as? AgentVMError else {
            return false
        }
        return code == ENOENT || code == ECONNREFUSED
    }
}
