# agent-vm guest protocol, version 1

How the host talks to `agent-vm-guest`, the daemon inside a box. The protocol is small and language-neutral, so another guest side (a Linux box, for example) can implement it.

## Transport

- **vsock**, port **1024** in the guest. The daemon accepts connections only from the host (CID 2): any process inside the guest can open vsock sockets too.
- **One connection per request.** Opening one costs about 0.2 ms, so there is no multiplexing of requests.
- The daemon runs as root (a LaunchDaemon, `com.abracode.agent-vm.guest`, started at boot before any login) and needs no network: a box can have no working network at all and still be driven.

## Frames

Every message in both directions is a frame:

| Bytes | Content |
|---|---|
| 1 | type |
| 4 | payload length, big-endian, at most 1 MiB (1048576) |
| n | payload |

A frame with an unknown type or an oversized length is a protocol error; the receiver closes the connection.

| Type | Name | Direction | Payload |
|---|---|---|---|
| 0x01 | request | host to guest | JSON, first frame of every connection |
| 0x02 | response | guest to host | JSON, answer to the request |
| 0x10 | stdin | host to guest | bytes for the program's standard input |
| 0x11 | stdin-end | host to guest | empty; closes the program's standard input |
| 0x12 | signal | host to guest | 4-byte big-endian signal number |
| 0x13 | resize | host to guest | rows, then columns, 2 bytes each, big-endian (feature `terminal`; ignored without a terminal); then, with feature `terminal-pixels`, the width and height in pixels, 2 bytes each (8 bytes in all) |
| 0x20 | stdout | guest to host | bytes the program wrote to standard output |
| 0x21 | stderr | guest to host | bytes the program wrote to standard error |
| 0x22 | exit | guest to host | JSON, how the program ended; last frame |
| 0x23 | notice | guest to host | JSON, something the program waits on that nobody sees (feature `prompt-notices`, only when the request asked for `notices`) |

## Request and response

```json
{"v": 1, "op": "exec", "argv": ["/bin/ls", "-l"], "env": {"FOO": "bar"}, "cwd": "/Users/agent", "user": "agent"}
```

- `v` (required): the protocol version. A daemon that speaks another version answers `ok: false`.
- `op` (required): `hello`, `exec`, `shutdown`, or `time-sync` (feature `time-sync`).
- `argv`, `env`, `cwd`, `user`: exec only; all but `argv` optional.
- `terminal`: exec only, optional: `{"rows": 24, "columns": 80}` runs the program on a new terminal of that size (feature `terminal`, below). With feature `terminal-pixels`, `xpixels` and `ypixels` may give the window's size in pixels (a guest without it ignores them).
- `notices`: exec only, optional: `true` asks for notice frames (feature `prompt-notices`, below).

```json
{"ok": true, "v": 1, "version": "0.1.1", "osBuild": "26A428", "pid": 612}
```

- `ok`: false with `error` (a message for a person) when the request is refused; the guest then closes the connection.
- `version`, `osBuild`: hello only (agent-vm-guest's version, the guest's macOS build).
- `features`: hello only, what the daemon supports beyond this document's base (see Versioning). Today: `terminal`, `prompt-notices`, `wallpaper`, `time-sync`, `user-session` and `terminal-pixels`.
- `pid`: exec only, the started process.
- `status`: a refused exec only, the status a shell would give: 127 when the program is not found, 126 when it cannot be run (unknown account, missing folder).

## Operations

**hello**: version and health check. The host refuses to drive a daemon with another protocol version.

**time-sync** (feature `time-sync`): `{"v": 1, "op": "time-sync", "epoch": 1790000000.25}` sets the guest's clock to `epoch` (seconds since 1970, with fractions) with `settimeofday`; the answer carries `offset`, how far the guest was behind before (negative: ahead). A time outside 2020 to 2200 is refused and never applied. A box on the allowlist network has no network time, so the supervisor sends it after the daemon's hello at boot, every 5 minutes, and at once after the Mac wakes from sleep.

