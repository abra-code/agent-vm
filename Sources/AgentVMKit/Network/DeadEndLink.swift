// Sources/AgentVMKit/Network/DeadEndLink.swift
//
// The network card of a box in allowlist or off mode: a VZFileHandleNetworkDeviceAttachment
// over a datagram socket pair whose host end forwards nothing. The guest gets a fixed address
// (10.254.0.2/24, router 10.254.0.1) and reaches the outside only through the proxy over vsock.
//
// One thing is answered: ARP for the router. Measured in spike 2: without an ARP answer macOS
// keeps the link "not reachable" - no default route, the proxy settings never become global,
// and URLSession reports -1009 "offline". With the answer, the whole system uses the proxy.
// Every other frame is read and dropped (reading keeps the socket buffer from filling up).

import Darwin
import Foundation

public final class DeadEndLink: @unchecked Sendable {
    public static let guestAddress = "10.254.0.2"
    public static let routerAddress = "10.254.0.1"
    public static let netmask = "255.255.255.0"
    static let routerIPv4: [UInt8] = [10, 254, 0, 1]
    /// A locally administered MAC for the router that does not exist.
    static let routerMAC: [UInt8] = [0x02, 0x00, 0x00, 0x00, 0x00, 0x01]

    /// The guest's end, for the network device attachment.
    public let guestHandle: FileHandle
    private let hostEnd: Int32
    private let lock = NSLock()
    private var dropped = 0
    private var answered = 0

    public init() throws {
        var pair: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_DGRAM, 0, &pair) == 0 else {
            throw AgentVMError.system(operation: "socketpair for the network card", code: errno)
        }
        for descriptor in pair {
            _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
        }
        guestHandle = FileHandle(fileDescriptor: pair[0], closeOnDealloc: true)
        hostEnd = pair[1]
        Thread.detachNewThread { [self] in
            serve()
        }
    }

    /// Frames answered (ARP) and dropped so far.
    public var counts: (answered: Int, dropped: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (answered, dropped)
    }

    private func serve() {
        var frame = [UInt8](repeating: 0, count: 65536)
        while true {
            let count = read(hostEnd, &frame, frame.count)
            if count < 0 && errno == EINTR {
                continue
            }
            if count <= 0 {
                return
            }
            if let reply = Self.arpReply(to: Array(frame[0..<count])) {
                // Never block this thread on a guest that stopped reading its card.
                _ = reply.withUnsafeBytes { send(hostEnd, $0.baseAddress, $0.count, MSG_DONTWAIT) }
                lock.lock()
                answered += 1
                lock.unlock()
            } else {
                lock.lock()
                dropped += 1
                lock.unlock()
            }
        }
    }

    /// The reply to an Ethernet ARP request for the router's address; nil for anything else.
    static func arpReply(to frame: [UInt8]) -> [UInt8]? {
        // Ethernet header (14) + ARP for IPv4 over Ethernet (28).
        guard frame.count >= 42,
              frame[12] == 0x08, frame[13] == 0x06,                     // ARP
              frame[14] == 0x00, frame[15] == 0x01,                     // hardware type Ethernet
              frame[16] == 0x08, frame[17] == 0x00,                     // protocol IPv4
              frame[18] == 6, frame[19] == 4,                           // address sizes
              frame[20] == 0x00, frame[21] == 0x01,                     // request
              Array(frame[38..<42]) == routerIPv4 else {
            return nil
        }
        let senderMAC = Array(frame[22..<28])
        let senderIP = Array(frame[28..<32])
        var reply = [UInt8]()
        reply += senderMAC + routerMAC + [0x08, 0x06]
        reply += [0x00, 0x01, 0x08, 0x00, 6, 4, 0x00, 0x02]
        reply += routerMAC + routerIPv4 + senderMAC + senderIP
        return reply
    }

    // The serving thread keeps the link alive for the life of the process: a box's
    // supervisor has exactly one, and it ends with the process.
}
