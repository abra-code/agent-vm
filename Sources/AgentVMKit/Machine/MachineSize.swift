// Sources/AgentVMKit/Machine/MachineSize.swift
//
// A box's CPUs and memory against the Mac it runs on. Two questions: can this Mac run a machine
// of that size at all (asked when a size is given, so the refusal comes then and not at the
// next start), and do the boxes that run together leave the Mac enough memory (asked at start,
// and only said: it works, slowly).

import Foundation
import Virtualization

public enum MachineSize {
    /// What the Mac needs for itself beside its boxes. A box costs the Mac close to its whole
    /// memory once it has been busy: the Mac hands pages over as the guest first uses them and
    /// gets none back before the box stops.
    public static let hostReserveBytes: UInt64 = 6 << 30

    /// Why this Mac cannot run a machine of that size, or nil. A nil value is not checked.
    public static func problem(cpuCount: Int?, memoryBytes: UInt64?,
                               maximumCPUs: Int = VZVirtualMachineConfiguration.maximumAllowedCPUCount,
                               maximumMemoryBytes: UInt64 = VZVirtualMachineConfiguration.maximumAllowedMemorySize) -> String? {
        if let cpuCount, cpuCount > maximumCPUs {
            return "\(cpuCount) CPUs are more than this Mac allows a box (\(maximumCPUs))"
        }
        if let memoryBytes, memoryBytes > maximumMemoryBytes {
            return "\(gigabytes(memoryBytes)) GB of memory are more than this Mac allows a box (\(gigabytes(maximumMemoryBytes)) GB)"
        }
        return nil
    }

    /// What to say when a box of `starting` bytes starts beside boxes of `running` bytes on a
    /// Mac with `hostBytes`, or nil when the Mac keeps its reserve.
    public static func memoryWarning(starting: UInt64, running: [UInt64], hostBytes: UInt64 = ProcessInfo.processInfo.physicalMemory) -> String? {
        var total = starting
        for bytes in running {
            let (sum, overflow) = total.addingReportingOverflow(bytes)
            total = overflow ? UInt64.max : sum
        }
        guard hostBytes < hostReserveBytes || total > hostBytes - hostReserveBytes else {
            return nil
        }
        let subject = running.isEmpty ? "this box has" : "with this box (\(gigabytes(starting)) GB) and \(running.count) already running, boxes have"
        return "\(subject) \(gigabytes(total)) GB of this Mac's \(gigabytes(hostBytes)) GB of memory; the Mac and the boxes may get slow. `agent-vm box set <box> --memory-gb N` changes a stopped box's memory."
    }

    /// Whole GB, rounded up, so 3.5 GB is not shown as 3.
    static func gigabytes(_ bytes: UInt64) -> UInt64 {
        return (bytes >> 30) + (bytes & ((1 << 30) - 1) == 0 ? 0 : 1)
    }
}
