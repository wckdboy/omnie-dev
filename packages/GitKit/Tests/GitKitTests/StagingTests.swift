// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing
@testable import GitKit

struct StagingApplyTests {
    let base = "a\nb\nc\nd\ne\n"
    let target = "a\nB\nc\nd\nd2\ne\nf\n"

    func refs(_ diff: FileDiff, where keep: (String) -> Bool) -> Set<Staging.LineRef> {
        var refs: Set<Staging.LineRef> = []
        for hunk in diff.hunks { for (i, l) in hunk.lines.enumerated() where (l.hasPrefix("+") || l.hasPrefix("-")) && keep(l) { refs.insert(.init(hunk: hunk.index, line: i)) } }
        return refs
    }

    @Test func allOrNothing() {
        let diff = FileDiff.texts(base, target)
        #expect(Staging.apply(base: base, target: target, selected: Staging.allChanges(diff)) == target)
        #expect(Staging.apply(base: base, target: target, selected: []) == base)
    }

    @Test func someLines() {
        let diff = FileDiff.texts(base, target)
        // Only the b → B change.
        #expect(Staging.apply(base: base, target: target, selected: refs(diff) { $0 == "-b" || $0 == "+B" }) == "a\nB\nc\nd\ne\n")
        // Only the added d2 and f.
        #expect(Staging.apply(base: base, target: target, selected: refs(diff) { $0 == "+d2" || $0 == "+f" }) == "a\nb\nc\nd\nd2\ne\nf\n")
        // Only the removal of b (without adding B).
        #expect(Staging.apply(base: base, target: target, selected: refs(diff) { $0 == "-b" }) == "a\nc\nd\ne\n")
    }

    @Test func endOfFileAndEmptyFiles() {
        // A newline added at the end only comes with the last line's change.
        let noNewline = "x\ny"
        let withMore = "x\ny\nz\n"
        let diff = FileDiff.texts(noNewline, withMore)
        #expect(Staging.apply(base: noNewline, target: withMore, selected: Staging.allChanges(diff)) == withMore)
        #expect(Staging.apply(base: noNewline, target: withMore, selected: []) == noNewline)
        // A new file, part of it.
        let newFile = "one\ntwo\n"
        let d2 = FileDiff.texts("", newFile)
        #expect(Staging.apply(base: "", target: newFile, selected: refs(d2) { $0 == "+one" }) == "one\n")
        #expect(Staging.apply(base: "", target: newFile, selected: Staging.allChanges(d2)) == newFile)
    }
}

struct StagingRepoTests {
    let dir: URL
    let me = Signature(name: "Pad", email: "pad@example.com")

    init() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("staging-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    @discardableResult
    func cli(_ args: String...) throws -> String { try SSHTests.git(args, in: dir) }

    func write(_ path: String, _ text: String) throws {
        try text.write(to: dir.appendingPathComponent(path), atomically: true, encoding: .utf8)
    }

    @Test func stageLinesCommitTheIndexAndUnstage() async throws {
        let repo = try Repository.create(at: dir)
        try write("a.txt", "one\ntwo\nthree\n")
        try write("keep.txt", "k\n")
        try await repo.commitAll(message: "Start\n", author: me)
        try write("a.txt", "ONE\ntwo\nthree\nfour\n")
        try write("keep.txt", "k2\n")
        try write("new.txt", "fresh\n")

        let status = try await repo.stagingStatus()
        #expect(Set(status.map(\.path)) == ["a.txt", "keep.txt", "new.txt"])
        #expect(status.allSatisfy { $0.staged == nil })

        // Stage only "four" in a.txt, and all of new.txt.
        let aDiff = try #require(status.first { $0.path == "a.txt" }?.unstaged)
        let four = Staging.allChanges(aDiff).filter { ref in aDiff.hunks[ref.hunk].lines[ref.line] == "+four" }
        try await repo.stage("a.txt", lines: four)
        try await repo.stage("new.txt")
        #expect(try cli("diff", "--cached", "--name-only").split(separator: "\n") == ["a.txt", "new.txt"])
        #expect(try cli("show", ":a.txt") == "one\ntwo\nthree\nfour")
        #expect(try cli("diff", "--name-only").split(separator: "\n") == ["a.txt", "keep.txt"])

        // Unstage new.txt again, then commit the index: only "four".
        try await repo.unstage("new.txt")
        #expect(try cli("diff", "--cached", "--name-only") == "a.txt")
        let commit = try await repo.commitIndex(message: "Add four\n", author: me)
        #expect(try cli("show", "--format=", "--name-only", commit.id.hex) == "a.txt")
        #expect(try cli("show", "HEAD:a.txt") == "one\ntwo\nthree\nfour")
        // The rest is still there, unstaged; the folder didn't change.
        #expect(try String(contentsOf: dir.appendingPathComponent("a.txt"), encoding: .utf8) == "ONE\ntwo\nthree\nfour\n")
        // (The CLI helper trims the output, so compare trimmed lines.)
        #expect(Set(try cli("status", "--porcelain").split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }) == ["M a.txt", "M keep.txt", "?? new.txt"])

        await #expect(throws: StagingError.nothingStaged) { try await repo.commitIndex(message: "Empty\n", author: me) }
        // Undo the commit like any other.
        #expect(try await repo.undo().title == "Commit “Add four”")
    }

    @Test func partialUnstageAndDeletions() async throws {
        let repo = try Repository.create(at: dir)
        try write("a.txt", "1\n2\n3\n")
        try write("gone.txt", "bye\n")
        try await repo.commitAll(message: "Start\n", author: me)
        try write("a.txt", "1a\n2\n3a\n")
        try FileManager.default.removeItem(at: dir.appendingPathComponent("gone.txt"))
        try await repo.stage("a.txt")
        try await repo.stage("gone.txt")
        #expect(try cli("diff", "--cached", "--name-status").split(separator: "\n") == ["M\ta.txt", "D\tgone.txt"])
        // Checkpoints (taken on every save) leave what's staged alone.
        try await repo.checkpoint(.save)
        #expect(try cli("diff", "--cached", "--name-status").split(separator: "\n") == ["M\ta.txt", "D\tgone.txt"])
        // Take the first line's change back out of the index.
        let staged = try #require(try await repo.stagingStatus().first { $0.path == "a.txt" }?.staged)
        let first = Staging.allChanges(staged).filter { staged.hunks[$0.hunk].lines[$0.line].hasSuffix("1a") || staged.hunks[$0.hunk].lines[$0.line] == "-1" }
        try await repo.unstage("a.txt", lines: first)
        #expect(try cli("show", ":a.txt") == "1\n2\n3a")
    }
}
