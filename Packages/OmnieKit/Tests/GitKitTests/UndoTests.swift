import Foundation
import Testing
@testable import GitKit

struct UndoTests {
    let dir: URL
    let me = Signature(name: "Pad", email: "pad@example.com")

    init() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("undo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    @discardableResult
    func cli(_ args: String...) throws -> String { try SSHTests.git(args, in: dir) }

    func write(_ path: String, _ text: String) throws {
        try text.write(to: dir.appendingPathComponent(path), atomically: true, encoding: .utf8)
    }

    func read(_ path: String) throws -> String {
        try String(contentsOf: dir.appendingPathComponent(path), encoding: .utf8)
    }

    func porcelain() throws -> Set<String> {
        Set(try cli("status", "--porcelain").split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) })
    }

    @Test func undoCommitBringsChangesBackUncommitted() async throws {
        let repo = try Repository.create(at: dir)
        try write("a.txt", "1\n")
        let base = try await repo.commitAll(message: "Base\n", author: me)
        try write("a.txt", "2\n")
        try write("new.txt", "n\n")
        try await repo.commitAll(message: "Second\n", author: me)
        #expect(try await repo.undoStack().last?.title == "Commit “Second”")

        let undone = try await repo.undo()
        #expect(undone.kind == .commit)
        #expect(try cli("rev-parse", "HEAD") == base.id.hex)
        #expect(try read("a.txt") == "2\n")
        #expect(try read("new.txt") == "n\n")
        #expect(try porcelain() == ["M a.txt", "?? new.txt"])
        #expect(try cli("diff", "--cached", "--name-only") == "")
    }

    @Test func undoIsAStack() async throws {
        let repo = try Repository.create(at: dir)
        try write("a.txt", "1\n")
        try await repo.commitAll(message: "One\n", author: me)
        try write("a.txt", "2\n")
        try await repo.commitAll(message: "Two\n", author: me)
        try write("a.txt", "3\n")
        try await repo.commitAll(message: "Three\n", author: me)

        try await repo.undo()
        try await repo.undo()
        #expect(try cli("log", "--format=%s") == "One")
        #expect(try read("a.txt") == "3\n")  // the latest work is still in the folder, uncommitted
        #expect(try await repo.undoStack().map(\.title) == ["Commit “One”"])
    }

    @Test func undoFirstCommitReturnsToUnbornBranch() async throws {
        let repo = try Repository.create(at: dir)
        try write("a.txt", "1\n")
        try await repo.commitAll(message: "First\n", author: me)
        try await repo.undo()
        #expect(try await repo.head().isUnborn)
        #expect(try await repo.head().branch == "main")
        #expect(try read("a.txt") == "1\n")
        await #expect(throws: UndoError.nothingToUndo) { try await repo.undo() }
    }

    @Test func undoBranchSwitch() async throws {
        let repo = try Repository.create(at: dir)
        try write("a.txt", "1\n")
        try await repo.commitAll(message: "Base\n", author: me)
        try await repo.createBranch("feature")
        try write("a.txt", "draft on main\n")
        try await repo.switchBranch(to: "feature")
        #expect(try read("a.txt") == "1\n")

        try await repo.undo()
        #expect(try await repo.head().branch == "main")
        #expect(try read("a.txt") == "draft on main\n")
    }

    @Test func undoSquashMerge() async throws {
        let repo = try Repository.create(at: dir)
        try write("a.txt", "1\n")
        let base = try await repo.commitAll(message: "Base\n", author: me)
        let wt = dir.deletingLastPathComponent().appendingPathComponent("undo-wt-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: wt) }
        let task = try await repo.createTaskWorktree(slug: "t", at: wt)
        try "agent\n".write(to: wt.appendingPathComponent("agent.txt"), atomically: true, encoding: .utf8)
        try await Repository.open(at: wt).commitAll(message: "Agent\n", author: me)
        try await repo.squashMerge(task.branch, message: "Land task", author: me, assistedBy: "m")
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("agent.txt").path))

        try await repo.undo()
        #expect(try cli("rev-parse", "HEAD") == base.id.hex)
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("agent.txt").path))
        #expect(try cli("status", "--porcelain") == "")
    }

    @Test func undoMergeRefusesToOverwriteLaterEdits() async throws {
        let repo = try Repository.create(at: dir)
        try write("a.txt", "1\n")
        try await repo.commitAll(message: "Base\n", author: me)
        let wt = dir.deletingLastPathComponent().appendingPathComponent("undo-wt-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: wt) }
        let task = try await repo.createTaskWorktree(slug: "t2", at: wt)
        try "agent\n".write(to: wt.appendingPathComponent("agent.txt"), atomically: true, encoding: .utf8)
        try await Repository.open(at: wt).commitAll(message: "Agent\n", author: me)
        try await repo.squashMerge(task.branch, message: "Land task", author: me, assistedBy: "m")
        try write("a.txt", "edited after the merge\n")

        await #expect(throws: UndoError.uncommittedChanges(count: 1)) { try await repo.undo() }
        #expect(try read("a.txt") == "edited after the merge\n")
    }

    @Test func refusesWhenSomethingChangedSince() async throws {
        let repo = try Repository.create(at: dir)
        try write("a.txt", "1\n")
        try await repo.commitAll(message: "Base\n", author: me)
        try await repo.createBranch("feature")
        try await repo.switchBranch(to: "feature")
        // A commit made outside Omnie-dev (CLI) after the switch.
        try write("b.txt", "b\n")
        try cli("add", "-A")
        try cli("commit", "--quiet", "-m", "CLI commit")
        try cli("checkout", "--quiet", "main")
        await #expect(throws: UndoError.changedSince) { try await repo.undo() }
    }

    @Test func refusesToUndoPushedCommits() async throws {
        let bare = dir.appendingPathComponent("forge.git")
        let work = dir.appendingPathComponent("work")
        try cli("init", "--quiet", "--bare", "-b", "main", bare.path)
        let repo = try Repository.create(at: work)
        try "1\n".write(to: work.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try await repo.commitAll(message: "Pushed\n", author: me)
        try await repo.addRemote(name: "origin", url: bare.path)
        try await repo.pushCurrentBranch(auth: RemoteAuth(credential: { _ in nil }, checkHostKey: { _ in .trusted }))
        try await repo.fetch(auth: RemoteAuth(credential: { _ in nil }, checkHostKey: { _ in .trusted }))

        await #expect(throws: UndoError.alreadyPushed) { try await repo.undo() }
        #expect(try await repo.head().commit != nil)
    }

    @Test func revertAddsAnInverseCommit() async throws {
        let repo = try Repository.create(at: dir)
        try write("a.txt", "1\n")
        try await repo.commitAll(message: "Base\n", author: me)
        try write("a.txt", "2\n")
        try write("b.txt", "b\n")
        let bad = try await repo.commitAll(message: "Bad change\n", author: me)
        try write("c.txt", "c\n")
        try await repo.commitAll(message: "Later\n", author: me)

        let revert = try await repo.revert(bad.id, author: me)
        #expect(revert.summary == "Revert “Bad change”")
        #expect(revert.message.contains("This reverts commit \(bad.id.hex)."))
        #expect(try read("a.txt") == "1\n")
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("b.txt").path))
        #expect(try read("c.txt") == "c\n")
        #expect(try cli("status", "--porcelain") == "")
        #expect(try cli("log", "--format=%s").split(separator: "\n").count == 4)
    }
}
