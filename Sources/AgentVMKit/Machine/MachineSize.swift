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

    /// The `box set` command that brings a box of these numbers down to what this Mac allows,
    /// changing only what is over. Memory is the limit rounded down, which `--memory-gb` can say.
    public static func fittingCommand(box: String, cpuCount: Int, memoryBytes: UInt64,
                                      maximumCPUs: Int = VZVirtualMachineConfiguration.maximumAllowedCPUCount,
                                      maximumMemoryBytes: UInt64 = VZVirtualMachineConfiguration.maximumAllowedMemorySize) -> String {
        var words = ["agent-vm", "box", "set", box]
        if cpuCount > maximumCPUs {
            words += ["--cpus", String(maximumCPUs)]
        }
        if memoryBytes > maximumMemoryBytes {
            words += ["--memory-gb", String(max(1, maximumMemoryBytes >> 30))]
        }
        return "`" + words.joined(separator: " ") + "`"
    }

    /// The least memory a box of the system starts with. A macOS box of 3 GB boots in the usual
    /// time and works, swapping from the start; at 2 GB and 1 GB its daemon never answers
    /// (measured 2026-10-03). A Linux box starts with 1 GB, the least `--memory-gb` takes (about
    /// 570 MB free, measured 2026-10-14 on Debian 13 with 16 KiB pages).
    public static func smallestMemory(for guest: GuestKind) -> UInt64 {
        return guest == .linux ? 1 << 30 : 3 << 30
    }

    /// Below this a box works, but too slowly or too tightly to recommend: 4 GB is what macOS
    /// itself asks for (it uses about 3 GB idle); a Linux box has no swap, so a program that
    /// needs more than is free is ended by the system, and an agent takes 0.3 to 1 GB. A Linux
    /// box with a desktop (`screen`) uses more: about 0.9 GB with XFCE, 1.1 to 1.4 GB with GNOME
    /// and 1.6 to 1.9 GB with KDE, against 0.7 GB without one (measured 2026-10-18 in boxes of
    /// 4 GB on Debian 13, idle after the login).
    public static func comfortableMemory(for guest: GuestKind, screen: Bool) -> UInt64 {
        return guest == .linux ? (screen ? 4 << 30 : 2 << 30) : 4 << 30
    }

    /// Why a box of `memoryBytes` cannot start, or nil.
    public static func memoryRefusal(memoryBytes: UInt64, guest: GuestKind) -> String? {
        let smallest = smallestMemory(for: guest)
        guard memoryBytes < smallest else {
            return nil
        }
        let system = guest == .linux ? "Linux" : "macOS"
        return "a \(system) box needs at least \(gigabytes(smallest)) GB of memory: with \(gigabytesText(memoryBytes)) GB, \(system) does not finish starting"
    }

    /// What to say about a box of `memoryBytes` that starts but is small for its system and its
    /// desktop, if it has one (`screen`), or nil.
    public static func smallMemoryNote(memoryBytes: UInt64, guest: GuestKind, screen: Bool) -> String? {
        let comfortable = comfortableMemory(for: guest, screen: screen)
        guard memoryBytes < comfortable else {
            return nil
        }
        switch guest {
        case .macOS:
            return "a macOS box of \(gigabytesText(memoryBytes)) GB starts, but macOS itself uses about 3 GB, so the box swaps from the start and builds are slow; \(gigabytes(comfortable)) GB is the least macOS asks for, and 8 GB suits an agent"
        case .linux:
            if screen {
                return "a Linux box of \(gigabytesText(memoryBytes)) GB with a desktop has little of it free and no swap: the system and its desktop use from 0.9 GB (XFCE) to 1.9 GB (KDE) of it, so a program that needs more, such as an agent session, a build or the application you try on the desktop, is ended by the system; \(gigabytes(comfortable)) GB or more suits a desktop and an agent"
            }
            return "a Linux box of \(gigabytesText(memoryBytes)) GB has only about half of it free and no swap, so a program that needs more, such as an agent session or a build, is ended by the system; \(gigabytes(comfortable)) GB or more suits an agent"
        }
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

    /// GB for a size said beside a whole limit: whole GB as is, else to a tenth, rounded down, so
    /// a box under 3 GB never reads as 3 (rounded up, 2.5 GB would read "at least 3 GB: with 3 GB").
    static func gigabytesText(_ bytes: UInt64) -> String {
        guard bytes & ((1 << 30) - 1) != 0 else {
            return String(bytes >> 30)
        }
        let tenths = ((bytes >> 20) * 10) >> 10
        return "\(tenths / 10).\(tenths % 10)"
    }
}
