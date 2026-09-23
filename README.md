# agent-vm

Run AI agents and their tools inside disposable macOS virtual machines, so a mistaken, prompt-injected or malicious agent cannot reach the rest of your Mac.

> **Status:** early development. Nothing below works yet except `--version`; this README describes the intended tool so the interface can be reviewed before it is built.

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
agent-vm image build macos-dev            # download macOS, install, configure - no clicks
agent-vm box create dev --image macos-dev
agent-vm exec --box dev --project ~/src/myapp --net allowlist:npm,github-read -- claude
agent-vm session report <id>              # what changed, with risky files flagged
agent-vm session undo <id>                # restore the project snapshot
```

`agent-vm exec` streams stdin, stdout and stderr, forwards signals and returns the command's exit status, so it can wrap any stdio program - including Agent Client Protocol (ACP) agents and Model Context Protocol (MCP) servers launched by another application.

## Building

```sh
swift build
swift test
```

Virtualization requires the `com.apple.security.virtualization` entitlement (`Resources/agent-vm.entitlements`), which any developer can use without Apple's approval; binaries that start virtual machines must be signed with it.

## License

Apache License 2.0 - see [LICENSE](LICENSE).
