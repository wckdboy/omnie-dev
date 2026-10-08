import Clibgit2
import Foundation

/// What Sync did to bring in upstream work.
public enum Integration: Sendable, Equatable {
    case upToDate
    case fastForwarded(commits: Int)
    /// Your unpushed commits were replayed on top of upstream (linear history on personal branches).
    case rebased(commits: Int)
}

public struct SyncResult: Sendable, Equatable {
    public let integration: Integration
    public let pulled: Int
    public let pushed: Int

    /// One line for the status strip: "Synced: pushed 3, pulled 1 (rebased)".
    public var summary: String {
        var parts: [String] = []
        if pushed > 0 { parts.append("pushed \(pushed)") }
        if pulled > 0 { parts.append("pulled \(pulled)") }
        guard !parts.isEmpty else { return "Synced: up to date" }
        var line = "Synced: " + parts.joined(separator: ", ")
        if case .rebased = integration { line += " (rebased)" }
        return line
    }
}

public enum SyncError: Error, Sendable, Equatable {
    case noRemote
    /// Upstream changed files you have uncommitted edits to. Nothing was changed.
    case localChangesBlock(paths: [String])
    /// A rebase is needed and the working tree has uncommitted changes. Nothing was changed.
    case uncommittedChanges(count: Int)
    /// Replaying your commits conflicted. The rebase was aborted; your branch is as it was.
    case conflicts(paths: [String])
}

extension Repository {
    /// Fetch, integrate, push (PLAN.md §9.8). Fast-forwards when possible; otherwise rebases your
    /// unpushed commits onto upstream. Never leaves a half-done rebase behind.
    public func sync(auth: RemoteAuth, committer: Signature) throws -> SyncResult {
        try recordingUndo(.sync, "Sync") { try syncUnrecorded(auth: auth, committer: committer) }
    }

    private func syncUnrecorded(auth: RemoteAuth, committer: Signature) throws -> SyncResult {
        guard let branch = try head().branch else { throw GitKitError.detachedHead }
        let remoteName: String
        if let configured = try upstreamRemoteName(of: branch) {
            remoteName = configured
        } else if try remotes().contains(where: { $0.name == "origin" }) {
            remoteName = "origin"
        } else {
            throw SyncError.noRemote
        }

        try fetch(remote: remoteName, auth: auth)

        var integration = Integration.upToDate
        var pulled = 0
        if let upstream = try upstreamCommit(of: branch) ?? remoteBranchTip(remoteName, branch) {
            let local = try head().commit!
            let (ahead, behind) = try aheadBehind(local, upstream)
            if behind > 0 && ahead == 0 {
                try fastForward(branch: branch, to: upstream)
                integration = .fastForwarded(commits: behind)
                pulled = behind
            } else if behind > 0 {
                let replayed = try rebaseOnto(upstream, committer: committer)
                integration = .rebased(commits: replayed)
                pulled = behind
            }
        }

        let toPush: Int
        if let upstream = try upstreamCommit(of: branch) ?? remoteBranchTip(remoteName, branch) {
            toPush = try aheadBehind(try head().commit!, upstream).ahead
        } else {
            toPush = try countNotOnAnyRemote()
        }
        if toPush > 0 {
            try pushCurrentBranch(auth: auth)
        }
        return SyncResult(integration: integration, pulled: pulled, pushed: toPush)
    }

    func aheadBehind(_ local: ObjectID, _ upstream: ObjectID) throws -> (ahead: Int, behind: Int) {
        var a = 0, b = 0
        var l = local.oid, u = upstream.oid
        try check(git_graph_ahead_behind(&a, &b, pointer, &l, &u), "ahead/behind")
        return (a, b)
    }

    /// Commits on HEAD that no remote-tracking branch already has (what a first push really sends).
    func countNotOnAnyRemote() throws -> Int {
        var walk: OpaquePointer?
        try check(git_revwalk_new(&walk, pointer), "count commits")
        defer { git_revwalk_free(walk) }
        try check(git_revwalk_push_head(walk), "count commits")
        try check(git_revwalk_hide_glob(walk, "refs/remotes/*"), "count commits")
        var count = 0
        var oid = git_oid()
        while git_revwalk_next(&oid, walk) == 0 { count += 1 }
        return count
    }

