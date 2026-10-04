// Sources/AgentVMKit/Images/FirstContact.swift
//
// What the wait for a new guest's SSH port has seen, so that a build that cannot reach its guest
// says why. The first boot is the only time agent-vm reaches a guest over the network, and so
// the only time the Mac's own rules about the local network apply: macOS charges a connection
// to an address on an attached network to the application that started the program, and
// refuses it without that application's Local Network permission. The refusal looks like an
// unreachable host and names no permission.

import Foundation

struct FirstContact {
    /// How long this Mac must have refused every attempt before the build says so: a guest
    /// that just got its address may be unreachable for a few seconds by itself.
    static let patience: Duration = .seconds(30)

    private(set) var host: String?
    private(set) var last: GuestNetwork.Attempt?
    private var refusedSince: ContinuousClock.Instant?
    private var said = false

    /// Records one attempt. Returns the notice to show, once, when this Mac has refused every
    /// attempt for `patience`.
    mutating func record(_ attempt: GuestNetwork.Attempt, host: String, at now: ContinuousClock.Instant = .now) -> String? {
        if host != self.host {
            self.host = host
            refusedSince = nil
        }
        last = attempt
        guard attempt.refusedByThisMac else {
            refusedSince = nil
            return nil
        }
        let since = refusedSince ?? now
        refusedSince = since
        guard !said, now - since >= Self.patience else {
            return nil
        }
        said = true
        return "this Mac is not letting agent-vm reach the guest at \(host) (the connection \(attempt.text)). \(Self.advice) The build keeps trying."
    }

    static let advice = "When an application started agent-vm, that application needs Local Network access: turn it on in System Settings > Privacy & Security > Local Network. A sandbox or a network filter around agent-vm does the same."

    /// The reason for giving up after `timeout`.
    func failure(after timeout: Duration) -> String {
        guard let host, let last else {
            return "SSH did not come up within \(timeout): the guest got no address on the Mac's virtual network"
        }
        let reason = "SSH did not come up within \(timeout): the last attempt to reach \(host) port 22 \(last.text)"
        return last.refusedByThisMac ? "\(reason). \(Self.advice)" : reason
    }
}
