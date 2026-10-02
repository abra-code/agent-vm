// Sources/AgentVMKit/Images/NewestMacOS.swift
//
// The newest macOS Apple offers for this Mac's virtual machines, as `agent-vm status
// --check-updates` last learned it (the restore image Virtualization names; the same lookup as
// `image fetch-ipsw --check`). It is kept in the store (`Cache/newest-macos.json`), so `status`
// and `image list` can say which images are behind without a network and without booting
// anything. Nothing asks Apple unless a command is told to.

import Foundation

public struct NewestMacOS: Codable, Equatable, Sendable {
    /// For example "27.0.1" and "26A434".
    public var version: String
    public var build: String
    /// When Apple was asked.
    public var checkedAt: Date

    public init(version: String, build: String, checkedAt: Date) {
        self.version = version
        self.build = build
        self.checkedAt = checkedAt
    }

    /// A macOS update an image can take with `image update --macos`.
    public struct Update: Codable, Equatable, Sendable {
        public var version: String
        public var build: String
        /// When Apple was asked.
        public var checkedAt: Date
    }

    static func file(root: URL) -> URL {
        return FileSystem.canonicalRoot(root).appendingPathComponent("Cache", isDirectory: true).appendingPathComponent("newest-macos.json")
    }

    /// What the store keeps; nil when Apple was never asked, or the file cannot be read.
    public static func read(root: URL) -> NewestMacOS? {
        guard let data = try? Data(contentsOf: file(root: root)) else {
            return nil
        }
        return try? SessionStore.decoder.decode(NewestMacOS.self, from: data)
    }

    public func write(root: URL) throws {
        let file = Self.file(root: root)
        try StoreRoot.prepare(root)
        try FileSystem.makeDirectories(file.deletingLastPathComponent().path)
        do {
            try SessionStore.encoder.encode(self).write(to: file, options: .atomic)
        } catch {
            throw AgentVMError.system(operation: "write \(file.path)", code: FileSystem.posixCode(error))
        }
    }

    /// Asks Apple, and keeps the answer in the store.
    public static func check(root: URL) async throws -> NewestMacOS {
        let latest = try await LatestRestoreImage.fetch()
        let newest = NewestMacOS(version: latest.version, build: latest.build,
                                 checkedAt: Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down)))
        try newest.write(root: root)
        return newest
    }

    /// The update a ready image is behind by, or nil: only a newer macOS of the image's own
    /// major version counts (`image update` installs nothing else; a new major version is a
    /// new image). An image whose own `image update --macos` asked Apple after this answer was
    /// kept has what softwareupdate offers it, which is what decides: it gets no hint.
    public func update(for record: ImageRecord) -> Update? {
        guard record.state == .ready, record.macOSBuild != build else {
            return nil
        }
        if let asked = record.macOSCheckedAt, asked >= checkedAt {
            return nil
        }
        let mine = MacOSUpdate.numbers(record.macOSVersion)
        let newest = MacOSUpdate.numbers(version)
        guard let major = mine.first, major == newest.first else {
            return nil
        }
        if mine.lexicographicallyPrecedes(newest) {
            return Update(version: version, build: build, checkedAt: checkedAt)
        }
        // The same version built again ("26A428" before "26A434").
        guard mine == newest, record.macOSBuild.compare(build, options: .numeric) == .orderedAscending else {
            return nil
        }
        return Update(version: version, build: build, checkedAt: checkedAt)
    }
}
