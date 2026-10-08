// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing
@testable import GitKit

struct BranchTests {
    let dir: URL
    let me = Signature(name: "Pad", email: "pad@example.com")

    init() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("branch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    @discardableResult
    func cli(_ args: String...) throws -> String { try SSHTests.git(args, in: dir) }

    func write(_ path: String, _ text: String, in root: URL? = nil) throws {
        let url = (root ?? dir).appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    func read(_ path: String, in root: URL? = nil) throws -> String {
        try String(contentsOf: (root ?? dir).appendingPathComponent(path), encoding: .utf8)
    }

    func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: dir.appendingPathComponent(path).path) }

    func makeRepo() async throws -> Repository {
        let repo = try Repository.create(at: dir)
        try write("app.js", "one\ntwo\nthree\n")
        try write("README.md", "readme\n")
        try await repo.commitAll(message: "Base\n", author: me)
        return repo
    }

    // MARK: Branches

    @Test func createListAndDelete() async throws {
        let repo = try await makeRepo()
        try await repo.createBranch("feature")
        let names = try await repo.branches().map(\.name)
        #expect(names == ["main", "feature"])  // current first
        #expect(try cli("branch", "--format=%(refname:short)").split(separator: "\n").sorted() == ["feature", "main"])
        await #expect(throws: BranchError.alreadyExists("feature")) { try await repo.createBranch("feature") }
        await #expect(throws: BranchError.isCurrent("main")) { try await repo.deleteBranch("main") }
        try await repo.deleteBranch("feature")
        #expect(try await repo.branches().map(\.name) == ["main"])
    }

