// Tests/AgentVMKitTests/KeptLogsTests.swift
//
// A deleted box's logs: moved out of the box's folder before it goes, listed, and removed by
// hand or by their age. The boxes are the scratch store's (BoxScratch); none runs.

import Darwin
import Foundation
import Testing
@testable import AgentVMKit

@Suite struct KeptLogsTests {
    static func write(_ text: String, _ name: String, in box: Box) throws {
        try Data(text.utf8).write(to: box.directory.appendingPathComponent(name))
    }

    /// What a kept log holds: `name` is the log's own name, and the file is compressed.
    static func read(_ kept: URL, _ name: String) throws -> String {
        let scratch = try Scratch()
        let expanded = scratch.root.appendingPathComponent("expanded").path
        try KeptLogs.expand(kept.appendingPathComponent(name + ".gz").path, to: expanded)
        return try String(contentsOfFile: expanded, encoding: .utf8)
    }

    @Test func deletingABoxKeepsItsLogs() throws {
        let fixture = try BoxScratch()
        let box = try fixture.boxes.create(name: "b1", from: fixture.image, imageStore: fixture.images)
        try Self.write("ran\n", "exec.jsonl", in: box)
        try Self.write("older\n", "exec.jsonl.1", in: box)
        try Self.write("allowed\n", "network-allowed.jsonl", in: box)
        try Self.write("refused\n", "network.jsonl", in: box)
        try Self.write("started\n", "supervisor.log", in: box)
        try Self.write("boot\n", "console.log", in: box)
        let when = Date(timeIntervalSince1970: 1_790_000_000)
        let deleted = try fixture.boxes.delete(named: "b1", now: when)
        #expect(deleted.logsProblem == nil)
        let kept = try #require(deleted.keptLogs)
        let logs = KeptLogs(root: fixture.boxes.root)
        #expect(kept.deletingLastPathComponent().path == logs.directory.path)
        #expect(kept.lastPathComponent == "b1-\(KeptLogs.stamp(when))")
        #expect(!FileManager.default.fileExists(atPath: box.directory.path))
        #expect(try Self.read(kept, "exec.jsonl") == "ran\n")
        #expect(try Self.read(kept, "exec.jsonl.1") == "older\n")
        // The folders are private, as the store is.
        for path in [logs.directory.path, kept.path] {
            #expect(((try FileManager.default.attributesOfItem(atPath: path))[.posixPermissions] as? Int) == 0o700, "\(path)")
        }
        let entries = logs.list()
        #expect(entries.count == 1)
        let entry = try #require(entries.first)
        #expect(entry.logs.id == kept.lastPathComponent && entry.logs.box == "b1" && entry.logs.image == "dev")
        #expect(entry.logs.guest == .macOS && entry.logs.keptAt == when && entry.logs.boxCreatedAt != nil)
        #expect(entry.path == kept.path)
        #expect(Set(entry.files) == ["exec.jsonl.gz", "exec.jsonl.1.gz", "network-allowed.jsonl.gz", "network.jsonl.gz", "supervisor.log.gz", "console.log.gz"])
        // The record has what the logs took in the box; the entry, what they take now.
        #expect(entry.logs.logBytes == Int64(39))
        #expect(entry.bytes == entry.files.reduce(0) { $0 + Int64((try? Data(contentsOf: kept.appendingPathComponent($1)).count) ?? -1000) })
        #expect(logs.totals() == KeptLogs.Totals(directory: logs.directory.path, holdDays: 30, count: 1, bytes: entry.bytes))
        // Nothing of the box but its logs is kept.
        #expect(Set(try FileManager.default.contentsOfDirectory(atPath: kept.path)) == Set(entry.files + ["kept.json"]))
    }

    @Test func aBoxThatLoggedNothingLeavesNothing() throws {
        let fixture = try BoxScratch()
        let box = try fixture.boxes.create(name: "b1", from: fixture.image, imageStore: fixture.images)
        // An empty log is nothing, and a link is not a log: what it points at stays.
        try Self.write("", "exec.jsonl", in: box)
        let outside = fixture.scratch.root.appendingPathComponent("outside.txt")
        try Data("mine".utf8).write(to: outside)
        #expect(symlink(outside.path, box.directory.appendingPathComponent("supervisor.log").path) == 0)
        let deleted = try fixture.boxes.delete(named: "b1")
        #expect(deleted == BoxStore.Deleted())
        let logs = KeptLogs(root: fixture.boxes.root)
        #expect(logs.list().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: logs.directory.path))
        #expect(try String(contentsOf: outside, encoding: .utf8) == "mine")
    }

