// Sources/AgentVMKit/Exported.swift
//
// The code the guest daemon shares with the host (the protocol, the daemon's server, the
// relay) is a target of its own, so the daemon links no host framework. The host library
// passes it on: a client of AgentVMKit imports one module, as before.

@_exported import AgentVMGuestKit
