// Sources/AgentVMKit/Host/SecretStore.swift
//
// Secrets for programs in boxes (API keys, tokens), kept in the login Keychain instead of files
// or command lines: generic passwords with service "agent-vm" and the secret's name as the
// account. `agent-vm secret set NAME` stores one (the value from stdin), and `exec --secret NAME`
// puts it in the program's environment. The Keychain ties each item to the program that made
// it: an agent-vm signed differently (an ad hoc build is a new identity after every rebuild)
// makes macOS ask before it reads the item.
//
// Whether a secret can be read without that question cannot be asked of the login Keychain:
// kSecUseAuthenticationUIFail and an LAContext with interactionNotAllowed both still show the
// dialog for an item another program made (measured on macOS 27). So each item records the
// code requirement of the agent-vm that stored it (kSecAttrGeneric), and `list` compares it
// with this agent-vm's, reading attributes only, which never asks.

import Foundation
import Security

public struct SecretStore: Sendable {
    /// The Keychain service; tests set AGENT_VM_SECRET_SERVICE so they never touch real secrets.
    public let service: String

    public init(service: String = SecretStore.defaultService) {
        self.service = service
    }

    public static var defaultService: String {
        let override = ProcessInfo.processInfo.environment["AGENT_VM_SECRET_SERVICE"] ?? ""
        return override.isEmpty ? "agent-vm" : override
    }

    /// The largest value stored: secrets are keys and tokens, not files.
    public static let maxValueBytes = 64 << 10

    /// A secret's name is usable as an environment variable name, which `exec --secret NAME`
    /// makes of it.
    public static func isValidName(_ name: String) -> Bool {
        return ExecEnvironment.isValidName(name)
    }

    /// One `--secret` value: `NAME` (the variable is named after the secret) or `VAR=NAME`.
    public static func option(_ spec: String) throws -> (variable: String, secret: String) {
        let parts = spec.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        let variable = parts[0]
        let secret = parts.count == 2 ? parts[1] : parts[0]
        guard ExecEnvironment.isValidName(variable), isValidName(secret) else {
            // Not the text after "=": a mistaken --secret VAR=value would show the value.
            throw AgentVMError.invalidSecret(name: variable, reason: "--secret takes NAME or VAR=NAME (letters, digits and _, not starting with a digit)")
        }
        return (variable, secret)
    }

    public struct Entry: Codable, Equatable, Sendable {
        public var name: String
        /// Whether this agent-vm can read it without macOS asking, as far as agent-vm can tell:
        /// true when an agent-vm with the same code requirement stored it. False when another
        /// build or program stored it, even if someone chose Always Allow for this one since.
        public var readable: Bool
    }

