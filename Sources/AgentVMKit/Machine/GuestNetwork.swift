// Sources/AgentVMKit/Machine/GuestNetwork.swift
//
// Finding a NAT guest on the network. Virtualization's NAT attachment gives the guest an
// address from the host's DHCP server (bootpd), which records every lease in
// /var/db/dhcpd_leases keyed by the guest's MAC address:
//
//   {
//       name=agent
//       ip_address=192.168.64.2
//       hw_address=1,da:51:72:d4:e5:72
//       identifier=1,da:51:72:d4:e5:72
//       lease=0x6ab4112a
//   }
//
// bootpd writes each MAC octet without leading zeros ("1,a:b:c:..."), so addresses are
// compared in that form.

import Darwin
import Foundation

public enum GuestNetwork {
    public static let leasesPath = "/var/db/dhcpd_leases"

    public struct Lease: Equatable, Sendable {
        public var address: String
        public var hardwareAddress: String
        /// bootpd's lease value (hex in the file): larger is newer.
        public var lease: UInt64
    }

    /// Every complete lease in a dhcpd_leases file. A line ends at a line feed and nowhere
    /// else: the `name=` value is the host name a guest sent, and a carriage return or another
    /// of Unicode's line ends inside it must not start a line of its own.
    public static func parseLeases(_ text: String) -> [Lease] {
        var leases: [Lease] = []
        var address: String?
        var hardware: String?
        var lease: UInt64 = 0
        for rawLine in text.utf8.split(separator: UInt8(ascii: "\n")) {
            let line = String(decoding: rawLine, as: UTF8.self).trimmingCharacters(in: .whitespaces)
            if line == "{" {
                address = nil
                hardware = nil
                lease = 0
            } else if line == "}" {
                if let address, let hardware {
                    leases.append(Lease(address: address, hardwareAddress: hardware, lease: lease))
                }
                address = nil
                hardware = nil
            } else if line.hasPrefix("ip_address=") {
                address = String(line.dropFirst("ip_address=".count))
            } else if line.hasPrefix("hw_address=") {
                // "1,da:51:..." - the type (1 = Ethernet), then the address.
                let value = line.dropFirst("hw_address=".count)
                if let comma = value.firstIndex(of: ",") {
                    hardware = normalizedMAC(String(value[value.index(after: comma)...]))
                }
            } else if line.hasPrefix("lease=0x") {
                lease = UInt64(line.dropFirst("lease=0x".count), radix: 16) ?? 0
            }
        }
        return leases
    }

    /// Lower case, no leading zeros in an octet: the form bootpd writes.
    public static func normalizedMAC(_ mac: String) -> String {
        return mac.lowercased().split(separator: ":", omittingEmptySubsequences: false).map { octet -> String in
            let trimmed = octet.drop { $0 == "0" }
            return trimmed.isEmpty ? "0" : String(trimmed)
        }.joined(separator: ":")
    }

    /// The newest leased IPv4 address for `mac`, if any.
    public static func address(forMAC mac: String, leases text: String) -> String? {
        let wanted = normalizedMAC(mac)
        return parseLeases(text)
            .filter { $0.hardwareAddress == wanted }
            .max { $0.lease < $1.lease }?
            .address
    }

    public static func address(forMAC mac: String) -> String? {
        // Read as bytes: a host name that is not UTF-8 (any guest on the Mac's virtual network
        // chooses its own) must not make the whole file unreadable.
        guard let data = FileManager.default.contents(atPath: leasesPath) else {
            return nil
        }
        return address(forMAC: mac, leases: String(decoding: data, as: UTF8.self))
    }

    /// How one attempt to connect ended.
    public enum Attempt: Equatable, Sendable {
        case open
        /// Nothing answered within the timeout.
        case noAnswer
        /// The connection failed with this errno: ECONNREFUSED when nothing listens yet,
        /// EHOSTDOWN when no machine has the address, EHOSTUNREACH or EPERM (see
        /// `refusedByThisMac`) when this Mac does not let the process reach it.
        case failed(Int32)

        /// Whether this Mac, not the guest, stopped the attempt. A guest that is up and has
        /// no listener answers with ECONNREFUSED; these come from the Mac's own network
        /// stack: Local Network privacy, a sandbox, a content filter.
        public var refusedByThisMac: Bool {
            switch self {
            case .failed(EHOSTUNREACH), .failed(EPERM), .failed(EACCES), .failed(ENETUNREACH):
                return true
            default:
                return false
            }
        }

        /// For a person: "failed with No route to host".
        public var text: String {
            switch self {
            case .open:
                return "succeeded"
            case .noAnswer:
                return "got no answer"
            case let .failed(code):
                return "failed with \(String(cString: strerror(code)))"
            }
        }
    }

    /// Whether a TCP connection to `host:port` succeeds within `timeout` seconds. Blocks.
    public static func isPortOpen(_ host: String, port: UInt16, timeout: Int = 2) -> Bool {
        return attempt(host, port: port, timeout: timeout) == .open
    }

    /// One attempt to connect to `host:port`, with the reason when it fails. Blocks.
    public static func attempt(_ host: String, port: UInt16, timeout: Int = 2) -> Attempt {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        guard inet_pton(AF_INET, host, &address.sin_addr) == 1 else {
            return .failed(EINVAL)
        }
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            return .failed(errno)
        }
        defer { close(descriptor) }
        // Non-blocking connect, then wait for writability with poll: connect(2) alone can block
        // for over a minute on an address nobody answers.
        let flags = fcntl(descriptor, F_GETFL)
        _ = fcntl(descriptor, F_SETFL, flags | O_NONBLOCK)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        let connectError = errno
        if result == 0 {
            return .open
        }
        guard connectError == EINPROGRESS else {
            return .failed(connectError)
        }
        var descriptorPoll = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
        guard poll(&descriptorPoll, 1, Int32(timeout * 1000)) == 1 else {
            return .noAnswer
        }
        var socketError: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &socketError, &length) == 0 else {
            return .failed(errno)
        }
        return socketError == 0 ? .open : .failed(socketError)
    }
}
