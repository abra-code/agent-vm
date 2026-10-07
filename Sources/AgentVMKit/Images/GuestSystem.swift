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

    public init(distribution: String, version: String, name: String, kernel: String? = nil, architecture: String = "arm64") {
        self.distribution = distribution
        self.version = version
        self.name = name
        self.kernel = kernel
        self.architecture = architecture
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
    /// What this agent-vm does not do with a Linux image yet: `what` is "build an image from",
    /// "update" or "rebuild".
    static func cannotYet(_ what: String, image: String) -> AgentVMError {
        return .notForThisGuest("image \(image) runs Linux, and this agent-vm cannot \(what) a Linux image yet")
    }

    static func noFullDiskAccess(image: String) -> AgentVMError {
        return .notForThisGuest("image \(image) runs Linux: there is no Full Disk Access to grant")
    }

    static func noScreen(_ owner: String) -> AgentVMError {
        return .notForThisGuest("\(owner) runs Linux, which has no screen to show; open a shell with `agent-vm box shell <box>`")
    }

    static func noSendYet(box: String) -> AgentVMError {
        return .notForThisGuest("box send is not there for Linux boxes yet; put the file in the shared project folder, or pipe it: `agent-vm exec --box \(box) -- sh -c 'cat > f' < f`")
    }
}

extension BoxRecord {
    /// Throws for a Linux box: `box view` shows a screen.
    public func requireScreen() throws {
        if effectiveGuest == .linux {
            throw LinuxGuest.noScreen("box \(name)")
        }
    }

    /// Throws for a Linux box: `box send` packs for a Mac.
    public func requireSend() throws {
        if effectiveGuest == .linux {
            throw LinuxGuest.noSendYet(box: name)
        }
    }
}
