// Sources/AgentVMKit/Images/GuestSystem.swift
//
// What system an image or a box runs, as their records say it and as lists print it. A record
// written before there were Linux guests names no guest and is a macOS one.

import Foundation

/// The Linux system in an image, read from its /etc/os-release when the image was built or
/// last updated.
public struct LinuxSystem: Codable, Equatable, Sendable {
    /// ID: "debian".
    public var distribution: String
    /// VERSION_ID: "13".
    public var version: String
    /// PRETTY_NAME: "Debian GNU/Linux 13 (trixie)".
    public var name: String
    /// The kernel at the last boot a build saw: "6.12.48+deb13-cloud-arm64".
    public var kernel: String?
    /// "arm64".
    public var architecture: String
    /// The size in bytes of that kernel's memory pages (4096, 16384); nil in a record written
    /// before it was read.
    public var pageSize: Int?

    public init(distribution: String, version: String, name: String, kernel: String? = nil, architecture: String = "arm64", pageSize: Int? = nil) {
        self.distribution = distribution
        self.version = version
        self.name = name
        self.kernel = kernel
        self.architecture = architecture
        self.pageSize = pageSize
    }

    /// "Debian 13": the distribution as people write it, and its version.
    public var shortName: String {
        let names = ["debian": "Debian", "ubuntu": "Ubuntu", "fedora": "Fedora", "alpine": "Alpine", "arch": "Arch"]
        let distribution = names[distribution] ?? (self.distribution.isEmpty ? "Linux" : self.distribution.prefix(1).uppercased() + self.distribution.dropFirst())
        return version.isEmpty ? distribution : "\(distribution) \(version)"
    }
}

/// The words for a record's system. The texts for macOS are the ones lists always printed.
enum GuestSystemText {
    /// "macOS 27.0 (26A428)", or the Linux system's own name ("Debian GNU/Linux 13 (trixie)").
    static func description(guest: GuestKind, macOSVersion: String?, macOSBuild: String?, linux: LinuxSystem?) -> String {
        switch guest {
        case .macOS:
            return "macOS \(macOSVersion ?? "?") (\(macOSBuild ?? "?"))"
        case .linux:
            return linux.map { $0.name.isEmpty ? $0.shortName : $0.name } ?? "Linux"
        }
    }

    /// "macOS 27.0", "Debian 13".
    static func short(guest: GuestKind, macOSVersion: String?, linux: LinuxSystem?) -> String {
        switch guest {
        case .macOS:
            return "macOS \(macOSVersion ?? "?")"
        case .linux:
            return linux?.shortName ?? "Linux"
        }
    }

    /// The system by what tells two states of it apart: "macOS 26A428" (the build), "Debian 13".
    static func build(guest: GuestKind, macOSBuild: String?, linux: LinuxSystem?) -> String {
        switch guest {
        case .macOS:
            return "macOS \(macOSBuild ?? "?")"
        case .linux:
            return linux?.shortName ?? "Linux"
        }
    }
}

/// Why a command turns down a Linux image or box: what has no meaning for a Linux guest, and
/// what this agent-vm does not do for one yet.
enum LinuxGuest {
    /// `image update --macos` names macOS; the system's part of an update is `--system` for
    /// both guests.
    static func macOSOption(image: String) -> AgentVMError {
        return .notForThisGuest("--macos is for macOS images; image \(image) runs Linux: use --system")
    }

    /// The deprecated `image update-guest` boots the image itself; see `updatableImage`.
    static func noUpdateGuest(image: String) -> AgentVMError {
        return .notForThisGuest("image update-guest is not there for Linux images; use `agent-vm image update \(image) --guest`, which works on a copy of the image")
    }

    static func noFullDiskAccess(image: String) -> AgentVMError {
        return .notForThisGuest("image \(image) runs Linux: there is no Full Disk Access to grant")
    }

    static func noScreen(_ owner: String) -> AgentVMError {
        return .notForThisGuest("\(owner) runs Linux without a desktop, so it has no screen to show (an image built with a desktop recipe, such as linux-xfce, has one); open a shell with `agent-vm box shell <box>`")
    }

    /// A Linux box's account has no password to type (it logs in to its desktop by itself).
    static func noPassword(_ owner: String) -> AgentVMError {
        return .notForThisGuest("\(owner) runs Linux, whose account has no password to type")
    }
}

extension BoxRecord {
    /// Throws for a box without a screen (a Linux box without a desktop): `box view` shows it.
    public func requireScreen() throws {
        if !hasScreen {
            throw LinuxGuest.noScreen("box \(name)")
        }
    }

    /// Throws for a Linux box: `box view --type-password` types the account's password.
    public func requirePassword() throws {
        if effectiveGuest == .linux {
            throw LinuxGuest.noPassword("box \(name)")
        }
    }

}
