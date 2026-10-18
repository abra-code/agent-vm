// Tests/AgentVMKitTests/LinuxSetupTests.swift
//
// What a Linux image's build runs in the guest and what it believes of the guest's answers:
// the setup and sealing scripts as text, the strict reading of /etc/os-release, the seed
// disk's files, and the daemon's unit. No guest runs here; the scripts themselves are run by
// the extended tests, which build a real image.

import Foundation
import Testing
@testable import AgentVMKit

@Suite struct LinuxSetupTests {
    static let sixteen = LinuxKernel(pageBytes: 16384, package: "linux-image-arm64-16k", flavor: "arm64-16k")

    static var everyStep: [LinuxSetup.Step] {
        return [LinuxSetup.waitForFirstBoot] + LinuxSetup.steps(user: "agent", tools: true) + LinuxSetup.seal(distribution: "debian") + LinuxSetup.sealChecks()
            + LinuxSetup.seal(distribution: "ubuntu") + LinuxSetup.sealChecks(distribution: "ubuntu") + LinuxSetup.systemUpdate + [LinuxSetup.removeNeedrestart]
            + [LinuxSetup.Step("packages", LinuxSetup.packageList), LinuxSetup.Step("newest kernel", LinuxSetup.newestKernel)]
            + [LinuxSetup.accountCheck(user: "agent"), LinuxSetup.waitForNetwork, LinuxSetup.packageLists, LinuxSetup.tools]
            + [LinuxSetup.kernel(Self.sixteen), LinuxSetup.waitForKernelBoot, LinuxSetup.Step("page size", LinuxSetup.pageSize)]
    }

