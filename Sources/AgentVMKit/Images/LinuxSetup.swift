// Sources/AgentVMKit/Images/LinuxSetup.swift
//
// What the Mac runs in a new Linux image, as data: the steps that set the system up, the steps
// that seal it, the checks of what was sealed, and what is cleared before every shutdown of an
// image. Each is a shell script run as root through the guest daemon, with its output in the
// build log. cloud-init does none of this (it only installs the daemon, see SeedDisk), so every
// step is logged, can be canceled, and can be read here.
//
// Every tool is named by its full path: a script must not depend on what a search path holds.
// Debian's and Ubuntu's /bin and /sbin are links to /usr/bin and /usr/sbin.

import Foundation

enum LinuxSetup {
    struct Step: Equatable {
        /// For the build log and for errors.
        var name: String
        var script: String
        /// Seconds without output before the step is stopped.
        var timeout: Int

        init(_ name: String, _ script: String, timeout: Int = 300) {
            self.name = name
            self.script = script
            self.timeout = timeout
        }
    }

    /// The environment of every step: apt asks nothing, and needrestart (Ubuntu), should it be
    /// there, restarts nothing after an apt run.
    static let environment = ["DEBIAN_FRONTEND": "noninteractive", "LC_ALL": "C.UTF-8", "NEEDRESTART_SUSPEND": "1"]

    /// apt-get as every step runs it: no questions, no progress bars, and dpkg's output as
    /// plain lines (with a terminal of its own it sends blank lines by the hundred).
    static let apt = "/usr/bin/apt-get -q -y -o Dpkg::Use-Pty=0"

    /// Packages a Linux image has that the cloud image lacks and agent-vm or its recipes use.
    static let packages = ["git", "jq", "unzip", "zip"]
    /// What `--command-line-tools` means on Linux: the compiler and make.
    static let toolsPackage = "build-essential"

    /// Run first: cloud-init, which installed the daemon, has more to finish (it grows the
    /// disk, among other things), and apt must not run beside it. Status 2 is cloud-init's
    /// "done, with something to note", which a disk without a network configuration earns.
    static let waitForFirstBoot = Step("wait for the first boot to finish",
        #"/usr/bin/cloud-init status --wait > /dev/null 2>&1; status=$?; if [ "$status" -ne 0 ] && [ "$status" -ne 2 ]; then /usr/bin/cloud-init status --long; exit 1; fi"#,
        timeout: 300)

    /// The system's own account of itself, each on its own request so that no answer can pose
    /// as another.
    static let osRelease = "/usr/bin/cat /etc/os-release"
    static let kernel = "/usr/bin/uname -r"
    static let architecture = "/usr/bin/dpkg --print-architecture"
    /// The size of the running kernel's memory pages in bytes.
    static let pageSize = "/usr/bin/getconf PAGESIZE"
    /// The size of the root file system in bytes.
    static let rootSize = "/usr/bin/df -B1 --output=size / | /usr/bin/tail -n 1"

    /// Ubuntu's needrestart restarts services, and the system manager itself, at the end of an
    /// apt run that replaced a library they use. Measured: one build in four never came back
    /// from that, in the middle of the system's updates. It goes before anything is installed
    /// (a recipe's own apt run has no environment of ours to stop it); needs no network.
    static let removeNeedrestart = Step("no restarts of services by apt (needrestart)", "\(apt) purge needrestart", timeout: 600)

    /// After a disk was made longer: the root partition, then its file system, grown into the
    /// new room. Debian's image does that by itself at boot; Ubuntu's leaves it to cloud-init,
    /// which is off in a sealed image. Where it is done already, growpart says so with status 1
    /// and resize2fs finds nothing to do.
    static let growRoot = Step("grow the root file system",
        #"root="$(/usr/bin/findmnt -n -o SOURCE /)" || exit 1; name="${root#/dev/}"; number="$(/usr/bin/cat "/sys/class/block/$name/partition")" || exit 1; "#
        + #"disk="/dev/$(/usr/bin/lsblk -n -o PKNAME "$root")"; said="$(/usr/bin/growpart "$disk" "$number" 2>&1)"; status=$?; "#
        + #"if [ "$status" -ne 0 ] && [ "$status" -ne 1 ]; then /usr/bin/echo "$said"; exit 1; fi; /usr/sbin/resize2fs "$root" 2>&1"#,
        timeout: 300)

