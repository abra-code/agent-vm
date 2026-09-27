// Sources/AgentVMKit/AgentVM.swift
//
// Package-wide constants shared by the host tool and the in-guest daemon. Both sides report
// these so a mismatched guest image can be detected before any work is sent to it.

public enum AgentVM {
    /// The tool's version, reported by `agent-vm --version` and `agent-vm-guest --version`.
    public static let version = "0.3.5"

    /// Version of the host-to-guest protocol. Bumped on any incompatible change to the frames
    /// exchanged over vsock; the host refuses to drive a guest daemon with a different value.
    public static let guestProtocolVersion = 1
}