**shutdown**: the guest answers `ok`, closes the connection and runs `/sbin/shutdown -h now`. This is the only clean way to stop a macOS guest with a logged-in user: Virtualization's `requestStop()` leaves it running.

**exec**: runs a program.
- **Account**: `user`, or the daemon's default account (the box user) when absent. Another account than the daemon's own goes through `agent-vm-guest exec-as USER DIR EXECUTABLE -- ARGV...`, which sets the supplementary groups, group and user in a fresh process, verifies root cannot be regained, changes to the folder as that user, then execs (the program sees the `argv[0]` it was asked by).
- **Environment**: `HOME`, `USER`, `LOGNAME`, `SHELL` from the account, `PATH=/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin`, `LANG=en_US.UTF-8`, then every variable of `env` on top.
- **Program**: `argv[0]` is looked up on that `PATH` unless it contains a slash; a relative path with a slash is taken from `cwd`. `cwd` defaults to the account's home folder.
- **Refusals**: an unknown account, a program that is not found and a missing working folder are refused in the response. Nothing is started.
- **Process**: the program runs in a new session, so it leads its own process group. Signal handling is at defaults and the signal mask is empty. It inherits no descriptors but standard input, output and error, which are pipes.
- **Login session** (feature `user-session`): a program for an account other than root runs in that account's login session, through `launchctl asuser` in front of `agent-vm-guest exec-as`: the desktop (Aqua) session once the account is logged in (images log it in automatically), else its background session. So it shares the login Keychain with apps in the box, and windows it opens appear on the screen. `launchctl` execs in place, so the pid, the process group, the terminal and the exit status are the program's. The daemon stays the responsible process for privacy prompts, so Full Disk Access given to `agent-vm-guest` still applies. Root's programs stay in the system session. Without the feature, programs run outside any login session, and the login Keychain refuses them ("User interaction is not allowed").
- **After `ok`**: the host sends `stdin`, `stdin-end` and `signal` frames, and the guest sends `stdout` and `stderr` frames as output appears, then one `exit` frame:

  ```json
  {"status": 3}
  ```
  or
  ```json
  {"signal": 15}
  ```

- **Signals** go to the whole process group. Allowed: HUP, INT, QUIT, TERM, KILL, USR1, USR2, WINCH, CONT, STOP, TSTP; others are ignored.
- **Host goes away** (the connection closes before `exit`): the process group gets SIGHUP, then SIGKILL 3 seconds later, as when a terminal closes. The same happens to background processes still in the group after the program exits.
- **Output after exit**: background children may keep the output pipes open. The guest waits at most 2 seconds after the program exits before sending `exit`.
- **Ordering**: frames travel in order on one connection, so a signal sent after input the program is not reading waits behind that input (the guest keeps delivering stdin while the pipe accepts it). Closing the connection always works: the guest notices the host is gone even while stdin is backed up.
- **Refusals** carry a plain message in `error`, meant to be shown as is (for example `"make: command not found"`).

**exec with `terminal`** (feature `terminal`): the program runs on a new pseudo-terminal instead of pipes.
- **Controlling terminal**: the program always starts through `agent-vm-guest exec-as --terminal`, which takes the terminal as its controlling terminal (`TIOCSCTTY`) before anything else; on macOS opening a terminal never does that by itself. The account owns the terminal device, as after a login.
- **Size**: set before the program starts; `resize` frames change it, which sends SIGWINCH to the foreground job.
- **Streams**: `stdin` frames go to the terminal as typed, so Control-C, Control-Z and Control-D act through the terminal's settings (the guest's defaults: canonical mode, echo, signals from keys). Everything the program writes, standard error included, arrives as `stdout` frames with the terminal's line endings. `stdin-end` stops input and leaves output flowing.
- **Signals** from `signal` frames go to the terminal's foreground process group (what a key would reach), which with job control is not the program's own group.
- **Host goes away**: the foreground job's group is hung up and killed along with the program's.
- **After exit**: output is forwarded until every holder of the terminal closes it, at most 2 seconds; then the guest closes the terminal, which hangs up what still has it open.

