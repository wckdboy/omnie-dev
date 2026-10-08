// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing
@testable import GitKit

/// Sync against a local bare "forge", with the git CLI playing a collaborator on another machine.
struct SyncTests {
    let root: URL
    let me = Signature(name: "Pad", email: "pad@example.com")
    let auth = RemoteAuth(credential: { _ in nil }, checkHostKey: { _ in .trusted })

    var bare: URL { root.appendingPathComponent("forge.git") }
    var mine: URL { root.appendingPathComponent("mine") }
    var theirs: URL { root.appendingPathComponent("theirs") }

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("sync-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try cli(["init", "--quiet", "--bare", "-b", "main", bare.path], in: root)
        let seed = root.appendingPathComponent("seed")
        try cli(["init", "--quiet", "-b", "main", seed.path], in: root)
        try write(seed, "shared.txt", "line 1\nline 2\nline 3\n")
        try cli(["add", "-A"], in: seed)
        try cli(["commit", "--quiet", "-m", "Seed"], in: seed)
        try cli(["push", "--quiet", bare.path, "main"], in: seed)
        try cli(["clone", "--quiet", bare.path, theirs.path], in: root)
    }

    @discardableResult
    func cli(_ args: [String], in dir: URL) throws -> String {
        try SSHTests.git(args, in: dir)
    }

    func write(_ dir: URL, _ path: String, _ text: String) throws {
        try text.write(to: dir.appendingPathComponent(path), atomically: true, encoding: .utf8)
    }

    func read(_ dir: URL, _ path: String) throws -> String {
        try String(contentsOf: dir.appendingPathComponent(path), encoding: .utf8)
    }

    /// The collaborator commits and pushes.
    func theyCommit(_ path: String, _ text: String, _ message: String) throws {
        try write(theirs, path, text)
        try cli(["add", "-A"], in: theirs)
        try cli(["commit", "--quiet", "-m", message], in: theirs)
        try cli(["push", "--quiet", "origin", "main"], in: theirs)
    }

    func cloneMine() async throws -> Repository {
        try await Repository.clone(from: bare.path, to: mine, auth: auth)
    }

    func forgeLog() throws -> [String] {
        try cli(["--git-dir", bare.path, "log", "--format=%s", "main"], in: root).split(separator: "\n").map(String.init)
    }

    // MARK: Sync

    @Test func upToDate() async throws {
        let repo = try await cloneMine()
        let result = try await repo.sync(auth: auth, committer: me)
        #expect(result == SyncResult(integration: .upToDate, pulled: 0, pushed: 0))
        #expect(result.summary == "Synced: up to date")
    }

    @Test func pushOnlyAndFirstPushOfNewBranchSetsUpstream() async throws {
        let repo = try await cloneMine()
        try write(mine, "a.txt", "a\n")
        try await repo.commitAll(message: "Add a\n", author: me)
        #expect(try await repo.sync(auth: auth, committer: me).summary == "Synced: pushed 1")
        #expect(try forgeLog() == ["Add a", "Seed"])

        try cli(["checkout", "--quiet", "-b", "feature"], in: mine)
        try write(mine, "b.txt", "b\n")
        try await repo.commitAll(message: "Add b\n", author: me)
        let result = try await repo.sync(auth: auth, committer: me)
        #expect(result.pushed == 1)  // only "Add b" is new to the forge
        #expect(try cli(["rev-parse", "--abbrev-ref", "feature@{upstream}"], in: mine) == "origin/feature")
        #expect(try await repo.status().ahead == 0)
    }

    @Test func fastForwardKeepsUncommittedEditsToOtherFiles() async throws {
        let repo = try await cloneMine()
        try theyCommit("theirs.txt", "from them\n", "Their change")
        try write(mine, "notes.md", "my draft\n")  // untracked, unrelated

        let result = try await repo.sync(auth: auth, committer: me)
        #expect(result == SyncResult(integration: .fastForwarded(commits: 1), pulled: 1, pushed: 0))
        #expect(try read(mine, "theirs.txt") == "from them\n")
        #expect(try read(mine, "notes.md") == "my draft\n")
        #expect(try cli(["rev-parse", "HEAD"], in: mine) == cli(["rev-parse", "origin/main"], in: mine))
        #expect(try cli(["status", "--porcelain"], in: mine) == "?? notes.md")
    }

