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
| 0x20 | stdout | guest to host | bytes the program wrote to standard output |
| 0x21 | stderr | guest to host | bytes the program wrote to standard error |
| 0x22 | exit | guest to host | JSON, how the program ended; last frame |

## Request and response

```json
{"v": 1, "op": "exec", "argv": ["/bin/ls", "-l"], "env": {"FOO": "bar"}, "cwd": "/Users/agent", "user": "agent"}
```

- `v` (required): the protocol version. A daemon that speaks another version answers `ok: false`.
- `op` (required): `hello`, `exec` or `shutdown`.
- `argv`, `env`, `cwd`, `user`: exec only; all but `argv` optional.

```json
{"ok": true, "v": 1, "version": "0.0.1", "osBuild": "26A428", "pid": 612}
```

- `ok`: false with `error` (a message for a person) when the request is refused; the guest then closes the connection.
- `version`, `osBuild`: hello only (agent-vm-guest's version, the guest's macOS build).
- `pid`: exec only, the started process.
- `status`: a refused exec only, the status a shell would give: 127 when the program is not found, 126 when it cannot be run (unknown account, missing folder).

## Operations

**hello**: version and health check. The host refuses to drive a daemon with another protocol version.

**shutdown**: the guest answers `ok`, closes the connection and runs `/sbin/shutdown -h now`. This is the only clean way to stop a macOS guest with a logged-in user: Virtualization's `requestStop()` leaves it running.

**exec**: runs a program.
- **Account**: `user`, or the daemon's default account (the box user) when absent. Another account than the daemon's own goes through `agent-vm-guest exec-as USER DIR EXECUTABLE -- ARGV...`, which sets the supplementary groups, group and user in a fresh process, verifies root cannot be regained, changes to the folder as that user, then execs (the program sees the `argv[0]` it was asked by).
- **Environment**: `HOME`, `USER`, `LOGNAME`, `SHELL` from the account, `PATH=/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin`, `LANG=en_US.UTF-8`, then every variable of `env` on top.
- **Program**: `argv[0]` is looked up on that `PATH` unless it contains a slash; a relative path with a slash is taken from `cwd`. `cwd` defaults to the account's home folder.
- **Refusals**: an unknown account, a program that is not found and a missing working folder are refused in the response. Nothing is started.
- **Process**: the program runs in a new session, so it leads its own process group. Signal handling is at defaults and the signal mask is empty. It inherits no descriptors but standard input, output and error, which are pipes.
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

## Versioning

`AgentVM.guestProtocolVersion` (in `Sources/AgentVMKit/AgentVM.swift`) is bumped on any incompatible change. Images record the daemon version and protocol they were built with (`guestVersion`, `guestProtocol` in `image.json`).
