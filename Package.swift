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
    targets: [
        // Host-side library: box images and clones, the VM supervisor, the guest protocol,
        // network policy, snapshots and change reports.
        .target(name: "AgentVMKit"),

        // The command-line tool; `agent-vm serve --box <name>` also runs the per-box supervisor.
        .executableTarget(name: "agent-vm", dependencies: ["AgentVMKit"]),

        // The daemon installed inside the guest; talks to the host over vsock only.
        .executableTarget(name: "agent-vm-guest", dependencies: ["AgentVMKit"]),

        .testTarget(name: "AgentVMKitTests", dependencies: ["AgentVMKit"]),
    ]
)