    /// The first word of every command in `script`: after the start, `;`, `&&`, `||`, `|`,
    /// `$(`, `then`, `else` and `do`.
    static func commandWords(_ script: String) -> [String] {
        var text = script
        // What is quoted is data, not a command.
        for pattern in [#"'[^']*'"#, #""[^"$]*""#] {
            text = text.replacingOccurrences(of: pattern, with: "Q", options: .regularExpression)
        }
        let pieces = text.replacingOccurrences(of: #"\$\("#, with: ";", options: .regularExpression)
            .replacingOccurrences(of: #"&&|\|\||\||\bthen\b|\belse\b|\bdo\b"#, with: ";", options: .regularExpression)
            .split(separator: ";")
        return pieces.compactMap { $0.split(separator: " ", omittingEmptySubsequences: true).first.map(String.init) }
    }

    @Test func everyToolIsNamedByItsPath() {
        // The reading of a script finds its commands at all.
        #expect(Self.commandWords(LinuxSetup.steps(user: "agent", tools: false)[0].script).contains("/usr/sbin/useradd"))
        #expect(Self.commandWords("a; b && c | d").count == 4)
        // Words of the shell itself, and assignments.
        let shell: Set<String> = ["if", "fi", "case", "esac", "exit", "[", "*)", "Q", "Q)", ")", "for", "done"]
        for step in Self.everyStep + [LinuxSetup.Step("clone", LinuxSetup.prepareForCloning), LinuxSetup.Step("os", LinuxSetup.osRelease),
                                      LinuxSetup.Step("kernel", LinuxSetup.kernel), LinuxSetup.Step("arch", LinuxSetup.architecture),
                                      LinuxSetup.Step("size", LinuxSetup.rootSize), LinuxSetup.Step("tools", LinuxSetup.toolsVersion), LinuxSetup.growRoot] {
            for word in Self.commandWords(step.script) where !shell.contains(word) && !word.contains("=") && !word.hasSuffix(")") {
                #expect(word.hasPrefix("/usr/bin/") || word.hasPrefix("/usr/sbin/") || word.hasPrefix("/usr/lib/systemd/"), "\(step.name): \(word)")
            }
        }
        // The same for what the first boot runs from the seed disk.
        let install = SeedDisk.userData(daemonDigest: String(repeating: "a", count: 64))
        for word in Self.commandWords(install.components(separatedBy: "-c, \"").last ?? "") where word != "Q" && !word.hasPrefix("\"") {
            #expect(word.hasPrefix("/usr/bin/"), "seed disk: \(word)")
        }
    }

    @Test func theStepsAreTheOnesABoxNeeds() {
        let names = LinuxSetup.steps(user: "agent", tools: true).map(\.name)
        #expect(names == ["account agent", "package lists", "system updates", "git, jq, unzip, zip", "the compiler and make (build-essential)", "git settings"])
        #expect(!LinuxSetup.steps(user: "agent", tools: false).map(\.name).contains { $0.contains("build-essential") })
        let account = LinuxSetup.steps(user: "dev", tools: false)[0].script
        // The account has a locked password and no group but its own; a default account left
        // by the first boot stops the build.
        #expect(account.contains("/usr/sbin/useradd --create-home --shell /bin/bash --uid 1000 --user-group dev"))
        #expect(account.contains("/usr/bin/passwd --lock dev"))
        // Its own tool folder is there from the start, and its own: a login shell's profile
        // puts it on the path only when it exists.
        #expect(account.contains("/usr/bin/install -d -o dev -g dev -m 755 /home/dev/.local /home/dev/.local/bin; fi && /usr/bin/id dev"))
        // The same step runs in an image built from an image, and leaves a folder that is there.
        #expect(LinuxSetup.toolFolder(user: "dev").script.hasPrefix("if [ ! -d /home/dev/.local/bin ]; then /usr/bin/install -d "))
        #expect(account.contains("if /usr/bin/getent passwd debian > /dev/null || /usr/bin/getent passwd ubuntu > /dev/null; then"))
        // apt asks nothing and dpkg prints plain lines.
        #expect(LinuxSetup.environment["DEBIAN_FRONTEND"] == "noninteractive")
        #expect(LinuxSetup.apt == "/usr/bin/apt-get -q -y -o Dpkg::Use-Pty=0")
    }

    @Test func anotherKernelIsInstalledBeforeAnythingElse() {
        // No kernel to install: the cloud image's own stays, and no step speaks of one.
        #expect(!LinuxSetup.steps(user: "agent", tools: true).contains { $0.name.contains("kernel") })
        // What runs on the cloud image's kernel is the lists (apt must know the package) and
        // the kernel; the image is then booted again.
        #expect(LinuxSetup.kernelSwitch(Self.sixteen).map(\.name) == ["package lists", "kernel with 16 KiB pages (linux-image-arm64-16k)"])
        #expect(LinuxSetup.kernelSwitch(Self.sixteen, distribution: "ubuntu").map(\.name)
                == ["no restarts of services by apt (needrestart)", "package lists", "kernel with 16 KiB pages (linux-image-arm64-16k)"])
        // The rest runs after that boot, and does not do again what was done before it.
        #expect(LinuxSetup.steps(user: "agent", tools: false, afterKernelSwitch: true).map(\.name) == ["account agent", "system updates", "git, jq, unzip, zip", "git settings"])
        #expect(LinuxSetup.steps(user: "agent", tools: false, distribution: "ubuntu", afterKernelSwitch: true).map(\.name) == ["account agent", "system updates", "git, jq, unzip, zip", "git settings"])
        #expect(LinuxSetup.steps(user: "agent", tools: false).map(\.name) == ["account agent", "package lists", "system updates", "git, jq, unzip, zip", "git settings"])
        #expect(LinuxSetup.waitForKernelBoot.script.hasPrefix("/usr/bin/cloud-init status --wait"))
        #expect(LinuxSetup.waitForKernelBoot.script.contains("/usr/lib/systemd/systemd-networkd-wait-online --timeout=30"))
        let script = LinuxSetup.kernel(Self.sixteen).script
        // The question about removing the running kernel is answered before anything is removed.
        #expect(script.hasPrefix("/usr/bin/echo 'linux-base linux-base/removing-running-kernel boolean false' | /usr/bin/debconf-set-selections || exit 1; /usr/bin/apt-get -q -y -o Dpkg::Use-Pty=0 install linux-image-arm64-16k || exit 1; "))
        // Every installed kernel package of another flavor goes, and the step fails when a
        // kernel of another flavor is still in /boot.
        #expect(script.contains(#"| /usr/bin/sed -n 's/^installed //p' | /usr/bin/grep -v -e '-arm64-16k$' -e '^linux-image-arm64-16k$')"; if [ -n "$others" ]; then /usr/bin/apt-get -q -y -o Dpkg::Use-Pty=0 purge $others || exit 1; fi; "#))
        // The modules packages are in the list: Ubuntu's would bring the kernel's unsigned build in.
        #expect(script.contains(#"'linux-image-*' 'linux-modules-*' 'linux-main-modules-*' 2> /dev/null | /usr/bin/sed"#))
        #expect(script.contains(#"if [ "$left" != "0" ]; then /usr/bin/ls /boot; exit 1; fi"#))
        // The way back names its own flavor.
        #expect(LinuxSetup.kernel(LinuxKernel(pageBytes: 4096, package: "linux-image-cloud-arm64", flavor: "cloud-arm64")).script.contains("grep -v -e '-cloud-arm64$'"))
        // The package itself is kept by name: Ubuntu's "linux-image-virtual" does not end with its flavor.
        #expect(LinuxSetup.kernel(LinuxKernel(pageBytes: 4096, package: "linux-image-virtual", flavor: "generic")).script.contains("grep -v -e '-generic$' -e '^linux-image-virtual$'"))
        #expect(LinuxSetup.pageSize == "/usr/bin/getconf PAGESIZE")
    }

    @Test func sealingRemovesTheWaysInAndTheChecksNameThem() {
        let seal = LinuxSetup.seal.map(\.script).joined(separator: "\n")
        // The ssh server is purged, not disabled, and what systemd opened for it is closed.
        #expect(seal.contains("purge openssh-server unattended-upgrades $polkitd"))
        // polkitd stays only beside the rules a desktop's recipe chose.
        #expect(seal.contains(#"polkitd=polkitd; if [ -f /etc/polkit-1/rules.d/00-agent-vm.rules ]; then polkitd=""; fi; "#))
        #expect(seal.contains("systemctl stop sshd-vsock.socket sshd-unix-local.socket"))
        // A purge that fails fails the step: the commands after it do not hide its status.
        #expect(seal.contains("/usr/bin/apt-get -q -y -o Dpkg::Use-Pty=0 clean || exit 1; /usr/bin/systemctl stop"))
        #expect(seal.contains("apt-daily.timer apt-daily-upgrade.timer"))
        #expect(seal.contains("/etc/cloud/cloud-init.disabled"))
        #expect(seal.contains(#"name: "en*""#))
        #expect(seal.contains("/usr/bin/rm -f /etc/netplan/50-cloud-init.yaml"))
        // Last on the kernel's line, whatever the image's own settings name before it.
        #expect(seal.contains(#"GRUB_CMDLINE_LINUX_DEFAULT="$GRUB_CMDLINE_LINUX_DEFAULT console=hvc0""#))
        #expect(seal.contains("LLMNR=no"))
        #expect(seal.contains("vmw_vsock_virtio_transport"))
        #expect(seal.contains("'kernel.panic_on_oops = 1\\n' > /etc/sysctl.d/90-agent-vm.conf"))
        #expect(LinuxSetup.stopOnKernelFaultRequest.user == "root")
        #expect(LinuxSetup.stopOnKernelFaultRequest.argv?.last == #"/usr/bin/printf '1\n' > /proc/sys/kernel/panic_on_oops"#)
        let checks = LinuxSetup.sealChecks(daemonPort: 1024)
        #expect(checks.map(\.name) == ["no ssh server", "no ssh server unit", "nothing listens on TCP port 22", "no TCP port is open to the network",
                                       "nothing listens on vsock but the guest daemon", "the removed packages are gone",
                                       "polkitd is gone, or has the rules a desktop's recipe chose", "no update timer is on",
                                       "no account has a usable password", "cloud-init is off"])
        // The daemon's own port is the one vsock listener allowed, and the user is the image's.
        #expect(checks[4].script.contains("[:*]1024[[:space:]]"))
        // ... and it must be there: an empty list proves nothing.
        #expect(checks[4].script.contains(#"[ "$own" != "1" ]"#))
        // polkitd: gone, Debian's rules, or the rule that refuses all but a console switch,
        // unchanged and read first.
        let polkit = checks[6].script
        #expect(polkit.contains(#"if [ "$first" = '// agent-vm polkit=debian' ]; then if [ "$(/usr/bin/cat /etc/polkit-1/rules.d/00-agent-vm.rules)" != '// agent-vm polkit=debian' ]"#))
        // With Debian's rules, every other rules file must be a package's, by a name dpkg cannot
        // take for a pattern.
        #expect(polkit.contains(#"! -path /etc/polkit-1/rules.d/00-agent-vm.rules -exec /usr/bin/sh -c 'case "$1" in *[!A-Za-z0-9._/-]*) /usr/bin/printf "%s\n" "$1"; exit 0;; esac; /usr/bin/dpkg -S "$1" > /dev/null 2>&1 || /usr/bin/printf "%s\n" "$1"' sh {} ';'"#))
        #expect(polkit.contains("'\(LinuxSetup.polkitDeny)' '\(LinuxSetup.polkitDenyRule)'"))
        #expect(polkit.contains("/usr/bin/find /etc/polkit-1/rules.d /run/polkit-1/rules.d /usr/local/share/polkit-1/rules.d /usr/share/polkit-1/rules.d -mindepth 1 -maxdepth 1 -name '*.rules' -printf '%f\\0'"))
        #expect(!LinuxSetup.polkitDenyRule.contains("'"))
        // The account is checked before the recipes, which may give it sudo on purpose: the
        // check is not among those run after them.
        let account = LinuxSetup.accountCheck(user: "dev")
        #expect(account.script.contains("/usr/bin/id -nG dev") && account.script.contains("/usr/bin/sudo -n -l -U dev"))
        // Every check ends with a status other than 0 when it finds something.
        for check in checks + [account] {
            #expect(check.script.contains("exit 1"), "\(check.name)")
        }
        #expect(LinuxSetup.prepareForCloning.contains("/usr/bin/truncate -s 0 /etc/machine-id"))
    }

    /// The desktop recipes that keep polkitd write, in their steps and their update steps, the
    /// rules the seal check accepts, word for word.
    @Test func desktopRecipesWriteThePolkitRulesTheSealAccepts() throws {
        let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Recipes")
        for name in ["linux-gnome", "linux-kde"] {
            let recipe = try ImageRecipe.load(from: folder.appendingPathComponent(name).appendingPathComponent("recipe.json"))
            var writers = 0
            for step in recipe.steps + recipe.updateSteps {
                guard case let .run(script) = step.action, script.contains(LinuxSetup.polkitRules) else {
                    continue
                }
                writers += 1
                #expect(script.contains("printf '%s\\n' '\(LinuxSetup.polkitDeny)' '\(LinuxSetup.polkitDenyRule)' > "), "\(name): \(step.name)")
                #expect(script.contains("printf '%s\\n' '\(LinuxSetup.polkitDebian)' > "), "\(name): \(step.name)")
            }
            #expect(writers == 2, "\(name)")
            #expect(recipe.parameters.map(\.name) == ["polkit"] && recipe.screen == true, "\(name)")
        }
    }

    @Test func ubuntuSealsWhatItAlonehas() {
        // Debian's list is the shared one.
        #expect(LinuxSetup.seal(distribution: "debian") == LinuxSetup.seal)
        let ubuntu = LinuxSetup.seal(distribution: "ubuntu")
        #expect(ubuntu.count == LinuxSetup.seal.count + 1)
        // After the shared removal, before the rest.
        #expect(ubuntu[0] == LinuxSetup.seal[0] && Array(ubuntu.dropFirst(2)) == Array(LinuxSetup.seal.dropFirst()))
        let own = ubuntu[1].script
        for package in ["snapd", "lxd-installer", "ubuntu-pro-client", "update-notifier-common", "needrestart", "udisks2", "open-vm-tools"] {
            #expect(own.contains(" \(package) ") || own.contains(" \(package) &&"), "\(package)")
        }
        // A purge that fails fails the step.
        #expect(own.contains("clean || exit 1; /usr/bin/rm -rf /snap "))
        // needrestart goes first of all, right after the account, and only on Ubuntu; until it
        // is gone, and in a derived build of an image that has it, the environment stops it.
        let setup = LinuxSetup.steps(user: "agent", tools: true, distribution: "ubuntu")
        #expect(setup[1] == LinuxSetup.removeNeedrestart && setup[2] == LinuxSetup.packageLists)
        #expect(setup.count == LinuxSetup.steps(user: "agent", tools: true).count + 1)
        #expect(!LinuxSetup.steps(user: "agent", tools: true).contains(LinuxSetup.removeNeedrestart))
        #expect(LinuxSetup.environment["NEEDRESTART_SUSPEND"] == "1")
        // The news timer stays with its package and is switched off.
        #expect(own.contains("motd-news.timer") && own.contains(#"/usr/bin/systemctl disable --now "$timer" || exit 1"#))
        // The checks name what was removed and switched off, for each system its own.
        let checks = LinuxSetup.sealChecks(distribution: "ubuntu", daemonPort: 1024)
        #expect(checks.map(\.name) == LinuxSetup.sealChecks(daemonPort: 1024).map(\.name))
        #expect(checks[5].script.contains("openssh-server unattended-upgrades snapd lxd-installer"))
        #expect(checks[7].script.contains("apt-daily.timer apt-daily-upgrade.timer motd-news.timer"))
        let debian = LinuxSetup.sealChecks(daemonPort: 1024)
        #expect(!debian[5].script.contains("snapd") && !debian[7].script.contains("motd-news"))
        #expect(debian[7].script.contains("for timer in apt-daily.timer apt-daily-upgrade.timer; do"))
    }

    @Test func osReleaseIsReadStrictly() throws {
        let debian = """
            PRETTY_NAME="Debian GNU/Linux 13 (trixie)"
            NAME="Debian GNU/Linux"
            VERSION_ID="13"
            VERSION="13 (trixie)"
            VERSION_CODENAME=trixie
            ID=debian
            HOME_URL="https://www.debian.org/"
            """
        let parsed = try LinuxSetup.parseOSRelease(debian)
        #expect(parsed.distribution == "debian" && parsed.version == "13" && parsed.name == "Debian GNU/Linux 13 (trixie)")
        // Single quotes and no quotes are the same value.
        #expect(try LinuxSetup.parseOSRelease("ID='ubuntu'\nVERSION_ID=26.04\nPRETTY_NAME=Ubuntu").version == "26.04")

        func refused(_ text: String, _ comment: Comment) {
            #expect(throws: AgentVMError.self, comment) { _ = try LinuxSetup.parseOSRelease(text) }
        }
        refused("VERSION_ID=13\nPRETTY_NAME=x", "no ID")
        refused("ID=debian\nPRETTY_NAME=x", "no VERSION_ID")
        refused("ID=debian\nVERSION_ID=13", "no PRETTY_NAME")
        refused("ID=debian\nID=other\nVERSION_ID=13\nPRETTY_NAME=x", "a key twice")
        refused("ID=deb ian\nVERSION_ID=13\nPRETTY_NAME=x", "a space in the ID")
        refused("ID=debian\nVERSION_ID=13\nPRETTY_NAME=\"a\u{1B}[31mred\"", "an escape sequence in the name")
        refused("ID=debian\nVERSION_ID=13\nPRETTY_NAME=\"a\\nb\"", "a backslash in the name")
        refused("ID=debian\nVERSION_ID=13\nPRETTY_NAME=\(String(repeating: "n", count: 81))", "a long name")
        refused("ID=debian\nVERSION_ID=\(String(repeating: "1", count: 33))\nPRETTY_NAME=x", "a long version")
        refused("ID=debian\nVERSION_ID=13\nPRETTY_NAME=x\nJUNK=\(String(repeating: "j", count: 10_000))", "a 10 KB file")
        // The message says what is wrong and repeats nothing the guest said.
        #expect(throws: AgentVMError.guestCommandFailed(command: "read the system's description", status: 0, output: "/etc/os-release has no usable ID")) {
            _ = try LinuxSetup.parseOSRelease("ID=\u{1B}]0;title\u{07}\nVERSION_ID=13\nPRETTY_NAME=x")
        }
    }

    @Test func theKernelAndArchitectureAreTokens() throws {
        #expect(try LinuxSetup.token("6.12.111+deb13-cloud-arm64\n", what: "kernel version") == "6.12.111+deb13-cloud-arm64")
        #expect(try LinuxSetup.token("arm64", what: "architecture") == "arm64")
        for bad in ["6.12\nsecond line\n", "6.12\u{1B}[2J", String(repeating: "k", count: 200), "", "two words", "a/b"] {
            #expect(throws: AgentVMError.self, "\(bad.debugDescription)") { _ = try LinuxSetup.token(bad, what: "kernel version") }
        }
    }

    @Test func debianNamesAreRefusedAsUserNames() {
        for name in ["agent", "dev", "me_2"] {
            #expect(LinuxSetup.isValidUserName(name), "\(name)")
        }
        for name in ["bin", "sys", "sync", "games", "man", "mail", "news", "proxy", "backup", "list", "irc", "sudo", "adm", "users", "debian",
                     "ubuntu", "admin", "lxd", "syslog", "staff", "www-data",
                     "systemd-network", "systemd", "_apt", "root", "nobody", "Agent", "a b", ""] {
            #expect(!LinuxSetup.isValidUserName(name), "\(name)")
        }
        // The macOS rule is not narrowed by the Linux list.
        #expect(ImageBuildOptions.isValidUserName("debian"))
    }

    // MARK: - The daemon's unit

    @Test func theUnitKeepsTheDaemonWhateverItsProgramsDo() {
        let unit = GuestDaemon.systemdUnit(user: "dev")
        #expect(unit.contains("ExecStart=/usr/local/libexec/agent-vm-guest serve --user dev\n"))
        for line in ["Restart=always", "RestartSec=1", "StartLimitIntervalSec=0", "TimeoutStopSec=10", "OOMPolicy=continue", "OOMScoreAdjust=-900",
                     "TasksMax=infinity", "WantedBy=multi-user.target", "StandardOutput=append:/var/log/agent-vm-guest.log"] {
            #expect(unit.contains(line + "\n"), "\(line)")
        }
        #expect(unit.hasSuffix("\n"))
        #expect(GuestDaemon.linuxUnitPath == "/etc/systemd/system/agent-vm-guest.service")
    }
}

