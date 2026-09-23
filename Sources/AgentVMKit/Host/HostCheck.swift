// Sources/AgentVMKit/Host/HostCheck.swift
//
// `agent-vm doctor`: can this Mac, and this binary, run boxes? The facts are gathered once
// (`HostFacts.current`) and judged by a pure function (`HostReport.evaluate`), so the rules
// are testable without a particular Mac or signature.
//
// The virtualization entitlement is the check that matters most: Virtualization refuses every
// configuration from a process without it, and `swift build` output is not signed with it.

import Darwin
import Foundation
import Security
import Virtualization

/// What doctor looks at. Every field is optional where the fact may be unobtainable (inside a
/// sandbox, for example), so an unknown fact is reported as unknown rather than as a failure.
public struct HostFacts: Sendable {
    public var osVersion: OperatingSystemVersion
    public var isAppleSilicon: Bool
    public var virtualizationSupported: Bool
    public var hasVirtualizationEntitlement: Bool?
    public var signature: Signature?
    public var cpuCount: Int
    public var memoryBytes: UInt64
    public var storeRoot: String
    /// Bytes available for important use on the store's volume (APFS counts purgeable space).
    public var storeFreeBytes: Int64?
    /// Virtualization framework VM processes on this Mac, from any application.
    public var runningVirtualMachines: Int?

    public struct Signature: Sendable, Equatable, Codable {
        public var isAdHoc: Bool
        public var teamIdentifier: String?
        public var hardenedRuntime: Bool

        public init(isAdHoc: Bool, teamIdentifier: String?, hardenedRuntime: Bool) {
            self.isAdHoc = isAdHoc
            self.teamIdentifier = teamIdentifier
            self.hardenedRuntime = hardenedRuntime
        }
    }

    public init(osVersion: OperatingSystemVersion, isAppleSilicon: Bool, virtualizationSupported: Bool,
                hasVirtualizationEntitlement: Bool?, signature: Signature?, cpuCount: Int,
                memoryBytes: UInt64, storeRoot: String, storeFreeBytes: Int64?,
                runningVirtualMachines: Int?) {
        self.osVersion = osVersion
        self.isAppleSilicon = isAppleSilicon
        self.virtualizationSupported = virtualizationSupported
        self.hasVirtualizationEntitlement = hasVirtualizationEntitlement
        self.signature = signature
        self.cpuCount = cpuCount
        self.memoryBytes = memoryBytes
        self.storeRoot = storeRoot
        self.storeFreeBytes = storeFreeBytes
        self.runningVirtualMachines = runningVirtualMachines
    }

    static let virtualizationEntitlement = "com.apple.security.virtualization"
    static let virtualMachineServicePath = "/System/Library/Frameworks/Virtualization.framework/Versions/A/XPCServices/com.apple.Virtualization.VirtualMachine.xpc/Contents/MacOS/com.apple.Virtualization.VirtualMachine"

    /// The facts for this process on this Mac.
    public static func current(storeRoot: URL) -> HostFacts {
        return HostFacts(
            osVersion: ProcessInfo.processInfo.operatingSystemVersion,
            isAppleSilicon: isArm64(),
            virtualizationSupported: VZVirtualMachine.isSupported,
            hasVirtualizationEntitlement: entitlement(virtualizationEntitlement),
            signature: ownSignature(),
            cpuCount: ProcessInfo.processInfo.activeProcessorCount,
            memoryBytes: ProcessInfo.processInfo.physicalMemory,
            storeRoot: storeRoot.path,
            storeFreeBytes: freeBytes(nearest: storeRoot),
            runningVirtualMachines: countVirtualMachineProcesses()
        )
    }

    private static func isArm64() -> Bool {
        #if arch(arm64)
        return true
        #else
        // An x86_64 build may still run under Rosetta on Apple silicon, where it cannot start a
        // macOS guest either; report the architecture of this binary, which is what matters.
        return false
        #endif
    }

    /// The kernel's view of one boolean entitlement of this process; nil if it cannot be read.
    private static func entitlement(_ name: String) -> Bool? {
        guard let task = SecTaskCreateFromSelf(kCFAllocatorDefault) else {
            return nil
        }
        var error: Unmanaged<CFError>?
        let value = SecTaskCopyValueForEntitlement(task, name as CFString, &error)
        if let error {
            error.release()
            return nil
        }
        return (value as? Bool) ?? false
    }

    private static func ownSignature() -> Signature? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else {
            return nil
        }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else {
            return nil
        }
        var information: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSSigningInformation)
        guard SecCodeCopySigningInformation(staticCode, flags, &information) == errSecSuccess,
              let dictionary = information as? [String: Any] else {
            return nil
        }
        // An unsigned binary has no flags entry at all; treat it like ad hoc (neither can be
        // distributed, and doctor's advice is the same).
        let codeFlags = (dictionary[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value ?? SecCodeSignatureFlags.adhoc.rawValue
        return Signature(
            isAdHoc: codeFlags & SecCodeSignatureFlags.adhoc.rawValue != 0,
            teamIdentifier: dictionary[kSecCodeInfoTeamIdentifier as String] as? String,
            hardenedRuntime: codeFlags & SecCodeSignatureFlags.runtime.rawValue != 0
        )
    }

    /// Free space on the volume of `url`, or of its nearest existing ancestor (the store may
    /// not exist yet).
    private static func freeBytes(nearest url: URL) -> Int64? {
        var candidate = url.standardizedFileURL
        while !FileManager.default.fileExists(atPath: candidate.path) {
            let parent = candidate.deletingLastPathComponent()
            if parent.path == candidate.path {
                return nil
            }
            candidate = parent
        }
        let values = try? candidate.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        // Inside a sandbox the important-usage figure comes back as 0 while the plain one is
        // right; fall back to the plain figure rather than report a full disk.
        if let important = values?.volumeAvailableCapacityForImportantUsage, important > 0 {
            return important
        }
        return values?.volumeAvailableCapacity.map { Int64($0) }
    }

    /// Counts processes running Virtualization's VM service, one per running VM of any
    /// application. Nil when the process list cannot be read (for example inside a sandbox).
    private static func countVirtualMachineProcesses() -> Int? {
        let capacity = proc_listallpids(nil, 0)
        guard capacity > 0 else {
            return nil
        }
        var pids = [pid_t](repeating: 0, count: Int(capacity) + 64)
        let filled = pids.withUnsafeMutableBytes { buffer in
            proc_listallpids(buffer.baseAddress, Int32(buffer.count))
        }
        guard filled > 0 else {
            return nil
        }
        var count = 0
        var readAny = false
        var path = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        for pid in pids.prefix(Int(filled)) where pid > 0 {
            let length = proc_pidpath(pid, &path, UInt32(path.count))
            guard length > 0 else {
                continue
            }
            readAny = true
            if strcmp(path, virtualMachineServicePath) == 0 {
                count += 1
            }
        }
        return readAny ? count : nil
    }
}

