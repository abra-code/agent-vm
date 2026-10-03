// Sources/AgentVMKit/Guest/GuestRelay.swift
//
// Inside the box: the proxy address programs use (127.0.0.1:3128, set as the system proxy and
// in HTTP_PROXY/HTTPS_PROXY) forwarded to the host's proxy on vsock port 3128. Every accepted
// connection becomes one vsock connection; the host decides what is allowed. When the host
// runs no proxy (open mode), the vsock connect fails at once and the client is closed.

import Darwin
import Foundation

public enum GuestRelay {
    public static let port: UInt16 = 3128
    public static let hostPort: UInt32 = 3128

    /// The most connections relayed at once. Each takes a thread and two descriptors of the
    /// daemon, which also needs descriptors to accept the host and to run programs: a box
    /// program that opens connections without end must not use them up. The host's proxy
    /// serves 256 at once for the whole box.
    public static let maxConnections = 128
    /// The daemon's limit on open descriptors once the relay runs: four times what the relay
    /// can hold.
    static let descriptorLimit: rlim_t = 1024

    /// Listens on 127.0.0.1:`port` (0: any free port) and relays forever on background threads;
    /// returns the port. A connection past `maxConnections` is closed at once. `connect` opens
    /// the far side of one connection (the host's proxy; replaced in tests) or returns -1.
    @discardableResult
    public static func start(port: UInt16 = port, hostPort: UInt32 = hostPort, connect: (@Sendable () -> Int32)? = nil) throws -> UInt16 {
        let listener = socket(AF_INET, SOCK_STREAM, 0)
        guard listener >= 0 else {
            throw AgentVMError.system(operation: "relay socket", code: errno)
        }
        _ = fcntl(listener, F_SETFD, FD_CLOEXEC)
        var one: Int32 = 1
        _ = setsockopt(listener, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, listen(listener, 64) == 0 else {
            let code = errno
            close(listener)
            throw AgentVMError.system(operation: "listen on 127.0.0.1:\(port)", code: code)
        }
        var listening = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &listening) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(listener, $0, &length) }
        }
        guard named == 0 else {
            let code = errno
            close(listener)
            throw AgentVMError.system(operation: "getsockname", code: code)
        }
        // launchd starts the daemon with room for 256 descriptors, which `maxConnections`
        // connections alone would fill. Programs the daemon starts inherit the higher limit.
        var limit = rlimit()
        if getrlimit(RLIMIT_NOFILE, &limit) == 0, limit.rlim_cur < descriptorLimit {
            limit.rlim_cur = min(descriptorLimit, limit.rlim_max)
            _ = setrlimit(RLIMIT_NOFILE, &limit)
        }
        let open = OpenCount()
        Thread.detachNewThread {
            while true {
                let client = accept(listener, nil, nil)
                if client < 0 {
                    if errno != EINTR && errno != ECONNABORTED {
                        usleep(100_000)
                    }
                    continue
                }
                guard open.take(limit: maxConnections) else {
                    close(client)
                    continue
                }
                _ = fcntl(client, F_SETFD, FD_CLOEXEC)
                Thread.detachNewThread {
                    relay(client, to: connect?() ?? connectToHost(port: hostPort))
                    open.give()
                }
            }
        }
        return UInt16(bigEndian: listening.sin_port)
    }

    /// Connections being relayed now.
    private final class OpenCount: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0

        func take(limit: Int) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard count < limit else {
                return false
            }
            count += 1
            return true
        }

        func give() {
            lock.lock()
            count -= 1
            lock.unlock()
        }
    }

    /// Copies between the two until either ends, and closes both.
    static func relay(_ client: Int32, to upstream: Int32) {
        defer { close(client) }
        guard upstream >= 0 else {
            return
        }
        defer { close(upstream) }
        Splice.run(client, upstream)
    }

    /// A connection to the host's vsock port `port`, or -1.
    static func connectToHost(port hostPort: UInt32) -> Int32 {
        let upstream = socket(AF_VSOCK, SOCK_STREAM, 0)
        guard upstream >= 0 else {
            return -1
        }
        _ = fcntl(upstream, F_SETFD, FD_CLOEXEC)
        var address = sockaddr_vm()
        address.svm_len = UInt8(MemoryLayout<sockaddr_vm>.size)
        address.svm_family = sa_family_t(AF_VSOCK)
        address.svm_port = hostPort
        address.svm_cid = 2 // VMADDR_CID_HOST
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(upstream, $0, socklen_t(MemoryLayout<sockaddr_vm>.size)) }
        }
        guard connected == 0 else {
            close(upstream)
            return -1
        }
        return upstream
    }
}
