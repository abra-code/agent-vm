// Sources/AgentVMKit/Machine/MachineProcess.swift
//
// The process that holds a running guest's memory. Virtualization runs each machine in an XPC
// service process of its own (com.apple.Virtualization.VirtualMachine, a child of launchd, not
// of the supervisor), and names no process id for it. That process keeps the machine's disk
// file open (measured on macOS 27.2 with lsof), so the one whose open files include the box's
// disk, by device and inode, is the box's. Only public libproc calls are used; they work on
// processes of this user, and fail inside a sandbox that hides other processes.

import Darwin
import Foundation

enum MachineProcess {
    /// The XPC service's executable name, the last part of its path.
    static let executableName = "com.apple.Virtualization.VirtualMachine"

    /// The Virtualization process that has `disk` open, or nil with the reason.
    static func find(holding disk: URL) -> Result<pid_t, Failure> {
        var info = stat()
        guard stat(disk.path, &info) == 0 else {
            return .failure(Failure("cannot read \(disk.path) (\(String(cString: strerror(errno))))"))
        }
        let candidates = virtualizationProcesses()
        if candidates.isEmpty {
            return .failure(Failure("no Virtualization process of this user can be seen"))
        }
        for pid in candidates where holds(pid, device: info.st_dev, inode: info.st_ino) {
            return .success(pid)
        }
        return .failure(Failure("none of the \(candidates.count) Virtualization processes that can be seen holds \(disk.path)"))
    }

    /// Whether `pid` is still a Virtualization process that has the file open.
    static func stillHolds(_ pid: pid_t, disk: URL) -> Bool {
        var info = stat()
        guard stat(disk.path, &info) == 0, isVirtualization(pid) else {
            return false
        }
        return holds(pid, device: info.st_dev, inode: info.st_ino)
    }

    /// The physical footprint of `pid` (RUSAGE_INFO_V4 ri_phys_footprint): resident memory and
    /// memory in the compressor, as Activity Monitor's Memory column shows it.
    static func footprint(of pid: pid_t) -> Result<UInt64, Failure> {
        var usage = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &usage) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
        }
        guard result == 0 else {
            return .failure(Failure("the footprint of process \(pid) cannot be read (\(String(cString: strerror(errno))))"))
        }
        return .success(usage.ri_phys_footprint)
    }

    struct Failure: Error, CustomStringConvertible {
        var description: String

        init(_ description: String) {
            self.description = description
        }
    }

    // MARK: - libproc

    /// Every process id this process can see whose executable is the Virtualization service's.
    private static func virtualizationProcesses() -> [pid_t] {
        // The count can grow between the two calls; room for more is asked for.
        let estimate = proc_listallpids(nil, 0)
        guard estimate > 0 else {
            return []
        }
        var pids = [pid_t](repeating: 0, count: Int(estimate) + 64)
        let filled = pids.withUnsafeMutableBytes { raw in
            proc_listallpids(raw.baseAddress, Int32(raw.count))
        }
        guard filled > 0 else {
            return []
        }
        return pids.prefix(min(Int(filled), pids.count)).filter { $0 > 0 && isVirtualization($0) }
    }

    private static func isVirtualization(_ pid: pid_t) -> Bool {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else {
            return false
        }
        let path = String(decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return (path as NSString).lastPathComponent == executableName
    }

    /// Whether one of `pid`'s open files is the file with this device and inode.
    private static func holds(_ pid: pid_t, device: dev_t, inode: ino_t) -> Bool {
        let size = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard size > 0 else {
            return false
        }
        let stride = MemoryLayout<proc_fdinfo>.stride
        // Room for a few opened meanwhile.
        var descriptors = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(size) / stride + 16)
        let filled = descriptors.withUnsafeMutableBytes { raw in
            proc_pidinfo(pid, PROC_PIDLISTFDS, 0, raw.baseAddress, Int32(raw.count))
        }
        guard filled > 0 else {
            return false
        }
        for descriptor in descriptors.prefix(min(Int(filled) / stride, descriptors.count))
        where descriptor.proc_fdtype == UInt32(PROX_FDTYPE_VNODE) {
            var vnode = vnode_fdinfowithpath()
            let got = proc_pidfdinfo(pid, descriptor.proc_fd, PROC_PIDFDVNODEPATHINFO, &vnode, Int32(MemoryLayout<vnode_fdinfowithpath>.size))
            guard got == Int32(MemoryLayout<vnode_fdinfowithpath>.size) else {
                continue
            }
            let stat = vnode.pvip.vip_vi.vi_stat
            if stat.vst_dev == device && stat.vst_ino == inode {
                return true
            }
        }
        return false
    }
}
