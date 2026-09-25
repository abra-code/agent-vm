// Sources/AgentVMKit/Images/BuildCancellation.swift
//
// Canceling an image build or guest update (SIGINT, SIGTERM) at the next safe point. The
// builder checks the flag between steps and in its wait loops; what blocks for long - a guest
// command on a vsock connection, the macOS installer - is interrupted: the connection is shut
// down (the guest daemon then stops the program), the installer's progress is canceled. The
// builder then shuts the guest down, or stops the VM when the guest cannot answer, and
// records the image as canceled.

import Darwin
import Foundation

public final class BuildCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var received: Int32?
    private var descriptors: Set<Int32> = []
    private var actions: [Int: @Sendable () -> Void] = [:]
    private var nextAction = 0

    public init() {}

    /// The signal that canceled the build, if one did.
    public var signal: Int32? {
        lock.lock()
        defer { lock.unlock() }
        return received
    }

    public var isCanceled: Bool {
        return signal != nil
    }

    /// Cancels (the first call wins): shuts down every registered connection and runs every
    /// registered action.
    public func cancel(signal: Int32) {
        lock.lock()
        guard received == nil else {
            lock.unlock()
            return
        }
        received = signal
        // Under the lock: a descriptor is unregistered before it is closed, so none of these
        // can have been closed and reused for something else.
        for descriptor in descriptors {
            Darwin.shutdown(descriptor, SHUT_RDWR)
        }
        let pending = Array(actions.values)
        actions = [:]
        lock.unlock()
        for action in pending {
            action()
        }
    }

    /// Registers a connection to shut down on cancel; false (and nothing registered) when the
    /// build is already canceled. Unregister it before closing it.
    func register(descriptor: Int32) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard received == nil else {
            return false
        }
        descriptors.insert(descriptor)
        return true
    }

    func unregister(descriptor: Int32) {
        lock.lock()
        descriptors.remove(descriptor)
        lock.unlock()
    }

    /// Runs `action` on cancel (at once when already canceled). Returns a key for `remove`.
    func whenCanceled(_ action: @escaping @Sendable () -> Void) -> Int {
        lock.lock()
        guard received == nil else {
            lock.unlock()
            action()
            return -1
        }
        let key = nextAction
        nextAction += 1
        actions[key] = action
        lock.unlock()
        return key
    }

    func remove(_ key: Int) {
        lock.lock()
        actions[key] = nil
        lock.unlock()
    }

    /// Watches SIGINT and SIGTERM on the main queue and cancels on the first; a second signal
    /// is ignored while the guest shuts down (at most about half a minute). `stop()` puts the
    /// default handling back.
    @MainActor
    public static func watchingSignals() -> (cancellation: BuildCancellation, stop: () -> Void) {
        let cancellation = BuildCancellation()
        var sources: [DispatchSourceSignal] = []
        for signalNumber in [SIGINT, SIGTERM] {
            Darwin.signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
            source.setEventHandler {
                cancellation.cancel(signal: signalNumber)
            }
            source.resume()
            sources.append(source)
        }
        return (cancellation, {
            for source in sources {
                source.cancel()
            }
            for signalNumber in [SIGINT, SIGTERM] {
                Darwin.signal(signalNumber, SIG_DFL)
            }
        })
    }

    /// The failure recorded in an image a cancel left failed.
    public static let failure = "canceled"
}
