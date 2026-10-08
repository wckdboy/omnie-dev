// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing
@testable import GitKit

/// Differential tests: every GitKit operation is checked against the real `git` CLI (PLAN.md §21).
struct GitKitTests {
    let dir: URL
    let me = Signature(name: "Test User", email: "test@example.com")

    init() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("gitkit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    // MARK: Helpers

    @discardableResult
    func git(_ args: String..., env: [String: String] = [:]) throws -> String {
        let p = Process()
        p.executableURL = URL(filePath: "/usr/bin/git")
        p.arguments = ["-c", "user.name=CLI", "-c", "user.email=cli@example.com", "-c", "core.autocrlf=false"] + args
        p.currentDirectoryURL = dir
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        environment["GIT_CONFIG_NOSYSTEM"] = "1"
        environment.merge(env) { $1 }
        p.environment = environment
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        try p.run()
        p.waitUntilExit()
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        guard p.terminationStatus == 0 else {
            let e = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw CLIError(message: "git \(args.joined(separator: " ")): \(e)")
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    struct CLIError: Error { let message: String }

    func write(_ path: String, _ text: String) throws {
        let url = dir.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    func read(_ path: String) throws -> String {
        try String(contentsOf: dir.appendingPathComponent(path), encoding: .utf8)
    }

    func exists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: dir.appendingPathComponent(path).path)
    }

    /// The tree `git add -A` would produce, computed with a throwaway index so the real one is untouched.
    func cliWorktreeTree() throws -> String {
        let tmpIndex = dir.appendingPathComponent(".git/tmp-index-\(UUID().uuidString)").path
        if exists(".git/index") { try FileManager.default.copyItem(atPath: dir.appendingPathComponent(".git/index").path, toPath: tmpIndex) }
        defer { try? FileManager.default.removeItem(atPath: tmpIndex) }
        try git("add", "-A", env: ["GIT_INDEX_FILE": tmpIndex])
        return try git("write-tree", env: ["GIT_INDEX_FILE": tmpIndex])
    }

    func indexData() throws -> Data? {
        try? Data(contentsOf: dir.appendingPathComponent(".git/index"))
    }

    // MARK: Tests

    @Test func createOnUnbornMainAndCommitMatchesCLI() async throws {
        let repo = try Repository.create(at: dir)
        let head = try await repo.head()
        #expect(head.branch == "main")
        #expect(head.isUnborn)
        #expect(try git("symbolic-ref", "HEAD") == "refs/heads/main")

        try write("README.md", "# Hello\n")
        try write("src/app.js", "console.log(1)\n")
        let c = try await repo.commitAll(message: "Add readme and app\n", author: me)

        #expect(try git("rev-parse", "HEAD") == c.id.hex)
        #expect(try git("rev-parse", "HEAD^{tree}") == c.tree.hex)
        #expect(try git("log", "-1", "--format=%an <%ae>|%s") == "Test User <test@example.com>|Add readme and app")
        #expect(try git("status", "--porcelain") == "")
    }

    @Test func commitAllWithNothingChangedThrows() async throws {
        let repo = try Repository.create(at: dir)
        try write("a.txt", "a\n")
        try await repo.commitAll(message: "a", author: me)
        await #expect(throws: GitKitError.nothingToCommit) { try await repo.commitAll(message: "again", author: me) }
    }

    @Test func commitAllIncludesDeletionsAndRespectsGitignore() async throws {
        let repo = try Repository.create(at: dir)
        try write(".gitignore", "secret.env\n")
        try write("keep.txt", "k\n")
        try write("gone.txt", "g\n")
        try await repo.commitAll(message: "one", author: me)
        try FileManager.default.removeItem(at: dir.appendingPathComponent("gone.txt"))
        try write("secret.env", "TOKEN=x\n")
        try await repo.commitAll(message: "two", author: me)
        #expect(try git("ls-tree", "--name-only", "HEAD").split(separator: "\n") == [".gitignore", "keep.txt"])
    }

    @Test func checkpointMatchesCLITreeAndLeavesIndexAlone() async throws {
        let repo = try Repository.create(at: dir)
        try write("a.txt", "one\n")
        try write("b.txt", "bee\n")
        try await repo.commitAll(message: "base", author: me)

        // A mix of states: staged change, unstaged change, untracked file, deletion.
        try write("a.txt", "two\n")
        try git("add", "a.txt")
        try write("a.txt", "three\n")
        try write("new/untracked.txt", "u\n")
        try FileManager.default.removeItem(at: dir.appendingPathComponent("b.txt"))

        let indexBefore = try indexData()
        let stagedBefore = try git("diff", "--cached", "--name-status")
        let expectedTree = try cliWorktreeTree()

        let cp = try #require(try await repo.checkpoint(.save))

        #expect(cp.tree.hex == expectedTree)
        #expect(try indexData() == indexBefore)
        #expect(try git("diff", "--cached", "--name-status") == stagedBefore)
        #expect(try read("a.txt") == "three\n")
        #expect(try git("rev-parse", "refs/checkpoints/main") == cp.id.hex)
        // Hidden ref: not a branch, not in the default log.
        #expect(try git("branch", "--list").contains("checkpoint") == false)
        #expect(try git("log", "--format=%s").contains("checkpoint") == false)
    }

    @Test func checkpointSkipsWhenNothingChangedAndChainsOtherwise() async throws {
        let repo = try Repository.create(at: dir)
        try write("a.txt", "1\n")
        let base = try await repo.commitAll(message: "base", author: me)

        #expect(try await repo.checkpoint(.save) == nil)

        try write("a.txt", "2\n")
        let first = try #require(try await repo.checkpoint(.save))
        #expect(try await repo.checkpoint(.interval) == nil)

        try write("a.txt", "3\n")
        let second = try #require(try await repo.checkpoint(.run))
        #expect(try git("rev-parse", "\(second.id.hex)^") == first.id.hex)
        #expect(try git("rev-parse", "\(first.id.hex)^") == base.id.hex)
        #expect(try await repo.checkpointsSinceHead().map(\.id) == [second.id, first.id])
        #expect(try await repo.checkpointsSinceHead().map(\.reason) == [.run, .save])
    }

    @Test func commitStartsANewCheckpointChain() async throws {
        let repo = try Repository.create(at: dir)
        try write("a.txt", "1\n")
        try await repo.commitAll(message: "base", author: me)
        try write("a.txt", "2\n")
        try await repo.checkpoint(.save)
        let c = try await repo.commitAll(message: "two", author: me)
        #expect(try await repo.checkpointsSinceHead().isEmpty)

        try write("a.txt", "3\n")
        let cp = try #require(try await repo.checkpoint(.save))
        #expect(cp.base == c.id)
        #expect(try git("rev-parse", "\(cp.id.hex)^") == c.id.hex)
    }

    @Test func checkpointOnUnbornBranch() async throws {
        let repo = try Repository.create(at: dir)
        #expect(try await repo.checkpoint(.save) == nil)
        try write("draft.md", "first words\n")
        let cp = try #require(try await repo.checkpoint(.save))
        #expect(cp.base == nil)
        #expect(cp.tree.hex == (try cliWorktreeTree()))
        #expect(try await repo.head().isUnborn)
    }

    @Test func restoreBringsBackFilesAndIsUndoable() async throws {
        let repo = try Repository.create(at: dir)
        try write("a.txt", "base\n")
        try await repo.commitAll(message: "base", author: me)

        try write("a.txt", "good\n")
        let good = try #require(try await repo.checkpoint(.save))

        try write("a.txt", "broken\n")
        try write("junk.txt", "junk\n")
        try await repo.restore(good)

        #expect(try read("a.txt") == "good\n")
        #expect(!exists("junk.txt"))
        #expect(try git("diff", "--cached", "--name-only") == "")

        // The state before the restore was checkpointed, so restoring is reversible.
        let history = try await repo.checkpointsSinceHead()
        #expect(history.first?.reason == .restore)
        try await repo.restore(try #require(history.first))
        #expect(try read("a.txt") == "broken\n")
        #expect(try read("junk.txt") == "junk\n")
    }

    @Test func statusMatchesCLIAndReportsAheadBehind() async throws {
        let repo = try Repository.create(at: dir)
        try write("a.txt", "1\n")
        try write("b.txt", "1\n")
        try await repo.commitAll(message: "one", author: me)
        try write("a.txt", "2\n")
        try await repo.commitAll(message: "two", author: me)

        // Fake an upstream one commit behind.
        try git("remote", "add", "origin", "https://example.invalid/repo.git")
        try git("update-ref", "refs/remotes/origin/main", "HEAD~1")
        try git("branch", "--set-upstream-to=origin/main", "main")

        try write("b.txt", "changed\n")
        try write("c.txt", "new\n")
        let status = try await repo.status()
        #expect(status.ahead == 1)
        #expect(status.behind == 0)
        #expect(status.changedCount == (try git("status", "--porcelain").split(separator: "\n").count))
        #expect(Set(status.entries.map(\.kind)) == [.modified, .untracked])
        #expect(status.plainLanguage == "main · 2 changed · ↑1")
    }

    @Test func detachedHeadStatusLine() async throws {
        let repo = try Repository.create(at: dir)
        try write("a.txt", "1\n")
        let c = try await repo.commitAll(message: "one", author: me)
        try git("checkout", "--quiet", "--detach")
        let status = try await repo.status()
        #expect(status.head.isDetached)
        #expect(status.plainLanguage == "Detached at \(c.id.short)")
        #expect(try await repo.checkpointRef() == "refs/checkpoints/detached")
    }

    @Test func logReadsCLICommitsAndAgentTrailer() async throws {
        let repo = try Repository.create(at: dir)
        try write("a.txt", "1\n")
        try git("add", "-A")
        try git("commit", "--quiet", "-m", "Human change", "--date=2020-01-02T03:04:05Z")
        try write("a.txt", "2\n")
        try await repo.commitAll(message: "Add orbit controls\n\nWhy: the scene needs it.\n\nAssisted-by: qwen2.5-coder-7b-4bit\n", author: me)

        let log = try await repo.log()
        #expect(log.map(\.summary) == ["Add orbit controls", "Human change"])
        #expect(log[0].assistedBy == "qwen2.5-coder-7b-4bit")
        #expect(log[1].assistedBy == nil)
        #expect(log[1].authorName == "CLI")
        #expect(log[1].date == Date(timeIntervalSince1970: 1_577_934_245))
        #expect(try git("log", "--format=%H").split(separator: "\n").map(String.init) == log.map(\.id.hex))
    }
}
