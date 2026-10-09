// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing
@testable import GitKit

struct MigrationTests {
    let root: URL
    let me = Signature(name: "Pad", email: "pad@example.com")
    let auth = RemoteAuth(credential: { _ in nil }, checkHostKey: { _ in .trusted })

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("migrate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func git(_ args: String..., in dir: URL? = nil) throws -> String { try SSHTests.git(args, in: dir ?? root) }

    @Test func movesBranchesTagsAndUpstreams() async throws {
        // The old forge (a bare repo) with main and a feature branch, cloned locally.
        _ = try git("init", "-q", "--bare", "-b", "main", "old.git")
        // (The new one made by GitKit itself.)
        _ = try Repository.create(at: root.appendingPathComponent("new.git"), bare: true)
        let work = root.appendingPathComponent("work")
        let repo = try await Repository.clone(from: root.appendingPathComponent("old.git").path, to: work, auth: auth)
        try "a\n".write(to: work.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        let first = try await repo.commitAll(message: "First\n", author: me)
        try await repo.push(remote: "origin", refspecs: ["refs/heads/main:refs/heads/main"], auth: auth)
        try await repo.setUpstream("main", to: "origin/main")
        try await repo.createBranch("feature")
        try await repo.createBranch("agent/fix-1")
        try await repo.tag("v1", at: first.id, tagger: me)

        let newURL = root.appendingPathComponent("new.git").path
        let plan = try await repo.migrationPlan(from: "origin", to: "forgejo", url: newURL)
        #expect(plan.branches == ["feature", "main"])          // the agent branch stays local
        #expect(plan.tags == ["v1"] && plan.upstreams == ["main"] && plan.addsRemote)
        #expect(plan.steps.count == 4)

        try await repo.migrate(plan, auth: auth)
        let newRefs = try git("for-each-ref", "--format=%(refname)", in: root.appendingPathComponent("new.git"))
        #expect(newRefs.split(separator: "\n") == ["refs/heads/feature", "refs/heads/main", "refs/tags/v1"])
        #expect(try git("rev-parse", "--abbrev-ref", "main@{upstream}", in: work) == "forgejo/main")
        let origin = try #require(try await repo.remotes().first { $0.name == "origin" })
        #expect(origin.isReadOnly)
        // Pushing to the old forge is refused now; fetching still works.
        await #expect(throws: (any Error).self) {
            try await repo.push(remote: "origin", refspecs: ["refs/heads/main:refs/heads/main"], auth: auth)
        }
        try await repo.fetch(remote: "origin", auth: auth)

        // Running it again is harmless; allowing pushes undoes the read-only mark.
        try await repo.migrate(plan, auth: auth)
        try await repo.allowPushes(to: "origin")
        #expect(try await repo.remotes().first { $0.name == "origin" }?.isReadOnly == false)
    }

    @Test func refusesClashesAndLabelsByHost() async throws {
        _ = try git("init", "-q", "--bare", "-b", "main", "old.git")
        let work = root.appendingPathComponent("work")
        let repo = try await Repository.clone(from: root.appendingPathComponent("old.git").path, to: work, auth: auth)
        try "a\n".write(to: work.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try await repo.commitAll(message: "First\n", author: me)
        await #expect(throws: MigrationError.noSuchRemote("upstream")) {
            try await repo.migrationPlan(from: "upstream", to: "x", url: "/tmp/x")
        }
        try await repo.addRemote(name: "mirror", url: "https://gitlab.com/me/app.git")
        await #expect(throws: MigrationError.nameTaken("mirror", url: "https://gitlab.com/me/app.git")) {
            try await repo.migrationPlan(from: "origin", to: "mirror", url: "https://codeberg.org/me/app.git")
        }
        #expect(RemoteInfo(name: "origin", url: "https://forgejo.example.net/me/app.git").label == "origin · forgejo.example.net")
        #expect(RemoteInfo(name: "origin", url: "git@github.com:me/app.git").label == "origin · github.com")
        #expect(RemoteInfo(name: "local", url: "/srv/app.git").label == "local")
        try await repo.renameRemote("mirror", to: "gitlab")
        try await repo.setRemoteURL("gitlab", "https://gitlab.com/me/other.git")
        #expect(try await repo.remotes().first { $0.name == "gitlab" }?.url == "https://gitlab.com/me/other.git")
        try await repo.removeRemote("gitlab")
        #expect(try await repo.remotes().map(\.name) == ["origin"])
    }

    @Test func anEmptyCloneStartsOnMain() async throws {
        // libgit2 alone would name the branch "master"; hide any global gitconfig the way iOS has none.
        setenv("GIT_CONFIG_NOSYSTEM", "1", 1)
        let empty = try Repository.create(at: root.appendingPathComponent("empty.git"), initialBranch: "trunk", bare: true)
        _ = empty
        let repo = try await Repository.clone(from: root.appendingPathComponent("empty.git").path, to: root.appendingPathComponent("c"), auth: auth)
        let branch = try await repo.head().branch
        #expect(branch == "main" || branch == "trunk", "\(branch ?? "nil")")
        #expect(branch != "master")
    }
}
