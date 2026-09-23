// Tests/AgentVMKitTests/AgentVMTests.swift

import Testing
@testable import AgentVMKit

@Suite struct AgentVMTests {
    @Test func versionIsSemantic() {
        let parts = AgentVM.version.split(separator: ".")
        #expect(parts.count == 3)
        #expect(parts.allSatisfy { Int($0) != nil })
    }

    @Test func guestProtocolVersionIsPositive() {
        #expect(AgentVM.guestProtocolVersion > 0)
    }
}
