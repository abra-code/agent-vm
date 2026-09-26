// Sources/AgentVMKit/Host/CodeSignature.swift
//
// Designated code requirements: what macOS trusts a program by. The Keychain trusts an item's
// creator by it, and TCC keeps a privacy grant such as Full Disk Access for any build that
// satisfies it. For an ad hoc build it is the hash of that one build ("cdhash H\"...\""); for a
// Developer ID build it names the identifier and the team, so every build signed the same way
// shares it (measured for Full Disk Access across `image update-guest`).

import Foundation
import Security

public enum CodeSignature {
    /// The designated requirement of the executable at `url` as text; nil when it is unsigned
    /// or cannot be read.
    public static func designatedRequirement(of url: URL) -> String? {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode) == errSecSuccess, let staticCode else {
            return nil
        }
        return designatedRequirement(of: staticCode)
    }

    static func designatedRequirement(of staticCode: SecStaticCode) -> String? {
        var requirement: SecRequirement?
        guard SecCodeCopyDesignatedRequirement(staticCode, [], &requirement) == errSecSuccess, let requirement else {
            return nil
        }
        var text: CFString?
        guard SecRequirementCopyString(requirement, [], &text) == errSecSuccess, let text else {
            return nil
        }
        return text as String
    }

    /// Whether `requirement` names a signer (an anchor, as Developer ID and Apple Development
    /// signatures have, or a self-signed root certificate), so other builds can satisfy it,
    /// rather than one build's hash.
    public static func namesASigner(_ requirement: String) -> Bool {
        return !requirement.hasPrefix("cdhash ") && (requirement.contains("anchor ") || requirement.contains("certificate root"))
    }
}
