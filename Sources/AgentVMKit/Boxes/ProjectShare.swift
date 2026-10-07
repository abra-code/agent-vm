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

    /// The tag of a Linux box's device. Apple's automount tag means nothing to Linux, and a
    /// name of its own says whose device it is in the guest's mount table.
    public static let linuxTag = "agent-vm-project"

    /// The tag of the project share device in a guest of this kind.
    public static func tag(for guest: GuestKind) -> String {
        return guest == .linux ? linuxTag : tag
    }

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

    // MARK: - Linux
    //
    // A Linux guest mounts the folder itself at its own path: there is no privacy system that
    // treats the mount as a network volume, and nothing writes into a volume's root, so the
    // synthetic root and the mount on the parent are not needed.
    //
    // Measured on Debian 13 guests: Apple's virtiofs reports every file as owned by whoever
    // asks, and remembers the answer for about a second. So nothing here looks at the mounted
    // folder as root: after root's look the box user would see root's files for a second, and
    // git would refuse the repository ("dubious ownership"). The mount itself does not
    // disturb it. git is told, besides, that the project is a safe place (`safeDirectoryRequest`),
    // for when a person runs something as root in the project and git as the user right after.

    /// What the guest runs, as root, to mount the share for the project at `path`: for Linux,
    /// on the path itself.
    static func mountRequests(_ path: String, guest: GuestKind, readOnly: Bool) -> [GuestRequest] {
        guard guest == .linux else {
            return mountRequests(path)
        }
        // nosuid and nodev: a file on the Mac must not become a way to root in the box.
        let options = "nosuid,nodev" + (readOnly ? ",ro" : "")
        return [
            GuestRequest(op: .exec, argv: ["/usr/bin/mkdir", "-p", path], cwd: "/", user: "root"),
            GuestRequest(op: .exec, argv: ["/usr/bin/mount", "-t", "virtiofs", "-o", options, linuxTag, path], cwd: "/", user: "root"),
        ]
    }

    /// What the guest runs, as root, before the mount: prints the first thing the share would
    /// hide. For Linux that is anything but a folder in the path itself: folders alone are
    /// what earlier mounts left (a project inside this one that was shared before).
    static func hiddenContentsRequest(_ path: String, guest: GuestKind) -> GuestRequest {
        guard guest == .linux else {
            return parentContentsRequest(path)
        }
        return GuestRequest(op: .exec, argv: ["/usr/bin/find", path, "-mindepth", "1", "!", "-type", "d", "-print", "-quit"], cwd: "/", user: "root")
    }

    /// The folder the share hides in a guest of this kind, for messages.
    static func mountPoint(_ path: String, guest: GuestKind) -> String {
        return guest == .linux ? path : (path as NSString).deletingLastPathComponent
    }

    /// What the guest runs, as root, to unmount the share for the project at `path`.
    static func unmountRequest(_ path: String, guest: GuestKind) -> GuestRequest {
        guard guest == .linux else {
            return unmountRequest(path)
        }
        // umount alone, with no look at the folder first. What it says when nothing is mounted
        // there, or the folder is gone, counts as done: a lost mount must not block every
        // later share. Its words are looked for after the path, which may hold the same words
        // (a folder named "not mounted", busy, must not count as done). The path is an
        // argument, never text of the script.
        let script = #"out=$(LC_ALL=C /usr/bin/umount "$1" 2>&1) && exit 0; case "${out#*"$1"}" in *"not mounted"*|*"no mount point specified"*) exit 0;; esac; /usr/bin/printf '%s\n' "$out" >&2; exit 1"#
        return GuestRequest(op: .exec, argv: ["/bin/sh", "-c", script, "sh", path], cwd: "/", user: "root")
    }

    /// The file of agent-vm's own that a Linux image's git reads (see LinuxSetup).
    static let linuxGitConfig = "/etc/agent-vm/gitconfig"

    /// What a Linux guest runs, as root, once the project is mounted: git is told that the
    /// project, and every repository under it (a submodule, a workspace of several), is a safe
    /// place, and no other. With no path, the file is emptied.
    static func safeDirectoryRequest(_ path: String?) -> GuestRequest {
        var script = "/usr/bin/mkdir -p /etc/agent-vm && /usr/bin/git config --file \(linuxGitConfig) --unset-all safe.directory; "
        if path != nil {
            script += #"/usr/bin/git config --file \#(linuxGitConfig) --add safe.directory "$1" && /usr/bin/git config --file \#(linuxGitConfig) --add safe.directory "$1/*""#
        } else {
            script += "exit 0"
        }
        return GuestRequest(op: .exec, argv: ["/bin/sh", "-c", script, "sh"] + (path.map { [$0] } ?? []), cwd: "/", user: "root")
    }

    /// What the guest runs, as root, to unmount the share for the project at `path`. Succeeds
    /// when nothing is mounted there any more (the guest unmounted it, or a failed share never
    /// mounted it), so a lost mount cannot block every later share.
    static func unmountRequest(_ path: String) -> GuestRequest {
        let script = #"[ -d "$1" ] || exit 0; a=$(/usr/bin/stat -f %d "$1") && b=$(/usr/bin/stat -f %d "$1/..") || exit 1; [ "$a" = "$b" ] && exit 0; exec /sbin/umount "$1""#
        return GuestRequest(op: .exec, argv: ["/bin/sh", "-c", script, "sh", (path as NSString).deletingLastPathComponent], cwd: "/", user: "root")
    }
}
