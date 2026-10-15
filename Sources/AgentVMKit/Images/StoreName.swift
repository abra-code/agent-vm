// Sources/AgentVMKit/Images/StoreName.swift
//
// Box and image names against their store folder (Boxes/, Images/). The Mac's disk ignores
// case and keeps it: a path made from "work" opens the folder "Work", and "work" and "Work"
// cannot be two folders. So a name is the one in the store only when the folder's listing has
// it as it is, and a new name is refused when another entry has it in other case.

import Foundation

enum StoreName {
    /// The entries of `folder` that equal `name` apart from case; empty when there is none or
    /// the folder is not there yet (a store with no boxes or images). A folder that cannot be
    /// listed is an error: taken for empty, every check would pass, and a rename would take
    /// its folder for moved.
    static func matches(_ name: String, in folder: URL) throws -> [String] {
        let entries: [String]
        do {
            entries = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        } catch {
            // As BoxStore.list: Foundation's "no such file" has no POSIX code behind it.
            if !FileSystem.exists(folder.path) {
                return []
            }
            throw AgentVMError.system(operation: "list \(folder.path)", code: FileSystem.posixCode(error))
        }
        let key = name.lowercased()
        return entries.filter { $0.lowercased() == key }.sorted()
    }

    /// Whether `folder` lists `name` as it is.
    static func isListed(_ name: String, in folder: URL) throws -> Bool {
        return try matches(name, in: folder).contains(name)
    }

    /// For a lookup: refuses `name` when the folder has it only in other case, which a path
    /// made from it would open. Nothing like it at all is the caller's "not found".
    static func checkExact(_ name: String, in folder: URL, what: String) throws {
        let found = try matches(name, in: folder)
        guard !found.isEmpty, !found.contains(name) else {
            return
        }
        throw AgentVMError.nameDiffersInCase(what: what, name: name, existing: found[0])
    }

    /// For a new name: refuses `name` when another entry has it in other case. The entry of
    /// that very name is the caller's "exists"; `except` is the entry being renamed, which a
    /// change of case only leaves in place.
    static func checkFree(_ name: String, in folder: URL, what: String, except: String? = nil) throws {
        guard let other = try matches(name, in: folder).first(where: { $0 != name && $0 != except }) else {
            return
        }
        throw AgentVMError.nameTakenInOtherCase(what: what, name: name, existing: other)
    }
}