    func remoteBranchTip(_ remote: String, _ branch: String) throws -> ObjectID? {
        try resolveReference("refs/remotes/\(remote)/\(branch)")
    }

    /// Moves the branch to `target`, updating only files you haven't changed locally.
    func fastForward(branch: String, to target: ObjectID) throws {
        try checkpoint(.sync)
        var oid = target.oid
        var commit: OpaquePointer?
        try check(git_commit_lookup(&commit, pointer, &oid), "read upstream commit")
        defer { git_commit_free(commit) }

        var opts = git_checkout_options()
        git_checkout_options_init(&opts, UInt32(GIT_CHECKOUT_OPTIONS_VERSION))
        opts.checkout_strategy = GIT_CHECKOUT_SAFE.rawValue
        let collector = ConflictCollector()
        opts.notify_flags = GIT_CHECKOUT_NOTIFY_CONFLICT.rawValue
        opts.notify_cb = { _, path, _, _, _, payload in
            if let path { Unmanaged<ConflictCollector>.fromOpaque(payload!).takeUnretainedValue().paths.append(String(cString: path)) }
            return 0
        }
        opts.notify_payload = Unmanaged.passUnretained(collector).toOpaque()
        let rc = withExtendedLifetime(collector) { git_checkout_tree(pointer, commit, &opts) }
        if rc == GIT_ECONFLICT.rawValue { throw SyncError.localChangesBlock(paths: collector.paths.sorted()) }
        try check(rc, "update files")

        var ref: OpaquePointer?
        try check(git_reference_lookup(&ref, pointer, "refs/heads/\(branch)"), "find branch")
        defer { git_reference_free(ref) }
        var moved: OpaquePointer?
        try check(git_reference_set_target(&moved, ref, &oid, "sync: fast-forward"), "move branch")
        git_reference_free(moved)
    }

    /// Replays HEAD's commits that aren't in `upstream` on top of it. Aborts cleanly on conflict.
    func rebaseOnto(_ upstream: ObjectID, committer: Signature) throws -> Int {
        let tracked = try status().entries.filter { $0.kind != .untracked }
        guard tracked.isEmpty else { throw SyncError.uncommittedChanges(count: tracked.count) }
        try checkpoint(.sync)

        var upOid = upstream.oid
        var annotated: OpaquePointer?
        try check(git_annotated_commit_lookup(&annotated, pointer, &upOid), "read upstream")
        defer { git_annotated_commit_free(annotated) }

        var opts = git_rebase_options()
        git_rebase_options_init(&opts, UInt32(GIT_REBASE_OPTIONS_VERSION))
        var rebase: OpaquePointer?
        try check(git_rebase_init(&rebase, pointer, nil, annotated, nil, &opts), "start rebase")
        defer { git_rebase_free(rebase) }

        var sig: UnsafeMutablePointer<git_signature>?
        try check(git_signature_now(&sig, committer.name, committer.email), "signature")
        defer { git_signature_free(sig) }

        var replayed = 0
        var operation: UnsafeMutablePointer<git_rebase_operation>?
        while true {
            let rc = git_rebase_next(&operation, rebase)
            if rc == GIT_ITEROVER.rawValue { break }
            if rc < 0 {
                git_rebase_abort(rebase)
                throw GitError.last(rc, "rebase")
            }
            let conflicts = try conflictedPaths()
            if !conflicts.isEmpty {
                git_rebase_abort(rebase)
                throw SyncError.conflicts(paths: conflicts)
            }
            var newOid = git_oid()
            let commitRC = git_rebase_commit(&newOid, rebase, nil, sig, nil, nil)
            if commitRC == GIT_EAPPLIED.rawValue { continue }  // already upstream
            if commitRC < 0 {
                git_rebase_abort(rebase)
                throw GitError.last(commitRC, "rebase commit")
            }
            replayed += 1
        }
        try check(git_rebase_finish(rebase, sig), "finish rebase")
        return replayed
    }

