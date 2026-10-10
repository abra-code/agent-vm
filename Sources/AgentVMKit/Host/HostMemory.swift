// Sources/AgentVMKit/Host/HostMemory.swift
//
// How much memory this Mac has to give right now, read before an image job boots a Linux guest
// on a kernel with pages smaller than the Mac's. Such a guest can lose memory of its kernel's
// own when the Mac runs short of memory and pushes the guest's memory out (LinuxPageNote), and
// a build that meets that fails, maybe after a long download. So a Mac with little to spare
// gets a note before the boot, and one with nothing to spare is refused. The reading
// (`current`) and the judgment (`verdict`) are apart, so the rules are testable without a
// particular Mac.

import Darwin
import Foundation

public struct HostMemory: Sendable, Equatable {
    /// What macOS itself says of its memory (`kern.memorystatus_vm_pressure_level`).
    public enum Pressure: Sendable, Equatable {
        case normal, warning, critical
    }

    public enum Verdict: Sendable, Equatable {
        case enough
        /// Little to spare: the job goes on, with these words.
        case tight(String)
        /// Nothing to spare: the job is refused, with these words.
        case exhausted(String)
    }

    /// Memory macOS can give without compressing or swapping anything: free pages, pages that
    /// hold files' contents, and pages their owners said can go.
    public var availableBytes: UInt64
    public var pressure: Pressure

    public init(availableBytes: UInt64, pressure: Pressure) {
        self.availableBytes = availableBytes
        self.pressure = pressure
    }

    /// With less than this available, and macOS reporting memory pressure, a guest is not
    /// booted. Without that report so little is only a note: on a Mac that runs boxes the
    /// figure is often low while macOS is at ease (a guest's memory is not a file's).
    public static let floorBytes: UInt64 = 1 << 30

    /// This Mac's memory now; nil when the kernel does not say (nothing is judged then).
    public static func current() -> HostMemory? {
        var statistics = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &statistics) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count) }
        }
        guard result == KERN_SUCCESS else {
            return nil
        }
        // The free count has the speculative pages in it (read ahead from files), and so has the
        // count of pages that hold files' contents: taken out of one, not to count them twice.
        let free = UInt64(statistics.free_count) - min(UInt64(statistics.speculative_count), UInt64(statistics.free_count))
        let pages = free + UInt64(statistics.external_page_count) + UInt64(statistics.purgeable_count)
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        // A level that cannot be read counts as normal: the available bytes still speak.
        let read = sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0)
        let pressure: Pressure = read != 0 ? .normal : level >= 4 ? .critical : level >= 2 ? .warning : .normal
        return HostMemory(availableBytes: pages * UInt64(getpagesize()), pressure: pressure)
    }

    /// Whether a guest of `guestBytes` should boot on a kernel with small pages now. `what`
    /// names the boot for the reader ("the first boot of a Linux image").
    public func verdict(guestBytes: UInt64, what: String) -> Verdict {
        let spare = "about \(Self.amount(availableBytes)) of memory to spare"
        let reported = pressure == .normal ? "" : ", and macOS reports memory pressure (\(pressure == .critical ? "critical" : "warning"))"
        let why = "\(what) runs on a kernel with 4 KiB memory pages, which can lose kernel memory and fail when the Mac runs short of memory (macOS 27)"
        if pressure == .critical || (pressure == .warning && availableBytes < Self.floorBytes) {
            return .exhausted("this Mac has \(spare)\(reported); \(why). Quit programs that use much memory or stop running boxes, and try again")
        }
        if pressure == .warning || availableBytes < guestBytes {
            return .tight("this Mac has \(spare) for a guest of \(MachineSize.gigabytes(guestBytes)) GB\(reported); \(why). If it fails, quit programs that use much memory and try again")
        }
        return .enough
    }

    /// "512 MB" below one GB, "3.4 GB" above.
    static func amount(_ bytes: UInt64) -> String {
        if bytes < 1 << 30 {
            return "\(bytes >> 20) MB"
        }
        return String(format: "%.1f GB", Double(bytes) / Double(1 << 30))
    }
}