    @Test func aSecondDeletionInTheSameSecondGetsItsOwnFolder() throws {
        let fixture = try BoxScratch()
        let when = Date(timeIntervalSince1970: 1_790_000_000)
        var ids: [String] = []
        for round in ["first", "second"] {
            let box = try fixture.boxes.create(name: "b1", from: fixture.image, imageStore: fixture.images)
            try Self.write(round, "exec.jsonl", in: box)
            ids.append(try #require(try fixture.boxes.delete(named: "b1", now: when).keptLogs).lastPathComponent)
        }
        let stamp = KeptLogs.stamp(when)
        #expect(ids == ["b1-\(stamp)", "b1-\(stamp)-2"])
        let logs = KeptLogs(root: fixture.boxes.root)
        #expect(logs.list().map(\.logs.id) == ["b1-\(stamp)-2", "b1-\(stamp)"])
        #expect(try Self.read(logs.directory.appendingPathComponent(ids[0]), "exec.jsonl") == "first")
    }

    @Test func recreateKeepsTheOldBoxsLogs() throws {
        let fixture = try BoxScratch()
        let old = try fixture.boxes.create(name: "b1", from: fixture.image, imageStore: fixture.images)
        try Self.write("ran\n", "exec.jsonl", in: old)
        var deleted: BoxStore.Deleted?
        let box = try fixture.boxes.recreate(name: "b1", from: fixture.image, imageStore: fixture.images) { deleted = $0 }
        #expect(!FileManager.default.fileExists(atPath: box.execLogURL.path))
        let kept = try #require(deleted?.keptLogs)
        #expect(try Self.read(kept, "exec.jsonl") == "ran\n")
    }

    @Test func aCollectedDisposableBoxKeepsItsLogs() throws {
        let fixture = try BoxScratch()
        let box = try fixture.boxes.create(name: "d1", from: fixture.image, imageStore: fixture.images, disposable: true)
        try Self.write("ran\n", "exec.jsonl", in: box)
        try Self.write("stopped\n", "tombstone", in: box)
        #expect(fixture.boxes.collectGarbage().deleted == ["d1"])
        let entry = try #require(KeptLogs(root: fixture.boxes.root).list().first)
        #expect(entry.logs.box == "d1" && entry.logs.disposable == true && entry.files == ["exec.jsonl.gz"])
    }

    @Test func logsThatCannotBeKeptDoNotKeepTheBox() throws {
        let fixture = try BoxScratch()
        let box = try fixture.boxes.create(name: "b1", from: fixture.image, imageStore: fixture.images)
        try Self.write("ran\n", "exec.jsonl", in: box)
        // Something that is no folder stands where Logs/ would be.
        let logs = KeptLogs(root: fixture.boxes.root)
        try Data("x".utf8).write(to: logs.directory)
        let deleted = try fixture.boxes.delete(named: "b1")
        #expect(deleted.keptLogs == nil)
        #expect(deleted.logsProblem?.isEmpty == false)
        #expect(!FileManager.default.fileExists(atPath: box.directory.path))
    }

    @Test func aLogThatCannotBeMovedLeavesTheOthersKept() throws {
        let fixture = try BoxScratch()
        let box = try fixture.boxes.create(name: "b1", from: fixture.image, imageStore: fixture.images)
        try Self.write("ran\n", "exec.jsonl", in: box)
        try Self.write("started\n", "supervisor.log", in: box)
        // A file that cannot be read is moved as it is, and a locked one cannot be moved; the
        // box's removal unlocks it.
        #expect(chmod(box.directory.appendingPathComponent("supervisor.log").path, 0) == 0)
        #expect(chflags(box.directory.appendingPathComponent("supervisor.log").path, UInt32(UF_IMMUTABLE)) == 0)
        let deleted = try fixture.boxes.delete(named: "b1")
        let kept = try #require(deleted.keptLogs)
        #expect(deleted.logsProblem?.contains("supervisor.log") == true)
        #expect(!FileManager.default.fileExists(atPath: box.directory.path))
        let entry = try #require(KeptLogs(root: fixture.boxes.root).list().first)
        #expect(entry.path == kept.path && entry.files == ["exec.jsonl.gz"])
    }

    @Test func aCollectedBoxWhoseLogsCannotBeKeptIsReported() throws {
        let fixture = try BoxScratch()
        let box = try fixture.boxes.create(name: "d1", from: fixture.image, imageStore: fixture.images, disposable: true)
        try Self.write("ran\n", "exec.jsonl", in: box)
        try Self.write("stopped\n", "tombstone", in: box)
        try Data("x".utf8).write(to: KeptLogs(root: fixture.boxes.root).directory)
        let collected = fixture.boxes.collectGarbage()
        #expect(collected.deleted == ["d1"])
        #expect(collected.problems.count == 1 && collected.problems.first?.contains("logs of disposable box d1") == true)
    }

    @Test func keptLogsAreRemovedByNameAndByAge() throws {
        let fixture = try BoxScratch()
        let logs = KeptLogs(root: fixture.boxes.root)
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        var ids: [Int: String] = [:]
        for days in [0, 29, 30, 45] {
            let box = try fixture.boxes.create(name: "b\(days)", from: fixture.image, imageStore: fixture.images)
            try Self.write("ran\n", "exec.jsonl", in: box)
            ids[days] = try #require(try fixture.boxes.delete(named: box.name, now: now.addingTimeInterval(-Double(days) * 86400)).keptLogs).lastPathComponent
        }
        #expect(logs.list().map(\.logs.box) == ["b0", "b29", "b30", "b45"])
        let older = logs.removeOlder(now: now)
        #expect(older.removed.sorted() == [ids[30]!, ids[45]!].sorted() && older.problems.isEmpty)
        #expect(logs.list().map(\.logs.box) == ["b0", "b29"])
        try logs.remove(ids[29]!)
        #expect(logs.list().map(\.logs.box) == ["b0"])
        #expect(throws: AgentVMError.keptLogsNotFound(ids[29]!)) { try logs.remove(ids[29]!) }
        // Another case of a kept folder's name is not that folder.
        let upper = ids[0]!.uppercased()
        #expect(KeptLogs.isValidID(upper) && !logs.exists(upper))
        #expect(throws: AgentVMError.keptLogsNotFound(upper)) { try logs.remove(upper) }
        for id in ["", "..", "../Boxes", "b0/x", "b0 x", ".hidden"] {
            #expect(!KeptLogs.isValidID(id), "\(id)")
            #expect(throws: AgentVMError.keptLogsNotFound(id)) { try logs.remove(id) }
        }
        // A folder whose record is gone is not listed, and goes by the age of the folder.
        let bare = logs.directory.appendingPathComponent(ids[0]!)
        try FileManager.default.removeItem(at: bare.appendingPathComponent("kept.json"))
        #expect(logs.list().isEmpty)
        // It is still one `remove` takes by name.
        #expect(logs.exists(ids[0]!) && !logs.exists("b0-nope") && !logs.exists("../Boxes"))
        #expect(logs.removeOlder(now: now).removed.isEmpty)
        #expect(logs.removeOlder(now: Date().addingTimeInterval(31 * 86400)).removed == [ids[0]!])
        #expect(logs.removeOlder(thanDays: 0).removed.isEmpty)
    }

    @Test func theRecordIsWhatAProgramReads() throws {
        let fixture = try BoxScratch()
        let box = try fixture.boxes.create(name: "b1", from: fixture.image, imageStore: fixture.images)
        try Self.write("ran\n", "exec.jsonl", in: box)
        _ = try fixture.boxes.delete(named: "b1")
        let entry = try #require(KeptLogs(root: fixture.boxes.root).list().first)
        let object = try #require(try JSONSerialization.jsonObject(with: SessionStore.encoder.encode(entry)) as? [String: Any])
        #expect(Set(object.keys) == ["logs", "path", "files", "bytes"])
        let record = try #require(object["logs"] as? [String: Any])
        #expect(Set(record.keys) == ["formatVersion", "id", "box", "image", "guest", "boxCreatedAt", "keptAt", "logBytes"])
        #expect(record["guest"] as? String == "macos")
    }
    @Test func compressedLogsExpandToWhatTheyWere() throws {
        let scratch = try Scratch()
        let source = scratch.root.appendingPathComponent("network.jsonl")
        // Lines like the proxy's, 2 MB of them: more than one chunk, and worth compressing.
        var text = ""
        for index in 0..<20_000 {
            text += #"{"decision":"denied","host":"host\#(index % 7).example","method":"CONNECT","port":443,"time":"2026-10-08T10:11:\#(index % 60)Z"}"# + "\n"
        }
        try Data(text.utf8).write(to: source)
        let packed = scratch.root.appendingPathComponent("network.jsonl.gz")
        try KeptLogs.compress(source.path, to: packed.path)
        let size = try #require((try FileManager.default.attributesOfItem(atPath: packed.path))[.size] as? Int)
        #expect(size > 0 && size * 10 < text.utf8.count)
        #expect(((try FileManager.default.attributesOfItem(atPath: packed.path))[.posixPermissions] as? Int) == 0o600)
        // It is a gzip file, as gunzip takes it.
        #expect(try Data(contentsOf: packed).prefix(2) == Data([0x1f, 0x8b]))
        let back = scratch.root.appendingPathComponent("back.jsonl")
        try KeptLogs.expand(packed.path, to: back.path)
        #expect(try Data(contentsOf: back) == Data(text.utf8))
        // Nothing that is there is replaced, and a link is not followed.
        #expect(throws: AgentVMError.self) { try KeptLogs.compress(source.path, to: packed.path) }
        #expect(throws: AgentVMError.self) { try KeptLogs.expand(packed.path, to: back.path) }
        let link = scratch.root.appendingPathComponent("link.jsonl")
        #expect(symlink(source.path, link.path) == 0)
        #expect(throws: AgentVMError.self) { try KeptLogs.compress(link.path, to: scratch.root.appendingPathComponent("link.gz").path) }
        #expect(!FileManager.default.fileExists(atPath: scratch.root.appendingPathComponent("link.gz").path))
        // More than the limit is refused and leaves nothing; so does a file that is no gzip
        // file past its first bytes.
        let small = scratch.root.appendingPathComponent("small.jsonl")
        #expect(throws: AgentVMError.self) { try KeptLogs.expand(packed.path, to: small.path, limit: 1000) }
        #expect(!FileManager.default.fileExists(atPath: small.path))
        let damaged = scratch.root.appendingPathComponent("damaged.gz")
        try (try Data(contentsOf: packed).prefix(size / 2) + Data(repeating: 0x55, count: 64)).write(to: damaged)
        #expect(throws: AgentVMError.self) { try KeptLogs.expand(damaged.path, to: small.path) }
        #expect(!FileManager.default.fileExists(atPath: small.path))
        // A file cut short reads without an error as far as it goes, and is refused all the same.
        let cut = scratch.root.appendingPathComponent("cut.gz")
        try Data(contentsOf: packed).prefix(size / 2).write(to: cut)
        let short = scratch.root.appendingPathComponent("cut.jsonl")
        #expect(throws: AgentVMError.self) { try KeptLogs.expand(cut.path, to: short.path) }
        #expect(!FileManager.default.fileExists(atPath: short.path))
    }

    @Test func aLogThatCannotBeCompressedIsMovedAsItIs() throws {
        let fixture = try BoxScratch()
        let box = try fixture.boxes.create(name: "b1", from: fixture.image, imageStore: fixture.images)
        try Self.write("ran\n", "exec.jsonl", in: box)
        try Self.write("started\n", "supervisor.log", in: box)
        // It cannot be read, so not compressed; a rename asks nothing of the file.
        #expect(chmod(box.directory.appendingPathComponent("supervisor.log").path, 0) == 0)
        let deleted = try fixture.boxes.delete(named: "b1")
        let kept = try #require(deleted.keptLogs)
        #expect(deleted.logsProblem == nil)
        #expect(Set(try FileManager.default.contentsOfDirectory(atPath: kept.path)) == ["exec.jsonl.gz", "supervisor.log", "kept.json"])
        let logs = KeptLogs(root: fixture.boxes.root)
        #expect(logs.list().first?.logs.logBytes == Int64(12))
        // Read together: the compressed one expanded, the other as it is.
        #expect(chmod(kept.appendingPathComponent("supervisor.log").path, 0o600) == 0)
        let readable = try logs.readable(kept.lastPathComponent, temporary: fixture.scratch.root)
        #expect(readable.temporary)
        #expect(try String(contentsOf: readable.folder.appendingPathComponent("exec.jsonl"), encoding: .utf8) == "ran\n")
        #expect(try String(contentsOf: readable.folder.appendingPathComponent("supervisor.log"), encoding: .utf8) == "started\n")
    }

    @Test func keptLogsAreReadAsABoxsAre() throws {
        let fixture = try BoxScratch()
        let box = try fixture.boxes.create(name: "b1", from: fixture.image, imageStore: fixture.images)
        let log = ExecLog(url: box.execLogURL)
        #expect(log.append(ExecLog.Entry(id: "p1", event: .start, time: Date(timeIntervalSince1970: 1_790_000_000), argv: ["/bin/echo"], user: "agent")) == nil)
        try Self.write("started\n", "supervisor.log", in: box)
        let kept = try #require(try fixture.boxes.delete(named: "b1").keptLogs)
        let logs = KeptLogs(root: fixture.boxes.root)
        let readable = try logs.readable(kept.lastPathComponent, temporary: fixture.scratch.root)
        #expect(readable.temporary && readable.folder.path != kept.path)
        #expect(readable.folder.deletingLastPathComponent().path == fixture.scratch.root.path)
        #expect(((try FileManager.default.attributesOfItem(atPath: readable.folder.path))[.posixPermissions] as? Int) == 0o700)
        #expect(ExecLog(url: readable.folder.appendingPathComponent("exec.jsonl")).records().map(\.id) == ["p1"])
        #expect(try String(contentsOf: readable.folder.appendingPathComponent("supervisor.log"), encoding: .utf8) == "started\n")
        // A folder that holds the files as they were (agent-vm 0.7.14 and 0.7.15, or a log
        // that could not be compressed) is read in place.
        let old = logs.directory.appendingPathComponent("old-20261001-000000")
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: false)
        try Data("ran\n".utf8).write(to: old.appendingPathComponent("exec.jsonl"))
        let plain = try logs.readable("old-20261001-000000", temporary: fixture.scratch.root)
        #expect(!plain.temporary && plain.folder.path == old.path)
        #expect(logs.totals().count == 2)
        #expect(throws: AgentVMError.keptLogsNotFound("nope")) { _ = try logs.readable("nope") }
    }