    @Test func fastForwardRefusesToOverwriteLocalEdits() async throws {
        let repo = try await cloneMine()
        try theyCommit("shared.txt", "line 1\nTHEIRS\nline 3\n", "Their edit")
        try write(mine, "shared.txt", "line 1\nMINE, unsaved\nline 3\n")
        let before = try await repo.head().commit

        await #expect(throws: SyncError.localChangesBlock(paths: ["shared.txt"])) {
            try await repo.sync(auth: auth, committer: me)
        }
        #expect(try read(mine, "shared.txt") == "line 1\nMINE, unsaved\nline 3\n")
        #expect(try await repo.head().commit == before)
    }

    @Test func divergedBranchesAreRebasedIntoLinearHistory() async throws {
        let repo = try await cloneMine()
        try theyCommit("theirs.txt", "t\n", "Their change")
        try write(mine, "mine.txt", "m\n")
        try await repo.commitAll(message: "My change\n", author: me)

        let result = try await repo.sync(auth: auth, committer: me)
        #expect(result == SyncResult(integration: .rebased(commits: 1), pulled: 1, pushed: 1))
        #expect(result.summary == "Synced: pushed 1, pulled 1 (rebased)")
        #expect(try forgeLog() == ["My change", "Their change", "Seed"])
        // Linear: no merge commits.
        #expect(try cli(["--git-dir", bare.path, "rev-list", "--merges", "main"], in: root) == "")
        #expect(try read(mine, "theirs.txt") == "t\n")
        #expect(try await repo.log().first?.authorName == "Pad")
    }

    @Test func rebaseConflictAbortsAndLeavesBranchAsItWas() async throws {
        let repo = try await cloneMine()
        try theyCommit("shared.txt", "line 1\nTHEIRS\nline 3\n", "Their edit")
        try write(mine, "shared.txt", "line 1\nMINE\nline 3\n")
        let mineCommit = try await repo.commitAll(message: "My edit\n", author: me)

        await #expect(throws: SyncError.conflicts(paths: ["shared.txt"])) {
            try await repo.sync(auth: auth, committer: me)
        }
        #expect(try await repo.head().commit == mineCommit.id)
        #expect(try await repo.head().branch == "main")
        #expect(try read(mine, "shared.txt") == "line 1\nMINE\nline 3\n")
        #expect(try cli(["status", "--porcelain"], in: mine) == "")
        #expect(!FileManager.default.fileExists(atPath: mine.appendingPathComponent(".git/rebase-merge").path))
        #expect(try forgeLog() == ["Their edit", "Seed"])
    }

    @Test func rebaseNeedsCommittedWork() async throws {
        let repo = try await cloneMine()
        try theyCommit("theirs.txt", "t\n", "Their change")
        try write(mine, "mine.txt", "m\n")
        try await repo.commitAll(message: "My change\n", author: me)
        try write(mine, "shared.txt", "edited but not committed\n")

        await #expect(throws: SyncError.uncommittedChanges(count: 1)) {
            try await repo.sync(auth: auth, committer: me)
        }
        #expect(try read(mine, "shared.txt") == "edited but not committed\n")
    }

    @Test func noRemote() async throws {
        let repo = try Repository.create(at: mine)
        try write(mine, "a.txt", "a\n")
        try await repo.commitAll(message: "a", author: me)
        await #expect(throws: SyncError.noRemote) { try await repo.sync(auth: auth, committer: me) }
    }

    // MARK: Push queue

    @Test func queuedPushFlushesWhenUnchanged() async throws {
        let repo = try await cloneMine()
        try write(mine, "a.txt", "a\n")
        try await repo.commitAll(message: "Offline commit\n", author: me)
        let intent = try await repo.makePushIntent()

        #expect(try await repo.flush(intent, auth: auth) == .pushed)
        #expect(try forgeLog().first == "Offline commit")
    }

    @Test func queuedPushNeedsYouIfBranchMoved() async throws {
        let repo = try await cloneMine()
        try write(mine, "a.txt", "a\n")
        try await repo.commitAll(message: "Authorized\n", author: me)
        let intent = try await repo.makePushIntent()
        try write(mine, "b.txt", "b\n")
        try await repo.commitAll(message: "Not authorized\n", author: me)

        #expect(try await repo.flush(intent, auth: auth) == .needsYou(reason: "main changed after the push was queued"))
        #expect(try forgeLog() == ["Seed"])
    }

    @Test func queuedPushExpiresAfter24Hours() async throws {
        let repo = try await cloneMine()
        try write(mine, "a.txt", "a\n")
        try await repo.commitAll(message: "Old\n", author: me)
        let intent = try await repo.makePushIntent(now: Date(timeIntervalSinceNow: -25 * 3600))
        #expect(try await repo.flush(intent, auth: auth) == .needsYou(reason: "Authorization expired after 24 h"))
    }

    @Test func queuedPushRejectedWhenRemoteMovedOn() async throws {
        let repo = try await cloneMine()
        try write(mine, "a.txt", "a\n")
        try await repo.commitAll(message: "Mine\n", author: me)
        let intent = try await repo.makePushIntent()
        try theyCommit("t.txt", "t\n", "Theirs")

        #expect(try await repo.flush(intent, auth: auth) == .needsYou(reason: "Remote rejected the push: non-fast-forward"))
        #expect(try forgeLog() == ["Theirs", "Seed"])
    }
}
