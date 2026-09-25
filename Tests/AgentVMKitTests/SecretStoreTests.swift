// Tests/AgentVMKitTests/SecretStoreTests.swift
//
// Secrets without the Keychain: names, --secret forms, and the code requirement items are
// marked with. The Keychain itself is exercised by the shell tests, through the signed
// agent-vm (a test process storing items would make macOS ask the next build about them).

import Foundation
import Testing
@testable import AgentVMKit

@Suite struct SecretStoreTests {
    @Test func namesAreEnvironmentVariableNames() {
        for good in ["ANTHROPIC_API_KEY", "_x", "k1"] {
            #expect(SecretStore.isValidName(good), "\(good)")
        }
        for bad in ["", "1KEY", "A-B", "A B", "A=B", "\u{e9}"] {
            #expect(!SecretStore.isValidName(bad), "\(bad)")
        }
    }

    @Test func optionsNameTheVariableAndTheSecret() throws {
        #expect(try SecretStore.option("OPENAI_API_KEY") == ("OPENAI_API_KEY", "OPENAI_API_KEY"))
        #expect(try SecretStore.option("OPENAI_API_KEY=WORK_OPENAI") == ("OPENAI_API_KEY", "WORK_OPENAI"))
        for bad in ["", "=X", "X=", "X=Y=Z", "1X", "X=1Y"] {
            #expect(throws: AgentVMError.self, "\(bad)") { try SecretStore.option(bad) }
        }
    }

    /// What items are marked with, and list compares: this process's designated requirement.
    @Test func thisProcessHasACodeRequirement() throws {
        let requirement = try #require(SecretStore.codeRequirement)
        #expect(!requirement.isEmpty)
    }

    @Test func errorsNameTheSecretNeverAValue() {
        #expect(AgentVMError.secretNotFound("KEY").description.contains("agent-vm secret set KEY"))
        #expect(AgentVMError.secretUnreadable(name: "KEY", reason: "User interaction is not allowed.").description.hasPrefix("secret KEY cannot be read"))
    }

    @Test func theServiceCanBeChangedForTests() {
        #expect(SecretStore(service: "x").service == "x")
        #expect(!SecretStore.defaultService.isEmpty)
    }
}