    /// What a build runs first when the image is to boot another kernel than the cloud image
    /// has: the package lists and the kernel, and nothing else. The build then boots the image
    /// again, so that as little as can be runs on the cloud image's kernel (one with 4 KiB
    /// pages can lose memory when the Mac runs short of it, and a build that meets that fails).
    static func kernelSwitch(_ kernel: LinuxKernel, distribution: String = "debian") -> [Step] {
        var steps = [packageLists, self.kernel(kernel)]
        if distribution == "ubuntu" {
            steps.insert(removeNeedrestart, at: 0)
        }
        return steps
    }

    /// After the boot on a kernel `kernelSwitch` installed: cloud-init is waited for, and the
    /// network card's address as in every later boot. What cloud-init says of this boot is not
    /// judged: its work was done and judged at the first boot, and on a kernel with larger
    /// pages its try to grow the root file system again ends in an error that means nothing
    /// (resize2fs rounds the size down to whole pages and calls that shrinking).
    static let waitForKernelBoot = Step("wait for the boot on the new kernel", "/usr/bin/cloud-init status --wait > /dev/null 2>&1; \(waitForNetwork.script)", timeout: 300)

    /// Setting the system up, after the first boot: the box user, the packages, git's include.
    /// `afterKernelSwitch`: `kernelSwitch` ran in this build, and what it did is not done again.
    static func steps(user: String, tools: Bool, distribution: String = "debian", afterKernelSwitch: Bool = false) -> [Step] {
        var steps = [
            // cloud-init was told to create no account; its default one would have sudo
            // without a password. The box user's password is locked: there is none to know.
            Step("account \(user)",
                 // One name to a getent: asked for two, it fails when either is missing.
                 "if /usr/bin/getent passwd debian > /dev/null || /usr/bin/getent passwd ubuntu > /dev/null; then /usr/bin/echo 'the first boot made a default account'; exit 1; fi; "
                 + "/usr/sbin/useradd --create-home --shell /bin/bash --uid 1000 --user-group \(user) && /usr/bin/passwd --lock \(user) > /dev/null && "
                 + "\(toolFolder(user: user).script) && /usr/bin/id \(user)"),
            packageLists,
            systemUpdates,
            Step(packages.joined(separator: ", "), "\(apt) install \(packages.joined(separator: " "))", timeout: 900),
        ]
        if tools {
            steps.append(self.tools)
        }
        if afterKernelSwitch {
            steps.removeAll { $0 == packageLists }
        } else if distribution == "ubuntu" {
            steps.insert(removeNeedrestart, at: 1)
        }
        // A file of agent-vm's own that git reads: a box's supervisor names the shared project
        // there, so git trusts it whoever looked at it last.
        steps.append(Step("git settings",
                          "/usr/bin/install -d -m 755 /etc/agent-vm && /usr/bin/install -m 644 /dev/null /etc/agent-vm/gitconfig && "
                          + "/usr/bin/git config --system include.path /etc/agent-vm/gitconfig"))
        return steps
    }

    /// A list that cannot be fetched fails the step: left to itself, apt-get update warns and
    /// exits 0, and an upgrade after it would find nothing new and call that up to date. A fetch
    /// that fails is tried three more times first: one slow mirror must not fail a build.
    /// The account's own tool folder, there from the start: the system's profile puts it on a
    /// login shell's path only when it exists at login, and exec has it first on the path
    /// either way. Run with the account, and again in an image built from an image (the base
    /// may be older than this step); a folder that is there is left as it is.
    static func toolFolder(user: String) -> Step {
        return Step("the account's tool folder",
                    "if [ ! -d /home/\(user)/.local/bin ]; then /usr/bin/install -d -o \(user) -g \(user) -m 755 /home/\(user)/.local /home/\(user)/.local/bin; fi")
    }

    static let packageLists = Step("package lists", "\(apt) -o APT::Update::Error-Mode=any -o Acquire::Retries=3 update", timeout: 600)
    /// A changed configuration file keeps what the image has (what sealing wrote among it).
    static let systemUpdates = Step("system updates", "\(apt) -o Dpkg::Options::=--force-confold dist-upgrade", timeout: 1800)

