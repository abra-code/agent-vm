// Tests/AgentVMKitTests/SecretStoreTests.swift
//
// Secrets without the Keychain: names, --secret forms, and the code requirement items are
// marked with. The Keychain itself is exercised by the shell tests, through the signed
// agent-vm (a test process storing items would make macOS ask the next build about them).

import Foundation
import Security
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

    /// An item under the secret's name that this agent-vm did not store (another marker):
    /// `set` makes a new item in its place instead of writing into it, since the old one would
    /// keep its own access list. Against the login Keychain, under a service of its own; off
    /// unless AGENT_VM_TEST_KEYCHAIN=1.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["AGENT_VM_TEST_KEYCHAIN"] == "1"))
    func anItemAnotherProgramStoredIsReplacedNotUpdated() throws {
        let secrets = SecretStore(service: "agent-vm-tests-\(UUID().uuidString)")
        defer { try? secrets.delete("KEY") }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: secrets.service,
            kSecAttrAccount as String: "KEY",
        ]
        var foreign = query
        foreign[kSecValueData as String] = Data("theirs".utf8)
        foreign[kSecAttrGeneric as String] = Data("another program".utf8)
        foreign[kSecAttrComment as String] = "left by the first item"
        #expect(SecItemAdd(foreign as CFDictionary, nil) == errSecSuccess)
        #expect(try secrets.list() == [SecretStore.Entry(name: "KEY", readable: false)])

        func comment() -> String? {
            var lookup = query
            lookup[kSecReturnAttributes as String] = true
            var result: CFTypeRef?
            guard SecItemCopyMatching(lookup as CFDictionary, &result) == errSecSuccess else {
                return nil
            }
            return (result as? [String: Any])?[kSecAttrComment as String] as? String
        }
        #expect(comment() == "left by the first item")
        try secrets.set("KEY", value: Data("ours".utf8))
        // A new item: what the first one carried besides its value is gone.
        #expect(comment() == nil)
        #expect(try secrets.list() == [SecretStore.Entry(name: "KEY", readable: true)])
        #expect(try secrets.read("KEY") == Data("ours".utf8))
        // Stored by this program, it is written into from then on.
        try secrets.set("KEY", value: Data("ours again".utf8))
        #expect(try secrets.read("KEY") == Data("ours again".utf8))
    }
}