    @Test func switchCarriesWorkInProgressAndRestoresIt() async throws {
        let repo = try await makeRepo()
        try await repo.createBranch("feature")

        // Uncommitted work on main: a modification and a new file.
        try write("app.js", "one\nTWO (main draft)\nthree\n")
        try write("notes.md", "main notes\n")

        try await repo.switchBranch(to: "feature")
        #expect(try cli("symbolic-ref", "--short", "HEAD") == "feature")
        #expect(try read("app.js") == "one\ntwo\nthree\n")
        #expect(!exists("notes.md"))
        #expect(try cli("status", "--porcelain") == "")
        #expect(try cli("rev-parse", "--verify", "--quiet", "refs/wip/main").count == 40)
        #expect(try await repo.branches().first { $0.name == "main" }?.hasWorkInProgress == true)

        // Work on feature, uncommitted too.
        try write("README.md", "readme (feature draft)\n")

        try await repo.switchBranch(to: "main")
        #expect(try read("app.js") == "one\nTWO (main draft)\nthree\n")
        #expect(try read("notes.md") == "main notes\n")
        #expect(try read("README.md") == "readme\n")
        // Restored as unstaged changes; nothing staged.
        #expect(try cli("diff", "--cached", "--name-only") == "")
        let porcelain = Set(try cli("status", "--porcelain").split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) })
        #expect(porcelain == ["M app.js", "?? notes.md"])  // unstaged modification + untracked
        #expect((try? cli("rev-parse", "--verify", "--quiet", "refs/wip/main")) == nil)

        try await repo.switchBranch(to: "feature")
        #expect(try read("README.md") == "readme (feature draft)\n")
    }

    @Test func savedWorkReappliesAfterTheBranchMovedOn() async throws {
        let repo = try await makeRepo()
        try await repo.createBranch("feature")
        try write("app.js", "one\ntwo\nthree\nfour (draft)\n")
        try await repo.switchBranch(to: "feature")

        // main moves on (e.g. a Sync) while we're away, in a different file.
        try cli("update-ref", "refs/heads/main", try cli("commit-tree", "-p", "main", "-m", "Upstream",
            try cli("rev-parse", "main^{tree}")))
        try await repo.switchBranch(to: "main")
        #expect(try read("app.js") == "one\ntwo\nthree\nfour (draft)\n")
        #expect(try cli("log", "-1", "--format=%s") == "Upstream")
    }

    @Test func cleanSwitchLeavesNoWipRef() async throws {
        let repo = try await makeRepo()
        try await repo.createBranch("feature")
        try await repo.switchBranch(to: "feature")
        #expect((try? cli("rev-parse", "--verify", "--quiet", "refs/wip/main")) == nil)
    }

    // MARK: Agent task worktrees

    @Test func taskWorktreeIsolatesAgentWorkAndSquashMerges() async throws {
        let repo = try await makeRepo()
        let path = dir.deletingLastPathComponent().appendingPathComponent("wt-\(UUID().uuidString)/fix-auth")
        defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }

        let task = try await repo.createTaskWorktree(slug: "fix-auth", at: path)
        #expect(task.branch == "agent/fix-auth")
        #expect(try cli("worktree", "list", "--porcelain").contains("branch refs/heads/agent/fix-auth"))
        let listed = try await repo.taskWorktrees()
        #expect(listed == [task])

        // The agent works in its worktree, in two steps.
        let agentRepo = try Repository.open(at: path)
        try write("auth.js", "check(token)\n", in: path)
        try await agentRepo.commitAll(message: "Add auth check\n", author: me)
        try write("app.js", "one\ntwo\nthree\nauth()\n", in: path)
        try await agentRepo.commitAll(message: "Call auth\n", author: me)

        // Meanwhile you keep typing in your own folder: untouched by the agent.
        try write("README.md", "readme, edited by you\n")
        #expect(!exists("auth.js"))
        try await repo.commitAll(message: "Edit readme\n", author: me)

        let merged = try await repo.squashMerge("agent/fix-auth", message: "Fix auth", author: me,
                                                assistedBy: "qwen2.5-coder-7b-4bit")
        #expect(merged.parents.count == 1)
        #expect(merged.assistedBy == "qwen2.5-coder-7b-4bit")
        #expect(try cli("log", "--format=%s").split(separator: "\n") == ["Fix auth", "Edit readme", "Base"])
        #expect(try read("auth.js") == "check(token)\n")
        #expect(try read("app.js") == "one\ntwo\nthree\nauth()\n")
        #expect(try read("README.md") == "readme, edited by you\n")
        #expect(try cli("status", "--porcelain") == "")

        try await repo.removeTaskWorktree(task, deleteBranch: true)
        #expect(!FileManager.default.fileExists(atPath: path.path))
        #expect(try await repo.taskWorktrees().isEmpty)
        #expect(!(try cli("branch")).contains("agent/fix-auth"))
    }

    @Test func conflictingTaskDoesNotMerge() async throws {
        let repo = try await makeRepo()
        let path = dir.deletingLastPathComponent().appendingPathComponent("wt-\(UUID().uuidString)/rename")
        defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        let task = try await repo.createTaskWorktree(slug: "rename", at: path)

        let agentRepo = try Repository.open(at: path)
        try write("app.js", "one\nAGENT\nthree\n", in: path)
        try await agentRepo.commitAll(message: "Agent edit\n", author: me)
        try write("app.js", "one\nYOU\nthree\n")
        let mine = try await repo.commitAll(message: "My edit\n", author: me)

        await #expect(throws: MergeError.conflicts(paths: ["app.js"])) {
            try await repo.squashMerge(task.branch, message: "Rename", author: me, assistedBy: "m")
        }
        #expect(try await repo.head().commit == mine.id)
        #expect(try read("app.js") == "one\nYOU\nthree\n")
        #expect(try cli("status", "--porcelain") == "")
    }

    @Test func squashMergeNeedsCommittedWork() async throws {
        let repo = try await makeRepo()
        let path = dir.deletingLastPathComponent().appendingPathComponent("wt-\(UUID().uuidString)/t")
        defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        let task = try await repo.createTaskWorktree(slug: "t", at: path)
        try write("x.txt", "x\n", in: path)
        try await Repository.open(at: path).commitAll(message: "x\n", author: me)
        try write("README.md", "dirty\n")
        await #expect(throws: MergeError.uncommittedChanges(count: 1)) {
            try await repo.squashMerge(task.branch, message: "t", author: me, assistedBy: nil)
        }
    }
}