    /// What `image update --system` runs in a Linux image: the distribution's updates, then
    /// what they left behind (an older kernel, downloaded packages).
    static let systemUpdate: [Step] = [
        packageLists,
        systemUpdates,
        Step("remove what is no longer needed", "\(apt) autoremove --purge && \(apt) clean", timeout: 900),
    ]

    /// Every package with its version and state, one to a line: compared before and after an
    /// update to tell whether anything changed.
    static let packageList = #"/usr/bin/dpkg-query -W -f '${Package}:${Architecture} ${Version} ${db:Status-Status}\n'"#
    /// The newest kernel in /boot, as its file's path ("/boot/vmlinuz-6.12.48+deb13-cloud-arm64").
    static let newestKernel = "/usr/bin/ls /boot/vmlinuz-* | /usr/bin/sort -V | /usr/bin/tail -n 1"

    /// How many packages differ between two outputs of `packageList`: installed in one and
    /// not the other, or at another version. A line that is not a package's is not counted.
    static func packageChanges(before: String, after: String) -> Int {
        func installed(_ text: String) -> [String: String] {
            var result: [String: String] = [:]
            for line in text.split(whereSeparator: \.isNewline) {
                let fields = line.split(separator: " ", omittingEmptySubsequences: true)
                if fields.count == 3, fields[2] == "installed" {
                    result[String(fields[0])] = String(fields[1])
                }
            }
            return result
        }
        let old = installed(before)
        let new = installed(after)
        return Set(old.keys).union(new.keys).filter { old[$0] != new[$0] }.count
    }

