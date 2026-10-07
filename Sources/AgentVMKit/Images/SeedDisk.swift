// Sources/AgentVMKit/Images/SeedDisk.swift
//
// The small disk a new Linux image reads once, on its first boot. A distribution's cloud image
// runs cloud-init, which looks for a volume labeled "cidata" and does what the `user-data` file
// on it says. Here that is one thing: install the guest daemon from the same disk and start it.
// The account, the packages and every setting are made afterwards by the Mac, through the
// daemon, as logged steps. So there is no SSH, no password and no key in a Linux image's
// build, and the disk holds no secret: the guest keeps a copy of `user-data`, and all it says
// is how the daemon was installed.

import Foundation

enum SeedDisk {
    /// The volume label cloud-init looks for.
    static let label = "cidata"
    static let daemonName = "agent-vm-guest"
    static let unitName = GuestDaemon.linuxUnitName
    /// Where the first boot mounts the disk while it copies from it.
    static let mountPoint = "/run/agent-vm-seed"

    /// What cloud-init is told. `users: []` keeps it from creating the distribution's default
    /// account, which would have sudo without a password. The command checks the daemon it
    /// copied against `daemonDigest` (SHA-256), so a daemon damaged on the way is not started.
    static func userData(daemonDigest: String) -> String {
        let install = [
            "/usr/bin/mkdir -p \(mountPoint)",
            "/usr/bin/mount -o ro /dev/disk/by-label/\(label) \(mountPoint)",
            "/usr/bin/install -D -m 755 -o root -g root \(mountPoint)/\(daemonName) \(GuestDaemon.executablePath)",
            "/usr/bin/echo '\(daemonDigest)  \(GuestDaemon.executablePath)' | /usr/bin/sha256sum -c --status",
            "/usr/bin/install -m 644 -o root -g root \(mountPoint)/\(unitName) \(GuestDaemon.linuxUnitPath)",
            "/usr/bin/umount \(mountPoint)",
            "/usr/bin/systemctl daemon-reload",
            "/usr/bin/systemctl enable --now \(GuestDaemon.linuxUnitName)",
        ].joined(separator: " && ")
        return """
            #cloud-config
            users: []
            ssh_pwauth: false
            runcmd:
              - [ /bin/sh, -c, "\(install)" ]

            """
    }

    /// The instance id is new for every image, so cloud-init treats the boot as a first one;
    /// every box of every image is the host "box".
    static func metaData(instance: String) -> String {
        return "instance-id: \(instance)\nlocal-hostname: box\n"
    }

    /// Makes the disk at `url` from the Linux daemon at `daemon` and the unit text. hdiutil is
    /// part of every macOS; it writes an ISO 9660 image with long (Joliet) names.
    static func make(at url: URL, daemon: URL, unit: String, instance: String) throws {
        let digest = try ImageBuilder.sha256(of: daemon)
        let work = url.deletingLastPathComponent().appendingPathComponent(".seed-\(UUID().uuidString)", isDirectory: true)
        try FileSystem.makeDirectories(work.path)
        defer { try? FileSystem.removeTree(work.path) }
        do {
            try Data(userData(daemonDigest: digest).utf8).write(to: work.appendingPathComponent("user-data"))
            try Data(metaData(instance: instance).utf8).write(to: work.appendingPathComponent("meta-data"))
            try Data(unit.utf8).write(to: work.appendingPathComponent(unitName))
        } catch {
            throw AgentVMError.system(operation: "write the seed disk's files in \(work.path)", code: FileSystem.posixCode(error))
        }
        // A clone: the daemon is 55 MB, and the copy is gone again in a moment.
        try BoxStore.cloneFile(daemon, to: work.appendingPathComponent(daemonName))
        try? FileManager.default.removeItem(at: url)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = ["makehybrid", "-quiet", "-iso", "-joliet", "-default-volume-name", label, "-o", url.path, work.path]
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        let errors = Pipe()
        process.standardError = errors
        do {
            try process.run()
        } catch {
            throw AgentVMError.hostNotReady("cannot run /usr/bin/hdiutil to make the seed disk: \(error.localizedDescription)")
        }
        let said = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        guard process.terminationStatus == 0, FileSystem.exists(url.path) else {
            throw AgentVMError.hostNotReady("hdiutil could not make the seed disk \(url.path) (status \(process.terminationStatus)): \(Printable.line(said, limit: 300))")
        }
    }
}