    @Test func aStoreCanKeepLogsLongerOrNotAtAll() throws {
        let fixture = try BoxScratch()
        let logs = KeptLogs(root: fixture.boxes.root)
        #expect(logs.holdDays == 30)
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        func deleteABox(_ name: String, daysAgo: Double) throws -> URL? {
            let box = try fixture.boxes.create(name: name, from: fixture.image, imageStore: fixture.images)
            try Self.write("ran\n", "exec.jsonl", in: box)
            return try fixture.boxes.delete(named: name, now: now.addingTimeInterval(-daysAgo * 86400)).keptLogs
        }
        _ = try #require(try deleteABox("b40", daysAgo: 40))
        try logs.setHoldDays(60)
        #expect(logs.holdDays == 60 && logs.totals().holdDays == 60)
        #expect(logs.removeOlder(now: now).removed.isEmpty)
        // With 0 a deleted box leaves nothing, with no problem said, and what was kept goes.
        try logs.setHoldDays(0)
        #expect(logs.holdDays == 0)
        let box = try fixture.boxes.create(name: "b0", from: fixture.image, imageStore: fixture.images)
        try Self.write("ran\n", "exec.jsonl", in: box)
        #expect(try fixture.boxes.delete(named: "b0", now: now) == BoxStore.Deleted())
        #expect(logs.list().map(\.logs.box) == ["b40"])
        #expect(logs.removeOlder(now: now).removed.count == 1)
        #expect(logs.totals().count == 0)
        // The setting is not one of the kept folders.
        #expect(FileManager.default.fileExists(atPath: fixture.boxes.root.appendingPathComponent("kept-logs.json").path))
        #expect(throws: AgentVMError.self) { try logs.setHoldDays(-1) }
        #expect(throws: AgentVMError.self) { try logs.setHoldDays(KeptLogs.maximumHoldDays + 1) }
        // A setting nobody can read, or out of range, is the default.
        for text in ["", "{", #"{"holdDays":-3}"#, #"{"holdDays":99999}"#, #"{"holdDays":"7"}"#] {
            try Data(text.utf8).write(to: fixture.boxes.root.appendingPathComponent("kept-logs.json"))
            #expect(logs.holdDays == 30, "\(text)")
        }
    }
}