    /// Whether a boot is needed to run the newest installed kernel: `newest` is the path
    /// `newestKernel` printed, `running` what `uname -r` says. An answer that names no kernel
    /// asks for no boot.
    static func kernelNeedsBoot(running: String, newest: String) -> Bool {
        let prefix = "/boot/vmlinuz-"
        let path = newest.trimmingCharacters(in: .whitespacesAndNewlines)
        guard path.hasPrefix(prefix), path.count > prefix.count else {
            return false
        }
        return String(path.dropFirst(prefix.count)) != running.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    /// Makes `kernel` the only kernel installed, and so the one the system boots: its package
    /// is installed and every kernel package of another flavor purged. The boot menu's first
    /// entry is then this kernel with no setting of ours, and the newest file in /boot is the
    /// kernel that boots (`newestKernel`). Removing the kernel that is running asks a question
    /// (linux-base's linux-check-removal, whose answer by default is to stop); it is answered
    /// first. The running kernel stays in memory until the next boot.
    static func kernel(_ kernel: LinuxKernel) -> Step {
        return Step("kernel with \(LinuxPageSize.name(kernel.pageBytes)) pages (\(kernel.package))",
                    #"/usr/bin/echo 'linux-base linux-base/removing-running-kernel boolean false' | /usr/bin/debconf-set-selections || exit 1; "#
                    + "\(apt) install \(kernel.withoutRecommended ? "--no-install-recommends " : "")\(([kernel.package] + kernel.alongside).joined(separator: " ")) || exit 1; "
                    + #"others="$(/usr/bin/dpkg-query -W -f '${db:Status-Status} ${Package}\n' 'linux-image-*' | /usr/bin/sed -n 's/^installed //p' | /usr/bin/grep -v -e '-\#(kernel.flavor)$')"; "#
                    + #"if [ -n "$others" ]; then \#(apt) purge $others || exit 1; fi; "#
                    + #"left="$(/usr/bin/ls /boot/vmlinuz-* | /usr/bin/grep -c -v -e '-\#(kernel.flavor)$')"; if [ "$left" != "0" ]; then /usr/bin/ls /boot; exit 1; fi; /usr/bin/ls /boot/vmlinuz-*"#,
                    timeout: 1800)
    }

    static let tools = Step("the compiler and make (\(toolsPackage))", "\(apt) install \(toolsPackage)", timeout: 1800)

    /// Run first in every later boot that builds on an image (a derived image, an update):
    /// the daemon answers before the network card has its address, and a step that downloads
    /// would fail on the name lookup. Half a minute at most, and no failure when it runs out:
    /// a recipe that needs no network still works, and one that does says what it misses.
    static let waitForNetwork = Step("wait for the network",
        "/usr/lib/systemd/systemd-networkd-wait-online --timeout=30 > /dev/null 2>&1 || /usr/bin/echo 'the network card got no address yet'", timeout: 60)

    /// The installed version of the tools package, for the record.
    static let toolsVersion = "/usr/bin/dpkg-query -W -f '${Version}' \(toolsPackage)"

    /// Sealing, at the end of the first build: the ways in are removed, the system no longer
    /// changes by itself, and it boots the same with any network card or none.
    static let seal: [Step] = [
        // Purged, not disabled: systemd makes an installed sshd listen on vsock port 22 by
        // itself, beside the TCP port. polkitd goes too: a program that runs with root's
        // rights for any user who asks it well, with a history of flaws, and nothing in a box
        // needs it (removing it takes no other package along).
        Step("remove the ssh server, background updates and polkitd",
             "\(apt) purge openssh-server unattended-upgrades polkitd && \(apt) autoremove --purge && \(apt) clean || exit 1; "
             // The sockets systemd made for sshd at this boot stay open until they are stopped
             // (a socket that is not there fails the stop, which is no failure of the step);
             // at the next boot it makes none, since there is no sshd.
             + "/usr/bin/systemctl stop sshd-vsock.socket sshd-unix-local.socket; /usr/bin/systemctl daemon-reload",
             timeout: 900),
        // A box changes only by what runs in it; updates are `image update`'s.
        Step("no update timers", "/usr/bin/systemctl disable --now apt-daily.timer apt-daily-upgrade.timer"),
        // cloud-init wrote a network file that names the first boot's card address: a box has
        // another address, or no card. Then cloud-init is switched off for good.
        Step("network settings for any card",
             "/usr/bin/rm -f /etc/netplan/50-cloud-init.yaml && "
             + #"/usr/bin/printf '%s\n' 'network:' '  version: 2' '  ethernets:' '    agent-vm:' '      match:' '        name: "en*"' '      dhcp4: true' '      dhcp6: true' > /etc/netplan/60-agent-vm.yaml && "#
             + "/usr/bin/chmod 600 /etc/netplan/60-agent-vm.yaml && /usr/sbin/netplan generate && "
             + #"/usr/bin/printf 'network: {config: disabled}\n' > /etc/cloud/cloud.cfg.d/99-agent-vm.cfg && "#
             + "/usr/bin/install -m 644 /dev/null /etc/cloud/cloud-init.disabled && "
             // The resolver answers name questions from the local network on every address
             // (port 5355) unless told not to; a box answers nobody.
             + "/usr/bin/install -d -m 755 /etc/systemd/resolved.conf.d && "
             + #"/usr/bin/printf '%s\n' '[Resolve]' 'LLMNR=no' 'MulticastDNS=no' > /etc/systemd/resolved.conf.d/agent-vm.conf && "#
             + "/usr/bin/systemctl restart systemd-resolved.service"),
        // The kernel's messages, and what the system writes to its console, go where agent-vm
        // keeps them (console.log), and the boot does not wait at a menu nobody sees. The
        // console named last on the kernel's line is the system's own: Ubuntu's image names
        // two others in this variable, so ours is put after them.
        Step("console and boot menu",
             #"/usr/bin/printf '%s\n' 'GRUB_CMDLINE_LINUX_DEFAULT="$GRUB_CMDLINE_LINUX_DEFAULT console=hvc0"' 'GRUB_TIMEOUT=0' > /etc/default/grub.d/99-agent-vm.cfg && /usr/sbin/update-grub"#,
             timeout: 300),
        // The daemon listens on vsock; loading its transport by name removes a race at boot.
        Step("vsock at boot", #"/usr/bin/printf 'vmw_vsock_virtio_transport\n' > /etc/modules-load.d/agent-vm.conf"#),
        stopOnKernelFault,
    ]

    static let stopOnKernelFaultFile = "/etc/sysctl.d/90-agent-vm.conf"

    /// A kernel that met a fault in itself ("Oops") goes on running by default, with whatever
    /// the fault left wrong in its memory, and may write that to the disk: a box was left with
    /// a damaged file system this way, twice. With this it stops at the first fault (a panic),
    /// which the supervisor sees on the console, and the disk keeps what the journal has.
    static let stopOnKernelFault = Step("stop at a kernel fault",
                                        #"/usr/bin/printf 'kernel.panic_on_oops = 1\n' > \#(stopOnKernelFaultFile) && /usr/bin/chmod 644 \#(stopOnKernelFaultFile) && "#
                                            + #"/usr/bin/printf '1\n' > /proc/sys/kernel/panic_on_oops"#)

    /// The same for a box that is starting, whatever its image has: what the supervisor runs,
    /// as root, before the box is ready.
    static let stopOnKernelFaultRequest = GuestRequest(op: .exec, argv: ["/bin/sh", "-c", #"/usr/bin/printf '1\n' > /proc/sys/kernel/panic_on_oops"#],
                                                       cwd: "/", user: "root")

    /// What Ubuntu's cloud image has beside Debian's that a box must not have, or has no use
    /// for (an inventory of a fresh Ubuntu 26.04 image, 2026-10-07):
    ///
    /// - snapd, a daemon of root's that any user can talk to and that updates its programs by
    ///   itself; with it what installs LXD through it when a socket is touched, and LXD's
    ///   agent.
    /// - What asks the network in the background, or changes the system by itself: the Ubuntu
    ///   Pro client (a timer, and a hook in every apt run), the update and news notices, the
    ///   firmware updater, the crash reporter, Landscape's notices, the release upgrader.
    /// - needrestart, which restarts services after every apt run when it finds their program
    ///   replaced: the guest daemon among them, in the middle of the step that runs apt.
    /// - Daemons for hardware and hosts a box does not have: VMware's tools, multipath and
    ///   iSCSI disks, and udisks2 (a daemon of root's that users ask over D-Bus).
    static let ubuntuRemoved = [
        "snapd", "lxd-installer", "lxd-agent-loader",
        "ubuntu-pro-client", "update-notifier-common", "motd-news-config", "fwupd", "apport", "landscape-common", "ubuntu-release-upgrader-core",
        "needrestart",
        "open-vm-tools", "multipath-tools", "open-iscsi", "udisks2",
    ]
    /// Ubuntu's timers that ask the network. Most go with their package; the check names them
    /// all, so that an update which brings one back is seen.
    static let ubuntuTimers = ["motd-news.timer", "update-notifier-download.timer", "update-notifier-motd.timer", "fwupd-refresh.timer", "ua-timer.timer",
                               "snapd.snap-repair.timer", "apport-autoreport.timer"]

    /// Sealing for a distribution: the shared steps, and after the first of them Ubuntu's own.
    static func seal(distribution: String) -> [Step] {
        var steps = seal
        if distribution == "ubuntu" {
            steps.insert(Step("remove snapd, Ubuntu's background services, and daemons for hardware a box does not have",
                              "\(apt) purge \(ubuntuRemoved.joined(separator: " ")) && \(apt) autoremove --purge && \(apt) clean || exit 1; "
                              // What snapd's own removal leaves when a snap was mounted.
                              + "/usr/bin/rm -rf /snap /var/snap /var/lib/snapd /var/cache/snapd /root/snap; /usr/bin/systemctl daemon-reload; "
                              // A timer that belongs to a package which stays (the news timer is
                              // in base-files) is switched off; one that went with its package
                              // is not there to switch.
                              + #"for timer in \#(ubuntuTimers.joined(separator: " ")); do state="$(/usr/bin/systemctl is-enabled "$timer" 2> /dev/null)"; "#
                              + #"if [ "$state" = "enabled" ]; then /usr/bin/systemctl disable --now "$timer" || exit 1; fi; done"#,
                              timeout: 900), at: 1)
        }
        return steps
    }

    /// What must be true of a sealed image of a distribution. A script prints what it found
    /// and ends with a status other than 0 when it is not.
    static func sealChecks(distribution: String = "debian", daemonPort: UInt32 = GuestProtocol.port) -> [Step] {
        let removed = ["openssh-server", "unattended-upgrades", "polkitd"] + (distribution == "ubuntu" ? ubuntuRemoved : [])
        let timers = ["apt-daily.timer", "apt-daily-upgrade.timer"] + (distribution == "ubuntu" ? ubuntuTimers : [])
        return [
            Step("no ssh server", "if [ -e /usr/sbin/sshd ]; then /usr/bin/echo '/usr/sbin/sshd is still there'; exit 1; fi"),
            // The server's units, installed or made at boot by systemd's generator and still
            // active. (systemd's own ssh-access.target is not one: it starts nothing.)
            Step("no ssh server unit",
                 #"found="$(/usr/bin/systemctl list-unit-files --no-legend 'ssh.*' 'ssh@*' 'sshd*'; /usr/bin/systemctl list-units --state=active --no-legend 'ssh.*' 'ssh@*' 'sshd*')"; if [ -n "$found" ]; then /usr/bin/echo "$found" | /usr/bin/head -n 5; exit 1; fi"#),
            Step("nothing listens on TCP port 22",
                 #"found="$(/usr/bin/ss -H -l -t -n 'sport = :22')"; if [ -n "$found" ]; then /usr/bin/echo "$found"; exit 1; fi"#),
            // The resolver and the daemon's relay listen on this machine's own addresses.
            Step("no TCP port is open to the network",
                 #"found="$(/usr/bin/ss -H -l -t -n | /usr/bin/grep -v -E '[[:space:]](127\.[0-9.]+(%lo)?|\[::1\]):[0-9]+[[:space:]]')"; if [ -n "$found" ]; then /usr/bin/echo "$found"; exit 1; fi"#),
            // The daemon's own line must be there: a list that came back empty (a tool that
            // failed, a kernel that tells nothing) is no proof that nobody else listens.
            Step("nothing listens on vsock but the guest daemon",
                 #"all="$(/usr/bin/ss -H -l --vsock)" || exit 1; own="$(/usr/bin/echo "$all" | /usr/bin/grep -c -E '[:*]\#(daemonPort)[[:space:]]')"; "#
                 + #"found="$(/usr/bin/echo "$all" | /usr/bin/grep -v -E '[:*]\#(daemonPort)[[:space:]]')"; "#
                 + #"if [ "$own" != "1" ] || [ -n "$found" ]; then /usr/bin/echo "vsock listeners: $all"; exit 1; fi"#),
            Step("the removed packages are gone",
                 #"found="$(/usr/bin/dpkg-query -W -f '${Package} ${db:Status-Status}\n' \#(removed.joined(separator: " ")) 2> /dev/null | /usr/bin/grep ' installed$')"; if [ -n "$found" ]; then /usr/bin/echo "$found"; exit 1; fi"#),
            // One unit to a question: the answer then is that unit's.
            Step("no update timer is on",
                 #"found=""; for timer in \#(timers.joined(separator: " ")); do state="$(/usr/bin/systemctl is-enabled "$timer" 2> /dev/null)"; if [ "$state" = "enabled" ]; then found="$found $timer"; fi; done; "#
                 + #"if [ -n "$found" ]; then /usr/bin/echo "still enabled:$found"; exit 1; fi"#),
            Step("no account has a usable password",
                 #"found="$(/usr/bin/passwd -S -a | /usr/bin/grep -E '^[^ ]+ P ')"; if [ -n "$found" ]; then /usr/bin/echo "$found"; exit 1; fi"#),
            Step("cloud-init is off", "if [ ! -e /etc/cloud/cloud-init.disabled ]; then /usr/bin/echo 'cloud-init is still on'; exit 1; fi"),
        ]
    }

    /// What must be true of the account the setup made, checked before any recipe runs: the
    /// first boot gave it no way to root. A recipe may then add one on purpose (a sudo rule, a
    /// group), and its name in the image's record says so.
    static func accountCheck(user: String) -> Step {
        return Step("the box user has no sudo rule and no group but its own",
                    #"groups="$(/usr/bin/id -nG \#(user))"; if [ "$groups" != "\#(user)" ]; then /usr/bin/echo "groups: $groups"; exit 1; fi; "#
                    + #"rule="$(/usr/bin/sudo -n -l -U \#(user) 2>&1)"; case "$rule" in *"is not allowed to run sudo"*) ;; *) /usr/bin/echo "$rule"; exit 1;; esac"#)
    }

    /// Before every shutdown of an image: each boot of the image, and of every box cloned from
    /// it, then gets a machine id of its own. The ssh host keys went with the server; a
    /// derived image whose recipe installed one must not hand the same keys to every box.
    static let prepareForCloning = "/usr/bin/truncate -s 0 /etc/machine-id && /usr/bin/rm -f /etc/ssh/ssh_host_* /var/lib/systemd/random-seed && /usr/bin/sync"

    /// The largest /etc/os-release that is read.
    static let osReleaseLimit = 4096

    /// A system's name, version and readable name from its /etc/os-release, each taken only as
    /// what it should be: `ID` and `VERSION_ID` short tokens, `PRETTY_NAME` one short printable
    /// line. The text is the guest's, and what is taken ends up in the record and every list.
    static func parseOSRelease(_ text: String) throws -> (distribution: String, version: String, name: String) {
        guard text.utf8.count <= osReleaseLimit else {
            throw problem("/etc/os-release is larger than \(osReleaseLimit) bytes")
        }
        var values: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            guard let equals = line.firstIndex(of: "=") else {
                continue
            }
            let key = String(line[..<equals])
            guard ["ID", "VERSION_ID", "PRETTY_NAME"].contains(key) else {
                continue
            }
            var value = Substring(line[line.index(after: equals)...])
            if value.count >= 2, let quote = value.first, quote == "\"" || quote == "'", value.last == quote {
                value = value.dropFirst().dropLast()
            }
            guard values[key] == nil else {
                throw problem("/etc/os-release says \(key) twice")
            }
            values[key] = String(value)
        }
        guard let distribution = values["ID"], Printable.isToken(distribution) else {
            throw problem("/etc/os-release has no usable ID")
        }
        guard let version = values["VERSION_ID"], Printable.isToken(version) else {
            throw problem("/etc/os-release has no usable VERSION_ID")
        }
        guard let name = values["PRETTY_NAME"], !name.isEmpty, name.unicodeScalars.count <= 80, Printable.line(name) == name, !name.contains("\\") else {
            throw problem("/etc/os-release has no usable PRETTY_NAME")
        }
        return (distribution, version, name)
    }

    /// A package's version as Debian writes one (an epoch's ":" and a "~" beside what a token
    /// has), or a refusal.
    static func packageVersion(_ text: String, package: String) throws -> String {
        let value = text.hasSuffix("\n") ? String(text.dropLast()) : text
        guard Printable.isToken(value.replacingOccurrences(of: ":", with: ".").replacingOccurrences(of: "~", with: "."), limit: 64) else {
            throw problem("the guest's version of \(package) is not a version")
        }
        return value
    }

    /// One word the guest said of itself (its kernel, its architecture), or a refusal.
    static func token(_ text: String, what: String) throws -> String {
        let value = text.hasSuffix("\n") ? String(text.dropLast()) : text
        guard Printable.isToken(value, limit: 64) else {
            throw problem("the guest's \(what) is not a short plain word")
        }
        return value
    }

    private static func problem(_ reason: String) -> AgentVMError {
        return .guestCommandFailed(command: "read the system's description", status: 0, output: reason)
    }

    /// Names a Debian or Ubuntu system has for its own accounts and groups, which the box user
    /// cannot take.
    static let reservedUserNames: Set<String> = [
        "bin", "sys", "sync", "games", "man", "lp", "mail", "news", "uucp", "proxy", "backup", "list", "irc", "sudo", "adm",
        "users", "debian", "ubuntu", "tty", "disk", "kmem", "dialout", "fax", "voice", "cdrom", "floppy", "tape", "audio", "dip",
        "operator", "src", "shadow", "utmp", "video", "sasl", "plugdev", "kvm", "input", "render", "nogroup", "messagebus", "polkitd",
        // Ubuntu's "admin" group has a sudo rule of its own.
        "admin", "clock", "crontab", "daemon", "dhcpcd", "lxd", "netdev", "rdma", "sgx", "staff", "syslog", "tcpdump", "uuidd", "www-data",
        "fwupd-refresh", "landscape", "snap",
    ]

    /// A name for the box user of a Linux image: as for macOS, and not one the system has.
    static func isValidUserName(_ name: String) -> Bool {
        return ImageBuildOptions.isValidUserName(name) && !reservedUserNames.contains(name) && !name.hasPrefix("systemd") && !name.hasPrefix("_")
    }
}
