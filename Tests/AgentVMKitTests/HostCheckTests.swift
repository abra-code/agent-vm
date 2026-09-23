// Tests/AgentVMKitTests/HostCheckTests.swift
//
// Doctor's rules, judged on made-up facts so they do not depend on this Mac or on how the test
// runner is signed.

import Foundation
import Testing
@testable import AgentVMKit

@Suite struct HostCheckTests {
    static func goodFacts() -> HostFacts {
        return HostFacts(
            osVersion: OperatingSystemVersion(majorVersion: 27, minorVersion: 0, patchVersion: 0),
            isAppleSilicon: true,
            virtualizationSupported: true,
            hasVirtualizationEntitlement: true,
            signature: HostFacts.Signature(isAdHoc: false, teamIdentifier: "TEAM123456", hardenedRuntime: true),
            cpuCount: 10,
            memoryBytes: 24 << 30,
            storeRoot: "/Users/someone/Library/Application Support/agent-vm",
            storeFreeBytes: 100 << 30,
            runningVirtualMachines: 0
        )
    }

    func status(_ report: HostReport, _ name: String) -> HostCheck.Status? {
        return report.checks.first { $0.name == name }?.status
    }

    @Test func goodHostPassesEveryCheck() {
        let report = HostReport.evaluate(Self.goodFacts())
        #expect(report.canRunBoxes)
        #expect(report.checks.allSatisfy { $0.status == .ok })
        #expect(report.checks.map(\.name) == ["macOS", "virtualization", "entitlement", "signature", "disk space", "running VMs"])
    }

    @Test func missingEntitlementFailsAndPointsAtTheBuildScript() {
        var facts = Self.goodFacts()
        facts.hasVirtualizationEntitlement = false
        let report = HostReport.evaluate(facts)
        #expect(!report.canRunBoxes)
        let check = report.checks.first { $0.name == "entitlement" }
        #expect(check?.status == .failure)
        #expect(check?.detail.contains("Scripts/build.sh") == true)
    }

    @Test func unreadableFactsWarnInsteadOfFailing() {
        var facts = Self.goodFacts()
        facts.hasVirtualizationEntitlement = nil
        facts.signature = nil
        facts.storeFreeBytes = nil
        facts.runningVirtualMachines = nil
        let report = HostReport.evaluate(facts)
        #expect(report.canRunBoxes)
        #expect(status(report, "entitlement") == .warning)
        #expect(status(report, "signature") == .warning)
        #expect(status(report, "disk space") == .warning)
        #expect(status(report, "running VMs") == .info)
    }

    @Test func oldMacOSAndIntelFail() {
        var facts = Self.goodFacts()
        facts.osVersion = OperatingSystemVersion(majorVersion: 26, minorVersion: 4, patchVersion: 0)
        #expect(status(HostReport.evaluate(facts), "macOS") == .failure)

        facts = Self.goodFacts()
        facts.isAppleSilicon = false
        #expect(status(HostReport.evaluate(facts), "virtualization") == .failure)

        facts = Self.goodFacts()
        facts.virtualizationSupported = false
        #expect(status(HostReport.evaluate(facts), "virtualization") == .failure)
    }

    @Test func signatureKinds() {
        var facts = Self.goodFacts()
        facts.signature = HostFacts.Signature(isAdHoc: true, teamIdentifier: nil, hardenedRuntime: true)
        #expect(status(HostReport.evaluate(facts), "signature") == .info)

        facts.signature = HostFacts.Signature(isAdHoc: false, teamIdentifier: "TEAM123456", hardenedRuntime: false)
        #expect(status(HostReport.evaluate(facts), "signature") == .warning)
        #expect(HostReport.evaluate(facts).canRunBoxes)
    }

    @Test func lowSpaceAndTheTwoGuestLimitWarn() {
        var facts = Self.goodFacts()
        facts.storeFreeBytes = HostReport.lowSpaceBytes - 1
        #expect(status(HostReport.evaluate(facts), "disk space") == .warning)
        facts.storeFreeBytes = HostReport.lowSpaceBytes
        #expect(status(HostReport.evaluate(facts), "disk space") == .ok)

        facts = Self.goodFacts()
        facts.runningVirtualMachines = 1
        #expect(status(HostReport.evaluate(facts), "running VMs") == .ok)
        facts.runningVirtualMachines = HostReport.macOSGuestLimit
        let report = HostReport.evaluate(facts)
        #expect(status(report, "running VMs") == .warning)
        #expect(report.canRunBoxes)
    }

    /// The live facts are gathered without crashing, whatever the test runner's signature.
    @Test func currentFactsAreReadable() {
        let facts = HostFacts.current(storeRoot: URL(fileURLWithPath: NSTemporaryDirectory()))
        #expect(facts.osVersion.majorVersion >= 27)
        #expect(facts.cpuCount > 0)
        _ = HostReport.evaluate(facts)
    }
}
