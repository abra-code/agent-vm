// Sources/AgentVMKit/Connect/AgentProbe.swift
//
// Which agents a running box has: one guest request that runs `command -v` for each agent's
// first word through the account's login shell, the way the agent itself will be started, so
// "installed" and "runs" see the same PATH (~/.zprofile included). Only lines that are exactly
// one of the names asked about count: whatever a login script prints is ignored.

import Darwin
import Foundation

public enum AgentProbe {
    /// Prints each of its arguments that is a command the shell finds, one per line.
    static let script = "for c in \"$@\"; do command -v \"$c\" >/dev/null 2>&1 && printf '%s\\n' \"$c\"; done; exit 0"

    /// The request, as the box's user, through the login wrapper.
    public static func request(commands: [String], user: String?) -> GuestRequest {
        return GuestRequest(op: .exec, argv: ConnectPlanner.loginWrapper + ["/bin/sh", "-c", script, "probe"] + commands, user: user)
    }

    /// The commands among `commands` that `stdout` names on a line of its own.
    public static func parse(_ stdout: String, commands: [String]) -> Set<String> {
        let wanted = Set(commands)
        var found: Set<String> = []
        for line in stdout.split(whereSeparator: { $0 == "\n" || $0 == "\r\n" || $0 == "\r" }) {
            let name = String(line)
            if wanted.contains(name) {
                found.insert(name)
            }
        }
        return found
    }

    /// The commands the running `box` has; nil when the probe itself failed (no answer within
    /// `timeout` seconds, a guest too old to run it).
    public static func run(box: Box, commands: [String], timeout: Int = 10) -> Set<String>? {
        guard !commands.isEmpty else {
            return []
        }
        do {
            let (control, guest, _) = try ControlClient.openGuest(path: box.controlSocketPath)
            defer {
                close(guest)
                close(control)
            }
            var limit = timeval(tv_sec: timeout, tv_usec: 0)
            _ = setsockopt(guest, SOL_SOCKET, SO_RCVTIMEO, &limit, socklen_t(MemoryLayout<timeval>.size))
            let result = try GuestClient.capture(guest, request(commands: commands, user: box.record.userName))
            guard result.report == ExitReport(status: 0) else {
                return nil
            }
            return parse(result.stdout, commands: commands)
        } catch {
            return nil
        }
    }
}
