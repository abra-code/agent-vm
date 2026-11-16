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
        /// The VM runs and its guest daemon answers; exec works. (An image's "ready" means
        /// something else, built and usable, so a box says "running". The control channel
        /// between supervisor and client still says "ready"; see `from(_:)`.)
        case running
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
    /// The first project shared into the box, if any (see ControlResponse.project).
    public var project: String?
    public var projectReadOnly: Bool?
    /// Every folder shared into the box (supervisors from 0.7.48).
    public var projects: [SharedFolder]?
    /// Programs run by exec or box shell right now, from any client (supervisors from 0.1.6).
    public var activeExecs: Int?
    /// The guest daemon of the running box, once it answered.
    public var guestVersion: String?
    public var guestFeatures: [String]?
    /// Why the state is unresponsive.
    public var statusError: String?
    /// From the box record: a box that is deleted once it stops (`box create --disposable`).
    public var disposable: Bool?
    /// The process whose exit stops the box (`box start --owner-pid`), if any.
    public var ownerPid: Int32?
    /// How much memory a running box uses (BoxMemory), when asked for (`of(_:memory:)`).
    public var memory: BoxMemory?

    public init(state: State, pid: Int32? = nil, supervisorVersion: String? = nil, supervisorPath: String? = nil,
                startedAt: Date? = nil, project: String? = nil, projectReadOnly: Bool? = nil, projects: [SharedFolder]? = nil, activeExecs: Int? = nil,
                guestVersion: String? = nil, guestFeatures: [String]? = nil, statusError: String? = nil,
                disposable: Bool? = nil, ownerPid: Int32? = nil) {
        self.disposable = disposable
        self.ownerPid = ownerPid
        self.state = state
        self.pid = pid
        self.supervisorVersion = supervisorVersion
        self.supervisorPath = supervisorPath
        self.startedAt = startedAt
        self.project = project
        self.projectReadOnly = projectReadOnly
        self.projects = projects
        self.activeExecs = activeExecs
        self.guestVersion = guestVersion
        self.guestFeatures = guestFeatures
        self.statusError = statusError
    }

    /// The folders shared into the box. A supervisor before 0.7.48 names one, without the
    /// programs on it: those are taken to be every program it runs (`activeExecs`).
    public var sharedFolders: [SharedFolder] {
        if let projects {
            return projects
        }
        return project.map { [SharedFolder(path: $0, readOnly: projectReadOnly == true, programs: activeExecs ?? 1)] } ?? []
    }

    public static let stopped = BoxStatus(state: .stopped)

    /// How long a status question waits for the supervisor's answer. The supervisor answers
    /// status on its own thread without touching the VM, so a slow answer means a wedged one.
    public static let answerTimeout = 5

    /// The box's status as of now. A socket that is not there yet (a supervisor starting up)
    /// is retried for up to `connectWait`. With `memory`, a running box's memory figures too:
    /// a second question, which runs a command in the guest (at most one every few seconds).
    public static func of(_ box: Box, connectWait: Duration = .seconds(2), memory: Bool = false) -> BoxStatus {
        var status = supervisorStatus(box, connectWait: connectWait)
        status.disposable = box.record.disposable == true ? true : nil
        if memory && status.state == .running {
            status.memory = memoryFigures(box, supervisorVersion: status.supervisorVersion)
        }
        return status
    }

    /// How long a memory question waits: the supervisor waits up to 15 s for the guest
    /// (SupervisorControl.memoryWait).
    public static let memoryTimeout = 20

    /// A running box's memory figures; without an answer, its size and why.
    static func memoryFigures(_ box: Box, supervisorVersion: String?) -> BoxMemory {
        var why: String
        do {
            let response = try ControlClient.request(ControlRequest(op: .memory), path: box.controlSocketPath, timeout: memoryTimeout)
            if response.ok, let memory = response.memory {
                return memory
            }
            why = response.error ?? "the supervisor sent none"
        } catch {
            why = "\(error)"
        }
        // A supervisor from before there was the question refuses it as one it cannot read.
        if let supervisorVersion, isOlder(supervisorVersion, than: memoryVersion) {
            why = "the box's supervisor is agent-vm \(supervisorVersion), which does not report memory; restarting the box runs this one (\(AgentVM.version))"
        }
        return BoxMemory(configuredBytes: box.record.memoryBytes, notes: ["no figures: \(why)"])
    }

    /// The first agent-vm whose supervisor answers the memory question.
    static let memoryVersion = "0.8.12"

    /// Whether dotted version `version` comes before `other` ("0.8.9" before "0.8.12").
    static func isOlder(_ version: String, than other: String) -> Bool {
        return version.compare(other, options: .numeric) == .orderedAscending
    }

    private static func supervisorStatus(_ box: Box, connectWait: Duration) -> BoxStatus {
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
    public static func from(_ response: ControlResponse) -> BoxStatus {
        guard response.ok, let state = response.state else {
            return BoxStatus(state: .unresponsive, pid: response.pid, statusError: response.error ?? "the supervisor sent no state")
        }
        let mapped: State
        switch state {
        case .starting: mapped = .starting
        case .ready: mapped = .running
        case .stopping: mapped = .stopping
        }
        return BoxStatus(state: mapped, pid: response.pid, supervisorVersion: response.supervisorVersion, supervisorPath: response.supervisorPath,
                         startedAt: response.startedAt, project: response.project, projectReadOnly: response.projectReadOnly, projects: response.projects,
                         activeExecs: response.activeExecs, guestVersion: response.guestVersion,
                         guestFeatures: mapped == .running ? response.guestFeatures : nil, ownerPid: response.ownerPid)
    }

    private static func isNotListening(_ error: Error?) -> Bool {
        guard case let AgentVMError.system(_, code)? = error as? AgentVMError else {
            return false
        }
        return code == ENOENT || code == ECONNREFUSED
    }
}
