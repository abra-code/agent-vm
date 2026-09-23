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

    /// Listens on 127.0.0.1:`port` and relays forever on background threads.
    public static func start(port: UInt16 = port, hostPort: UInt32 = hostPort) throws {
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
        Thread.detachNewThread {
            while true {
                let client = accept(listener, nil, nil)
                if client < 0 {
                    if errno != EINTR && errno != ECONNABORTED {
                        usleep(100_000)
                    }
                    continue
                }
                _ = fcntl(client, F_SETFD, FD_CLOEXEC)
                Thread.detachNewThread {
                    relay(client, hostPort: hostPort)
                }
            }
        }
    }

    static func relay(_ client: Int32, hostPort: UInt32) {
        defer { close(client) }
        let upstream = socket(AF_VSOCK, SOCK_STREAM, 0)
        guard upstream >= 0 else {
            return
        }
        defer { close(upstream) }
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
            return
        }
        Splice.run(client, upstream)
    }
}
