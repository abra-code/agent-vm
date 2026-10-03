// Tests/AgentVMKitTests/SessionStoreTests.swift
//
// Live-mode sessions against real folders on the test machine's APFS volume: snapshot
// fidelity, undo restoring the exact tree, discard surviving agent-hostile trees, and the
// refusals that keep a session from covering too much.

import Darwin
import Foundation
import Testing
@testable import AgentVMKit

@Suite struct SessionStoreTests {
    // MARK: - start

    @Test func startSnapshotsTheWholeTree() throws {
        let scratch = try Scratch()
        try scratch.populate()
        let session = try scratch.store.start(project: scratch.project.path)

        #expect(session.record.state == .active)
        #expect(session.record.project == scratch.project.path)
        #expect(try describeTree(session.snapshotPath) == describeTree(scratch.project.path))
    }

    @Test func snapshotIsIndependentOfLaterChanges() throws {
        let scratch = try Scratch()
        try scratch.populate()
        let session = try scratch.store.start(project: scratch.project.path)
        try scratch.write("README.md", "changed by the agent\n")

        let snapshotReadme = try String(contentsOfFile: session.snapshotPath + "/README.md", encoding: .utf8)
        #expect(snapshotReadme == "hello\n")
    }

    @Test func startRecordsATimeBeforeTheSnapshot() throws {
        let scratch = try Scratch()
        try scratch.populate()
        let before = Date()
        let session = try scratch.store.start(project: scratch.project.path)
        #expect(session.record.startedAt >= before.addingTimeInterval(-1))
        #expect(session.record.startedAt <= Date())
    }

