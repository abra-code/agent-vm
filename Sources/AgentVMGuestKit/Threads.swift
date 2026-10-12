// Sources/AgentVMGuestKit/Threads.swift
//
// A lock and a detached thread over pthread. The Linux daemon is one static program, and all
// of Foundation in it brings the Unicode library's data with it: 34 MB of a 54 MB file. So on
// Linux this kit imports FoundationEssentials, the part of Foundation without that library,
// which has no NSLock and no Thread; there those two names stand for the types here. On macOS,
// where Foundation is part of the system, the names stay Foundation's.

#if canImport(Darwin)
import Darwin
#elseif canImport(Musl)
import Musl
#elseif canImport(Glibc)
import Glibc
#endif
import Dispatch

/// A mutual-exclusion lock: `pthread_mutex_t` at an address that does not move.
public final class PthreadLock: @unchecked Sendable {
    private let mutex = UnsafeMutablePointer<pthread_mutex_t>.allocate(capacity: 1)

    public init() {
        mutex.initialize(to: pthread_mutex_t())
        let status = pthread_mutex_init(mutex, nil)
        precondition(status == 0, "pthread_mutex_init failed (\(status))")
    }

    deinit {
        pthread_mutex_destroy(mutex)
        mutex.deinitialize(count: 1)
        mutex.deallocate()
    }

    public func lock() {
        let status = pthread_mutex_lock(mutex)
        precondition(status == 0, "pthread_mutex_lock failed (\(status))")
    }

    public func unlock() {
        let status = pthread_mutex_unlock(mutex)
        precondition(status == 0, "pthread_mutex_unlock failed (\(status))")
    }
}

/// Threads that nobody joins.
public enum DetachedThread {
    /// What a thread started here gets as its stack: what macOS gives a thread that is not the
    /// first. The C library's own default is far smaller on Linux with musl (128 KiB).
    static let stackSize = 512 * 1024

    /// Runs `block` on a new thread. When the system refuses another thread, the block runs on
    /// a queue thread, so what waits for it still gets its answer.
    public static func detachNewThread(_ block: @escaping @Sendable () -> Void) {
        var attributes = pthread_attr_t()
        guard pthread_attr_init(&attributes) == 0 else {
            DispatchQueue.global().async(execute: block)
            return
        }
        defer { pthread_attr_destroy(&attributes) }
        pthread_attr_setstacksize(&attributes, stackSize)
        pthread_attr_setdetachstate(&attributes, Int32(PTHREAD_CREATE_DETACHED))
        let body = Unmanaged.passRetained(DetachedBody(block))
        #if canImport(Darwin) || canImport(Musl)
        var thread: pthread_t?
        let status = pthread_create(&thread, &attributes, { runDetachedBody($0) }, body.toOpaque())
        #else
        var thread = pthread_t()
        let status = pthread_create(&thread, &attributes, { runDetachedBody($0) }, body.toOpaque())
        #endif
        if status != 0 {
            body.release()
            DispatchQueue.global().async(execute: block)
        }
    }

    /// Sleeps the calling thread for that long, whatever signals arrive meanwhile.
    public static func sleep(forTimeInterval seconds: Double) {
        guard seconds > 0 else {
            return
        }
        let whole = seconds.rounded(.down)
        var wanted = timespec(tv_sec: Int(whole), tv_nsec: Int((seconds - whole) * 1_000_000_000))
        var left = timespec()
        while nanosleep(&wanted, &left) != 0 && errno == EINTR {
            wanted = left
        }
    }
}

private final class DetachedBody {
    let run: @Sendable () -> Void

    init(_ run: @escaping @Sendable () -> Void) {
        self.run = run
    }
}

/// What a thread of `DetachedThread` starts in: runs the block it was handed and lets it go.
private func runDetachedBody(_ raw: UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer? {
    if let raw {
        Unmanaged<DetachedBody>.fromOpaque(raw).takeRetainedValue().run()
    }
    return nil
}

#if !canImport(Darwin)
typealias NSLock = PthreadLock
typealias Thread = DetachedThread
#endif
