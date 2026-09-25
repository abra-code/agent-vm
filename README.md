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

How images and boxes relate (a box is a copy of its image made once, and never updated from it afterwards), and the everyday procedures - adding tools, upgrading agent-vm, refreshing a box, freeing space - with answers to common questions: [Docs/images-and-boxes.md](Docs/images-and-boxes.md).

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
agent-vm box shell dev1                       # a login shell in the box, on this terminal
agent-vm exec -t --box dev1 -- top            # any full-screen program
agent-vm box view dev1                        # the box's screen in a window (view only)
agent-vm box execlog dev1                     # what exec and shell ran there
agent-vm box status dev1                      # its state, supervisor and running programs; starts nothing
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
- **API keys and other credentials:**
  - `--env NAME` without a value passes on the value agent-vm was given, as `docker run -e NAME` does: `ANTHROPIC_API_KEY=... agent-vm exec --box dev1 --env ANTHROPIC_API_KEY -- claude`. Unlike docker, a variable that is not set is an error, not a silent omission.
  - `--env-file PATH` reads one `NAME=VALUE` per line, the value taken as is to the end of the line (no quotes or escapes); a line with only `NAME` passes that variable on, and `#` starts a comment line. The file may be a pipe, so a password manager can hand keys over without a file on disk: `--env-file <(op read ...)`. Later sources win: the proxy settings of a proxied box, then the files, then `--env`.
  - The values go in the exec request straight to the guest daemon. agent-vm does not log them or write them anywhere, and its error messages name variables, never values.
  - What this does not protect: every program in the box can read the value, and an agent can send it to any host the network allows, so an allowed host that accepts uploads is a way out. Prefer keys limited to the task that you can revoke.
