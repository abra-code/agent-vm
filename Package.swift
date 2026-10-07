// swift-tools-version: 6.0
//
// agent-vm - run AI agents and their tools inside disposable macOS virtual machines on
// Apple silicon, so a mistaken, prompt-injected or malicious agent cannot reach the rest of
// the Mac. The host side (library, CLI, per-box supervisor) and the in-guest daemon are
// Swift; plain C APIs (vmnet, POSIX sockets, clonefile) are called directly.

import PackageDescription

let package = Package(
    name: "agent-vm",
    platforms: [
        .macOS("27.0"),
    ],
    products: [
        .library(name: "AgentVMKit", targets: ["AgentVMKit"]),
        .executable(name: "agent-vm", targets: ["agent-vm"]),
        .executable(name: "agent-vm-guest", targets: ["agent-vm-guest"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.6.0"),
    ],
    targets: [
        // What the guest daemon and the host share: the guest protocol, the daemon's server and
        // its relay. No host framework is linked here.
        .target(name: "AgentVMGuestKit"),

        // Host-side library: box images and clones, the VM supervisor, the guest client,
        // network policy, sessions with project snapshots and change reports. It passes the
        // guest kit on to its clients.
        .target(name: "AgentVMKit", dependencies: ["AgentVMGuestKit"]),

        // The command-line tool; `agent-vm box serve <name>` also runs the per-box supervisor,
        // and started as `avm` (a symlink) it is `agent-vm connect`.
        .executableTarget(
            name: "agent-vm",
            dependencies: [
                "AgentVMKit",
                "TerminalUI",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),

        // The daemon installed inside the guest; talks to the host over vsock only.
        .executableTarget(name: "agent-vm-guest", dependencies: ["AgentVMGuestKit"]),

        // The terminal pickers and prompts of `agent-vm connect`: raw mode, keys, drawing inline.
        .target(name: "TerminalUI"),

        .testTarget(name: "AgentVMKitTests", dependencies: ["AgentVMKit", "AgentVMGuestKit"]),
        .testTarget(name: "TerminalUITests", dependencies: ["TerminalUI"]),
    ]
)
