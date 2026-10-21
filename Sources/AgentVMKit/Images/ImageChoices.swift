// Sources/AgentVMKit/Images/ImageChoices.swift
//
// What a new image can be, said for a program that offers the choice (`version --json`): the
// Linux systems `image create --linux` takes, and for each kind of guest the sizes a new image
// gets and the ones that are refused. Everything here is what this build holds: no store is
// read and nothing is asked of the network.

import Foundation

/// One Linux system `image create --linux` takes.
public struct LinuxRelease: Encodable, Sendable, Equatable {
    /// The word `--linux` takes: lower-case letters, digits, "." and "-", not starting with "-".
    public var id: String
    /// For people: "Debian 13".
    public var name: String
    public var distribution: String
    public var version: String

    public init(_ base: LinuxBase) {
        id = base.id
        name = base.name
        distribution = base.distribution
        version = base.version
    }

    /// Every system `image create --linux` builds, in the order of `LinuxBase.known`: the newest of each
    /// distribution first.
    public static var all: [LinuxRelease] {
        return LinuxBase.known.map(LinuxRelease.init)
    }

    /// Whether a word can be an id: what a client may check before it puts one on a command line.
    public static func isValidID(_ id: String) -> Bool {
        guard let first = id.utf8.first, first != UInt8(ascii: "-") else {
            return false
        }
        return id.utf8.allSatisfy { byte in
            (byte >= UInt8(ascii: "a") && byte <= UInt8(ascii: "z")) || (byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9"))
                || byte == UInt8(ascii: ".") || byte == UInt8(ascii: "-")
        }
    }
}

/// The sizes of a new image of one kind of guest: what `image create` uses when an option is
/// not given, and what it refuses.
public struct ImageSizes: Encodable, Sendable, Equatable {
    /// The defaults of `--cpus`, `--memory-gb` and `--disk-gb` for an image built from nothing.
    public var cpuCount: Int
    public var memoryBytes: UInt64
    public var diskBytes: UInt64
    /// The smallest disk an image built from nothing may have.
    public var minimumDiskBytes: UInt64
    /// With `--from` and a larger disk: the least it may be larger by.
    public var minimumDiskGrowthBytes: UInt64

    public static func of(_ guest: GuestKind) -> ImageSizes {
        switch guest {
        case .macOS:
            return ImageSizes(cpuCount: ImageBuildOptions.defaultCPUCount, memoryBytes: ImageBuildOptions.defaultMemoryBytes,
                              diskBytes: ImageBuildOptions.defaultDiskBytes, minimumDiskBytes: ImageBuildOptions.minimumDiskBytes,
                              minimumDiskGrowthBytes: ImageBuilder.minimumDiskGrowth)
        case .linux:
            return ImageSizes(cpuCount: LinuxImageBuildOptions.defaultCPUCount, memoryBytes: LinuxImageBuildOptions.defaultMemoryBytes,
                              diskBytes: LinuxImageBuildOptions.defaultDiskBytes, minimumDiskBytes: LinuxImageBuildOptions.minimumDiskBytes,
                              minimumDiskGrowthBytes: ImageBuilder.minimumLinuxDiskGrowth)
        }
    }

    /// The sizes of every kind of guest, under the word `guest` has in the lists ("macos", "linux").
    public static var all: [String: ImageSizes] {
        return Dictionary(uniqueKeysWithValues: GuestKind.allCases.map { ($0.rawValue, ImageSizes.of($0)) })
    }
}