- **Looking inside a box:**
  - `box shell <name>` opens the account's login shell in the box on your terminal (`--user root` for root, `--project` to start in a shared project). It is `exec --tty` with the shell, over the box's private channel: SSH stays off and no network is involved.
  - `exec -t` (`--tty`) runs any program on a terminal in the box: editors, `top`, agents with a full-screen interface. Your terminal is put in raw mode, so keys such as Control-C go to the program as typed, and window size changes follow. SIGHUP or SIGTERM to `agent-vm` ends the session, as for ssh. Its output, standard error included, arrives on standard output. The terminal type is yours when the guest knows it, else `xterm-256color`.
  - `box execlog <name>` lists every program `exec` and `box shell` ran in the box: start time, duration, exit status, account and command (`--json` adds folders, project and process ids). The log is kept on your Mac (`Boxes/<name>/exec.jsonl`), out of the box's reach, until the box is deleted. With `box netlog` it shows what happened in a box. It never records the programs' environment, but command lines are recorded as given, so keep keys out of them.
  - `box view <name>` shows the box's screen in a window on your Mac, as a VM app would; closing the window leaves the box running. It is view only unless you add `--interactive`: keys and clicks do not reach the box. In interactive mode the window has a Type Password button (see the account password under Images). The screen shows the box's desktop (Finder, system dialogs, permission prompts that would otherwise wait unseen). Programs run with `exec` do not appear on it, because the guest daemon starts them outside the desktop session; `box shell` and `box execlog` are the way to follow those. The box's supervisor opens the window, so a box started over SSH or by a service, with no screen to draw on, cannot show one. The desktop's wallpaper names the box (dark gray, the box's name and its image), so you can tell windows apart; a box sets its own when it starts, and images show their own name until then. A wallpaper someone picks inside a box is kept. It takes an image whose guest daemon has the `wallpaper` feature (`image update-guest`).
  - **A program waiting on a hidden permission prompt is reported.** When macOS in the box asks for permission (for the Downloads folder, say, in an image without Full Disk Access), `exec` and `box shell` print what the program waits on and how to answer it (`box view --interactive`) or avoid it (`image setup`), and `box execlog` marks the run as soon as it happens (a `notice` line in `exec.jsonl`, with the program, its process id and what it waits for). When nobody is at a terminal to answer, waiting helps no one: without a terminal on stdin (a program started by another application), `exec` stops the program that waits, only that one, so what started it sees it fail as if access had been refused, and exec goes on. `--prompts wait` lets it wait for an answer instead (the default on a terminal), `--prompts stop` stops it on a terminal too. It works with images whose guest daemon has the `prompt-notices` feature.
  - Terminals need an image whose guest daemon has them: `image list` names what an image lacks, and `image update-guest <image>` adds it.
- **How it connects:** `exec` asks the box's supervisor, over a Unix socket only you can use (`Boxes/<name>/control.sock`), for a connection to the guest daemon. It then talks to the daemon directly, so the supervisor is not in the data path.
- **Boxes need the image's volume**: the clone costs nothing until the box writes, and the box's disk grows as the guest works. `box list` shows each box's folder and its space: all of it, and the part no image or other box shares, which is what `box delete` frees (what the box wrote, plus image blocks the image rewrote after the box was made, for example by `image update-guest`). APFS reports that part per file; `--json` has it as `diskUsage` (`bytes`, and `unsharedBytes` unless the volume does not report it) next to `path`.
- **`box start` is safe to repeat**: on a running box it reports the box, and during another start it waits for that one.
- **Progress for programs:** with `--json`, `box start` and `box stop` report their steps on standard error as JSON lines, as image builds do ([Docs/progress-events.md](Docs/progress-events.md)).
- **`box status <name>` only looks.** A stopped box reports `stopped` from its folder; a running one is asked through its supervisor: `starting`, `ready` or `stopping`, the supervisor's process id, agent-vm version and executable, when it started, the shared project, and how many programs `exec` and `box shell` run in it now (from any client), plus its guest daemon's version and features. `unresponsive` means something holds the box but its supervisor does not answer within 5 seconds (`statusError` says why). With `--json` it prints the same entry as `box list --json`: the record under `box`, `running`, `path`, `diskUsage`, and the status fields `state`, `pid`, `supervisorVersion`, `supervisorPath`, `startedAt`, `project`, `projectReadOnly`, `activeExecs`, `guestVersion`, `guestFeatures` (each only when known; supervisors older than 0.1.6 give no version, path, start or count).
- **The supervisor** is `agent-vm box serve <name>` in its own session, started with the full path of the agent-vm that started it as its first argument, so a process list tells which binary runs each box, logging to `Boxes/<name>/supervisor.log`. It holds the box's lock, so a running box cannot be deleted or started twice. SIGTERM, SIGINT or SIGHUP to it stop the box cleanly, the same as `box stop`. Started in a login session, it is also an application without a Dock icon or menu (so `box view` can open a window): quitting it, as a logout does, stops the box cleanly too.
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
  - `pack:<name>` allows a curated list: `apple-updates`, `github`, `npm`, `pypi`, `swiftpm`, `homebrew`, `anthropic` and `openai` (`box packs` lists the hosts; `box packs --json` gives `[{"name": "github", "hosts": [...]}, ...]`).
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
agent-vm image setup dev                            # once: Full Disk Access for the guest daemon, in a window
agent-vm image delete dev
```

- **Takes about 6 minutes** on a MacBook Air M5 from a local restore image. About 3 minutes go to installing macOS, and about 3 more to the first boot: the SSH check of the new account, the guest daemon, the Command Line Tools and a clean shutdown. The disk is a 64 GB sparse file that holds about 28 GB after setup, plus about 2 GB for the tools.
- **Developer tools**: Xcode's Command Line Tools (clang, Swift, git, make, Python 3) are installed without a dialog. They are about 530 MB from Apple, so the build needs the internet; `--no-command-line-tools` skips them. Spotlight indexing is turned off in images: boxes have no use for it, and indexing a new disk slowed the tools install from about 2 to 26 minutes. Desktop widgets are hidden too (Desktop & Dock > Show Widgets, off): with the widgets macOS puts on a new desktop, about 20 widget programs start at every login and take 256 MB of the box's memory; hidden, about 3 take 70 MB. Turning them back on in System Settings in a box sticks.
- **The guest daemon** (`agent-vm-guest`, a root LaunchDaemon started at boot) is the only way into a finished image: it runs programs for the host over vsock, needs no network, and accepts connections only from the host. Its protocol is described in [Docs/guest-protocol.md](Docs/guest-protocol.md). `image create` installs the `agent-vm-guest` found next to `agent-vm` (or `--guest-daemon <path>`).
- **Options:** `--cpus` (default 4), `--memory-gb` (8), `--disk-gb` (64; at least 40), `--user` (the account name, default `agent`), `--recipe`, `--no-command-line-tools`. Values below what the restore image requires are raised to its minimum.
- **The account's password** is 24 random letters and digits, stored in the image folder and copied to each box's (`Password`, mode 0600, in folders only you can open). During the build, agent-vm reaches the guest with the system's `/usr/bin/ssh` using password authentication, until the daemon is in place. It never uses your SSH configuration, keys, agent or `known_hosts` file: the guest's host key goes into the image folder.
  - You never need to type it: the guest's screen does not lock (no screen saver, no display sleep, no screen lock; set in images, and again in a box when its screen is first shown, since part of it is stored per machine), and when macOS in the box asks for it anyway (an administrator prompt, for one), the window's **Type Password** button, or `box view <name> --type-password`, types it into the focused field. It never goes through the pasteboard.
  - What it guards: inside the box, it is what keeps the agent (an administrator account) from root. It never enters the box as a file, and projects in `~/Library` are refused. On your Mac it adds nothing: anything running as you can already get root in a box (`exec --user root`) or read its disk. Weak spots: it is in plain text in backups of your Library, it is shared by an image, its boxes and images derived from it, and it is also stored obfuscated in the guest (`/etc/kcpassword`, readable by root only), which automatic login needs.
- **Full Disk Access for the guest daemon, once per image.** Every program `exec` and `box shell` run is started by `agent-vm-guest`, so macOS asks on its behalf before one opens the box account's Desktop, Documents or Downloads, and in a box nobody sees that prompt: the program just waits. Apple's zero-click setup offers no privacy settings, so `agent-vm image setup <image>` boots the image in an interactive window with System Settings open on Full Disk Access and `agent-vm-guest` shown in Finder: drag it into the list, turn it on, press Type Password when asked, and close the window. Boxes made from the image afterwards inherit it. `image list` says which images lack it. macOS ties the grant to the daemon's code signature, and the default ad hoc signature changes with every build, so `image update-guest` loses it (measured; it says so): set the image up again, or sign with a Developer ID (`Scripts/build.sh --identity ...`), which should keep it.
- **Where it lives:** `~/Library/Application Support/agent-vm/Images/<name>/` (or `$AGENT_VM_HOME/Images/<name>/`): `image.json` (state, macOS version and build, resources, timings, the guest daemon's version, protocol, features and SHA-256), the disk, the auxiliary storage, the hardware model and the machine identifier. `image list` shows each image's folder, its space, and how much of it no box or other image shares (what `image delete` frees; the rest stays in use by the clones). For an image built with `--from`, a third line gives what its disk added over the image it was built from, which does not change as other images and boxes come and go (only a little when the base itself is started again, by `image update-guest` or `image setup`), so the growth of each layer can be traced (`addedOverBase` in `--json`). It compares where the two disks' data lies on the volume (`F_LOG2PHYS_EXT`), about 0.3 s per image. With `--json`, each record gains `path` and `diskUsage` (`bytes`, and `unsharedBytes` unless the volume does not report it).
- **A failed or interrupted build** stays in the list with its state (`installing`, `provisioning`) or `failed` and the reason; delete it and create it again. An image in use by another agent-vm process cannot be deleted.
- **Canceling a build.** Control-C (SIGINT) or SIGTERM during `image create` or `image update-guest` stops at the next safe point instead of killing the virtual machine mid-write: a guest command in progress (a recipe step, the Command Line Tools) is stopped, a macOS install is canceled, the guest is shut down through its daemon (a guest still booting is given up to 30 seconds for its daemon to answer; one that cannot answer is stopped), and agent-vm exits with 128 + the signal (130, 143). A new image is kept as `failed` with the reason `canceled`; delete it. An image whose guest daemon was being updated stays `ready` and unchanged when the cancel came before its daemon was replaced, and is marked failed (`canceled`) after; the images named after it are skipped and listed. `image setup` already ends this way when its window is closed or on a signal.
- **Images from images.** `image create <name> --from <image> --recipe <recipe.json>` clones a ready image and applies the recipe to the clone. The clone gets its own identity, is built on NAT, and costs only what the recipe adds. It takes minutes instead of a macOS install, so tool sets can be layered and rebuilt quickly: in a test, `dev` to `dev-node` (Homebrew and Node) took 2 minutes, then `dev-agents` (Claude Code, Codex, opencode) 1 minute. `image list` shows each image's base and recipe. Example recipes are in [Recipes/](Recipes/README.md), Xcode among them.
- **A bigger disk for a derived image.** `--disk-gb` with `--from` makes the new image's disk larger than its base's, by at least 8 GB (a disk never shrinks). The disk file is sparse, so the extra room costs nothing until the guest uses it. macOS puts its recovery container last on the disk, where it would block the main container from growing, so agent-vm moves it to the new end of the file before the first boot (its bytes and its partition table entry; the file system inside is untouched), and the guest then grows its main container into the gap (`diskutil apfs resizeContainer`). Growing `dev` from 64 to 96 GB took 62 s in all, and the moved recovery container passes `diskutil verifyVolume`. The move writes the recovery container's data anew, about 1.5 GB that the new image no longer shares with its base. Tart's image builder does the same; deleting the recovery container instead, the other way, stops macOS updates.
- **Recipes: anything else you want in the image.** `--recipe <recipe.json>` runs your steps while the image is built, after the Command Line Tools and before the image is sealed: shell commands as the box user or as root, files copied from next to the recipe, and checks that must pass. Output appears in the build log as it happens, and the image records the recipe and its digest. A recipe can also ask for files (`--input NAME=PATH`, streamed into the guest while it builds and deleted after, such as an Xcode `.xip`) and for values (`--set NAME=VALUE`, such as which simulator runtimes to install); the image records both. The format is described in [Docs/image-recipes.md](Docs/image-recipes.md).
- **Updating the guest daemon.** A newer agent-vm may bring guest features (the terminal for `exec -t` and `box shell` is one), and `image list` names what an image lacks (with `--json`, as `needs`: `{"kind": "guest-update", "missing": [...]}` and `{"kind": "full-disk-access", "reason": "not-granted" | "not-checked"}`, empty when nothing is missing). `agent-vm version` shows the daemon `update-guest` would install, with its version, features and SHA-256; an image whose `guestDigest` differs would get it. `image update-guest <image>` boots the image, replaces its `agent-vm-guest` with the one next to `agent-vm` when they differ, and boots it once more to check the new one: about 45 seconds, or 30 when there is nothing to replace. Several images can be named at once (`image update-guest dev dev-node dev-agents`): they are updated one after another, every name is checked before the first boot, and the first failure stops the rest, since a daemon that does not start marks its image failed and would mark the next one too. Boxes made from the image earlier keep their daemon; create them again. `image create --from` puts the current daemon into every image it builds.
- **Progress for programs.** With `--json`, `image create`, `image update-guest` and `image setup` report their steps on standard error as one JSON object per line (`{"event": "progress", "step": "install", "fraction": 0.4, ...}`, log lines and notices), and print only the image record on standard output; without it, the text is as shown above. The steps and fields are in [Docs/progress-events.md](Docs/progress-events.md).
- **Not yet:** downloading the restore image (get it from Apple, or reuse the one a VM app such as Viable keeps in its bundle).

## Building

```sh
swift build
swift test
Scripts/build.sh                          # release build, signed ad hoc for this Mac
Scripts/build.sh --identity <Developer ID Application identity or team ID>
.build/signed/release/agent-vm doctor     # can this Mac and this binary run boxes?
.build/signed/release/agent-vm version    # versions, protocols, and the guest daemon next to it
```

Virtualization refuses every virtual machine from a process without the `com.apple.security.virtualization` entitlement (`Resources/agent-vm.entitlements`). Any developer can use it without Apple's approval, but a plain `swift build` does not sign it in, so `session` commands work from `.build/debug/agent-vm` while anything that starts a virtual machine needs the output of `Scripts/build.sh`. The script builds `agent-vm` and `agent-vm-guest`, signs copies in a staging folder and renames them into `.build/signed/<configuration>/` (so running boxes survive a rebuild: macOS stops a process whose signed file is rewritten under it) with the hardened runtime (ad hoc by default, or with a Developer ID and a secure timestamp; `AGENT_VM_SIGN_IDENTITY` sets the default), verifies the signatures and runs `agent-vm doctor` with the result.

`agent-vm doctor` checks the macOS version, Apple silicon, the binary's entitlement and signature, free space for the store, and how many virtual machines already run (macOS runs at most two macOS guests at once, whichever applications started them). It exits 1 when something prevents running boxes; `--json` prints the checks for programs.

## Testing

`swift test` runs the unit tests. `Tests/Shell/run.sh` runs out-of-process tests: shell scripts that drive the signed binary from `Scripts/build.sh` the way a user or a program would, and check its output, exit statuses and files.

```sh
Tests/Shell/run.sh fast                   # seconds, no virtual machine, a private store per test
Tests/Shell/run.sh extended               # minutes, real boxes from the image "dev"
Tests/Shell/run.sh all --filter network   # both tiers, only tests whose name contains "network"
```

- **fast** covers the CLI, sessions (report, undo, refusals), the image and box stores, network rules and recipe checks. Each test gets its own `AGENT_VM_HOME` in a scratch folder, so it never touches your images or boxes.
- **extended** starts real boxes: their life cycle, exec (streams, exit statuses, signals, a killed client), terminals, `box shell` and the exec log, `box view` (a window appears briefly), the allowlist network (it needs the internet), project shares, and derived images built from recipes. It uses your store (or `$AGENT_VM_TEST_HOME`) and needs a ready image named `dev` (or `$AGENT_VM_TEST_IMAGE`); without one those tests are skipped. It creates boxes and images named `shtest-*` and deletes them. A full install from a restore image runs only when `$AGENT_VM_TEST_IPSW` names one. The tier takes about 7 minutes, and macOS runs at most two virtual machines at once, so stop other boxes first.

A test that fails keeps its scratch folder, with the commands it ran and their output, and the last lines are printed. `--keep` keeps every folder, and `--agent-vm <path>` tests another binary.

## License

Apache License 2.0 - see [LICENSE](LICENSE).
