// Sources/AgentVMKit/Machine/GuestMachine.swift
//
// A guest's machine, macOS or Linux: the files it is made of, how its network card is
// connected, and the running machine. Virtualization runs a machine on one serial queue; this
// wrapper uses the main queue, so it is a main-actor class and every call happens on the main
// actor. The command-line tool's async entry point runs there.
//
// The configuration is built per guest (MacMachineSpec, LinuxMachineSpec) and chosen in one
// place (MachineBuilder).

import Foundation
import Virtualization

/// The files that make up one guest (an image's or a box's).
struct MachineFiles: Sendable {
    var name: String
    var directory: URL
    var disk: URL
    var platform: Platform

    init(name: String, directory: URL, disk: URL, platform: Platform) {
        self.name = name
        self.directory = directory
        self.disk = disk
        self.platform = platform
    }

    /// The files of a guest of this kind in `directory`, under the names every image and box
    /// folder uses.
    init(name: String, directory: URL, guest: GuestKind) {
        let identifier = directory.appendingPathComponent(ImageStore.machineIdentifierName)
        let platform: Platform
        switch guest {
        case .macOS:
            platform = .mac(auxiliaryStorage: directory.appendingPathComponent(ImageStore.auxiliaryStorageName),
                            hardwareModel: directory.appendingPathComponent(ImageStore.hardwareModelName), machineIdentifier: identifier)
        case .linux:
            platform = .linux(efiVariableStore: directory.appendingPathComponent(ImageStore.efiVariableStoreName), machineIdentifier: identifier)
        }
        self.init(name: name, directory: directory, disk: directory.appendingPathComponent(ImageStore.diskName), platform: platform)
    }

    /// What a machine has besides its disk.
    enum Platform: Sendable {
        case mac(auxiliaryStorage: URL, hardwareModel: URL, machineIdentifier: URL)
        case linux(efiVariableStore: URL, machineIdentifier: URL)
    }

    /// The same machine with its disk, and what the guest writes besides the disk (a Mac's
    /// auxiliary storage, a Linux guest's firmware variables), in `folder`: the copies an
    /// update works on. What never changes stays where it is.
    func working(in folder: URL) -> MachineFiles {
        var files = self
        files.disk = folder.appendingPathComponent(ImageStore.diskName)
        switch platform {
        case let .mac(_, hardwareModel, machineIdentifier):
            files.platform = .mac(auxiliaryStorage: folder.appendingPathComponent(ImageStore.auxiliaryStorageName),
                                  hardwareModel: hardwareModel, machineIdentifier: machineIdentifier)
        case let .linux(_, machineIdentifier):
            files.platform = .linux(efiVariableStore: folder.appendingPathComponent(ImageStore.efiVariableStoreName),
                                    machineIdentifier: machineIdentifier)
        }
        return files
    }
}

extension GoldenImage {
    /// The machine files, as the VM configuration reads them.
    var machineFiles: MachineFiles {
        return MachineFiles(name: name, directory: directory, guest: record.effectiveGuest)
    }
}

/// How the guest's network card is connected.
enum MachineNetwork {
    /// NAT through the host: the internet and the local network.
    case nat
    /// A card whose other end is this handle (a box's dead-end link).
    case fileHandle(FileHandle)
    /// No card at all (a Linux box whose programs reach the proxy through the guest daemon).
    case none
}

/// How a shared folder appears in the guest.
public enum ShareLayout: Sendable {
    /// The one entry, named after the folder, of a read-only root (macOS guests, which write
    /// their own folders into the root of a volume).
    case namedEntry
    /// The folder itself.
    case single
}

/// A running (or startable) guest, operated on the main queue.
@MainActor
public final class GuestMachine: NSObject, VZVirtualMachineDelegate {
    /// For the macOS-only half (MacMachineSpec.swift), which installs and starts with options.
    let machine: VZVirtualMachine
    private var stopped = false {
        didSet {
            if stopped {
                releaseRunningMark()
            }
        }
    }
    private var stopError: String?
    /// A lock held for as long as this guest runs, and released when it stops (or with the
    /// machine): how others see that an image's Linux guest is running.
    var runningMark: FolderLock?