@Suite struct SeedDiskTests {
    static let digest = String(repeating: "5e", count: 32)

    @Test func userDataCreatesNoUserAndRunsOneCommand() {
        let text = SeedDisk.userData(daemonDigest: Self.digest)
        #expect(text.hasPrefix("#cloud-config\n"))
        #expect(text.contains("\nusers: []\n"))
        #expect(text.contains("\nssh_pwauth: false\n"))
        // One command, and nothing that names a user, a key or a password.
        #expect(text.components(separatedBy: "\n  - ").count == 2)
        for word in ["passwd", "ssh_authorized_keys", "sudo", "chpasswd", "write_files"] {
            #expect(!text.contains(word), "\(word)")
        }
        // The command is one double-quoted YAML string: nothing in it may end the string early.
        let command = text.components(separatedBy: "-c, \"")[1].components(separatedBy: "\" ]")[0]
        #expect(!command.contains("\"") && !command.contains("\\") && !command.contains("\n"))
        #expect(command.contains("/usr/bin/mount -o ro /dev/disk/by-label/cidata /run/agent-vm-seed"))
        #expect(command.contains("/usr/bin/systemctl enable --now agent-vm-guest.service"))
        #expect(SeedDisk.metaData(instance: "agent-vm-1") == "instance-id: agent-vm-1\nlocal-hostname: box\n")
    }