    func conflictedPaths() throws -> [String] {
        let index = try repositoryIndex()
        defer { git_index_free(index) }
        return try conflictedPaths(in: index)
    }

    func conflictedPaths(in index: OpaquePointer) throws -> [String] {
        guard git_index_has_conflicts(index) == 1 else { return [] }
        var iterator: OpaquePointer?
        try check(git_index_conflict_iterator_new(&iterator, index), "read conflicts")
        defer { git_index_conflict_iterator_free(iterator) }
        var paths: [String] = []
        var ancestor: UnsafePointer<git_index_entry>?, ours: UnsafePointer<git_index_entry>?, theirs: UnsafePointer<git_index_entry>?
        while git_index_conflict_next(&ancestor, &ours, &theirs, iterator) == 0 {
            if let path = (ours ?? theirs ?? ancestor)?.pointee.path { paths.append(String(cString: path)) }
        }
        return paths.sorted()
    }
}

private final class ConflictCollector: @unchecked Sendable {
    var paths: [String] = []
}

// MARK: - Offline push queue

/// A push authorized while offline (Face ID at queue time), sent when the network returns
/// only if nothing changed since (PLAN.md §9.8).
public struct PushIntent: Sendable, Hashable, Codable, Identifiable {
    public let id: UUID
    public let branch: String
    /// The commit that was authorized.
    public let commit: String
    public let createdAt: Date
    public let expiresAt: Date

    public init(branch: String, commit: ObjectID, createdAt: Date = .now, lifetime: TimeInterval = 24 * 3600) {
        self.id = UUID()
        self.branch = branch
        self.commit = commit.hex
        self.createdAt = createdAt
        self.expiresAt = createdAt.addingTimeInterval(lifetime)
    }
}

public enum FlushOutcome: Sendable, Equatable {
    case pushed
    /// The intent can't be sent as authorized; it needs you (and a fresh Face ID).
    case needsYou(reason: String)
}

extension Repository {
    /// Records what you're authorizing: the current branch at its current commit.
    public func makePushIntent(now: Date = .now) throws -> PushIntent {
        let head = try head()
        guard let branch = head.branch else { throw GitKitError.detachedHead }
        guard let commit = head.commit else { throw GitKitError.nothingToCommit }
        return PushIntent(branch: branch, commit: commit, createdAt: now)
    }

    /// Sends a queued push if it's still exactly what was authorized and hasn't expired.
    public func flush(_ intent: PushIntent, auth: RemoteAuth, now: Date = .now) throws -> FlushOutcome {
        if now > intent.expiresAt { return .needsYou(reason: "Authorization expired after 24 h") }
        guard let tip = try resolveReference("refs/heads/\(intent.branch)") else {
            return .needsYou(reason: "Branch \(intent.branch) no longer exists")
        }
        guard tip.hex == intent.commit else {
            return .needsYou(reason: "\(intent.branch) changed after the push was queued")
        }
        let remoteName = try upstreamRemoteName(of: intent.branch) ?? "origin"
        do {
            try push(remote: remoteName, refspecs: ["refs/heads/\(intent.branch):refs/heads/\(intent.branch)"], auth: auth)
        } catch GitKitError.pushRejected(_, let reason) {
            return .needsYou(reason: "Remote rejected the push: \(reason)")
        }
        return .pushed
    }
}

extension Repository {
    /// The current branch's upstream tip (after a fetch), falling back to origin/<branch>.
    public func upstreamTip() throws -> ObjectID? {
        guard let branch = try head().branch else { return nil }
        if let tip = try upstreamCommit(of: branch) { return tip }
        return try remoteBranchTip(try upstreamRemoteName(of: branch) ?? "origin", branch)
    }

    /// "origin/main", for messages.
    public func upstreamName() throws -> String? {
        guard let branch = try head().branch else { return nil }
        return "\(try upstreamRemoteName(of: branch) ?? "origin")/\(branch)"
    }
}