/// One line of doctor's report.
public struct HostCheck: Sendable, Equatable, Codable {
    public enum Status: String, Sendable, Codable {
        case ok, info, warning, failure
    }

    public var name: String
    public var status: Status
    public var detail: String
}

public struct HostReport: Sendable, Equatable, Codable {
    public var checks: [HostCheck]

    /// True when nothing prevents running boxes (warnings allowed).
    public var canRunBoxes: Bool {
        return !checks.contains { $0.status == .failure }
    }

    /// Free space below which doctor warns: a golden macOS image takes tens of GB, and every
    /// box grows its clone as the guest writes.
    public static let lowSpaceBytes: Int64 = 50 << 30

    /// macOS allows at most two macOS guests at a time, whichever applications run them.
    public static let macOSGuestLimit = 2

    public static func evaluate(_ facts: HostFacts) -> HostReport {
        var checks: [HostCheck] = []
        let os = facts.osVersion
        let osText = "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
        if os.majorVersion >= 27 {
            checks.append(HostCheck(name: "macOS", status: .ok, detail: "macOS \(osText)"))
        } else {
            checks.append(HostCheck(name: "macOS", status: .failure, detail: "macOS \(osText); agent-vm needs macOS 27 or later (zero-click guest setup)"))
        }

        if facts.isAppleSilicon && facts.virtualizationSupported {
            checks.append(HostCheck(name: "virtualization", status: .ok, detail: "supported; this Mac has \(facts.cpuCount) CPU cores and \(facts.memoryBytes >> 30) GB of memory to share with boxes"))
        } else if !facts.isAppleSilicon {
            checks.append(HostCheck(name: "virtualization", status: .failure, detail: "macOS guests need an Apple silicon Mac and an arm64 build of agent-vm"))
        } else {
            checks.append(HostCheck(name: "virtualization", status: .failure, detail: "Virtualization reports that this process cannot run virtual machines; agent-vm may be running inside a virtual machine, or under a sandbox that blocks virtualization (for example one inherited from the program that started it)"))
        }

        switch facts.hasVirtualizationEntitlement {
        case true?:
            checks.append(HostCheck(name: "entitlement", status: .ok, detail: "\(HostFacts.virtualizationEntitlement) present"))
        case false?:
            checks.append(HostCheck(name: "entitlement", status: .failure, detail: "this binary lacks \(HostFacts.virtualizationEntitlement), so every VM will be refused; build with Scripts/build.sh, which signs it"))
        case nil:
            checks.append(HostCheck(name: "entitlement", status: .warning, detail: "could not read this binary's entitlements"))
        }

        if let signature = facts.signature {
            if signature.isAdHoc {
                checks.append(HostCheck(name: "signature", status: .info, detail: "ad hoc: runs on this Mac only; sign with a Developer ID to distribute"))
            } else {
                let team = signature.teamIdentifier ?? "unknown team"
                let runtime = signature.hardenedRuntime ? "hardened runtime" : "no hardened runtime (needed for notarization)"
                checks.append(HostCheck(name: "signature", status: signature.hardenedRuntime ? .ok : .warning, detail: "team \(team), \(runtime)"))
            }
        } else {
            checks.append(HostCheck(name: "signature", status: .warning, detail: "could not read this binary's signature"))
        }

        if let free = facts.storeFreeBytes {
            let text = "\(free >> 30) GB free on the volume of \(facts.storeRoot)"
            if free < lowSpaceBytes {
                checks.append(HostCheck(name: "disk space", status: .warning, detail: "\(text); a macOS image needs tens of GB (\(lowSpaceBytes >> 30) GB or more recommended)"))
            } else {
                checks.append(HostCheck(name: "disk space", status: .ok, detail: text))
            }
        } else {
            checks.append(HostCheck(name: "disk space", status: .warning, detail: "could not read free space for \(facts.storeRoot)"))
        }

        if let running = facts.runningVirtualMachines {
            let text = "\(running) virtual machine\(running == 1 ? "" : "s") running on this Mac (any application)"
            if running >= macOSGuestLimit {
                checks.append(HostCheck(name: "running VMs", status: .warning, detail: "\(text); macOS runs at most \(macOSGuestLimit) macOS guests at once, so a box will not start while those are macOS guests"))
            } else {
                checks.append(HostCheck(name: "running VMs", status: .ok, detail: text))
            }
        } else {
            checks.append(HostCheck(name: "running VMs", status: .info, detail: "could not list processes (sandboxed?); at most \(macOSGuestLimit) macOS guests can run at once"))
        }
        return HostReport(checks: checks)
    }
}
