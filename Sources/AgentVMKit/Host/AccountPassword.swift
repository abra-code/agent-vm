// Sources/AgentVMKit/Host/AccountPassword.swift
//
// The password of the account in an image and in its boxes. An image built from a restore
// file gets a random one; derived images and boxes are clones of its disk, so they share it.
//
// It is kept in the login Keychain: one generic password per installed macOS, service
// "agent-vm.account", the account a random identifier. The image's record names the identifier
// (`passwordID`), and derived images and boxes record the same one, so making a box or deriving
// an image needs no Keychain access and adds no item. An item is removed when the last record
// in its store that names it is gone.
//
// A record without `passwordID` keeps the password in a `Password` file (mode 0600) in its
// folder, as every image did before 0.6.0. That is also what an ad hoc build makes: the
// Keychain ties an item to the program that stored it, and an ad hoc build is a new program
// after every rebuild, so macOS would ask about every image the previous build made.
//
// What the Keychain adds: the password is no longer plain text for whatever reads small files
// in the store (a backup of ~/Library, a sync or search tool, a sandboxed program allowed to
// read there). It does not hide it from a reader of the disk images: automatic login keeps the
// same password in each guest's /etc/kcpassword, obscured with a public key.

import Foundation
import Security

public struct AccountPasswordStore: Sendable {
    /// The Keychain service: the secrets' service plus ".account", so the tests' own service
    /// (AGENT_VM_SECRET_SERVICE) covers both and `secret list` never shows these.
    public let service: String
    /// For tests: items kept in memory instead (a test process that stored Keychain items
    /// would make macOS ask the next build about them).
    let memory: Memory?

    public init(service: String = AccountPasswordStore.defaultService) {
        self.service = service
        self.memory = nil
    }

    init(memory: Memory) {
        self.service = "memory"
        self.memory = memory
    }

    final class Memory: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [String: (password: String, store: String)] = [:]

        func withItems<T>(_ body: (inout [String: (password: String, store: String)]) -> T) -> T {
            lock.lock()
            defer { lock.unlock() }
            return body(&items)
        }
    }

    public static var defaultService: String {
        return SecretStore.defaultService + ".account"
    }

    /// Whether this agent-vm puts the password of an image it installs in the Keychain: only a
    /// build whose code requirement names its signer, which every later build then meets.
    public static var keepsNewPasswords: Bool {
        guard let requirement = SecretStore.codeRequirement else {
            return false
        }
        return !requirement.hasPrefix("cdhash ")
    }

    /// Stores a new password under `id`. `label` is what Keychain Access shows; `store` is the
    /// agent-vm store the item belongs to (`removeUnused` looks only at its own).
    public func add(id: String, password: String, label: String, store root: URL) throws {
        if let memory {
            memory.withItems { $0[id] = (password, root.path) }
            return
        }
        var item = query(id)
        item[kSecValueData as String] = Data(password.utf8)
        item[kSecAttrGeneric as String] = Self.marker
        item[kSecAttrLabel as String] = label
        item[kSecAttrDescription as String] = "agent-vm account password"
        item[kSecAttrComment as String] = root.path
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw AgentVMError.keychain(operation: "store the account password", message: Self.message(status))
        }
    }

    /// The password stored under `id`. `owner` names the image or box for the refusal. For an
    /// item another build stored, macOS asks the person first, and the call waits for the
    /// answer.
    public func read(id: String, owner: String) throws -> String {
        if let memory {
            guard let item = memory.withItems({ $0[id] }) else {
                throw AgentVMError.accountPasswordMissing(owner: owner, reason: Self.notInKeychain)
            }
            return item.password
        }
        var query = query(id)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data, let password = String(data: data, encoding: .utf8), !password.isEmpty else {
                throw AgentVMError.accountPasswordMissing(owner: owner, reason: "the Keychain item holds no text")
            }
            return password
        case errSecItemNotFound:
            throw AgentVMError.accountPasswordMissing(owner: owner, reason: Self.notInKeychain)
        case errSecInteractionNotAllowed:
            throw AgentVMError.accountPasswordUnreadable(owner: owner, reason: "the login Keychain is locked or cannot ask (\(Self.message(status))); run the command in a session on this Mac's screen, or unlock it first with `security unlock-keychain`")
        case errSecAuthFailed, errSecUserCanceled:
            throw AgentVMError.accountPasswordUnreadable(owner: owner, reason: "the Keychain refused this agent-vm (\(Self.message(status))); another build stored it, and macOS asks before it lets this one read it")
        default:
            throw AgentVMError.keychain(operation: "read the account password of \(owner)", message: Self.message(status))
        }
    }

    /// Whether an item exists under `id`. Reads attributes only: never a value, never a question.
    public func contains(_ id: String) -> Bool {
        if let memory {
            return memory.withItems { $0[id] != nil }
        }
        var query = query(id)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        return SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess
    }

    /// Removes the item; none is not an error.
    public func delete(id: String) throws {
        if let memory {
            memory.withItems { $0[id] = nil }
            return
        }
        let status = SecItemDelete(query(id) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw AgentVMError.keychain(operation: "remove an account password", message: Self.message(status))
        }
    }

    /// Removes the passwords no record in the store at `root` names any more: after an image or
    /// a box was deleted, a build failed before its VM ran, or a rebuild replaced an image.
    /// Only items this build stored for this store are looked at. When some record cannot be
    /// read, nothing is removed: its password may be one of them. Returns the identifiers
    /// removed.
    @discardableResult
    public func removeUnused(store root: URL) -> [String] {
        // The items first, the records after: a build names its identifier in its record before
        // it adds the item, so the record of every item listed here is there to be read.
        let stored = identifiers(storedFor: root)
        guard !stored.isEmpty, let used = Self.identifiersInUse(store: root) else {
            return []
        }
        var removed: [String] = []
        for id in stored where !used.contains(id) {
            if (try? delete(id: id)) != nil {
                removed.append(id)
            }
        }
        return removed.sorted()
    }

    /// The items this build stored for the store at `root`. Reads attributes only.
    private func identifiers(storedFor root: URL) -> [String] {
        if let memory {
            return memory.withItems { items in items.filter { $0.value.store == root.path }.map(\.key) }
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else {
            return []
        }
        return (result as? [[String: Any]] ?? []).compactMap { item in
            guard item[kSecAttrComment as String] as? String == root.path,
                  item[kSecAttrGeneric as String] as? Data == Self.marker else {
                return nil
            }
            return item[kSecAttrAccount as String] as? String
        }
    }

    /// The `passwordID` of every image and box record in the store, or nil when a record
    /// cannot be read. A folder without a record names nothing.
    static func identifiersInUse(store root: URL) -> Set<String>? {
        // Read twice: a rebuild exchanges two image folders in one step, and a pass that reads
        // one folder before the exchange and the other after it sees the old image twice and
        // the new one not at all.
        guard let first = namedIdentifiers(store: root), let second = namedIdentifiers(store: root) else {
            return nil
        }
        return first.union(second)
    }

    private static func namedIdentifiers(store root: URL) -> Set<String>? {
        struct Named: Decodable {
            var passwordID: String?
        }
        var used = Set<String>()
        for (folder, record) in [("Images", ImageStore.recordName), ("Boxes", BoxStore.recordName)] {
            let directory = root.appendingPathComponent(folder, isDirectory: true)
            let names: [String]
            do {
                names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            } catch {
                // No such folder holds no records; one that cannot be listed may hold some.
                guard !FileSystem.exists(directory.path) else {
                    return nil
                }
                continue
            }
            for name in names {
                let entry = directory.appendingPathComponent(name, isDirectory: true)
                // An image being updated keeps a second record there until the update is committed.
                for file in [entry.appendingPathComponent(record), entry.appendingPathComponent("Update").appendingPathComponent(record)] {
                    let data: Data
                    do {
                        data = try Data(contentsOf: file)
                    } catch {
                        // No record there (or a plain file among the folders). Any other failure
                        // is a record that cannot be read.
                        let code = FileSystem.posixCode(error)
                        guard code == ENOENT || code == ENOTDIR else {
                            return nil
                        }
                        continue
                    }
                    guard let named = try? JSONDecoder().decode(Named.self, from: data) else {
                        return nil
                    }
                    if let id = named.passwordID {
                        used.insert(id)
                    }
                }
            }
        }
        return used
    }

    static let notInKeychain = "it is not in this Mac's login Keychain; a store copied from another Mac or restored from a backup comes without it"

    /// The storing program's code requirement, as `SecretStore` records it: `removeUnused`
    /// leaves alone what another build stored.
    private static var marker: Data {
        return Data((SecretStore.codeRequirement ?? "").utf8)
    }

    private func query(_ id: String) -> [String: Any] {
        return [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id,
        ]
    }

    private static func message(_ status: OSStatus) -> String {
        return SecCopyErrorMessageString(status, nil) as String? ?? "error \(status)"
    }
}

