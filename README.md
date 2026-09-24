# agent-vm

Run AI agents and their tools inside disposable macOS virtual machines, so a mistaken, prompt-injected or malicious agent cannot reach the rest of your Mac.

> **Status:** early development. Working today: sessions (snapshot, change report and undo, with or without a virtual machine), golden images (`image create`, macOS installed and set up with no clicks), boxes with `agent-vm exec`, the allowlist network with host packs and a connection log, projects shared at the same path, and `doctor`. The rest of this README describes the intended tool: packs for tools installed in images, disposable per-session boxes and the Cadabra integration are not built yet.

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

## Usage

```sh
agent-vm image create macos-dev --ipsw <restore image>   # install macOS and set it up - no clicks
agent-vm box create dev --image macos-dev --allow pack:npm --allow pack:github --allow pack:anthropic
agent-vm box start dev
agent-vm session start --project ~/src/myapp             # snapshot, prints the session id
agent-vm exec --box dev --project ~/src/myapp -- claude
agent-vm session report <id>                             # what changed, with risky files flagged
agent-vm session undo <id>                               # restore the project snapshot
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

## Boxes and exec (works today)

A box is an instant copy-on-write clone of a ready image with its own identity (MAC address, machine identifier). `box start` runs it in the background under a supervisor process that owns the virtual machine; `agent-vm exec` runs programs in it.

```sh
agent-vm box create dev1 --image dev --allow pack:github --allow pypi.org   # instant APFS clone
agent-vm box start dev1                       # boots in about 10 seconds, waits until ready
agent-vm exec --box dev1 -- uname -a
printf 'b\na\n' | agent-vm exec --box dev1 -- sort
agent-vm exec --box dev1 --cwd /tmp --env FOO=bar -- sh -c 'echo $FOO; pwd'
agent-vm box list
agent-vm box stop dev1                        # clean shutdown through the guest daemon
agent-vm box delete dev1
```

- **`exec` behaves like the program itself.**
  - stdin, stdout and stderr are streamed: about 550 MB/s out of the box, 430 MB/s into it.
  - SIGINT, SIGTERM, SIGHUP, SIGQUIT, SIGUSR1 and SIGUSR2 go to the program's process group.
  - The exit status is the program's: 128 + the signal number when a signal ended it, 127 when the program is not found, 126 when it cannot be started, and 125 when agent-vm itself fails (for example, the box is not running). A closed output (`exec ... | head -1`) ends `exec` with 141, as SIGPIPE would end the program locally, and the program is hung up.
  - If `agent-vm exec` is killed, the program gets SIGHUP, then SIGKILL 3 seconds later.
  - Programs run as the box user in their home folder unless `--user` or `--cwd` say otherwise.
- **How it connects:** `exec` asks the box's supervisor, over a Unix socket only you can use (`Boxes/<name>/control.sock`), for a connection to the guest daemon. It then talks to the daemon directly, so the supervisor is not in the data path.
- **Boxes need the image's volume**: the clone costs nothing until the box writes, and the box's disk grows as the guest works.
- **`box start` is safe to repeat**: on a running box it reports the box, and during another start it waits for that one.
- **The supervisor** is `agent-vm box serve <name>` in its own session, logging to `Boxes/<name>/supervisor.log`. It holds the box's lock, so a running box cannot be deleted or started twice. SIGTERM, SIGINT or SIGHUP to it stop the box cleanly, the same as `box stop`.
- **macOS runs at most two macOS guests at once**, whichever applications started them (`agent-vm doctor` counts them).
- **Socket paths:** the control socket's full path must stay under 104 bytes, which a very long `AGENT_VM_HOME` can exceed.

## Network: allowlist, off or open (works today)

Every box has a network mode, chosen at `box create --net` (default `allowlist`) and changed with `box network`:

| Mode | The box's network card | Reaches | Logged |
|---|---|---|---|
| `allowlist` | leads nowhere (a fixed address, no route, no DNS) | only listed hosts, through a proxy on this Mac | every attempt |
| `off` | leads nowhere | nothing | every attempt |
| `open` | NAT through this Mac | the internet and your local network | no |

```sh
agent-vm box create dev1 --image dev --allow pack:github --allow '*.example.com' --allow api.example.org:8443
agent-vm box network dev1 --allow pypi.org --allow files.pythonhosted.org   # takes effect at once
agent-vm box network dev1 --disallow pypi.org
agent-vm box netlog dev1 --denied --last 20                                  # what was refused, and why
agent-vm box packs                                                           # the built-in host lists
agent-vm box network dev1 --net open                                         # while the box is stopped
```

- **How the allowlist works.** Programs in the box see a system proxy at 127.0.0.1:3128 (set in the guest's network settings, and as `HTTP_PROXY`/`HTTPS_PROXY` for programs run by `exec`). The guest daemon relays it over vsock to a proxy in the box's supervisor on this Mac. That proxy serves `CONNECT` (HTTPS and anything else tunneled) and plain `http://` requests. It checks each against the rules by host name and port, resolves the name here on the Mac, and connects only to public addresses: an allowed name that resolves to this Mac or your local network is refused (a DNS rebinding defense). Nothing else leaves the box: it has no route and no DNS, so tools that ignore the proxy fail at once.
- **Rules:**
  - `github.com` allows exactly that host, and `*.github.com` its subdomains, not the host itself.
  - A rule without a port allows HTTPS (`CONNECT` to 443) and plain HTTP (`http://` requests to 80), and `host:port` allows that port for both. There are no tunnels to port 80 without an explicit rule: raw requests through a tunnel could name any other site the allowed server hosts. For plain HTTP, the proxy writes the `Host` header from the URL itself.
  - `pack:<name>` allows a curated list: `apple-updates`, `github`, `npm`, `pypi`, `swiftpm`, `homebrew`, `anthropic` and `openai` (`box packs` lists the hosts).
