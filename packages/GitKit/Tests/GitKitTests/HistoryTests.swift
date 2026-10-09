// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing
@testable import GitKit

struct HistoryTests {
    let dir: URL
    let me = Signature(name: "Pad", email: "pad@example.com")

    init() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("history-\(UUID().uuidString)")
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

    /// Base, then A (a.txt), B (b.txt), C (a.txt again), D (d.txt).
    func fourCommits() async throws -> Repository {
        let repo = try Repository.create(at: dir)
        try write("base.txt", "base\n")
        try await repo.commitAll(message: "Base\n", author: me)
        try write("a.txt", "a1\n"); try await repo.commitAll(message: "A\n", author: me)
        try write("b.txt", "b\n"); try await repo.commitAll(message: "B\n", author: me)
        try write("a.txt", "a2\n"); try await repo.commitAll(message: "C fixes A\n", author: me)
        try write("d.txt", "d\n"); try await repo.commitAll(message: "D\n", author: me)
        return repo
    }

    @Test func reordersRewordsSquashesAndDrops() async throws {
        let repo = try await fourCommits()
        let (base, commits) = try #require(try await repo.editableHistory())
        #expect(commits.map(\.summary) == ["A", "B", "C fixes A", "D"])
        #expect(try await repo.commit(base).summary == "Base")
        let (a, b, c, d) = (commits[0].id, commits[1].id, commits[2].id, commits[3].id)
        let steps = [HistoryStep(a, .reword("A, reworded")), HistoryStep(c, .fixup), HistoryStep(d), HistoryStep(b, .drop)]

        // The preview changes nothing.
        let preview = try await repo.rewriteHistory(base: base, steps: steps, committer: me, apply: false)
        #expect(preview.map(\.summary) == ["A, reworded", "D"])
        #expect(try cli("log", "--format=%s").split(separator: "\n") == ["D", "C fixes A", "B", "A", "Base"])

        try write("scratch.txt", "untracked\n")
        let applied = try await repo.rewriteHistory(base: base, steps: steps, committer: me, apply: true)
        #expect(applied.map(\.summary) == ["A, reworded", "D"])
        #expect(try cli("log", "--format=%s").split(separator: "\n") == ["D", "A, reworded", "Base"])
        // The fixup brought C's change into A; B's file is gone with B; untracked files stay.
        #expect(try read("a.txt") == "a2\n")
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("b.txt").path))
        #expect(try read("scratch.txt") == "untracked\n")
        #expect(try cli("status", "--porcelain") == "?? scratch.txt")
        // Authors stay.
        #expect(try cli("log", "-1", "--format=%an", "HEAD~1") == "Pad")

        // One undo puts it all back.
        try FileManager.default.removeItem(at: dir.appendingPathComponent("scratch.txt"))
        let undone = try await repo.undo()
        #expect(undone.kind == .history)
        #expect(try cli("log", "--format=%s").split(separator: "\n") == ["D", "C fixes A", "B", "A", "Base"])
        #expect(try read("b.txt") == "b\n")
    }

    @Test func squashKeepsBothMessages() async throws {
        let repo = try await fourCommits()
        let (base, commits) = try #require(try await repo.editableHistory())
        let steps = commits.enumerated().map { HistoryStep($0.element.id, $0.offset == 2 ? .squash : .pick) }
        let result = try await repo.rewriteHistory(base: base, steps: steps, committer: me, apply: true)
        #expect(result.map(\.summary) == ["A", "B", "D"])
        #expect(result[1].message == "B\n\nC fixes A\n")
    }

    @Test func refusesWhatCantWork() async throws {
        let repo = try await fourCommits()
        let (base, commits) = try #require(try await repo.editableHistory())
        let (a, b, c, d) = (commits[0].id, commits[1].id, commits[2].id, commits[3].id)
        // C changes a line A wrote: before A it conflicts. Nothing changes.
        await #expect(throws: HistoryError.conflict(summary: "C fixes A", paths: ["a.txt"])) {
            try await repo.rewriteHistory(base: base, steps: [HistoryStep(c), HistoryStep(a), HistoryStep(b), HistoryStep(d)], committer: me, apply: true)
        }
        #expect(try cli("log", "--format=%s").split(separator: "\n") == ["D", "C fixes A", "B", "A", "Base"])
        await #expect(throws: HistoryError.nothingToJoin(summary: "A")) {
            try await repo.rewriteHistory(base: base, steps: [HistoryStep(a, .squash)], committer: me, apply: false)
        }
        try write("b.txt", "edited\n")
        await #expect(throws: HistoryError.uncommittedChanges(count: 1)) {
            try await repo.rewriteHistory(base: base, steps: [HistoryStep(a), HistoryStep(b)], committer: me, apply: true)
        }
    }
}