**exec with `notices`** (feature `prompt-notices`): the guest tells the host when the program waits on something nobody in the box can see.
- **Why**: every program exec runs is started by the daemon, so macOS asks on the daemon's behalf before one opens protected data (the account's Downloads, Documents or Desktop folders, other apps, the camera). The question appears on the guest's screen, and the program waits for an answer.
- **Keychain dialogs** (feature `user-session`): a program in the desktop session may make macOS ask, on the screen, whether it may use a Keychain item (one another program made, for example). securityd logs `displaying keychain prompt for <program>(<pid>)` (category `kcacl`), and the guest sends a notice. A dialog to unlock a locked keychain names no program, so it is not reported; images keep the login keychain unlocked. A program stopped while it waits may leave its dialog on the screen until someone answers it or the next one replaces it; nothing waits on it.
- **How**: the daemon reads the privacy service's log (`log stream`, subsystem `com.apple.TCC`) from its start. An `AUTHREQ_ATTRIBUTION` line names the program that tried the access, and an `AUTHREQ_PROMPTING` line with the same message id (from the same tccd process) says a prompt went up. The program's session id is the exec's pid, since every exec starts a new session, so descendants count too. Only lines logged by tccd and securityd themselves count (checked by their executables' paths, which System Integrity Protection guards): any process may log under their subsystems, and a faked line could otherwise get another exec's program stopped.
- **Frame**: `{"kind": "permission-prompt", "service": "kTCCServiceSystemPolicyDownloadsFolder", "program": "/bin/ls", "pid": 688}`. For a Keychain dialog: `{"kind": "keychain-prompt", "service": "keychain", "program": "/usr/bin/security", "pid": 806}`. It is advice, never output: a host that cannot read one drops it. None follows the `exit` frame.

**The wallpaper** (feature `wallpaper`): not a new operation, but a command the host runs with exec. `agent-vm-guest wallpaper` reads a PNG (at most 16 MB) on stdin and makes it the calling user's wallpaper on every screen. It must run in that user's desktop session, so the host runs it as root through `launchctl asuser UID sudo -u USER`; outside the session macOS reports success and changes nothing.
- **File**: `~/Library/Application Support/agent-vm/wallpaper-<first 16 hex digits of its SHA-256>.png`, a new name for a new picture. The previous one is deleted once the desktop reports the new one.
- **Only the default is replaced**: the picture is set only over macOS's default (`/System/Library/CoreServices/DefaultDesktop.heic`) or an earlier `wallpaper-*.png` of agent-vm's; a wallpaper someone chose in the box stays.
- **Output**: `set PATH`, `unchanged PATH` when the picture already is the wallpaper, or `kept PATH` when someone chose another one; exit status 1 with a reason on stderr otherwise (not a PNG, no desktop session, the desktop did not take it within 10 seconds).
- **Who draws it**: agent-vm, on the Mac: the image's name at `image create` and `image update-guest`, the box's name at every `box start` (unchanged after the first, and never over a wallpaper chosen in the box).

## Proxy relay

Besides the protocol port, the daemon listens on TCP 127.0.0.1:3128 inside the guest and relays each connection, byte for byte, to vsock port 3128 on the host, where a box in `allowlist` or `off` mode runs its proxy. When the host runs no proxy (`open` mode), the vsock connection fails at once and the client is closed. The relay carries no framing; the host proxy speaks plain HTTP proxy protocol (`CONNECT`, or absolute-form `http://` requests), one request per connection, at most 256 connections at once.

## Versioning

`AgentVM.guestProtocolVersion` (in `Sources/AgentVMKit/AgentVM.swift`) is bumped on any incompatible change. Additions a host can do without are features instead: the daemon lists them in its hello answer, the box's supervisor keeps that list, and the host never sends a request, field or frame an older daemon would ignore or misread (for a daemon without `terminal`, `exec --tty` is refused with a way to update it). Images record the daemon they were built with (`guestVersion`, `guestProtocol`, `guestFeatures` and `guestDigest`, the SHA-256 of its executable, in `image.json`); `agent-vm image update-guest` puts the current one into an existing image, and `image create --from` does so for the new image.
