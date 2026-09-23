# agent-vm

Run AI agents and their tools inside disposable macOS virtual machines, so a mistaken, prompt-injected or malicious agent cannot reach the rest of your Mac.

> **Status:** early development. Sessions (snapshot, change report and undo) work today, with or without a virtual machine; so do golden images (`image create`, macOS installed and set up with no clicks) and `doctor`. Everything else in this README describes the intended tool so the interface can be reviewed before it is built.

## What it does

An AI coding agent (Claude Code, Codex, opencode, or any tool an agent drives) runs inside a macOS virtual machine - a "box" - instead of directly on your Mac:

- **Only your project is shared.** The project folder is mounted at the same path inside the box. Your home folder, Keychain, SSH keys, other projects and browser data do not exist there.
- **Network is allowlisted.** The box has no route to your Mac or your local network. Outbound connections go through a proxy on the host that allows only the hosts you choose (package registries, the agent's API) and logs every connection.
- **Every session can be undone.** Before a session starts, `agent-vm` takes an instant snapshot of the project. Afterwards it reports what changed, flags files that run code later on your Mac (git hooks, build scripts, package install scripts), and can restore the snapshot.
- **Boxes are disposable.** A box is a copy-on-write clone of a sealed "golden" image, created in seconds and discarded after use, so nothing an agent plants survives.
- **Model inference stays on your Mac.** Local models keep the full GPU; only the agent and its tools run in the box.

It builds on Apple's Virtualization framework and the zero-click macOS guest setup added in macOS 27.

## Requirements

- A Mac with Apple silicon
- macOS 27 or later (host and guest)
- Disk space for one golden image (tens of GB) plus per-box changes

## Intended usage

```sh
agent-vm image create macos-dev          # install macOS and set it up - no clicks
agent-vm box create dev --image macos-dev
agent-vm exec --box dev --project ~/src/myapp --net allowlist:npm,github-read -- claude
agent-vm session report <id>              # what changed, with risky files flagged
agent-vm session undo <id>                # restore the project snapshot
```

`agent-vm exec` streams stdin, stdout and stderr, forwards signals and returns the command's exit status, so it can wrap any stdio program - including Agent Client Protocol (ACP) agents and Model Context Protocol (MCP) servers launched by another application.

## Sessions: snapshot, report and undo (works today)

A session protects a project folder while an agent works on it - in a box, or directly on your Mac. It is useful on its own: run it around any agent session.

```sh
agent-vm session start --project ~/src/myapp   # instant snapshot, prints the session id
# ... let the agent work ...
agent-vm session report <id>                   # what changed, with risky files flagged
agent-vm session end <id>                      # optional: mark the run finished
agent-vm session undo <id>                     # put the project back as it was at start
agent-vm session discard <id>                  # delete the snapshot when you no longer need undo
agent-vm session list                          # all sessions and their states
```

- **The snapshot is instant and nearly free.** Every file is cloned copy-on-write on APFS, so it takes space only as the agent changes files.
- **The report shows what changed and what to look at first.** Additions, deletions, modifications, type and permission changes, with whole new or deleted folders collapsed to one line. A change is found by content, not by modification time: a file is unchanged when its status-change time (ctime, which a process cannot set), and that of every folder above it, is older than the session start (a moved folder gets a new ctime, the files inside it keep theirs); every other file is compared with its snapshot copy, instantly while both are still APFS clones of the same data, otherwise byte for byte.
- **Flags mark what would run later on your Mac** - the return path an agent can use even when boxed: git hooks and git configuration (`core.hooksPath`, `core.fsmonitor`, filters), the agents' own configuration and instructions (`.mcp.json`, `.claude/`, `.codex/`, `opencode.json`, `.cursor/`, `CLAUDE.md`, `AGENTS.md`), CI workflows, editor tasks and `.envrc`, build scripts, package manifests, Xcode projects and schemes, new executables (files the agent writes carry no quarantine attribute, so Gatekeeper will not check them), and symlinks that point outside the project. Any other hidden file is marked too. Flags are a review aid, not a security boundary. `--fail-on high` exits with status 2 when something high is flagged, for scripts.
- **Undo restores only what changed and loses nothing.** Each changed entry is put back from the snapshot; the agent's version is moved into the session folder, mirroring its path, never deleted; the snapshot stays. The project folder keeps its identity, so editors and shells with it open stay attached. `undo --whole-tree` instead swaps the whole folder with a copy of the snapshot in one atomic step. Stop the agent before undoing either way.
- **Neither undo nor discard can be blocked by the agent.** Folders it made read-only or unreadable, files it locked (`chflags uchg`) and access control lists it added (`chmod +a "everyone deny delete"`) are opened up first; symlinks are never followed. Sockets and FIFOs are left out of the snapshot.
- **Guard rails.** A session refuses `/`, your home folder or any folder containing it, and folders overlapping the agent-vm store; only one active session per project.
- **Where state lives.** `~/Library/Application Support/agent-vm/Sessions/<id>/`, or `$AGENT_VM_HOME/Sessions/<id>/`. The project must be on the same APFS volume as the store; for a project on another volume, point `AGENT_VM_HOME` at a folder on that volume.
- **Known limits.** Access control lists and extended attributes an agent adds or changes are neither reported nor undone. A file nobody can read (mode 000) stops `start`, because it cannot be snapshotted. Sockets and FIFOs are neither snapshotted nor reported.
- **For programs.** Every session command accepts `--json`: the session record, the change report, or the undo result.

| State | Meaning |
|---|---|
| `active` | Snapshot taken; the agent may still be working. |
| `ended` | The run is over; undo is still available. |
| `undone` | The project was restored; what the agent left is kept in the session folder. |
| `discarded` | Snapshot and replaced tree deleted; only the record remains. |

## Images: macOS installed and set up with no clicks (works today)

A golden image is the macOS guest boxes will be cloned from. `image create` installs macOS from a restore image (`.ipsw`) and sets it up without a single click, using the guest provisioning added to Virtualization in macOS 27: the first boot creates an administrator account, logs it in automatically and turns on Remote Login. agent-vm then copies its guest daemon in over SSH, checks that it answers over vsock and runs programs as the account, turns Remote Login off again, and shuts the guest down through the daemon.

```sh
Scripts/build.sh                                    # signed agent-vm and agent-vm-guest
.build/signed/release/agent-vm image create dev --ipsw ~/Downloads/UniversalMac_27.0_26A428_Restore.ipsw
agent-vm image list
agent-vm image delete dev
```

- **Takes about 4 minutes** on a MacBook Air M5 from a local restore image: about 3 minutes to install, then about a minute for the first boot, the SSH check of the new account, the guest daemon, and a clean shutdown. The disk is a 64 GB sparse file that holds about 28 GB after setup.
- **The guest daemon** (`agent-vm-guest`, a root LaunchDaemon started at boot) is the only way into a finished image: it runs programs for the host over vsock, needs no network, and accepts connections only from the host. Its protocol is described in [Docs/guest-protocol.md](Docs/guest-protocol.md). `image create` installs the `agent-vm-guest` found next to `agent-vm` (or `--guest-daemon <path>`).
- **Options:** `--cpus` (default 4), `--memory-gb` (8), `--disk-gb` (64; at least 40), `--user` (the account name, default `agent`). Values below what the restore image requires are raised to its minimum.
- **The account's password** is 24 random characters, stored only in the image folder (`Password`, mode 0600). During the build, agent-vm reaches the guest with the system's `/usr/bin/ssh` using password authentication, until the daemon is in place. It never uses your SSH configuration, keys, agent or `known_hosts` file: the guest's host key goes into the image folder.
- **Where it lives:** `~/Library/Application Support/agent-vm/Images/<name>/` (or `$AGENT_VM_HOME/Images/<name>/`): `image.json` (state, macOS version and build, resources, timings, guest daemon version and protocol), the disk, the auxiliary storage, the hardware model and the machine identifier.
- **A failed or interrupted build** stays in the list with its state (`installing`, `provisioning`) or `failed` and the reason; delete it and create it again. An image in use by another agent-vm process cannot be deleted.
- **Not yet:** downloading the restore image (get it from Apple, or reuse the one a VM app such as Viable keeps in its bundle), and developer tools in the image (Command Line Tools install non-interactively; measured, not yet automated).

## Building

```sh
swift build
swift test
Scripts/build.sh                          # release build, signed ad hoc for this Mac
Scripts/build.sh --identity <Developer ID Application identity or team ID>
.build/signed/release/agent-vm doctor     # can this Mac and this binary run boxes?
```

Virtualization refuses every virtual machine from a process without the `com.apple.security.virtualization` entitlement (`Resources/agent-vm.entitlements`). Any developer can use it without Apple's approval, but a plain `swift build` does not sign it in, so `session` commands work from `.build/debug/agent-vm` while anything that starts a virtual machine needs the output of `Scripts/build.sh`. The script builds `agent-vm` and `agent-vm-guest`, signs copies in `.build/signed/<configuration>/` with the hardened runtime (ad hoc by default, or with a Developer ID and a secure timestamp; `AGENT_VM_SIGN_IDENTITY` sets the default), verifies the signatures and runs `agent-vm doctor` with the result.

`agent-vm doctor` checks the macOS version, Apple silicon, the binary's entitlement and signature, free space for the store, and how many virtual machines already run (macOS runs at most two macOS guests at once, whichever applications started them). It exits 1 when something prevents running boxes; `--json` prints the checks for programs.

## License

Apache License 2.0 - see [LICENSE](LICENSE).
