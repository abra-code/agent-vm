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

    @Test func socketsAndFIFOsAreLeftOutOfTheSnapshot() throws {
        let scratch = try Scratch()
        try scratch.populate()
        let original = try describeTree(scratch.project.path)
        #expect(mkfifo(scratch.path(".git/fifo"), 0o600) == 0)

        let session = try scratch.store.start(project: scratch.project.path)
        #expect(!FileSystem.exists(session.snapshotPath + "/.git/fifo"))
        #expect(try describeTree(session.snapshotPath) == original)
    }

    @Test func failedSnapshotReportsTheCauseAndLeavesNothingBehind() throws {
        let scratch = try Scratch()
        try scratch.populate()
        chmod(scratch.path("README.md"), 0o000)
        #expect(throws: AgentVMError.self) { try scratch.store.start(project: scratch.project.path) }
        do {
            try scratch.store.start(project: scratch.project.path)
        } catch let AgentVMError.system(_, code) {
            #expect(code == EACCES)
        }
        #expect(try scratch.store.list().isEmpty)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: scratch.store.sessionsDirectory.path)
        #expect(leftovers.filter(SessionStore.isValidID).isEmpty)
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
