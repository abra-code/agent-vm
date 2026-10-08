// Sources/agent-vm-guest/main.swift
//
// The daemon inside a box. Installed by `agent-vm image create`: on macOS as the root
// LaunchDaemon com.abracode.agent-vm.guest, on Linux as the systemd unit agent-vm-guest. It
// talks to the host over vsock only.
//
//   agent-vm-guest serve [--port N] [--user NAME]   answer the host (hello, exec, shutdown) and
//                                                   relay 127.0.0.1:3128 to the host proxy
//   agent-vm-guest exec-as [--checked] [--terminal] USER DIR EXECUTABLE -- ARGV...  (internal)
//                                                   take the terminal, drop privileges and exec
//   agent-vm-guest wallpaper < PNG                   (internal, macOS only) make the PNG the
//                                                   calling user's wallpaper; run in their
//                                                   desktop session
//   agent-vm-guest --version [--json]

import AgentVMGuestKit
#if canImport(Darwin)
import Darwin
#elseif canImport(Musl)
import Musl
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation

// Before anything is opened: a closed standard stream must not lend its number to a file.
StandardStream.openMissing()

let arguments = Array(CommandLine.arguments.dropFirst())

func usage() -> Never {
    #if os(macOS)
    let wallpaper = " | wallpaper < PNG"
    #else
    let wallpaper = ""
    #endif
    StandardStream.write("usage: agent-vm-guest serve [--port N] [--user NAME] | exec-as [--checked] [--terminal] USER DIR EXECUTABLE -- ARGV...\(wallpaper) | --version [--json]\n", to: STDERR_FILENO)
    exit(64) // EX_USAGE
}

switch arguments.first {
case "--version":
    // With --json, for `agent-vm version`: what this daemon is, features included.
    if arguments == ["--version", "--json"] {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(GuestDaemonInfo.current) else {
            exit(1)
        }
        print(String(decoding: data, as: UTF8.self))
        exit(0)
    }
    print("agent-vm-guest \(AgentVM.version) (protocol \(AgentVM.guestProtocolVersion))")
    exit(0)

case "exec-as":
    GuestServer.execAs(Array(arguments.dropFirst()))

#if os(macOS)
case "wallpaper":
    guard arguments.count == 1 else {
        usage()
    }
    do {
        let result = try await GuestWallpaper.apply(FileHandle.standardInput.readToEnd() ?? Data())
        print("\(result.outcome.rawValue) \(result.path)")
        exit(0)
    } catch {
        StandardStream.write("agent-vm-guest wallpaper: \(error)\n", to: STDERR_FILENO)
        exit(1)
    }
#endif

case "serve":
    // A host that goes away mid-write must not kill the daemon.
    signal(SIGPIPE, SIG_IGN)
    var port = GuestProtocol.port
    var user: String?
    var index = 1
    while index < arguments.count {
        let value = index + 1 < arguments.count ? arguments[index + 1] : nil
        switch (arguments[index], value) {
        case ("--port", let value?):
            guard let parsed = UInt32(value) else {
                usage()
            }
            port = parsed
        case ("--user", let value?):
            user = value
        default:
            usage()
        }
        index += 2
    }
    guard let helper = Bundle.main.executableURL?.resolvingSymlinksInPath().path else {
        StandardStream.write("agent-vm-guest: cannot find its own executable\n", to: STDERR_FILENO)
        exit(1)
    }
    let listener: Int32
    do {
        listener = try GuestServer.listen(port: port)
        // The box's proxy address; harmless when the host runs no proxy (open network).
        try GuestRelay.start()
    } catch {
        StandardStream.write("agent-vm-guest: \(error)\n", to: STDERR_FILENO)
        exit(1)
    }
    GuestServer.logStopSignals()
    GuestServer.logLine("agent-vm-guest \(AgentVM.version): listening on vsock port \(port), default user \(user ?? "(self)"), pid \(getpid())")
    GuestServer(defaultUser: user, helperPath: helper).run(listener: listener)

default:
    usage()
}
