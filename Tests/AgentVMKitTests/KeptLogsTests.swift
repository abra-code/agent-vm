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
        #expect(try String(contentsOf: kept.appendingPathComponent("exec.jsonl"), encoding: .utf8) == "ran\n")
        #expect(try String(contentsOf: kept.appendingPathComponent("exec.jsonl.1"), encoding: .utf8) == "older\n")
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
        #expect(Set(entry.files) == ["exec.jsonl", "exec.jsonl.1", "network-allowed.jsonl", "network.jsonl", "supervisor.log", "console.log"])
        #expect(entry.bytes == 4 + 6 + 8 + 8 + 8 + 5)
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
        #expect(try String(contentsOf: logs.directory.appendingPathComponent(ids[0]).appendingPathComponent("exec.jsonl"), encoding: .utf8) == "first")
    }

    @Test func recreateKeepsTheOldBoxsLogs() throws {
        let fixture = try BoxScratch()
        let old = try fixture.boxes.create(name: "b1", from: fixture.image, imageStore: fixture.images)
        try Self.write("ran\n", "exec.jsonl", in: old)
        var deleted: BoxStore.Deleted?
        let box = try fixture.boxes.recreate(name: "b1", from: fixture.image, imageStore: fixture.images) { deleted = $0 }
        #expect(!FileManager.default.fileExists(atPath: box.execLogURL.path))
        let kept = try #require(deleted?.keptLogs)
        #expect(try String(contentsOf: kept.appendingPathComponent("exec.jsonl"), encoding: .utf8) == "ran\n")
    }

    @Test func aCollectedDisposableBoxKeepsItsLogs() throws {
        let fixture = try BoxScratch()
        let box = try fixture.boxes.create(name: "d1", from: fixture.image, imageStore: fixture.images, disposable: true)
        try Self.write("ran\n", "exec.jsonl", in: box)
        try Self.write("stopped\n", "tombstone", in: box)
        #expect(fixture.boxes.collectGarbage().deleted == ["d1"])
        let entry = try #require(KeptLogs(root: fixture.boxes.root).list().first)
        #expect(entry.logs.box == "d1" && entry.logs.disposable == true && entry.files == ["exec.jsonl"])
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
        // A locked file cannot be renamed; the box's removal unlocks it.
        #expect(chflags(box.directory.appendingPathComponent("supervisor.log").path, UInt32(UF_IMMUTABLE)) == 0)
        let deleted = try fixture.boxes.delete(named: "b1")
        let kept = try #require(deleted.keptLogs)
        #expect(deleted.logsProblem?.contains("supervisor.log") == true)
        #expect(!FileManager.default.fileExists(atPath: box.directory.path))
        let entry = try #require(KeptLogs(root: fixture.boxes.root).list().first)
        #expect(entry.path == kept.path && entry.files == ["exec.jsonl"])
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
        for id in ["", "..", "../Boxes", "b0/x", "B0", ".hidden"] {
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
        #expect(Set(record.keys) == ["formatVersion", "id", "box", "image", "guest", "boxCreatedAt", "keptAt"])
        #expect(record["guest"] as? String == "macos")
    }
}
