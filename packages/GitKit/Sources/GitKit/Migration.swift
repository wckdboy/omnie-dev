// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

import Clibgit2
import Foundation

/// "Move this repo" (PLAN.md §9.11): add the new forge as a remote, mirror-push your branches and
/// tags there, switch upstreams to it, and keep the old remote for fetching only. Planned first
/// (the preview), then run step by step.
public struct MigrationPlan: Sendable, Hashable {
    public let from: String
    public let to: String
    public let url: String
    /// Local branches to push (agent task branches stay local unless asked for).
    public let branches: [String]
    public let tags: [String]
    /// Branches whose upstream is on `from`; they'll track `to` instead.
    public let upstreams: [String]
    /// Whether `to` must be added (it may exist already with the same URL).
    public let addsRemote: Bool

    /// The steps in words, for the preview.
    public var steps: [String] {
        var steps: [String] = []
        if addsRemote { steps.append("Add remote “\(to)” → \(url)") }
        steps.append("Push \(branches.count) branch\(branches.count == 1 ? "" : "es") and \(tags.count) tag\(tags.count == 1 ? "" : "s") to “\(to)”")
        if !upstreams.isEmpty { steps.append("Track “\(to)” instead of “\(from)” for \(upstreams.joined(separator: ", "))") }
        steps.append("Keep “\(from)” for fetching only (pushes to it are refused)")
        return steps
    }
}

public enum MigrationError: Error, Sendable, Equatable, LocalizedError {
    case noSuchRemote(String)
    case nameTaken(String, url: String)
    case nothingToPush

    public var errorDescription: String? {
        switch self {
        case .noSuchRemote(let n): "There's no remote “\(n)”."
        case .nameTaken(let n, let url): "A remote “\(n)” exists already (\(url)). Pick another name."
        case .nothingToPush: "There are no branches to move."
        }
    }
}

extension Repository {
    /// The push URL given to a remote kept for fetching only; pushing to it fails with a clear error.
    public static let readOnlyPushPrefix = "read-only://"

    public func migrationPlan(from old: String, to name: String, url: String, includeAgentBranches: Bool = false) throws -> MigrationPlan {
        let remotes = try remotes()
        guard remotes.contains(where: { $0.name == old }) else { throw MigrationError.noSuchRemote(old) }
        if let existing = remotes.first(where: { $0.name == name }), existing.url != url {
            throw MigrationError.nameTaken(name, url: existing.url)
        }
        let branches = try self.branches().filter { includeAgentBranches || !$0.isAgentTask }
        guard !branches.isEmpty else { throw MigrationError.nothingToPush }
        let upstreams = try branches.compactMap { try upstreamRemoteName(of: $0.name) == old ? $0.name : nil }
        return MigrationPlan(from: old, to: name, url: url, branches: branches.map(\.name).sorted(),
                             tags: try tags().values.flatMap { $0 }.sorted(), upstreams: upstreams.sorted(),
                             addsRemote: !remotes.contains { $0.name == name })
    }

    /// Runs the plan. Each step is safe to repeat, so a move that failed partway (the network)
    /// can simply be run again.
    public func migrate(_ plan: MigrationPlan, auth: RemoteAuth) async throws {
        if try !remotes().contains(where: { $0.name == plan.to }) { try addRemote(name: plan.to, url: plan.url) }
        // Large files first, so the moved commits don't point at objects the new forge lacks.
        if usesLFS() { try await lfsPush(remote: plan.to, auth: auth) }
        let refspecs = plan.branches.map { "refs/heads/\($0):refs/heads/\($0)" } + plan.tags.map { "refs/tags/\($0):refs/tags/\($0)" }
        try push(remote: plan.to, refspecs: refspecs, auth: auth)
        // Remote-tracking branches for the new remote, so upstreams can point at them.
        try fetch(remote: plan.to, auth: auth)
        for branch in plan.upstreams { try setUpstream(branch, to: "\(plan.to)/\(branch)") }
        try setPushURL(plan.from, Self.readOnlyPushPrefix + plan.from)
    }

    /// Makes a read-only remote pushable again.
    public func allowPushes(to remote: String) throws {
        var r: OpaquePointer?
        try check(git_remote_lookup(&r, pointer, remote), "find remote \(remote)")
        git_remote_free(r)
        // An empty push URL means "push to url", as git does.
        var config: OpaquePointer?
        try check(git_repository_config(&config, pointer), "open config")
        defer { git_config_free(config) }
        let rc = git_config_delete_entry(config, "remote.\(remote).pushurl")
        if rc != GIT_ENOTFOUND.rawValue { try check(rc, "clear push URL") }
    }

    public func setUpstream(_ branch: String, to remoteBranch: String) throws {
        var ref: OpaquePointer?
        try check(git_branch_lookup(&ref, pointer, branch, GIT_BRANCH_LOCAL), "find branch \(branch)")
        defer { git_reference_free(ref) }
        try check(git_branch_set_upstream(ref, remoteBranch), "track \(remoteBranch)")
    }

    public func removeRemote(_ name: String) throws {
        try check(git_remote_delete(pointer, name), "remove remote \(name)")
    }

    public func renameRemote(_ name: String, to newName: String) throws {
        var problems = git_strarray()
        defer { git_strarray_dispose(&problems) }
        try check(git_remote_rename(&problems, pointer, name, newName), "rename remote \(name)")
    }

    public func setRemoteURL(_ name: String, _ url: String) throws {
        try check(git_remote_set_url(pointer, name, url), "set URL of \(name)")
    }

    private func setPushURL(_ name: String, _ url: String) throws {
        try check(git_remote_set_pushurl(pointer, name, url), "set push URL of \(name)")
    }
}
