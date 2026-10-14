// Sources/AgentVMKit/Boxes/ProjectShare.swift
//
// A project folder shared into a box at the same absolute path it has on the Mac, so paths in
// build logs, error messages and editor links mean the same thing on both sides. One virtio
// file system device per folder a box can share at once (`slots(for:)`), empty at start; the
// supervisor fills one on the running machine and the guest daemon mounts it (as root). A
// macOS box has one, so a new project replaces the previous one, which fails while programs
// in the box still use it; a Linux box has several, and its projects are not kept apart.
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

    /// The tag of a Linux box's first device. Apple's automount tag means nothing to Linux, and
    /// a name of its own says whose device it is in the guest's mount table.
    public static let linuxTag = "agent-vm-project"

    /// The tag of the project share device in a guest of this kind (the first, for Linux).
    public static func tag(for guest: GuestKind) -> String {
        return guest == .linux ? linuxTag : tag
    }

    /// How many folders a box of this kind shares at once: one device each, and the device set
    /// is fixed when the machine starts. A macOS guest has one: only Apple's automount tag
    /// gives a local volume (see above), and a device's share cannot change while the guest
    /// has it mounted. A Linux guest has several, so sessions on different folders can share
    /// one box; nothing in the box keeps them apart (they run as the same account).
    public static func slots(for guest: GuestKind) -> Int {
        return guest == .linux ? 8 : 1
    }

    /// The tags of every project share device in a guest of this kind, in slot order:
    /// "agent-vm-project", "agent-vm-project-2", ... for Linux.
    public static func tags(for guest: GuestKind) -> [String] {
        guard guest == .linux else {
            return [tag]
        }
        return (0..<slots(for: guest)).map { $0 == 0 ? linuxTag : "\(linuxTag)-\($0 + 1)" }
    }

    /// Whether one of the two folders (canonical paths) is the other or inside it: a mount on
    /// one would cover the other, or be made inside the Mac's copy of it.
    static func overlaps(_ a: String, _ b: String) -> Bool {
        return a == b || a.hasPrefix(b + "/") || b.hasPrefix(a + "/")
    }

    /// What sharing a folder beside the shared ones takes.
    enum Room: Equatable {
        /// It is shared already, in that mode.
        case shared
        /// Take these away first (none: there is room).
        case remove([SharedProject])
        /// Programs run on this one, which is in the way.
        case blocked(by: SharedProject)
    }

    /// What sharing `project` (canonical) in mode `readOnly` beside `shared` (oldest first)
    /// takes in a box with `slots` devices. In its way: the same folder in the other mode, a
    /// folder inside it or around it, and, when every device is in use, the project shared
    /// longest ago that no program runs on. Any of those with programs on it blocks it, as
    /// does a box whose every device holds a project with programs on it.
    static func room(for project: String, readOnly: Bool, among shared: [SharedProject], slots: Int) -> Room {
        if shared.contains(where: { $0.path == project && $0.readOnly == readOnly }) {
            return .shared
        }
        var inTheWay = shared.filter { overlaps($0.path, project) }
        if shared.count - inTheWay.count >= slots,
           let oldest = shared.first(where: { $0.programs == 0 && !overlaps($0.path, project) }) {
            inTheWay.append(oldest)
        }
        if let busy = inTheWay.first(where: { $0.programs > 0 }) {
            return .blocked(by: busy)
        }
        if shared.count - inTheWay.count >= slots, let busy = shared.first {
            return .blocked(by: busy)
        }
        return .remove(inTheWay)
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
    /// on the path itself, from the device tagged `tag` (one of `tags(for:)`).
    static func mountRequests(_ path: String, guest: GuestKind, readOnly: Bool, tag: String = linuxTag) -> [GuestRequest] {
        guard guest == .linux else {
            return mountRequests(path)
        }
        // nosuid and nodev: a file on the Mac must not become a way to root in the box.
        let options = "nosuid,nodev" + (readOnly ? ",ro" : "")
        return [
            GuestRequest(op: .exec, argv: ["/usr/bin/mkdir", "-p", path], cwd: "/", user: "root"),
            GuestRequest(op: .exec, argv: ["/usr/bin/mount", "-t", "virtiofs", "-o", options, tag, path], cwd: "/", user: "root"),
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

    /// What a Linux guest runs, as root, whenever the shared projects change: git is told that
    /// each project, and every repository under it (a submodule, a workspace of several), is a
    /// safe place, and no other. With no paths, the file is emptied.
    static func safeDirectoryRequest(_ paths: [String]) -> GuestRequest {
        var script = "/usr/bin/mkdir -p /etc/agent-vm && /usr/bin/git config --file \(linuxGitConfig) --unset-all safe.directory; "
        if paths.isEmpty {
            script += "exit 0"
        } else {
            // The paths are arguments, never text of the script.
            script += #"for p in "$@"; do /usr/bin/git config --file \#(linuxGitConfig) --add safe.directory "$p" && /usr/bin/git config --file \#(linuxGitConfig) --add safe.directory "$p/*" || exit 1; done"#
        }
        return GuestRequest(op: .exec, argv: ["/bin/sh", "-c", script, "sh"] + paths, cwd: "/", user: "root")
    }

    /// What the guest runs, as root, after an unmount that was refused because the folder is in
    /// use, when the folder is taken away regardless. Its result is not waited on for anything:
    /// the Mac stops sharing either way.
    ///
    /// In a Linux guest the programs that hold the folder are ended first (those whose working
    /// folder, root, program file or an open file is in it), then it is unmounted, lazily if
    /// that still fails. Ending them is not for the Mac's sake: a virtiofs mount that lives on
    /// in a program is the one the next share of this box would get, and it answers every call
    /// with an I/O error once the Mac stopped sharing (measured: the next exec could not enter
    /// the project). A macOS guest unmounts by force.
    static func forcedUnmountRequest(_ path: String, guest: GuestKind) -> GuestRequest {
        guard guest == .linux else {
            return GuestRequest(op: .exec, argv: ["/sbin/umount", "-f", (path as NSString).deletingLastPathComponent], cwd: "/", user: "root")
        }
        let script = #"for p in /proc/[0-9]*; do hit=; for l in "$p/cwd" "$p/root" "$p/exe" "$p"/fd/*; do t=$(/usr/bin/readlink "$l" 2>/dev/null) || continue; case "$t" in "$1"|"$1"/*) hit=1; break;; esac; done; [ -n "$hit" ] && kill -9 "${p#/proc/}" 2>/dev/null; done; /usr/bin/sleep 0.3; /usr/bin/umount "$1" 2>/dev/null || /usr/bin/umount -l "$1""#
        return GuestRequest(op: .exec, argv: ["/bin/sh", "-c", script, "sh", path], cwd: "/", user: "root")
    }

    /// What the guest runs, as root, to unmount the share for the project at `path`. Succeeds
    /// when nothing is mounted there any more (the guest unmounted it, or a failed share never
    /// mounted it), so a lost mount cannot block every later share.
    static func unmountRequest(_ path: String) -> GuestRequest {
        let script = #"[ -d "$1" ] || exit 0; a=$(/usr/bin/stat -f %d "$1") && b=$(/usr/bin/stat -f %d "$1/..") || exit 1; [ "$a" = "$b" ] && exit 0; exec /sbin/umount "$1""#
        return GuestRequest(op: .exec, argv: ["/bin/sh", "-c", script, "sh", (path as NSString).deletingLastPathComponent], cwd: "/", user: "root")
    }
}