    @Test func theCommandNamesTheDaemonsDigest() {
        let text = SeedDisk.userData(daemonDigest: Self.digest)
        // Checked where it was installed, before the unit is enabled.
        let check = "/usr/bin/echo '\(Self.digest)  /usr/local/libexec/agent-vm-guest' | /usr/bin/sha256sum -c --status"
        #expect(text.contains(check))
        let order = ["/usr/bin/install -D -m 755", check, "/usr/bin/systemctl enable --now"].map { text.range(of: $0)?.lowerBound }
        #expect(order.allSatisfy { $0 != nil })
        #expect(order[0]! < order[1]! && order[1]! < order[2]!)
    }

    /// A stand-in for the Linux daemon: any file will do.
    static func daemon(in scratch: Scratch) throws -> URL {
        let url = scratch.root.appendingPathComponent("agent-vm-guest")
        try Data((0..<4096).map { UInt8($0 & 0xFF) }).write(to: url)
        return url
    }

    @Test func theImageHoldsTheFourFiles() throws {
        let scratch = try Scratch()
        let daemon = try Self.daemon(in: scratch)
        let disk = scratch.root.appendingPathComponent("Seed.iso")
        try SeedDisk.make(at: disk, daemon: daemon, unit: GuestDaemon.systemdUnit(user: "agent"), instance: "agent-vm-test")
        let listing = try Self.run("/usr/bin/tar", ["-tf", disk.path])
        let names = Set(listing.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "./")) }.filter { !$0.isEmpty })
        #expect(names == ["user-data", "meta-data", "agent-vm-guest", "agent-vm-guest.service"])
        // The files are what was put in: the daemon byte for byte, and the user data with its digest.
        let out = scratch.root.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        _ = try Self.run("/usr/bin/tar", ["-xf", disk.path, "-C", out.path])
        #expect(try Data(contentsOf: out.appendingPathComponent("agent-vm-guest")) == Data(contentsOf: daemon))
        let userData = try String(contentsOf: out.appendingPathComponent("user-data"), encoding: .utf8)
        #expect(userData == SeedDisk.userData(daemonDigest: try ImageBuilder.sha256(of: daemon)))
        #expect(try String(contentsOf: out.appendingPathComponent("meta-data"), encoding: .utf8) == "instance-id: agent-vm-test\nlocal-hostname: box\n")
        // Nothing is left beside the disk.
        #expect(try FileManager.default.contentsOfDirectory(atPath: scratch.root.path).filter { $0.hasPrefix(".seed") }.isEmpty)
        // Made again over an old one.
        try SeedDisk.make(at: disk, daemon: daemon, unit: "x", instance: "second")
        #expect(FileSystem.exists(disk.path))
    }

    @Test func theVolumeIsNamedCidata() throws {
        let scratch = try Scratch()
        let disk = scratch.root.appendingPathComponent("Seed.iso")
        try SeedDisk.make(at: disk, daemon: try Self.daemon(in: scratch), unit: "unit", instance: "i")
        // An ISO 9660 primary volume descriptor is the block at 32768: its type (1), "CD001",
        // and the volume's name at offset 40, padded to 32 characters.
        let handle = try FileHandle(forReadingFrom: disk)
        defer { try? handle.close() }
        try handle.seek(toOffset: 32768)
        let descriptor = try handle.read(upToCount: 2048) ?? Data()
        #expect(descriptor.count == 2048)
        #expect(descriptor[0] == 1 && String(decoding: descriptor[1..<6], as: UTF8.self) == "CD001")
        let name = String(decoding: descriptor[40..<72], as: UTF8.self).trimmingCharacters(in: CharacterSet(charactersIn: " \0"))
        #expect(name.lowercased() == "cidata")
    }

    static func run(_ tool: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw AgentVMError.system(operation: "\(tool) \(arguments.joined(separator: " "))", code: process.terminationStatus)
        }
        return String(decoding: data, as: UTF8.self)
    }
}
