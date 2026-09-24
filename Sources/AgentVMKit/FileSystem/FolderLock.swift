// Sources/AgentVMKit/FileSystem/FolderLock.swift
//
// An exclusive, non-blocking flock on a lock file, held until released or deallocated. The
// kernel drops it when the process exits, so a crashed holder never leaves a stale lock.
// Images and boxes use one each: whoever builds an image or runs a box holds it.

import Darwin

public final class FolderLock: @unchecked Sendable {
    private var descriptor: Int32

    init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    /// Takes the lock on `path` (created if missing, never through a symlink); nil when
    /// another open file holds it, in this process or another.
    public static func tryAcquire(_ path: String) throws -> FolderLock? {
        // Both calls retry when a signal interrupts them (child processes exiting send SIGCHLD);
        // isHeld would otherwise report a free lock as held.
        var descriptor: Int32
        repeat {
            descriptor = open(path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
        } while descriptor < 0 && errno == EINTR
        guard descriptor >= 0 else {
            throw AgentVMError.system(operation: "open lock \(path)", code: errno)
        }
        var locked: Int32
        repeat {
            locked = flock(descriptor, LOCK_EX | LOCK_NB)
        } while locked != 0 && errno == EINTR
        if locked != 0 {
            let code = errno
            close(descriptor)
            if code == EWOULDBLOCK {
                return nil
            }
            throw AgentVMError.system(operation: "lock \(path)", code: code)
        }
        return FolderLock(descriptor: descriptor)
    }

    /// Whether someone holds the lock on `path` right now (a missing lock file is free).
    public static func isHeld(_ path: String) -> Bool {
        guard FileSystem.exists(path) else {
            return false
        }
        guard let lock = try? tryAcquire(path) else {
            return true
        }
        lock.release()
        return false
    }

    public func release() {
        if descriptor >= 0 {
            // Unlock first: close alone releases the lock only when no other reference to this
            // open file exists anywhere, and a lock seemed to outlive its release under load.
            _ = flock(descriptor, LOCK_UN)
            close(descriptor)
            descriptor = -1
        }
    }

    deinit {
        release()
    }
}