- **Which tools follow the proxy** (measured): URLSession programs, `softwareupdate`, Python and pip use the system proxy; curl, git, SwiftPM and Node need the environment variables, which `exec` sets. git over SSH is not proxied; use HTTPS remotes.
- **The log** (`Boxes/<name>/network.jsonl`, one JSON object per line) records the time, method, host and port, the decision and rule, the address connected to, and the bytes each way.
  - macOS's own background services (iCloud, software update checks) show up as refused connections unless allowed, about 2-4 a second from an idle guest.
  - At 64 MB the log moves to `network.jsonl.1`, replacing the previous one.
- **Limits against a hostile guest:**
  - at most 256 proxied connections at once (the next get 503);
  - 30 seconds to send a complete request head of at most 16 KB;
  - log fields cut to 256 characters.
- **Rules can change while a box runs**: the supervisor rereads them at once. The mode decides the network card, so it changes only while the box is stopped.
- **Boxes created before network policy** keep running on NAT (`open`).

## Projects: your folder in the box, at the same path (works today)

```sh
agent-vm exec --box dev1 --project ~/src/myapp -- swift test      # runs in /Users/you/src/myapp in the box
agent-vm exec --box dev1 --project ~/src/myapp --read-only -- grep -r TODO .
agent-vm session start --project ~/src/myapp                      # snapshot first, to review and undo afterwards
```

- **Same path on both sides**: the project appears in the box at its absolute path on your Mac, so paths in build logs, error messages and editor links match. Programs started with `--project` begin in that folder.
- **Live**: the box edits your real folder, and you see changes as they happen. Take a session snapshot first (`agent-vm session start`) to get a change report with risky files flagged, and undo.
- **One project per box at a time**: while a program started with `--project` runs, a different folder or mode is refused; afterwards, `--project` with another folder replaces the previous one. The share lasts until the box stops.
- **The project's parent folder in the box** must be new or hold only folders, because the share is mounted on it and would hide anything there. So `/Users/Shared/<project>` is refused, since the box has `/Users/Shared/.localized`.
- **Owners map across**: files you own appear owned by the box user inside the box, and what the box user creates is owned by you on the Mac.
- **Not shareable**: `/` and folders directly in it, your home folder or any folder containing it, anything inside `~/Library` or a hidden folder of your home (`~/.ssh`, `~/.aws`, ...), and anything overlapping the agent-vm store. These are checked by folder identity, so other names for the same folders (`/System/Volumes/Data/Users/...`) are refused too; session snapshots follow the same home-folder rule.
- **Keep build output inside the box.** Large files cross the share quickly (1 GB written in 0.7 s), but creating many small files is about 8 times slower than on the box's own disk, and walking a tree about 30 times slower. Put build products on the box's disk: Xcode's DerivedData already lives in the box user's Library, and `swift build --scratch-path ~/build/myapp` does the same for SwiftPM.
- **How it works**: each box has one virtio file system device, filled on the running box and mounted by the guest daemon. It uses Apple's automount tag: with any other tag, macOS treats the share as a network volume and holds every program not run as root on a privacy prompt nobody can see. The project sits inside a small read-only root mounted on its parent folder, so the guest's volume housekeeping (`.fseventsd`, `.Trashes`) never lands in your project.