    private func releaseRunningMark() {
        runningMark?.release()
        runningMark = nil
    }
    // Listeners and their delegates (the delegate reference is weak) live as long as the machine.
    private var listeners: [VZVirtioSocketListener] = []
    private var acceptors: [SocketAcceptor] = []

    public init(configuration: VZVirtualMachineConfiguration) {
        machine = VZVirtualMachine(configuration: configuration)
        super.init()
        machine.delegate = self
    }

    public var isRunning: Bool {
        return machine.state == .running || machine.state == .starting
    }

    /// Why the guest stopped on its own with an error, if it did.
    public var failure: String? {
        return stopError
    }

    /// Shows this machine's display in `view`.
    public func attach(_ view: VZVirtualMachineView) {
        view.virtualMachine = machine
    }

    /// Forgets how an earlier run ended; every start calls it first.
    func willStart() {
        stopped = false
        stopError = nil
    }

    /// Starts the guest, with no options (a macOS guest's start with options is
    /// `start(provisioning:)`).
    public func start() async throws {
        willStart()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            machine.start { result in
                switch result {
                case .success:
                    continuation.resume()
                case let .failure(error):
                    continuation.resume(throwing: AgentVMError.virtualMachine(operation: "start the guest", error: error))
                }
            }
        }
    }

    /// Presses the power button. A Linux guest shuts down on it within seconds; a macOS guest
    /// with a logged-in user does not (measured), so there a clean shutdown goes through the
    /// guest itself. Nothing is waited for: see `waitUntilStopped`.
    public func requestStop() throws {
        guard machine.canRequestStop else {
            return
        }
        do {
            try machine.requestStop()
        } catch {
            throw AgentVMError.virtualMachine(operation: "ask the guest to stop", message: error.localizedDescription)
        }
    }

    /// Waits for the guest to stop by itself; false when `timeout` passes first.
    public func waitUntilStopped(timeout: Duration) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while !stopped && machine.state != .stopped && machine.state != .error {
            if ContinuousClock.now >= deadline {
                return false
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
        // The machine's state can say so before the delegate is told; the next boot of the
        // same image takes the mark again.
        releaseRunningMark()
        return true
    }

    /// Pulls the plug. The guest gets no chance to flush its disk; use only when it does not
    /// shut down by itself.
    public func forceStop() async throws {
        guard machine.canStop else {
            return
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            machine.stop { error in
                if let error {
                    continuation.resume(throwing: AgentVMError.virtualMachine(operation: "stop the guest", message: error.localizedDescription))
                } else {
                    continuation.resume()
                }
            }
        }
        stopped = true
    }

    /// How long the guest has to answer a connection request. It answers in milliseconds, or
    /// refuses at once; the limit is for a guest that does neither, so that no caller (a box's
    /// supervisor asked to stop, above all) waits on it for good.
    public static let connectLimit: Duration = .seconds(20)

    /// Opens a vsock connection to `port` in the guest (the guest daemon listens on
    /// `GuestProtocol.port`). Fails at once when nothing listens there yet, and after
    /// `connectLimit` when the guest does not answer at all.
    public func connect(toPort port: UInt32) async throws -> GuestConnection {
        guard let device = machine.socketDevices.first as? VZVirtioSocketDevice else {
            throw AgentVMError.virtualMachine(operation: "connect to the guest", message: "the machine has no vsock device")
        }
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<GuestConnection, Error>) in
            // The answer and the limit are both taken on the main queue; the first one counts,
            // and a connection that comes after the limit is closed.
            let waiting = ConnectWait(continuation)
            device.connect(toPort: port) { result in
                let answer: Result<GuestConnection, Error>
                switch result {
                case let .success(connection):
                    answer = .success(GuestConnection(connection))
                case let .failure(error):
                    answer = .failure(AgentVMError.guestUnreachable("vsock port \(port): \(error.localizedDescription)"))
                }
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        if !waiting.resume(answer), case let .success(guest) = answer {
                            guest.close()
                        }
                    }
                }
            }
            let (seconds, attoseconds) = Self.connectLimit.components
            DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(Int(seconds)) + .nanoseconds(Int(attoseconds / 1_000_000_000))) {
                MainActor.assumeIsolated {
                    _ = waiting.resume(.failure(AgentVMError.guestUnreachable("vsock port \(port): the guest did not answer the connection within \(Self.connectLimit)")))
                }
            }
        }
    }

    /// One waiting `connect`: resumed once, by the answer or by the limit.
    @MainActor
    private final class ConnectWait {
        private var continuation: CheckedContinuation<GuestConnection, Error>?

        init(_ continuation: CheckedContinuation<GuestConnection, Error>) {
            self.continuation = continuation
        }

        /// False when the other one came first.
        func resume(_ result: Result<GuestConnection, Error>) -> Bool {
            guard let continuation else {
                return false
            }
            self.continuation = nil
            continuation.resume(with: result)
            return true
        }
    }

    /// Shares `directory` (or nothing) through the file system device tagged `tag`: as the
    /// one entry of a synthetic read-only root, named after the folder, or as the folder
    /// itself. The guest must not have it mounted while the share changes.
    public func share(tag: String, directory: URL?, readOnly: Bool, layout: ShareLayout = .namedEntry) throws {
        guard let device = machine.directorySharingDevices.compactMap({ $0 as? VZVirtioFileSystemDevice }).first(where: { $0.tag == tag }) else {
            throw AgentVMError.virtualMachine(operation: "share a folder", message: "the machine has no file system device \(tag)")
        }
        guard let directory else {
            device.share = nil
            return
        }
        if layout == .single {
            device.share = VZSingleDirectoryShare(directory: VZSharedDirectory(url: directory, readOnly: readOnly))
            return
        }
        let name = directory.lastPathComponent
        do {
            try VZMultipleDirectoryShare.validateName(name)
        } catch {
            throw AgentVMError.virtualMachine(operation: "share \(directory.path)", message: error.localizedDescription)
        }
        device.share = VZMultipleDirectoryShare(directories: [name: VZSharedDirectory(url: directory, readOnly: readOnly)])
    }

    /// Accepts guest-initiated vsock connections to `port`; `accept` runs on the main queue
    /// and owns the connection (close it when done).
    public func listen(port: UInt32, accept: @escaping @Sendable (GuestConnection) -> Void) throws {
        guard let device = machine.socketDevices.first as? VZVirtioSocketDevice else {
            throw AgentVMError.virtualMachine(operation: "listen for the guest", message: "the machine has no vsock device")
        }
        let listener = VZVirtioSocketListener()
        let acceptor = SocketAcceptor(accept)
        listener.delegate = acceptor
        acceptors.append(acceptor)
        listeners.append(listener)
        device.setSocketListener(listener, forPort: port)
    }

    // MARK: - VZVirtualMachineDelegate (called on the main queue)

    nonisolated public func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        MainActor.assumeIsolated {
            stopped = true
        }
    }

    nonisolated public func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: any Error) {
        let message = error.localizedDescription
        MainActor.assumeIsolated {
            stopError = message
            stopped = true
        }
    }
}

/// Hands each accepted guest connection to a closure.
private final class SocketAcceptor: NSObject, VZVirtioSocketListenerDelegate {
    private let accept: @Sendable (GuestConnection) -> Void

    init(_ accept: @escaping @Sendable (GuestConnection) -> Void) {
        self.accept = accept
    }

    func listener(_ listener: VZVirtioSocketListener, shouldAcceptNewConnection connection: VZVirtioSocketConnection, from socketDevice: VZVirtioSocketDevice) -> Bool {
        accept(GuestConnection(connection))
        return true
    }
}

/// One vsock connection to the guest. Its descriptor stays valid only while this object is
/// alive and not closed: closing it also breaks copies handed to other processes (measured),
/// so the owner closes it only when every user of the descriptor is done.
public final class GuestConnection: @unchecked Sendable {
    private let connection: VZVirtioSocketConnection
    private let lock = NSLock()
    private var closed = false

    init(_ connection: VZVirtioSocketConnection) {
        self.connection = connection
    }

    public var descriptor: Int32 {
        return connection.fileDescriptor
    }

    public func close() {
        lock.lock()
        defer { lock.unlock() }
        if !closed {
            closed = true
            connection.close()
        }
    }

    deinit {
        close()
    }
}
