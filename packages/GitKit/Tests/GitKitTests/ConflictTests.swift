// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing
@testable import GitKit

struct ConflictTests {
    let dir: URL
    let me = Signature(name: "Pad", email: "pad@example.com")

    init() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("conflict-\(UUID().uuidString)")
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

    /// main and "other" both edit line 2 of app.js; other also adds a file cleanly.
    func makeConflict() async throws -> (Repository, theirs: ObjectID) {
        let repo = try Repository.create(at: dir)
        try write("app.js", "one\ntwo\nthree\n")
        try write("keep.txt", "k\n")
        try await repo.commitAll(message: "Base\n", author: me)
        try await repo.createBranch("other")
        try write("app.js", "one\nTWO (yours)\nthree\n")
        try await repo.commitAll(message: "Yours\n", author: me)
        try cli("checkout", "--quiet", "other")
        try write("app.js", "one\nTWO (theirs)\nthree\n")
        try write("new.txt", "clean addition\n")
        try cli("add", "-A")
        try cli("commit", "--quiet", "-m", "Theirs")
        let theirs = try #require(ObjectID(hex: try cli("rev-parse", "HEAD")))
        try cli("checkout", "--quiet", "main")
        return (repo, theirs)
    }

    @Test func prepareListsConflictsWithAllSides() async throws {
        let (repo, theirs) = try await makeConflict()
        let session = try await repo.prepareMerge(with: theirs)
        #expect(session.conflicts.map(\.path) == ["app.js"])
        let c = try #require(session.conflicts.first)
        #expect(c.base == "one\ntwo\nthree\n")
        #expect(c.ours == "one\nTWO (yours)\nthree\n")
        #expect(c.theirs == "one\nTWO (theirs)\nthree\n")
        #expect(c.merged == "one\n<<<<<<< Yours\nTWO (yours)\n=======\nTWO (theirs)\n>>>>>>> Theirs\nthree\n")
        #expect(ConflictFile.hasMarkers(c.merged))
        #expect(!c.isBinary)
        // Preparing changes nothing on disk.
        #expect(try read("app.js") == "one\nTWO (yours)\nthree\n")
        #expect(try cli("status", "--porcelain") == "")
    }

    @Test func completeWritesMergeCommitWithResolution() async throws {
        let (repo, theirs) = try await makeConflict()
        let session = try await repo.prepareMerge(with: theirs)
        let resolved = "one\nTWO (both, reconciled)\nthree\n"
        let commit = try await repo.completeMerge(session, resolutions: ["app.js": resolved],
                                                  message: "Merge other", author: me, asMergeCommit: true)
        #expect(commit.parents == [session.ours, theirs])
        #expect(try read("app.js") == resolved)
        #expect(try read("new.txt") == "clean addition\n")  // the clean side came through
        #expect(try cli("status", "--porcelain") == "")
        #expect(try cli("show", "HEAD:app.js") == resolved.trimmingCharacters(in: .newlines))
        #expect(try cli("log", "-1", "--format=%p").split(separator: " ").count == 2)
    }

    @Test func squashStyleCompleteHasOneParent() async throws {
        let (repo, theirs) = try await makeConflict()
        let session = try await repo.prepareMerge(with: theirs)
        let commit = try await repo.completeMerge(session, resolutions: ["app.js": "one\nTWO\nthree\n"],
                                                  message: "Land task", author: me, asMergeCommit: false)
        #expect(commit.parents == [session.ours])
    }

    @Test func refusesUnresolvedAndMarkers() async throws {
        let (repo, theirs) = try await makeConflict()
        let session = try await repo.prepareMerge(with: theirs)
        await #expect(throws: ResolveError.unresolved(paths: ["app.js"])) {
            try await repo.completeMerge(session, resolutions: [:], message: "m", author: me, asMergeCommit: true)
        }
        await #expect(throws: ResolveError.stillHasMarkers(path: "app.js")) {
            try await repo.completeMerge(session, resolutions: ["app.js": session.conflicts[0].merged],
                                         message: "m", author: me, asMergeCommit: true)
        }
        #expect(try read("app.js") == "one\nTWO (yours)\nthree\n")
    }

    @Test func refusesStaleSession() async throws {
        let (repo, theirs) = try await makeConflict()
        let session = try await repo.prepareMerge(with: theirs)
        try write("keep.txt", "moved on\n")
        try await repo.commitAll(message: "Later\n", author: me)
        await #expect(throws: ResolveError.stale) {
            try await repo.completeMerge(session, resolutions: ["app.js": "x\n"], message: "m", author: me, asMergeCommit: true)
        }
    }

    @Test func resolvingKeepsCleanlyMergedParts() {
        let merged = "top (theirs, clean)\n<<<<<<< Yours\nmine\n=======\ntheirs\n>>>>>>> Theirs\nmiddle\n<<<<<<< Yours\nm2\n=======\nt2\n>>>>>>> Theirs\nend\n"
        #expect(ConflictFile.resolving(merged, to: .ours) == "top (theirs, clean)\nmine\nmiddle\nm2\nend\n")
        #expect(ConflictFile.resolving(merged, to: .theirs) == "top (theirs, clean)\ntheirs\nmiddle\nt2\nend\n")
        #expect(ConflictFile.resolving(merged, to: .both) == "top (theirs, clean)\nmine\ntheirs\nmiddle\nm2\nt2\nend\n")
        #expect(!ConflictFile.hasMarkers(ConflictFile.resolving(merged, to: .both)))
    }

    @Test func noConflictsMeansEmptySession() async throws {
        let repo = try Repository.create(at: dir)
        try write("a.txt", "a\n")
        try await repo.commitAll(message: "Base\n", author: me)
        try await repo.createBranch("other")
        try cli("checkout", "--quiet", "other")
        try write("b.txt", "b\n")
        try cli("add", "-A")
        try cli("commit", "--quiet", "-m", "B")
        let theirs = try #require(ObjectID(hex: try cli("rev-parse", "HEAD")))
        try cli("checkout", "--quiet", "main")
        let session = try await repo.prepareMerge(with: theirs)
        #expect(session.conflicts.isEmpty)
    }
}