    /// Stores `value` under `name`, replacing an earlier value. The value must be text without
    /// NUL characters (it becomes an environment variable).
    public func set(_ name: String, value: Data) throws {
        try Self.check(name)
        guard !value.isEmpty else {
            throw AgentVMError.invalidSecret(name: name, reason: "the value is empty")
        }
        guard value.count <= Self.maxValueBytes else {
            throw AgentVMError.invalidSecret(name: name, reason: "the value is longer than \(Self.maxValueBytes >> 10) KB")
        }
        guard String(data: value, encoding: .utf8) != nil, !value.contains(0) else {
            throw AgentVMError.invalidSecret(name: name, reason: "the value is not text (UTF-8 without NUL characters)")
        }
        let query = baseQuery(name)
        let marker = Data((Self.codeRequirement ?? "").utf8)
        // An item another build or program stored keeps its access list through an update,
        // which would still make macOS ask this agent-vm (and the marker would say otherwise):
        // such an item is replaced by a new one, which trusts this agent-vm.
        var replaced = false
        if let existing = try attributes(name), existing[kSecAttrGeneric as String] as? Data != marker {
            let removed = SecItemDelete(query as CFDictionary)
            if removed != errSecItemNotFound {
                // No name: a refusal here is not "cannot be read", whose advice (store it again)
                // is what just failed.
                try Self.check(removed, operation: "replace secret \(name)", name: nil)
                replaced = true
            }
        }
        // After a replacement, a failure below means the earlier value is gone too: say so.
        let operation = "store secret \(name)\(replaced ? " (its earlier value was already removed)" : "")"
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: value, kSecAttrGeneric as String: marker] as CFDictionary)
        switch status {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var item = query
            item[kSecValueData as String] = value
            item[kSecAttrGeneric as String] = marker
            item[kSecAttrLabel as String] = "agent-vm secret \(name)"
            item[kSecAttrDescription as String] = "agent-vm secret"
            try Self.check(SecItemAdd(item as CFDictionary, nil), operation: operation, name: replaced ? nil : name)
        default:
            try Self.check(status, operation: operation, name: replaced ? nil : name)
        }
    }

    /// Deletes the secret; an error when there is none.
    public func delete(_ name: String) throws {
        try Self.check(name)
        let status = SecItemDelete(baseQuery(name) as CFDictionary)
        if status == errSecItemNotFound {
            throw AgentVMError.secretNotFound(name)
        }
        try Self.check(status, operation: "delete secret \(name)", name: name)
    }

    /// The value of the secret. For a secret another build or program stored, macOS asks the
    /// person first, and the call waits for the answer.
    public func read(_ name: String) throws -> Data {
        try Self.check(name)
        var query = baseQuery(name)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            throw AgentVMError.secretNotFound(name)
        }
        try Self.check(status, operation: "read secret \(name)", name: name)
        guard let data = result as? Data else {
            throw AgentVMError.secretUnreadable(name: name, reason: "the Keychain returned no value")
        }
        return data
    }

    /// One secret's attributes (never its value, so macOS never asks), or nil when there is none.
    private func attributes(_ name: String) throws -> [String: Any]? {
        var query = baseQuery(name)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        try Self.check(status, operation: "look up secret \(name)", name: name)
        return result as? [String: Any]
    }

    /// Every secret's name, sorted, and whether this agent-vm stored it (so reads it without
    /// macOS asking). Reads attributes only: never a value, never a question.
    public func list() throws -> [Entry] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return []
        }
        try Self.check(status, operation: "list secrets", name: nil)
        let current = Self.codeRequirement
        var entries: [String: Entry] = [:]
        for item in result as? [[String: Any]] ?? [] {
            guard let name = item[kSecAttrAccount as String] as? String else {
                continue
            }
            let marker = (item[kSecAttrGeneric as String] as? Data).map { String(decoding: $0, as: UTF8.self) }
            entries[name] = Entry(name: name, readable: current != nil && marker == current)
        }
        return entries.keys.sorted().compactMap { entries[$0] }
    }

    /// This process's designated code requirement as text ("cdhash H\"...\"" for an ad hoc
    /// build, identifier and team for a Developer ID one): what the Keychain trusts an item's
    /// creator by. Nil when it cannot be read.
    public static let codeRequirement: String? = {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else {
            return nil
        }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else {
            return nil
        }
        var requirement: SecRequirement?
        guard SecCodeCopyDesignatedRequirement(staticCode, [], &requirement) == errSecSuccess, let requirement else {
            return nil
        }
        var text: CFString?
        guard SecRequirementCopyString(requirement, [], &text) == errSecSuccess, let text else {
            return nil
        }
        return text as String
    }()

    private func baseQuery(_ name: String) -> [String: Any] {
        return [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: name,
        ]
    }

    private static func check(_ name: String) throws {
        guard isValidName(name) else {
            throw AgentVMError.invalidSecret(name: name, reason: "a secret's name is letters, digits and \"_\", not starting with a digit (it is also the environment variable's)")
        }
    }

    private static func check(_ status: OSStatus, operation: String, name: String?) throws {
        guard status != errSecSuccess else {
            return
        }
        let message = SecCopyErrorMessageString(status, nil) as String? ?? "error \(status)"
        switch status {
        case errSecInteractionNotAllowed, errSecAuthFailed, errSecUserCanceled:
            if let name {
                throw AgentVMError.secretUnreadable(name: name, reason: message)
            }
        default:
            break
        }
        throw AgentVMError.keychain(operation: operation, message: message)
    }
}