    @Test func secondActiveSessionOnTheSameProjectIsRefused() throws {
        let scratch = try Scratch()
        try scratch.populate()
        let first = try scratch.store.start(project: scratch.project.path)
        #expect(throws: AgentVMError.sessionAlreadyActive(project: scratch.project.path, id: first.id)) {
            try scratch.store.start(project: scratch.project.path)
        }
        try scratch.store.end(id: first.id)
        let second = try scratch.store.start(project: scratch.project.path)
        #expect(second.id != first.id)
    }

    @Test func unsuitableProjectsAreRefused() throws {
        let scratch = try Scratch()
        try scratch.write("file.txt", "x")
        let store = scratch.store

        func expectRefused(_ path: String) {
            #expect(throws: AgentVMError.self) { try store.start(project: path) }
        }
        expectRefused("/")
        expectRefused(NSHomeDirectory())
        expectRefused((NSHomeDirectory() as NSString).deletingLastPathComponent) // contains home
        expectRefused(scratch.path("file.txt"))                                 // not a folder
        expectRefused(scratch.path("does-not-exist"))
        expectRefused(scratch.root.path)                                         // contains the store
        #expect(try store.list().isEmpty)
    }

    @Test func projectInsideTheStoreIsRefused() throws {
        let scratch = try Scratch()
        let inside = scratch.store.root.appendingPathComponent("Sessions/inner", isDirectory: true)
        try FileManager.default.createDirectory(at: inside, withIntermediateDirectories: true)
        #expect(throws: AgentVMError.self) { try scratch.store.start(project: inside.path) }
    }

    // MARK: - undo

    @Test func undoRestoresTheExactTreeAndKeepsWhatWasReplaced() throws {
        let scratch = try Scratch()
        try scratch.populate()
        let original = try describeTree(scratch.project.path)
        let session = try scratch.store.start(project: scratch.project.path)

        // What an agent might do: edit, add, delete, plant a hook, change modes, add links.
        try scratch.write("README.md", "rewritten\n")
        try scratch.write("new/file.txt", "added\n")
        try FileManager.default.removeItem(atPath: scratch.path("Sources/App/main.swift"))
        try scratch.write(".git/hooks/pre-commit", "#!/bin/sh\ncurl evil.example\n")
        chmod(scratch.path("build.sh"), 0o644)
        symlink("/etc/passwd", scratch.path("escape"))
        let agentTree = try describeTree(scratch.project.path)

        let undone = try scratch.store.undo(id: session.id, mode: .wholeTree).session

        #expect(undone.record.state == .undone)
        #expect(try describeTree(scratch.project.path) == original)
        let replaced = try #require(undone.replacedTreePath)
        #expect(try describeTree(replaced) == agentTree)
        #expect(try describeTree(undone.snapshotPath) == original)
        #expect(try scratch.store.session(id: session.id).record.state == .undone)
    }

    @Test func undoWorksAfterEndButOnlyOnce() throws {
        let scratch = try Scratch()
        try scratch.populate()
        let session = try scratch.store.start(project: scratch.project.path)
        try scratch.write("README.md", "agent\n")
        try scratch.store.end(id: session.id)
        try scratch.store.undo(id: session.id)
        #expect(try scratch.read("README.md") == "hello\n")
        #expect(throws: AgentVMError.wrongSessionState(id: session.id, state: "undone", operation: "undo")) {
            try scratch.store.undo(id: session.id)
        }
    }

    // MARK: - undo by path

    @Test func undoByPathRestoresOnlyThoseEntries() throws {
        let scratch = try Scratch()
        try scratch.populate()
        let session = try scratch.store.start(project: scratch.project.path)
        try scratch.write("README.md", "rewritten\n")
        try FileManager.default.removeItem(atPath: scratch.path("Sources/App/main.swift"))
        try scratch.write("new/file.txt", "added\n")
        // A flagged entry inside a folder the agent added is listed, and undoable on its own.
        try scratch.write("tool/.mcp.json", "{\"mcpServers\": {}}\n")
        try scratch.write("tool/notes.txt", "notes\n")
        let report = try scratch.store.report(id: session.id)
        #expect(report.changes.contains { $0.path == "tool/.mcp.json" && $0.coveredByAncestor })

        let first = try scratch.store.undo(id: session.id, paths: ["./README.md", scratch.path("Sources")])
        #expect(first.isComplete)
        #expect(first.restore?.restored == ["README.md", "Sources/App/main.swift"])
        #expect(first.restore?.remaining == 0)
        #expect(first.session.record.state == .active)
        #expect(try scratch.read("README.md") == "hello\n")
        #expect(try scratch.read("Sources/App/main.swift") == "print(\"hi\")\n")
        #expect(try scratch.read("new/file.txt") == "added\n")
        let replaced = try #require(first.session.replacedTreePath)
        #expect(try String(contentsOfFile: replaced + "/README.md", encoding: .utf8) == "rewritten\n")

        let flagged = try scratch.store.undo(id: session.id, paths: ["tool/.mcp.json/"])
        #expect(flagged.restore?.restored == ["tool/.mcp.json"])
        #expect(!FileManager.default.fileExists(atPath: scratch.path("tool/.mcp.json")))
        #expect(try scratch.read("tool/notes.txt") == "notes\n")
        #expect(flagged.session.record.state == .active)

        // What is left, all at once; now nothing changed remains.
        let rest = try scratch.store.undo(id: session.id)
        #expect(rest.isComplete)
        #expect(rest.session.record.state == .undone)
        #expect(try scratch.store.report(id: session.id).changes.isEmpty)
    }

    @Test func undoByPathMovesANestedListedFolderAsOne() throws {
        let scratch = try Scratch()
        try scratch.populate()
        let session = try scratch.store.start(project: scratch.project.path)
        // Inside an added folder, a hidden folder and a file in it are both listed (flagged).
        try scratch.write("tool/.claude/settings.json", "{}\n")
        try scratch.write("tool/notes.txt", "notes\n")
        let report = try scratch.store.report(id: session.id)
        #expect(report.changes.contains { $0.path == "tool/.claude" && $0.coveredByAncestor })
        #expect(report.changes.contains { $0.path == "tool/.claude/settings.json" && $0.coveredByAncestor })

        let outcome = try scratch.store.undo(id: session.id, paths: ["tool/.claude"])
        #expect(outcome.isComplete, "\(outcome.restore?.failed ?? [:])")
        #expect(outcome.restore?.restored == ["tool/.claude"])
        #expect(!FileManager.default.fileExists(atPath: scratch.path("tool/.claude")))
        let replaced = try #require(outcome.session.replacedTreePath)
        #expect(try String(contentsOfFile: replaced + "/tool/.claude/settings.json", encoding: .utf8) == "{}\n")
        #expect(try scratch.read("tool/notes.txt") == "notes\n")
    }

    @Test func undoByPathMarksTheSessionUndoneWhenNothingIsLeft() throws {
        let scratch = try Scratch()
        try scratch.populate()
        let session = try scratch.store.start(project: scratch.project.path)
        try scratch.write("README.md", "rewritten\n")
        let outcome = try scratch.store.undo(id: session.id, paths: ["README.md"])
        #expect(outcome.session.record.state == .undone)
        #expect(outcome.session.record.undoneAt != nil)
    }

    @Test func undoByPathRefusesPathsItCannotRestoreBeforeMovingAnything() throws {
        let scratch = try Scratch()
        try scratch.populate()
        let session = try scratch.store.start(project: scratch.project.path)
        try scratch.write("README.md", "rewritten\n")
        try scratch.write("new/file.txt", "added\n")
        // Listed (flagged), but its folder is not: undoing the folder would leave the rest.
        try scratch.write("new/sub/.mcp.json", "{}\n")
        try FileManager.default.removeItem(atPath: scratch.path("Sources"))
        let refusals: [(String, String)] = [
            ("build.sh", "did not change"),
            ("new/file.txt", "inside new, which the agent added as a whole"),
            ("new/sub", "inside new, which the agent added as a whole"),
            ("Sources/App/main.swift", "inside Sources, which the agent deleted as a whole"),
            ("../elsewhere", "without . or .."),
            ("/etc/hosts", "not inside the project"),
            ("", "names no entry"),
        ]
        for (path, reason) in refusals {
            do {
                try scratch.store.undo(id: session.id, paths: ["README.md", path])
                Issue.record("\(path) was accepted")
            } catch let AgentVMError.invalidUndoPath(refused, why) {
                #expect(refused == path)
                #expect(why.contains(reason), "\(path): \(why)")
            }
        }
        #expect(throws: AgentVMError.invalidUndoPath("README.md", reason: "a whole-tree undo restores everything")) {
            try scratch.store.undo(id: session.id, mode: .wholeTree, paths: ["README.md"])
        }
        #expect(throws: AgentVMError.invalidUndoPath("", reason: "no paths given; undo without paths restores everything")) {
            try scratch.store.undo(id: session.id, paths: [])
        }
        // Nothing moved, and no replaced folder was made.
        #expect(try scratch.read("README.md") == "rewritten\n")
        let children = try FileManager.default.contentsOfDirectory(atPath: session.directory.path)
        #expect(!children.contains { $0.hasPrefix(SessionStore.replacedPrefix) })
        #expect(try scratch.store.session(id: session.id).record.state == .active)
    }

    @Test func theProjectFolderItselfIsUndoneAsDot() throws {
        let scratch = try Scratch()
        try scratch.populate()
        let session = try scratch.store.start(project: scratch.project.path)
        chmod(scratch.project.path, 0o700)
        try scratch.write("README.md", "rewritten\n")
        let outcome = try scratch.store.undo(id: session.id, paths: [scratch.project.path])
        #expect(outcome.restore?.restored == ["."])
        #expect(try scratch.read("README.md") == "rewritten\n")
    }

    // MARK: - snapshotPath and discard by age

    @Test func theSnapshotPathIsPrintedButNotSaved() throws {
        let scratch = try Scratch()
        try scratch.populate()
        let session = try scratch.store.start(project: scratch.project.path)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let object = try #require(try JSONSerialization.jsonObject(with: encoder.encode(SessionOutput(session))) as? [String: Any])
        #expect(object["snapshotPath"] as? String == session.snapshotPath)
        #expect(object["id"] as? String == session.id)
        #expect(object["state"] as? String == "active")
        let saved = try String(contentsOfFile: session.directory.path + "/session.json", encoding: .utf8)
        #expect(!saved.contains("snapshotPath"))
        #expect(try scratch.store.report(id: session.id).snapshotPath == session.snapshotPath)

        let discarded = try scratch.store.discard(id: session.id)
        let gone = try #require(try JSONSerialization.jsonObject(with: encoder.encode(SessionOutput(discarded))) as? [String: Any])
        #expect(gone["snapshotPath"] == nil)
        #expect(gone["state"] as? String == "discarded")
    }

    @Test func discardByAgeLeavesActiveAndRecentSessions() throws {
        let scratch = try Scratch()
        try scratch.populate()
        let ended = try scratch.store.start(project: scratch.project.path)
        try scratch.store.end(id: ended.id)
        let undone = try scratch.store.start(project: scratch.project.path)
        try scratch.write("README.md", "agent\n")
        try scratch.store.undo(id: undone.id)
        let active = try scratch.store.start(project: scratch.project.path)

        let none = try scratch.store.discard(olderThan: 3600)
        #expect(none.discarded.isEmpty && none.failures.isEmpty)

        let later = try scratch.store.discard(olderThan: 3600, now: Date().addingTimeInterval(7200))
        #expect(Set(later.discarded.map(\.id)) == [ended.id, undone.id])
        #expect(later.failures.isEmpty)
        #expect(try scratch.store.session(id: active.id).record.state == .active)
        #expect(!FileManager.default.fileExists(atPath: ended.snapshotPath))
        #expect(FileManager.default.fileExists(atPath: active.snapshotPath))
        // Already discarded: not again.
        #expect(try scratch.store.discard(olderThan: 0, now: Date().addingTimeInterval(7200)).discarded.isEmpty)
    }

    @Test func undoRefusesWhenTheProjectIsGone() throws {
        let scratch = try Scratch()
        try scratch.populate()
        let session = try scratch.store.start(project: scratch.project.path)
        try FileSystem.removeTree(scratch.project.path)
        #expect(throws: AgentVMError.projectMissing(path: scratch.project.path)) {
            try scratch.store.undo(id: session.id)
        }
    }

    // MARK: - end, list, discard

    @Test func endOnlyAppliesToActiveSessions() throws {
        let scratch = try Scratch()
        try scratch.populate()
        let session = try scratch.store.start(project: scratch.project.path)
        let ended = try scratch.store.end(id: session.id)
        #expect(ended.record.state == .ended)
        #expect(ended.record.endedAt != nil)
        #expect(throws: AgentVMError.wrongSessionState(id: session.id, state: "ended", operation: "end")) {
            try scratch.store.end(id: session.id)
        }
    }

    @Test func listReturnsSessionsOldestFirstAndIgnoresStrayFolders() throws {
        let scratch = try Scratch()
        try scratch.populate()
        let first = try scratch.store.start(project: scratch.project.path)
        try scratch.store.end(id: first.id)
        let second = try scratch.store.start(project: scratch.project.path)
        try FileManager.default.createDirectory(
            at: scratch.store.sessionsDirectory.appendingPathComponent("not-a-session"),
            withIntermediateDirectories: true)

        let ids = try scratch.store.list().map(\.id)
        #expect(ids == [first.id, second.id])
    }

    @Test func aDamagedRecordDoesNotBlockOtherSessions() throws {
        let scratch = try Scratch()
        try scratch.populate()
        let first = try scratch.store.start(project: scratch.project.path)
        try scratch.store.end(id: first.id)
        try Data("not json".utf8).write(to: first.directory.appendingPathComponent("session.json"))

        let second = try scratch.store.start(project: scratch.project.path)
        let (sessions, problems) = try scratch.store.listWithProblems()
        #expect(sessions.map(\.id) == [second.id])
        #expect(problems.count == 1)
    }

    @Test func discardDeletesAgentHostileTrees() throws {
        let scratch = try Scratch()
        try scratch.populate()
        let session = try scratch.store.start(project: scratch.project.path)

        // Things an agent can do to make its leftovers hard to delete.
        try scratch.write("locked/inner/file.txt", "x")
        chmod(scratch.path("locked/inner"), 0o000)
        chmod(scratch.path("locked"), 0o500)
        try scratch.write("immutable.txt", "x")
        chflags(scratch.path("immutable.txt"), UInt32(UF_IMMUTABLE))
        try scratch.store.undo(id: session.id)
        let replaced = try #require(try scratch.store.session(id: session.id).replacedTreePath)

        let discarded = try scratch.store.discard(id: session.id)
        #expect(discarded.record.state == .discarded)
        #expect(!FileSystem.exists(discarded.snapshotPath))
        #expect(!FileSystem.exists(replaced))
        #expect(try scratch.store.session(id: session.id).record.state == .discarded)
        #expect(throws: AgentVMError.wrongSessionState(id: session.id, state: "discarded", operation: "discard")) {
            try scratch.store.discard(id: session.id)
        }
    }

    @Test func discardNeverFollowsSymlinksOutOfTheSession() throws {
        let scratch = try Scratch()
        try scratch.populate()
        let outside = scratch.root.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: outside.appendingPathComponent("keep.txt"))
        symlink(outside.path, scratch.path("link-out"))

        let session = try scratch.store.start(project: scratch.project.path)
        try scratch.store.discard(id: session.id)
        #expect(FileSystem.exists(outside.appendingPathComponent("keep.txt").path))
    }

    // MARK: - an agent still running during the undo

    /// Reports leave FIFOs out, so one left where a file or a folder was reads as a deletion.
    /// Opening it would wait forever for a writer, with every session command behind the lock.
    @Test(.timeLimit(.minutes(1)))
    func aFIFOLeftWhereAnEntryWasDoesNotBlockUndo() throws {
        let scratch = try Scratch()
        try scratch.populate()
        let original = try describeTree(scratch.project.path)
        let session = try scratch.store.start(project: scratch.project.path)

        try FileManager.default.removeItem(atPath: scratch.path("README.md"))
        #expect(mkfifo(scratch.path("README.md"), 0o600) == 0)
        try FileManager.default.removeItem(atPath: scratch.path("Sources"))
        #expect(mkfifo(scratch.path("Sources"), 0o600) == 0)

        let outcome = try scratch.store.undo(id: session.id)
        #expect(outcome.restore?.failed.isEmpty == true)
        #expect(try describeTree(scratch.project.path) == original)
        // Moved aside, like everything else of the agent's.
        let replaced = try #require(outcome.session.replacedTreePath)
        for name in ["README.md", "Sources"] {
            let info = try FileSystem.status(replaced + "/" + name)
            #expect(info.st_mode & S_IFMT == S_IFIFO)
        }
        #expect(!FileSystem.exists(outcome.session.directory.appendingPathComponent(ProjectRestorer.stagingName).path))
    }

    /// The agent exchanges a folder of the project with a link to a folder outside it, again and
    /// again, while the undo works through that folder's entries. Whatever the undo manages to
    /// restore, nothing outside the project may be moved, written or deleted.
    @Test(.timeLimit(.minutes(2)))
    func undoNeverLeavesTheProjectThroughAFolderSwappedForALink() throws {
        let scratch = try Scratch()
        let outside = scratch.root.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let count = 400
        for index in 0..<count {
            try scratch.write("a/modified-\(index)", "at session start\n")
            try scratch.write("a/deleted-\(index)", "at session start\n")
            // The same names outside: what a path-based undo would move away or overwrite.
            try Data("the user's own\n".utf8).write(to: outside.appendingPathComponent("modified-\(index)"))
        }
        let outsideBefore = try describeTree(outside.path)
        let session = try scratch.store.start(project: scratch.project.path)
        for index in 0..<count {
            try scratch.write("a/modified-\(index)", "changed by the agent\n")
            try FileManager.default.removeItem(atPath: scratch.path("a/deleted-\(index)"))
        }
        symlink(outside.path, scratch.path("lnk"))

        let stop = StopFlag()
        let folder = scratch.path("a")
        let link = scratch.path("lnk")
        let flipper = Thread {
            while !stop.isSet {
                renamex_np(folder, link, UInt32(RENAME_SWAP))
                renamex_np(folder, link, UInt32(RENAME_SWAP))
            }
            stop.finished.signal()
        }
        flipper.start()
        let outcome = try scratch.store.undo(id: session.id)
        stop.set()
        stop.finished.wait()

        #expect(try describeTree(outside.path) == outsideBefore)
        let replaced = try #require(outcome.session.replacedTreePath)
        let moved = try describeTree(replaced).filter {
            if case .file(let data) = $0.kind {
                return data == Data("the user's own\n".utf8)
            }
            return false
        }
        #expect(moved.isEmpty)
    }

    /// A locked FIFO where a deleted file was: it is opened up like any other entry of the
    /// agent's, without being opened as a FIFO (which waits for a writer).
    @Test(.timeLimit(.minutes(1)))
    func aLockedFIFOLeftWhereAnEntryWasIsMovedAside() throws {
        let scratch = try Scratch()
        try scratch.populate()
        let original = try describeTree(scratch.project.path)
        let session = try scratch.store.start(project: scratch.project.path)

        try FileManager.default.removeItem(atPath: scratch.path("README.md"))
        #expect(mkfifo(scratch.path("README.md"), 0o600) == 0)
        #expect(lchflags(scratch.path("README.md"), UInt32(UF_IMMUTABLE)) == 0)

        let outcome = try scratch.store.undo(id: session.id)
        #expect(outcome.restore?.failed.isEmpty == true)
        #expect(try describeTree(scratch.project.path) == original)
        let replaced = try #require(outcome.session.replacedTreePath)
        #expect(try FileSystem.status(replaced + "/README.md").st_mode & S_IFMT == S_IFIFO)
    }

    /// The agent swaps a changed file for a FIFO in a folder it made read-only, after the
    /// report was made: moving it aside must not open it.
    @Test(.timeLimit(.minutes(1)))
    func aFIFOPutWhereAChangedFileWasDoesNotBlockUndo() throws {
        let scratch = try Scratch()
        try scratch.populate()
        let session = try scratch.store.start(project: scratch.project.path)
        try scratch.write("Sources/App/main.swift", "changed by the agent\n")
        let changes = try ChangeScanner.report(session: session).changes.filter { !$0.coveredByAncestor }

        try FileManager.default.removeItem(atPath: scratch.path("Sources/App/main.swift"))
        #expect(mkfifo(scratch.path("Sources/App/main.swift"), 0o600) == 0)
        chmod(scratch.path("Sources/App"), 0o555)

        let replaced = session.directory.appendingPathComponent("replaced-test").path
        let result = try ProjectRestorer.restore(session: session, changes: changes, replacedPath: replaced)
        #expect(result.failed.isEmpty)
        #expect(try scratch.read("Sources/App/main.swift") == "print(\"hi\")\n")
        #expect(try FileSystem.status(replaced + "/Sources/App/main.swift").st_mode & S_IFMT == S_IFIFO)
    }

    /// What the undo moves into the replaced tree is the agent's, a link to a folder outside
    /// included: nothing moved there later may go through it.
    @Test(.timeLimit(.minutes(2)))
    func aLinkMovedIntoTheReplacedTreeIsNeverFollowed() throws {
        for _ in 0..<20 {
            let scratch = try Scratch()
            let outside = scratch.root.appendingPathComponent("outside", isDirectory: true)
            try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
            try scratch.write("notes", "at session start\n")
            try scratch.write("notes.unlisted-2/planted", "at session start\n")
            let session = try scratch.store.start(project: scratch.project.path)
            try scratch.write("notes", "changed by the agent\n")
            try FileManager.default.removeItem(atPath: scratch.path("notes.unlisted-2/planted"))

            let stop = StopFlag()
            let entry = scratch.path("notes")
            let planted = scratch.path("notes.unlisted-2/planted")
            let agent = Thread {
                while !stop.isSet {
                    symlink(outside.path, entry)
                    close(open(planted, O_CREAT | O_WRONLY, 0o600))
                }
                stop.finished.signal()
            }
            agent.start()
            _ = try scratch.store.undo(id: session.id)
            stop.set()
            stop.finished.wait()

            #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
        }
    }

    /// The same exchange while the snapshot is taken (an agent of an earlier session that
    /// still runs): whatever the snapshot ends up holding, it is never a copy of what is
    /// outside the project. A start that fails instead is fine.
    @Test(.timeLimit(.minutes(2)))
    func aSnapshotNeverHoldsWhatIsOutsideTheProject() throws {
        let marker = Data("the user's own\n".utf8)
        for _ in 0..<5 {
            let scratch = try Scratch()
            let outside = scratch.root.appendingPathComponent("outside", isDirectory: true)
            try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
            for index in 0..<400 {
                try scratch.write("a/file-\(index)", "in the project\n")
                try marker.write(to: outside.appendingPathComponent("file-\(index)"))
            }
            symlink(outside.path, scratch.path("lnk"))
            let outsideBefore = try describeTree(outside.path)

            let stop = StopFlag()
            let folder = scratch.path("a")
            let link = scratch.path("lnk")
            let flipper = Thread {
                while !stop.isSet {
                    renamex_np(folder, link, UInt32(RENAME_SWAP))
                    renamex_np(folder, link, UInt32(RENAME_SWAP))
                }
                stop.finished.signal()
            }
            flipper.start()
            _ = try? scratch.store.start(project: scratch.project.path)
            stop.set()
            stop.finished.wait()

            #expect(try describeTree(outside.path) == outsideBefore)
            let kept = try describeTree(scratch.store.root.path).filter { $0.kind == .file(marker) }
            #expect(kept.isEmpty)
        }
    }

    // MARK: - awkward but legitimate projects, and agents that lock things down

    @Test func readOnlyFoldersAreSnapshottedAndRestored() throws {
        let scratch = try Scratch()
        try scratch.populate()
        try scratch.write("vendor/pkg/inner/file.go", "package inner\n")
        symlink("file.go", scratch.path("vendor/pkg/inner/link.go"))       // copyfile makes symlinks last
        try scratch.write("shared/notes.txt", "notes\n")
        try addACL("everyone deny add_file,add_subdirectory", to: scratch.path("shared"))
        try addACL("everyone deny delete", to: scratch.path("shared/notes.txt"))
        chmod(scratch.path("vendor/pkg/inner"), 0o555)
        chmod(scratch.path("vendor/pkg"), 0o555)
        chmod(scratch.project.path, 0o555)
        defer { chmod(scratch.project.path, 0o755) }
        let original = try describeTree(scratch.project.path)

        let session = try scratch.store.start(project: scratch.project.path)
        #expect(try describeTree(session.snapshotPath) == original)
        #expect(hasACL(session.snapshotPath + "/shared") && hasACL(session.snapshotPath + "/shared/notes.txt"))
        chmod(scratch.project.path, 0o755)
        try scratch.write("added.txt", "agent\n")
        try scratch.store.undo(id: session.id)
        #expect(try describeTree(scratch.project.path) == original)
        #expect(try FileSystem.status(scratch.project.path).st_mode & 0o7777 == 0o555)
        #expect(hasACL(scratch.path("shared")) && hasACL(scratch.path("shared/notes.txt")))
    }

    @Test func aFolderKeepsItsAttributesInTheSnapshot() throws {
        let scratch = try Scratch()
        try scratch.populate()
        try scratch.write("assets/logo.txt", "logo\n")
        #expect(setxattr(scratch.path("assets"), "com.example.note", "kept", 4, 0, 0) == 0)
        #expect(setxattr(scratch.path("assets/logo.txt"), "com.example.note", "kept", 4, 0, 0) == 0)
        chmod(scratch.path("assets"), 0o750)
        chflags(scratch.path("assets"), UInt32(UF_HIDDEN))
        var times = [timespec(tv_sec: 1_600_000_000, tv_nsec: 0), timespec(tv_sec: 1_600_000_000, tv_nsec: 0)]
        #expect(utimensat(AT_FDCWD, scratch.path("assets"), &times, 0) == 0)

        let session = try scratch.store.start(project: scratch.project.path)
        let copy = try FileSystem.status(session.snapshotPath + "/assets")
        #expect(copy.st_mode & 0o7777 == 0o750)
        #expect(copy.st_flags & UInt32(UF_HIDDEN) != 0)
        #expect(copy.st_mtimespec.tv_sec == 1_600_000_000)
        var value = [UInt8](repeating: 0, count: 16)
        #expect(getxattr(session.snapshotPath + "/assets", "com.example.note", &value, value.count, 0, 0) == 4)
        #expect(getxattr(session.snapshotPath + "/assets/logo.txt", "com.example.note", &value, value.count, 0, 0) == 4)
        #expect(try scratch.store.report(id: session.id).isEmpty)
    }

    @Test func socketsAndFIFOsAreLeftOutOfTheSnapshot() throws {
        let scratch = try Scratch()
        try scratch.populate()
        let original = try describeTree(scratch.project.path)
        #expect(mkfifo(scratch.path(".git/fifo"), 0o600) == 0)

        let session = try scratch.store.start(project: scratch.project.path)
        #expect(!FileSystem.exists(session.snapshotPath + "/.git/fifo"))
        #expect(try describeTree(session.snapshotPath) == original)
    }

    @Test func aFailedCloneReportsTheCauseAndLeavesNothingBehind() throws {
        let scratch = try Scratch()
        try scratch.populate()
        let missing = scratch.root.appendingPathComponent("missing/copy").path
        do {
            try FileSystem.cloneTree(scratch.project.path, to: missing)
            Issue.record("cloning into a folder that does not exist succeeded")
        } catch let AgentVMError.system(_, code) {
            #expect(code == ENOENT)
        }
        #expect(!FileSystem.exists(missing))
        // The same for a single file: a clone that made nothing is not a success.
        do {
            try FileSystem.cloneTree(scratch.path("README.md"), to: missing)
            Issue.record("cloning a file into a folder that does not exist succeeded")
        } catch let AgentVMError.system(_, code) {
            #expect(code == ENOENT)
        }
        // What is already there is not the clone's to replace, or to remove.
        let taken = scratch.root.appendingPathComponent("taken").path
        try FileSystem.makeDirectory(taken)
        do {
            try FileSystem.cloneTree(scratch.project.path, to: taken)
            Issue.record("cloning over an existing folder succeeded")
        } catch let AgentVMError.system(_, code) {
            #expect(code == EEXIST)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: taken).isEmpty)
    }

    // MARK: - what an agent leaves to stop the next snapshot, or the cleanup

    /// A tree nested deeper than a path may be long (PATH_MAX): copyfile, fts with full paths
    /// and FileManager all stop there. Left in the project it made every later `start` fail,
    /// and moved into the session folder by an undo it could not be discarded.
    @Test(.timeLimit(.minutes(2)))
    func aTreeDeeperThanAPathMayBeIsSnapshottedRestoredAndDiscarded() throws {
        let scratch = try Scratch()
        try scratch.populate()
        let name = String(repeating: "d", count: 200)
        try makeChain(in: scratch.project.path, name: name, levels: 20, text: "at session start\n")

        let session = try scratch.store.start(project: scratch.project.path)
        #expect(describeChain(in: session.snapshotPath, name: name) == (20, "at session start\n"))

        // The agent removes the tree and leaves a deeper one of its own.
        try FileSystem.removeTree(scratch.path(name))
        #expect(!FileSystem.exists(scratch.path(name)))
        let other = String(repeating: "e", count: 200)
        try makeChain(in: scratch.project.path, name: other, levels: 30, text: "the agent's\n")

        let outcome = try scratch.store.undo(id: session.id)
        #expect(outcome.restore?.failed.isEmpty == true)
        #expect(describeChain(in: scratch.project.path, name: name) == (20, "at session start\n"))
        #expect(!FileSystem.exists(scratch.path(other)))
        let replaced = try #require(outcome.session.replacedTreePath)
        #expect(describeChain(in: replaced, name: other) == (30, "the agent's\n"))

        // The next session starts with the deep tree in place, and the old one can be discarded.
        try scratch.store.end(id: session.id)
        let next = try scratch.store.start(project: scratch.project.path)
        #expect(describeChain(in: next.snapshotPath, name: name).levels == 20)
        try scratch.store.discard(id: session.id)
        #expect(!FileSystem.exists(replaced))
        #expect(!FileSystem.exists(session.snapshotPath))
        try scratch.store.undo(id: next.id, mode: .wholeTree)
        #expect(describeChain(in: scratch.project.path, name: name) == (20, "at session start\n"))
        try scratch.store.discard(id: next.id)
        #expect(!FileSystem.exists(next.snapshotPath))
    }

    /// Hundreds of folders deep: the walk keeps no descriptor and no stack frame per level.
    @Test(.timeLimit(.minutes(2)))
    func aTreeHundredsOfFoldersDeepIsClonedAndRemoved() throws {
        let scratch = try Scratch()
        try makeChain(in: scratch.project.path, name: "n", levels: 500, text: "bottom\n")
        let copy = scratch.root.appendingPathComponent("copy").path
        try FileSystem.cloneTree(scratch.project.path, to: copy)
        #expect(describeChain(in: copy, name: "n") == (500, "bottom\n"))
        try FileSystem.removeTree(copy)
        #expect(!FileSystem.exists(copy))
    }

    /// Entries their owner cannot read. Each one stopped `start` (a clone needs to read its
    /// source), so one `chmod 000` in a session took the snapshot away from every later one.
    @Test func entriesNobodyCanReadAreSnapshottedAsTheyAre() throws {
        let scratch = try Scratch()
        try scratch.populate()
        try scratch.write("secret.txt", "nobody reads this\n")
        try scratch.write("closed/inner/file.txt", "inside\n")
        try scratch.write("denied/file.txt", "inside\n")
        try scratch.write("denied.txt", "denied\n")
        try scratch.write("locked/file.txt", "inside\n")
        try scratch.write("hidden.txt", "hidden\n")
        chmod(scratch.path("secret.txt"), 0o000)
        chmod(scratch.path("closed/inner"), 0o000)
        chmod(scratch.path("closed"), 0o000)
        try addACL("everyone deny list,search", to: scratch.path("denied"))
        try addACL("everyone deny read", to: scratch.path("denied.txt"))
        try addACL("everyone deny readsecurity,readattr", to: scratch.path("hidden.txt"))
        chflags(scratch.path("locked/file.txt"), UInt32(UF_IMMUTABLE))
        chflags(scratch.path("locked"), UInt32(UF_IMMUTABLE))

        let session = try scratch.store.start(project: scratch.project.path)
        // The project is as it was, and the snapshot is the same.
        for root in [scratch.project.path, session.snapshotPath] {
            #expect(try FileSystem.status(root + "/secret.txt").st_mode & 0o7777 == 0o000, "\(root)")
            #expect(try FileSystem.status(root + "/closed").st_mode & 0o7777 == 0o000, "\(root)")
            #expect(hasACL(root + "/denied") && hasACL(root + "/denied.txt"), "\(root)")
            #expect(try FileSystem.status(root + "/locked").st_flags & UInt32(UF_IMMUTABLE) != 0, "\(root)")
            #expect(try FileSystem.status(root + "/locked/file.txt").st_flags & UInt32(UF_IMMUTABLE) != 0, "\(root)")
        }
        // What nobody could read is in the snapshot all the same.
        let copy = scratch.root.appendingPathComponent("readable").path
        try FileSystem.cloneTree(session.snapshotPath, to: copy)
        chmod(copy + "/secret.txt", 0o600)
        chmod(copy + "/closed", 0o700)
        chmod(copy + "/closed/inner", 0o700)
        #expect(try String(contentsOfFile: copy + "/secret.txt", encoding: .utf8) == "nobody reads this\n")
        #expect(try String(contentsOfFile: copy + "/closed/inner/file.txt", encoding: .utf8) == "inside\n")
        try FileSystem.removeTree(copy)
        #expect(!FileSystem.exists(copy))

        // The agent replaces the unreadable file and removes the closed folder: undo brings
        // both back, closed as they were.
        chmod(scratch.path("secret.txt"), 0o600)
        try scratch.write("secret.txt", "the agent's\n")
        try FileSystem.removeTree(scratch.path("closed"))
        let outcome = try scratch.store.undo(id: session.id, paths: ["secret.txt", "closed"])
        #expect(outcome.restore?.failed.isEmpty == true)
        #expect(try FileSystem.status(scratch.path("secret.txt")).st_mode & 0o7777 == 0o000)
        #expect(try FileSystem.status(scratch.path("closed")).st_mode & 0o7777 == 0o000)
        chmod(scratch.path("secret.txt"), 0o600)
        #expect(try scratch.read("secret.txt") == "nobody reads this\n")
        try scratch.store.discard(id: session.id)
        #expect(!FileSystem.exists(session.snapshotPath))
    }

    /// Locked, with an ACL that hides even the lock: neither can be read to be saved, so both
    /// go, and the entry is snapshotted and can be deleted.
    @Test func aLockedEntryThatHidesItsAttributesIsSnapshottedAndRemoved() throws {
        let scratch = try Scratch()
        try scratch.populate()
        try scratch.write("hidden.txt", "hidden\n")
        try addACL("everyone deny readattr,readsecurity,delete", to: scratch.path("hidden.txt"))
        #expect(lchflags(scratch.path("hidden.txt"), UInt32(UF_IMMUTABLE)) == 0)

        let session = try scratch.store.start(project: scratch.project.path)
        #expect(try String(contentsOfFile: session.snapshotPath + "/hidden.txt", encoding: .utf8) == "hidden\n")
        try addACL("everyone deny readattr,readsecurity,delete", to: session.snapshotPath + "/hidden.txt")
        #expect(lchflags(session.snapshotPath + "/hidden.txt", UInt32(UF_IMMUTABLE)) == 0)
        try scratch.store.discard(id: session.id)
        #expect(!FileSystem.exists(session.snapshotPath))
    }

    /// Locked entries below the depth a path reaches: they are opened up through their identity
    /// on the volume, the only name left for them.
    @Test(.timeLimit(.minutes(1)))
    func lockedEntriesInADeepTreeAreRemoved() throws {
        let scratch = try Scratch()
        try scratch.write("closed/file.txt", "x")
        try scratch.write("denied/file.txt", "x")
        try scratch.write("locked.txt", "x")
        try scratch.write("denied.txt", "x")
        let name = String(repeating: "d", count: 200)
        try makeChain(in: scratch.project.path, name: name, levels: 12, text: "bottom\n")
        // Moved to the bottom first: the calls that lock them take paths.
        var bottom = open(scratch.project.path, O_RDONLY | O_DIRECTORY)
        for _ in 0..<12 {
            let next = openat(bottom, name, O_RDONLY | O_DIRECTORY)
            close(bottom)
            bottom = next
        }
        defer { close(bottom) }
        let top = open(scratch.project.path, O_RDONLY | O_DIRECTORY)
        defer { close(top) }
        try addACL("everyone deny list,search,readsecurity,readattr", to: scratch.path("denied"))
        try addACL("everyone deny read,readsecurity,readattr", to: scratch.path("denied.txt"))
        for entry in ["closed", "denied", "denied.txt"] {
            #expect(renameat(top, entry, bottom, entry) == 0, "\(entry): \(String(cString: strerror(errno)))")
        }
        #expect(renameat(top, "locked.txt", bottom, "locked.txt") == 0)
        #expect(fchmodat(bottom, "closed", 0o000, 0) == 0)
        let locked = openat(bottom, "locked.txt", O_RDONLY)
        #expect(fchflags(locked, UInt32(UF_IMMUTABLE)) == 0)
        close(locked)

        try FileSystem.removeTree(scratch.project.path)
        #expect(!FileSystem.exists(scratch.project.path))
    }

    /// A symlink has permissions of its own (`chmod -h`), and one without any cannot be cloned
    /// as it is either.
    @Test func aSymlinkNobodyCanReadIsSnapshottedAsItIs() throws {
        let scratch = try Scratch()
        try scratch.populate()
        #expect(symlink("README.md", scratch.path("closed-link")) == 0)
        #expect(lchmod(scratch.path("closed-link"), 0o000) == 0)

        let session = try scratch.store.start(project: scratch.project.path)
        let copy = session.snapshotPath + "/closed-link"
        #expect(try FileSystem.status(scratch.path("closed-link")).st_mode & 0o7777 == 0o000)
        #expect(try FileSystem.status(copy).st_mode == S_IFLNK)
        #expect(try scratch.store.report(id: session.id).isEmpty)
        #expect(lchmod(copy, 0o700) == 0)
        var target = [CChar](repeating: 0, count: 64)
        #expect(readlink(copy, &target, target.count - 1) == 9)
        #expect(String(cString: target) == "README.md")
    }

    /// Opening a FIFO waits for a writer, even an open made only to change its ACL: without
    /// care, one FIFO with an ACL makes `start` wait forever.
    @Test(.timeLimit(.minutes(1)))
    func aFIFOWithAnACLDoesNotStopTheSnapshot() throws {
        let scratch = try Scratch()
        try scratch.populate()
        #expect(mkfifo(scratch.path("unseen"), 0o600) == 0)
        try addACL("everyone deny readattr,readsecurity", to: scratch.path("unseen"), itself: false)
        #expect(mkfifo(scratch.path("Sources/kept"), 0o600) == 0)
        try addACL("everyone deny delete", to: scratch.path("Sources/kept"), itself: false)

        let session = try scratch.store.start(project: scratch.project.path)
        #expect(!FileSystem.exists(session.snapshotPath + "/unseen"))
        #expect(!FileSystem.exists(session.snapshotPath + "/Sources/kept"))
        #expect(hasACL(scratch.path("Sources/kept")))
    }

    /// The same for the cleanup: the ACL of a FIFO that denies deleting it is removed.
    @Test(.timeLimit(.minutes(1)))
    func aFIFOWithAnACLIsRemoved() throws {
        let scratch = try Scratch()
        try scratch.populate()
        #expect(mkfifo(scratch.path("Sources/kept"), 0o600) == 0)
        try addACL("everyone deny delete", to: scratch.path("Sources/kept"), itself: false)
        #expect(unlink(scratch.path("Sources/kept")) != 0)

        try FileSystem.removeTree(scratch.project.path)
        #expect(!FileSystem.exists(scratch.project.path))
    }

    enum Lock: String, CaseIterable {
        case readOnly, immutable, denyDelete, denyReadSecurity, denyEverything
    }

    @Test(arguments: Lock.allCases)
    func undoIsNotBlockedByALockedProjectFolder(lock: Lock) throws {
        let scratch = try Scratch()
        try scratch.populate()
        try addACL("everyone deny delete", to: scratch.path("README.md"))  // the user's own ACL
        let original = try describeTree(scratch.project.path)
        let session = try scratch.store.start(project: scratch.project.path)
        try scratch.write("added.txt", "agent\n")

        switch lock {
        case .readOnly: chmod(scratch.project.path, 0o555)
        case .immutable: chflags(scratch.project.path, UInt32(UF_IMMUTABLE))
        case .denyDelete: try addACL("everyone deny delete", to: scratch.project.path)
        case .denyReadSecurity: try addACL("everyone deny readsecurity", to: scratch.project.path)
        case .denyEverything:
            try addACL("everyone deny delete,readsecurity,list,add_file,add_subdirectory,delete_child", to: scratch.project.path)
        }
        let undone = try scratch.store.undo(id: session.id, mode: .wholeTree).session

        #expect(try describeTree(scratch.project.path) == original)
        #expect(!hasACL(scratch.project.path))
        #expect(hasACL(scratch.path("README.md")))
        let replaced = try #require(undone.replacedTreePath)
        let replacedInfo = try FileSystem.statusRemovingUnreadableACL(replaced)
        switch lock {
        case .readOnly: #expect(replacedInfo.st_mode & 0o7777 == 0o555)
        case .immutable: #expect(replacedInfo.st_flags & UInt32(UF_IMMUTABLE) != 0)
        case .denyDelete: #expect(hasACL(replaced))
        case .denyReadSecurity, .denyEverything: break  // unreadable, so not kept
        }
        try scratch.store.discard(id: session.id)
        #expect(!FileSystem.exists(replaced))
    }

    @Test func discardDeletesTreesLockedWithACLs() throws {
        let scratch = try Scratch()
        try scratch.populate()
        let session = try scratch.store.start(project: scratch.project.path)
        try scratch.write("acl/sub/file.txt", "x")
        try addACL("everyone deny delete,readsecurity", to: scratch.path("acl/sub/file.txt"))
        try addACL("everyone deny delete_child,list,search,readsecurity", to: scratch.path("acl/sub"))
        try addACL("everyone deny delete_child", to: scratch.path("acl"))
        symlink("README.md", scratch.path("acl/link"))
        try addACL("everyone deny delete,readsecurity", to: scratch.path("acl/link"))
        try scratch.store.undo(id: session.id)
        let replaced = try #require(try scratch.store.session(id: session.id).replacedTreePath)
        try addACL("everyone deny delete,readsecurity,list", to: replaced)

        try scratch.store.discard(id: session.id)
        var info = stat()
        #expect(lstat(replaced, &info) == -1 && errno == ENOENT)
        #expect(hasACL(scratch.path("README.md")) == false)  // the link target was not touched
    }

    @Test func foundationErrorsAreReportedWithTheirPOSIXCode() {
        do {
            try FileManager.default.removeItem(atPath: "/nonexistent-agent-vm-\(UUID().uuidString)")
            Issue.record("removing a missing path succeeded")
        } catch {
            #expect(FileSystem.posixCode(error) == ENOENT)
        }
    }

    // MARK: - ids and records

    @Test func malformedIDsAreRejectedBeforeTouchingTheDisk() throws {
        let scratch = try Scratch()
        for id in ["../etc", "20260923-120000-zzzz", "", "20260923-120000-abcd/..", "x"] {
            #expect(throws: AgentVMError.invalidSessionID(id)) { try scratch.store.session(id: id) }
        }
        #expect(throws: AgentVMError.sessionNotFound("20260923-120000-abcd")) {
            try scratch.store.session(id: "20260923-120000-abcd")
        }
    }

    @Test func generatedIDsHaveTheDocumentedShape() {
        let id = SessionStore.newID()
        #expect(SessionStore.isValidID(id))
    }

    @Test func defaultRootHonorsAgentVMHome() {
        #expect(SessionStore.defaultRoot(environment: ["AGENT_VM_HOME": "/tmp/x"]).path == "/tmp/x")
        #expect(SessionStore.defaultRoot(environment: [:]).path.hasSuffix("Library/Application Support/agent-vm"))
    }
}
