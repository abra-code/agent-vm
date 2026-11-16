// Sources/AgentVMKit/Boxes/BoxMemory.swift
//
// How much memory a running box uses, as `box status` and `box list` report it: what the
// guest says it uses (read by the supervisor with a command in the guest, so every
// agent-vm-guest answers), and what the Mac holds for it (the physical footprint of the
// box's Virtualization process, MachineProcess). Each figure is left out, with a note, when it
// cannot be had.

import Foundation

public struct BoxMemory: Codable, Equatable, Sendable {
    /// The box's memory size, as its record gives it.
    public var configuredBytes: UInt64
    /// What the guest system counts as its memory (a little under the size on Linux, which keeps
    /// some for the kernel).
    public var guestTotalBytes: UInt64?
    /// What the guest could give its programs without swapping: free memory and the file cache
    /// it can drop (Linux: MemAvailable).
    public var guestAvailableBytes: UInt64?
    /// The guest's file cache (Linux: Cached; macOS: file-backed pages).
    public var guestCacheBytes: UInt64?
    /// The physical footprint of the box's Virtualization process on this Mac: its memory in
    /// RAM and in the compressor, which resident size alone leaves out.
    public var hostFootprintBytes: UInt64?
    /// When the figures were taken.
    public var sampledAt: Date
    /// Why a figure is missing, one line each.
    public var notes: [String]?

    public init(configuredBytes: UInt64, guestTotalBytes: UInt64? = nil, guestAvailableBytes: UInt64? = nil, guestCacheBytes: UInt64? = nil,
                hostFootprintBytes: UInt64? = nil, sampledAt: Date = Date(), notes: [String]? = nil) {
        self.configuredBytes = configuredBytes
        self.guestTotalBytes = guestTotalBytes
        self.guestAvailableBytes = guestAvailableBytes
        self.guestCacheBytes = guestCacheBytes
        self.hostFootprintBytes = hostFootprintBytes
        self.sampledAt = sampledAt
        self.notes = notes
    }

    /// What the guest's programs hold and the system cannot drop: total less available.
    public var guestUsedBytes: UInt64? {
        guard let guestTotalBytes, let guestAvailableBytes else {
            return nil
        }
        return guestTotalBytes > guestAvailableBytes ? guestTotalBytes - guestAvailableBytes : 0
    }

    mutating func note(_ line: String) {
        notes = (notes ?? []) + [line]
    }

    /// One line for a person: "memory 8 GB: programs use 4.4 GB, file cache 2.4 GB; the Mac
    /// holds 3.7 GB for it", with what is known.
    public var line: String {
        var text = "memory \(MachineSize.gigabytesText(configuredBytes)) GB"
        var guestParts: [String] = []
        if let used = guestUsedBytes {
            guestParts.append("programs use \(Self.gigabytes(used))")
        }
        if let cache = guestCacheBytes {
            guestParts.append("file cache \(Self.gigabytes(cache))")
        }
        if !guestParts.isEmpty {
            text += ": " + guestParts.joined(separator: ", ")
        }
        if let host = hostFootprintBytes {
            text += "\(guestParts.isEmpty ? ":" : ";") the Mac holds \(Self.gigabytes(host)) for it"
        }
        return text
    }

    /// Bytes as GB with one decimal (GiB, as the box sizes are).
    public static func gigabytes(_ bytes: UInt64) -> String {
        return String(format: "%.1f GB", Double(bytes) / Double(1 << 30))
    }

    // MARK: - The guest's figures

    /// The command that prints the guest's memory figures, run as root: /proc/meminfo on Linux;
    /// on macOS the memory size, then vm_stat.
    static func guestRequest(for guest: GuestKind) -> GuestRequest {
        switch guest {
        case .linux:
            return GuestRequest(op: .exec, argv: ["/bin/cat", "/proc/meminfo"], user: "root")
        case .macOS:
            return GuestRequest(op: .exec, argv: ["/bin/sh", "-c", "/usr/sbin/sysctl -n hw.memsize && /usr/bin/vm_stat"], user: "root")
        }
    }

    /// The figures the guest printed, or nil when its output is not what the command prints.
    /// The output is the guest's: numbers are bounded and checked, nothing else is kept.
    static func guestFigures(_ output: String, guest: GuestKind) -> (total: UInt64, available: UInt64, cache: UInt64)? {
        switch guest {
        case .linux:
            return linuxFigures(output)
        case .macOS:
            return macFigures(output)
        }
    }

    /// No guest counts more memory than this (1 PiB): a larger number is not believed.
    static let largest: UInt64 = 1 << 50

    /// MemTotal, MemAvailable and Cached of /proc/meminfo, in bytes (the file says kB, which is
    /// KiB).
    static func linuxFigures(_ text: String) -> (total: UInt64, available: UInt64, cache: UInt64)? {
        var values: [String: UInt64] = [:]
        for line in text.split(separator: "\n") {
            let parts = line.split(whereSeparator: { $0 == " " || $0 == ":" })
            guard parts.count == 3, parts[2] == "kB", let kilobytes = UInt64(parts[1]), kilobytes <= largest >> 10 else {
                continue
            }
            let key = String(parts[0])
            if key == "MemTotal" || key == "MemAvailable" || key == "Cached" {
                values[key] = kilobytes << 10
            }
        }
        guard let total = values["MemTotal"], total > 0, let available = values["MemAvailable"], let cache = values["Cached"] else {
            return nil
        }
        return (total, min(available, total), min(cache, total))
    }

    /// hw.memsize on the first line, then vm_stat's page counts. Used is what Activity Monitor
    /// calls used: anonymous pages less purgeable ones, wired pages, and what the compressor
    /// occupies; available is the rest, cache the file-backed pages.
    static func macFigures(_ text: String) -> (total: UInt64, available: UInt64, cache: UInt64)? {
        let lines = text.split(separator: "\n")
        guard let first = lines.first, let total = UInt64(first.trimmingCharacters(in: .whitespaces)), total > 0, total <= largest else {
            return nil
        }
        var pageSize: UInt64?
        var pages: [String: UInt64] = [:]
        for line in lines.dropFirst() {
            if line.hasPrefix("Mach Virtual Memory Statistics:") {
                // "(page size of 16384 bytes)"
                let words = line.split(separator: " ")
                if let index = words.firstIndex(of: "of"), index + 1 < words.count, let size = UInt64(words[index + 1]), size > 0, size <= 1 << 20 {
                    pageSize = size
                }
                continue
            }
            guard let colon = line.firstIndex(of: ":") else {
                continue
            }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            var number = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if number.hasSuffix(".") {
                number.removeLast()
            }
            if let count = UInt64(number), count <= largest {
                pages[key] = count
            }
        }
        guard let pageSize, let anonymous = pages["Anonymous pages"], let wired = pages["Pages wired down"],
              let compressor = pages["Pages occupied by compressor"], let fileBacked = pages["File-backed pages"] else {
            return nil
        }
        let purgeable = pages["Pages purgeable"] ?? 0
        // Each count is at most `largest`, so the sum cannot overflow.
        let usedPages = (anonymous > purgeable ? anonymous - purgeable : 0) + wired + compressor
        let used = bytes(usedPages, pageSize, atMost: total)
        return (total, total - used, bytes(fileBacked, pageSize, atMost: total))
    }

    /// pages times their size, at most `limit` (a guest's numbers may be anything).
    private static func bytes(_ pages: UInt64, _ size: UInt64, atMost limit: UInt64) -> UInt64 {
        let (product, overflow) = pages.multipliedReportingOverflow(by: size)
        return overflow ? limit : min(product, limit)
    }
}
