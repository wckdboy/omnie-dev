import Clibgit2
import Foundation

/// Why a checkpoint was taken (PLAN.md §9.3).
public enum CheckpointReason: String, Sendable, CaseIterable {
    case save
    case agentApply = "agent-apply"
    case run
    case branchSwitch = "branch-switch"
    case interval
    case restore
    case sync
    case manual
}

/// A snapshot of the working tree, stored as a commit on a hidden ref.
public struct Checkpoint: Sendable, Hashable, Identifiable {
    public let id: ObjectID
    public let tree: ObjectID
    /// The HEAD commit this checkpoint was taken on top of; nil on an unborn branch.
    public let base: ObjectID?
    public let reason: CheckpointReason
    public let date: Date
}

extension Repository {
    static let checkpointPrefix = "checkpoint: "
    static let baseTrailer = "Checkpoint-base"

    /// `refs/checkpoints/<branch>`, or `refs/checkpoints/detached` when HEAD is detached.
    /// These refs are outside refs/heads, so they don't show in `git log` and are never pushed by default.
    public func checkpointRef() throws -> String {
        "refs/checkpoints/" + (try head().branch ?? "detached")
    }

    /// Snapshots the working tree, including untracked files that aren't ignored, **without touching
    /// the index or the working tree**. Returns nil when nothing changed since the last checkpoint
    /// (or since HEAD, if there is no checkpoint on top of it yet).
    @discardableResult
    public func checkpoint(_ reason: CheckpointReason, date: Date = .now) throws -> Checkpoint? {
        let head = try head()
        let tree = try snapshotTree()
        let ref = try checkpointRef()

        // Chain onto the previous checkpoint only if it was taken on the same HEAD.
        // After a commit, a new chain starts from the new HEAD.
        let parents: [ObjectID]
        if let tip = try resolveReference(ref), let previous = try? checkpointInfo(tip), previous.base == head.commit {
            if previous.tree == tree { return nil }
            parents = [tip]
        } else if let headCommit = head.commit {
            if try treeOf(headCommit) == tree { return nil }
            parents = [headCommit]
        } else {
            if tree == .emptyTree { return nil }
            parents = []
        }

        let message = "\(Self.checkpointPrefix)\(reason.rawValue)\n\n\(Self.baseTrailer): \(head.commit?.hex ?? "none")\n"
        let id = try createCommit(updating: nil, tree: tree, parents: parents,
                                  message: message, author: .checkpoint, date: date)
        try setReference(ref, to: id, log: "checkpoint: \(reason.rawValue)")
        return Checkpoint(id: id, tree: tree, base: head.commit, reason: reason, date: date)
    }

    /// Checkpoints taken since the current HEAD commit, newest first. This is what the commit
    /// composer turns into one commit.
    public func checkpointsSinceHead() throws -> [Checkpoint] {
        let headCommit = try head().commit
        guard var cursor = try resolveReference(try checkpointRef()) else { return [] }
        var result: [Checkpoint] = []
        while let cp = try? checkpointInfo(cursor), cp.base == headCommit {
            result.append(cp)
            guard let parent = try commit(cursor).parents.first else { break }
            cursor = parent
        }
        return result
    }

    /// Puts the working tree back to a checkpoint. Takes a `restore` checkpoint first, so restoring is
    /// never destructive, and leaves HEAD and the index alone (the index is reset to HEAD).
    public func restore(_ checkpoint: Checkpoint) throws {
        try self.checkpoint(.restore)

        var treeOid = checkpoint.tree.oid
        var tree: OpaquePointer?
        try check(git_tree_lookup(&tree, pointer, &treeOid), "read checkpoint tree")
        defer { git_tree_free(tree) }

        var opts = git_checkout_options()
        git_checkout_options_init(&opts, UInt32(GIT_CHECKOUT_OPTIONS_VERSION))
        opts.checkout_strategy = GIT_CHECKOUT_FORCE.rawValue | GIT_CHECKOUT_REMOVE_UNTRACKED.rawValue
        try check(git_checkout_tree(pointer, tree, &opts), "restore checkpoint")

        // checkout_tree also rewrote the index; point it back at HEAD so nothing looks staged.
        let index = try repositoryIndex()
        defer { git_index_free(index) }
        if let headCommit = try head().commit {
            var headTreeOid = try treeOf(headCommit).oid
            var headTree: OpaquePointer?
            try check(git_tree_lookup(&headTree, pointer, &headTreeOid), "read HEAD tree")
            defer { git_tree_free(headTree) }
            try check(git_index_read_tree(index, headTree), "reset index")
        } else {
            try check(git_index_clear(index), "reset index")
        }
        try check(git_index_write(index), "write index")
    }

    func checkpointInfo(_ id: ObjectID) throws -> Checkpoint {
        let c = try commit(id)
        guard c.message.hasPrefix(Self.checkpointPrefix) else { throw GitKitError.notACheckpoint(id) }
        let reasonText = c.summary.dropFirst(Self.checkpointPrefix.count)
        let baseText = Trailers.value(for: Self.baseTrailer, in: c.message)
        return Checkpoint(
            id: id,
            tree: c.tree,
            base: baseText.flatMap { ObjectID(hex: $0) },
            reason: CheckpointReason(rawValue: String(reasonText)) ?? .manual,
            date: c.date
        )
    }

    /// The working tree as a tree object. Uses the repository's index in memory and then
    /// re-reads it from disk, so the on-disk index (and anything you staged) is untouched.
    func snapshotTree() throws -> ObjectID {
        let index = try repositoryIndex()
        defer { git_index_free(index) }
        try check(git_index_read(index, 1), "read index")
        defer { git_index_read(index, 1) }
        try stageEverything(index)
        return try writeTree(index)
    }
}
