// Sources/AgentVMKit/Network/SocketRead.swift
//
// Reading a stream socket without sleeping inside read(). On macOS 27, a thread asleep in
// read() or recv() on an AF_UNIX stream socket can miss a shutdown of either end made at the
// same moment (measured: 1.5 to 5.4 percent of such races). It then sleeps until a signal or
// until the other end is closed; its receive timeout frees it only when it was the peer that
// shut down, and a later shutdown of its own socket does not wake it. A thread waiting in poll()
// saw every one, and readers of TCP, pipes and a guest's vsock were not affected. The host's
// connections to a guest are AF_UNIX sockets (the Virtualization framework's), which carry the
// guest's shutdowns (a half-close keeps the guest's end open), and a canceled build or Send
// shuts its own connection down to stop its reader; so their readers wait in poll().

import Darwin

enum SocketRead {
    /// The longest one poll() waits before trying the socket again. poll() never missed a
    /// shutdown in the measurements; this bounds the delay if it ever did.
    static let sliceMilliseconds: Int32 = 1000

    /// Like read(2) on a blocking socket: the bytes read, 0 at end of file, or -1 with errno
    /// set. The wait happens in poll(), never inside recv(), and the socket's flags are left
    /// alone, so other threads' writes still block. SO_RCVTIMEO applies as it does to one
    /// blocking read: -1 with EAGAIN once nothing has arrived for that long, counted from the
    /// call's first wait (the kernel also restarts it after a wakeup that brought nothing).
    /// `count` must be above 0: 0 would read as end of file. `giveUp` is asked after every wait
    /// that brought nothing (so about once a slice): when it says yes, -1 with ETIMEDOUT.
    static func read(_ descriptor: Int32, _ buffer: UnsafeMutableRawPointer, _ count: Int, giveUp: (() -> Bool)? = nil) -> Int {
        var deadline: ContinuousClock.Instant?
        var waited = false
        while true {
            let got = recv(descriptor, buffer, count, MSG_DONTWAIT)
            if got >= 0 {
                return got
            }
            let code = errno
            if code == EINTR {
                continue
            }
            guard code == EAGAIN else {
                errno = code
                return -1
            }
            if waited, let giveUp, giveUp() {
                errno = ETIMEDOUT
                return -1
            }
            if !waited {
                // From the first wait, as the kernel times one read.
                waited = true
                deadline = receiveTimeout(descriptor).map { ContinuousClock.now + $0 }
            }
            var slice = sliceMilliseconds
            if let deadline {
                let left = deadline - ContinuousClock.now
                guard left > .zero else {
                    errno = EAGAIN
                    return -1
                }
                slice = min(slice, milliseconds(left))
            }
            var watched = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            let ready = poll(&watched, 1, slice)
            if ready < 0 {
                let code = errno
                guard code == EINTR else {
                    errno = code
                    return -1
                }
            } else if watched.revents & Int16(POLLNVAL) != 0 {
                errno = EBADF
                return -1
            }
            // Readable, hung up, an error, the slice over or EINTR: try the socket again.
        }
    }

    /// The socket's SO_RCVTIMEO, or nil when it has none.
    static func receiveTimeout(_ descriptor: Int32) -> Duration? {
        var value = timeval()
        var length = socklen_t(MemoryLayout<timeval>.size)
        guard getsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &value, &length) == 0 else {
            return nil
        }
        let timeout = Duration.seconds(value.tv_sec) + Duration.microseconds(value.tv_usec)
        return timeout > .zero ? timeout : nil
    }

    /// Whole milliseconds, rounded up (a slice must not end before the deadline), at least 1.
    static func milliseconds(_ duration: Duration) -> Int32 {
        let (seconds, attoseconds) = duration.components
        let perMillisecond: Int64 = 1_000_000_000_000_000
        return Int32(clamping: max(1, seconds * 1000 + (attoseconds + perMillisecond - 1) / perMillisecond))
    }
}