public enum AccountPassword {
    /// Where a record's password is: `keychain` or `file`.
    public enum Storage: String, Codable, Sendable {
        case keychain, file
    }

    /// The password of an image or a box: the Keychain item its record names, or its file.
    static func read(id: String?, file: URL, owner: String, keychain: AccountPasswordStore) throws -> String {
        if let id {
            return try keychain.read(id: id, owner: owner)
        }
        guard let password = try? String(contentsOf: file, encoding: .utf8), !password.isEmpty else {
            throw AgentVMError.accountPasswordMissing(owner: owner, reason: "its file \(file.path) is missing or empty")
        }
        return password
    }
}

extension GoldenImage {
    public var passwordStorage: AccountPassword.Storage {
        return record.passwordID == nil ? .file : .keychain
    }

    /// Throws when the password is nowhere to be had, without reading it (so macOS never asks):
    /// for a command that needs it only minutes in, after cloning disks and booting a guest.
    func requireAccountPassword(keychain: AccountPasswordStore) throws {
        if let id = record.passwordID {
            guard keychain.contains(id) else {
                throw AgentVMError.accountPasswordMissing(owner: "image \(name)", reason: AccountPasswordStore.notInKeychain)
            }
        } else if !FileSystem.exists(passwordURL.path) {
            throw AgentVMError.accountPasswordMissing(owner: "image \(name)", reason: "its file \(passwordURL.path) is missing or empty")
        }
    }

    /// The account's password. From the Keychain it can make macOS ask (another build stored
    /// it) and wait for the answer.
    public func accountPassword(keychain: AccountPasswordStore = AccountPasswordStore()) throws -> String {
        return try AccountPassword.read(id: record.passwordID, file: passwordURL, owner: "image \(name)", keychain: keychain)
    }
}

extension Box {
    public var passwordStorage: AccountPassword.Storage {
        return record.passwordID == nil ? .file : .keychain
    }

    /// The account's password. From the Keychain it can make macOS ask (another build stored
    /// it) and wait for the answer.
    public func accountPassword(keychain: AccountPasswordStore = AccountPasswordStore()) throws -> String {
        return try AccountPassword.read(id: record.passwordID, file: passwordURL, owner: "box \(name) (image \(record.image))", keychain: keychain)
    }
}
