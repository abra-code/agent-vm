// Sources/AgentVMKit/Boxes/ProjectShare.swift
//
// A project folder shared into a box at the same absolute path it has on the Mac, so paths in
// build logs, error messages and editor links mean the same thing on both sides. One virtio
// file system device per box, empty at start; the supervisor fills it on the running machine
// and the guest daemon mounts it (as root) with mount_virtiofs. One project at a time per box:
// switching unmounts the previous one, which fails while programs in the box still use it.
//
// Measured on macOS 27 guests (the reasons for the details below):
// - The device uses Apple's automount tag. With any other tag the guest treats the mount as a
//   network volume: every program not run as root waits on a privacy (TCC) prompt nobody can
//   see, and system binaries are refused outright. With the automount tag the volume is
//   local, file owners map to the box user, and no prompt appears.
// - A local volume gets .fseventsd and .Trashes at its root. So the share is a synthetic,
//   read-only root holding one entry named after the project, mounted on the project's parent
//   folder: the project keeps its exact path (pwd -P is the same), and nothing is written
//   into it.
// - Large files are fast (1 GB written in 0.7 s), many small files are 6-30 times slower
//   than the guest's own disk: keep build products inside the box.

import Foundation

public enum ProjectShare {
    /// Apple's automount tag (`VZVirtioFileSystemDeviceConfiguration.macOSGuestAutomountTag`);
    /// see above for why.
    public static let tag = "com.apple.virtio-fs.automount"

    /// The canonical folder for `path`, or why it cannot be shared: the session rules (exists,
    /// a folder, not the disk or the home folder or a folder containing it, clear of the
    /// agent-vm store), and nothing inside ~/Library or a hidden folder of the home folder
    /// (keychains, keys, application data).
    public static func validated(_ path: String, storeRoot: URL) throws -> String {
        let project = try SessionStore(root: storeRoot).validatedProject(path)
        // The share is mounted on the parent folder, which cannot be the guest's root.
        guard (project as NSString).deletingLastPathComponent != "/" else {
            throw AgentVMError.unsuitableProject(path: project, reason: "a folder directly in / cannot be shared; move it one level down")
        }
        // By file identity, not by path (see FileSystem.identity); the home folder and the
        // folders above it are refused by the session rules already.
        let home = (try? FileSystem.canonicalPath(NSHomeDirectory())) ?? NSHomeDirectory()
        guard let homeID = FileSystem.identity(home) else {
            throw AgentVMError.unsuitableProject(path: project, reason: "your home folder cannot be examined")
        }
        var folder = project
        var first = ""
        while folder != "/" {
            if FileSystem.identity(folder) == homeID {
                if first.lowercased() == "library" || first.hasPrefix(".") {
                    throw AgentVMError.unsuitableProject(path: project, reason: "it is inside ~/\(first), which holds keys and application data; share a project folder")
                }
                break
            }
            first = (folder as NSString).lastPathComponent
            folder = (folder as NSString).deletingLastPathComponent
        }
        return project
    }

    /// What the guest runs, as root, to mount the share for the project at `path`: the
    /// synthetic root goes on the project's parent, so the project has its own path.
    static func mountRequests(_ path: String) -> [GuestRequest] {
        let parent = (path as NSString).deletingLastPathComponent
        return [
            GuestRequest(op: .exec, argv: ["/bin/mkdir", "-p", parent], cwd: "/", user: "root"),
            GuestRequest(op: .exec, argv: ["/sbin/mount_virtiofs", tag, parent], cwd: "/", user: "root"),
        ]
    }

    /// What the guest runs, as root, after creating the parent: prints the first thing in it
    /// that is not a folder. The mount would hide it (the box's /tmp, a home folder, ...);
    /// folders alone are left over from earlier mounts.
    static func parentContentsRequest(_ path: String) -> GuestRequest {
        let parent = (path as NSString).deletingLastPathComponent
        return GuestRequest(op: .exec, argv: ["/usr/bin/find", parent, "-mindepth", "1", "!", "-type", "d", "-print", "-quit"], cwd: "/", user: "root")
    }

    /// What the guest runs, as root, to unmount the share for the project at `path`. Succeeds
    /// when nothing is mounted there any more (the guest unmounted it, or a failed share never
    /// mounted it), so a lost mount cannot block every later share.
    static func unmountRequest(_ path: String) -> GuestRequest {
        let script = #"[ -d "$1" ] || exit 0; a=$(/usr/bin/stat -f %d "$1") && b=$(/usr/bin/stat -f %d "$1/..") || exit 1; [ "$a" = "$b" ] && exit 0; exec /sbin/umount "$1""#
        return GuestRequest(op: .exec, argv: ["/bin/sh", "-c", script, "sh", (path as NSString).deletingLastPathComponent], cwd: "/", user: "root")
    }
}