## Images: macOS installed and set up with no clicks (works today)

A golden image is the macOS guest boxes will be cloned from. `image create` installs macOS from a restore image (`.ipsw`) and sets it up without a single click, using the guest provisioning added to Virtualization in macOS 27: the first boot creates an administrator account, logs it in automatically and turns on Remote Login. agent-vm then copies its guest daemon in over SSH, checks that it answers over vsock and runs programs as the account, turns Remote Login off again, and shuts the guest down through the daemon.

```sh
Scripts/build.sh                                    # signed agent-vm and agent-vm-guest
.build/signed/release/agent-vm image create dev --ipsw ~/Downloads/UniversalMac_27.0_26A428_Restore.ipsw --recipe my-tools.json
agent-vm image list
agent-vm image delete dev
```

- **Takes about 6 minutes** on a MacBook Air M5 from a local restore image. About 3 minutes go to installing macOS, and about 3 more to the first boot: the SSH check of the new account, the guest daemon, the Command Line Tools and a clean shutdown. The disk is a 64 GB sparse file that holds about 28 GB after setup, plus about 2 GB for the tools.
- **Developer tools**: Xcode's Command Line Tools (clang, Swift, git, make, Python 3) are installed without a dialog. They are about 530 MB from Apple, so the build needs the internet; `--no-command-line-tools` skips them. Spotlight indexing is turned off in images: boxes have no use for it, and indexing a new disk slowed the tools install from about 2 to 26 minutes.
- **The guest daemon** (`agent-vm-guest`, a root LaunchDaemon started at boot) is the only way into a finished image: it runs programs for the host over vsock, needs no network, and accepts connections only from the host. Its protocol is described in [Docs/guest-protocol.md](Docs/guest-protocol.md). `image create` installs the `agent-vm-guest` found next to `agent-vm` (or `--guest-daemon <path>`).
- **Options:** `--cpus` (default 4), `--memory-gb` (8), `--disk-gb` (64; at least 40), `--user` (the account name, default `agent`), `--recipe`, `--no-command-line-tools`. Values below what the restore image requires are raised to its minimum.
- **The account's password** is 24 random characters, stored only in the image folder (`Password`, mode 0600). During the build, agent-vm reaches the guest with the system's `/usr/bin/ssh` using password authentication, until the daemon is in place. It never uses your SSH configuration, keys, agent or `known_hosts` file: the guest's host key goes into the image folder.
- **Where it lives:** `~/Library/Application Support/agent-vm/Images/<name>/` (or `$AGENT_VM_HOME/Images/<name>/`): `image.json` (state, macOS version and build, resources, timings, guest daemon version and protocol), the disk, the auxiliary storage, the hardware model and the machine identifier.
- **A failed or interrupted build** stays in the list with its state (`installing`, `provisioning`) or `failed` and the reason; delete it and create it again. An image in use by another agent-vm process cannot be deleted.
- **Images from images.** `image create <name> --from <image> --recipe <recipe.json>` clones a ready image and applies the recipe to the clone. The clone gets its own identity, is built on NAT, and costs only what the recipe adds. It takes minutes instead of a macOS install, so tool sets can be layered and rebuilt quickly: in a test, `dev` to `dev-node` (Homebrew and Node) took 2 minutes, then `dev-agents` (Claude Code, Codex, opencode) 1 minute. `image list` shows each image's base and recipe. Example recipes are in [Recipes/](Recipes/README.md).
- **Recipes: anything else you want in the image.** `--recipe <recipe.json>` runs your steps while the image is built, after the Command Line Tools and before the image is sealed: shell commands as the box user or as root, files copied from next to the recipe, and checks that must pass. Output appears in the build log as it happens, and the image records the recipe and its digest. The format is described in [Docs/image-recipes.md](Docs/image-recipes.md).
- **Not yet:** downloading the restore image (get it from Apple, or reuse the one a VM app such as Viable keeps in its bundle).

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
