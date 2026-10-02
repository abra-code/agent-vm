// Sources/AgentVMKit/FileSystem/RecordNumbers.swift
//
// The sizes in an image's or a box's record are added to and rounded in many places. A record
// is a file anyone with the store can damage, so its numbers are checked once, where it is
// read: far above any real machine, far below where a sum overflows (which stops a Swift
// program on the spot).

import Foundation

enum RecordNumbers {
    static let maximumCPUs = 1024
    /// 1 PB, for memory and for a disk.
    static let maximumBytes: UInt64 = 1 << 50
    /// An image's revision is counted up, and its recorded durations are shown as whole seconds.
    static let maximumRevision = 1 << 32
    /// 10 years.
    static let maximumSeconds: Double = 315_360_000

    /// Why these cannot be a machine's numbers, or nil.
    static func problem(cpuCount: Int, memoryBytes: UInt64, diskBytes: UInt64?) -> String? {
        guard (1...maximumCPUs).contains(cpuCount) else {
            return "it names \(cpuCount) CPUs"
        }
        guard (1...maximumBytes).contains(memoryBytes) else {
            return "it names \(memoryBytes) bytes of memory"
        }
        if let diskBytes, diskBytes > maximumBytes {
            return "it names a disk of \(diskBytes) bytes"
        }
        return nil
    }
}
