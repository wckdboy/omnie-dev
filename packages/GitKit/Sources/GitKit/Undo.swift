// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

import Clibgit2
import Foundation

/// One undoable git operation (PLAN.md §9.4: "Undo reverses the last git operation").
public struct UndoEntry: Sendable, Hashable, Codable, Identifiable {
    public enum Kind: String, Sendable, Codable {
        case commit, merge, sync, switchBranch
    }

    public let id: UUID
    public let kind: Kind
    /// "Commit “Add page style”", "Switch to feature".
    public let title: String
    public let date: Date
    /// Branch HEAD was on before the operation.
    public let branch: String?
    public let headBefore: String?
    public let headAfter: String?
    /// The working tree before the operation, kept alive by refs/omnie/undo/<id>.
    public let snapshot: String
    /// For switches: the branch that was switched to.
    public let switchedTo: String?
}

public enum UndoError: Error, Sendable, Equatable {
    case nothingToUndo
    /// Something happened after the operation (a new commit, a branch switch).
    case changedSince
    /// The commits are on the remote already; revert instead of rewriting shared history.
    case alreadyPushed
    /// Undoing a merge or sync would overwrite edits made after it. Commit or discard them first.
    case uncommittedChanges(count: Int)
}

extension Repository {
    static let undoLimit = 20

    public func undoStack() -> [UndoEntry] {
        guard let data = try? Data(contentsOf: undoFile) else { return [] }
        return (try? JSONDecoder().decode([UndoEntry].self, from: data)) ?? []
    }

    /// Reverses the most recent operation and returns it. Your uncommitted work from before the
    /// operation comes back exactly as it was; a checkpoint of the current state is taken first.
    @discardableResult
    public func undo() throws -> UndoEntry {
        var stack = undoStack()
        guard let entry = stack.last else { throw UndoError.nothingToUndo }
        let head = try head()

        switch entry.kind {
        case .switchBranch:
            guard head.branch == entry.switchedTo, let from = entry.branch else { throw UndoError.changedSince }
            try switchBranch(to: from, recordUndo: false)

        case .commit, .merge, .sync:
            guard head.branch == entry.branch, head.commit?.hex == entry.headAfter else { throw UndoError.changedSince }
            if let after = entry.headAfter.flatMap(ObjectID.init(hex:)), try isOnRemote(after) {
                throw UndoError.alreadyPushed
            }
            // Merges and syncs brought in other people's files; putting the folder back means
            // replacing it, so refuse rather than overwrite edits made since.
            if entry.kind != .commit {
                let edited = try status().entries
                guard edited.isEmpty else { throw UndoError.uncommittedChanges(count: edited.count) }
            }
            try checkpoint(.undo)
            let branchRef = "refs/heads/\(entry.branch ?? "")"
            if let before = entry.headBefore.flatMap(ObjectID.init(hex:)) {
                try setReference(branchRef, to: before, log: "undo: \(entry.title)")
            } else {
                try deleteReference(branchRef)  // back to an unborn branch
            }
            if entry.kind == .commit {
                // Like `git reset --mixed`: the folder stays as it is, the commit's changes become uncommitted.
                try resetIndexToHead()
            } else {
                guard let snapshotCommit = ObjectID(hex: entry.snapshot) else { throw UndoError.changedSince }
                try restoreWorkingTree(to: try commit(snapshotCommit).tree)
            }
        }

        stack.removeLast()
        try? deleteReference(Self.undoRef(entry.id))
        try saveUndoStack(stack)
        return entry
    }

    // MARK: Recording

    /// Runs `body`, recording it as undoable if HEAD (or the branch) changed.
    func recordingUndo<T>(_ kind: UndoEntry.Kind, _ title: String, switchedTo: String? = nil,
                          _ body: () throws -> T) throws -> T {
        let before = try head()
        let snapshotTree = try snapshotTree()
        let snapshot = try createCommit(updating: nil, tree: snapshotTree, parents: before.commit.map { [$0] } ?? [],
                                        message: "undo snapshot: \(title)\n", author: .checkpoint, date: .now)
        let result = try body()
        let after = try head()
        guard after.commit != before.commit || after.branch != before.branch else { return result }

        let entry = UndoEntry(id: UUID(), kind: kind, title: title, date: .now, branch: before.branch,
                              headBefore: before.commit?.hex, headAfter: after.commit?.hex,
                              snapshot: snapshot.hex, switchedTo: switchedTo)
        try setReference(Self.undoRef(entry.id), to: snapshot, log: "undo snapshot")
        var stack = undoStack()
        stack.append(entry)
        while stack.count > Self.undoLimit {
            let dropped = stack.removeFirst()
            try? deleteReference(Self.undoRef(dropped.id))
        }
        try saveUndoStack(stack)
        return result
    }

    static func undoRef(_ id: UUID) -> String { "refs/omnie/undo/\(id.uuidString.lowercased())" }

    private var undoFile: URL {
        URL(filePath: String(cString: git_repository_path(pointer)), directoryHint: .isDirectory)
            .appendingPathComponent("omnie/undo.json")
    }

    private func saveUndoStack(_ stack: [UndoEntry]) throws {
        try FileManager.default.createDirectory(at: undoFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(stack).write(to: undoFile, options: .atomic)
    }

    /// True if any remote-tracking branch contains `commit`.
    func isOnRemote(_ commit: ObjectID) throws -> Bool {
        var iterator: OpaquePointer?
        try check(git_reference_iterator_glob_new(&iterator, pointer, "refs/remotes/*"), "list remote branches")
        defer { git_reference_iterator_free(iterator) }
        var ref: OpaquePointer?
        while git_reference_next(&ref, iterator) == 0 {
            defer { git_reference_free(ref) }
            guard let target = git_reference_target(ref) else { continue }
            var tip = target.pointee
            var c = commit.oid
            if git_oid_equal(&tip, &c) == 1 || git_graph_descendant_of(pointer, &tip, &c) == 1 { return true }
        }
        return false
    }

    /// Makes the working tree match `tree` exactly (untracked files included) and points the index at HEAD.
    func restoreWorkingTree(to tree: ObjectID) throws {
        var treeOid = tree.oid
        var treeObj: OpaquePointer?
        try check(git_tree_lookup(&treeObj, pointer, &treeOid), "read tree")
        defer { git_tree_free(treeObj) }
        var opts = git_checkout_options()
        git_checkout_options_init(&opts, UInt32(GIT_CHECKOUT_OPTIONS_VERSION))
        opts.checkout_strategy = GIT_CHECKOUT_FORCE.rawValue | GIT_CHECKOUT_REMOVE_UNTRACKED.rawValue
        try check(git_checkout_tree(pointer, treeObj, &opts), "restore files")
        try resetIndexToHead()
    }

    /// Points the index at HEAD's tree (empty on an unborn branch), leaving the working tree alone.
    func resetIndexToHead() throws {
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
}

extension Repository {
    /// Adds a commit that reverses `target` — the safe way to undo something already pushed.
    @discardableResult
    public func revert(_ target: ObjectID, author: Signature, date: Date = .now) throws -> CommitInfo {
        guard let ours = try head().commit else { throw GitKitError.nothingToCommit }
        let tracked = try status().entries.filter { $0.kind != .untracked }
        guard tracked.isEmpty else { throw MergeError.uncommittedChanges(count: tracked.count) }
        let reverted = try commit(target)

        var targetOid = target.oid, oursOid = ours.oid
        var targetCommit: OpaquePointer?, ourCommit: OpaquePointer?
        try check(git_commit_lookup(&targetCommit, pointer, &targetOid), "read commit")
        defer { git_commit_free(targetCommit) }
        try check(git_commit_lookup(&ourCommit, pointer, &oursOid), "read HEAD")
        defer { git_commit_free(ourCommit) }

        var index: OpaquePointer?
        try check(git_revert_commit(&index, pointer, targetCommit, ourCommit, 0, nil), "revert \(target.short)")
        defer { git_index_free(index) }
        if git_index_has_conflicts(index) == 1 { throw MergeError.conflicts(paths: try conflictedPaths(in: index!)) }
        var tree = git_oid()
        try check(git_index_write_tree_to(&tree, index, pointer), "write tree")

        return try recordingUndo(.commit, "Revert “\(reverted.summary)”") {
            let id = try createCommit(updating: "HEAD", tree: ObjectID(tree), parents: [ours],
                                      message: "Revert “\(reverted.summary)”\n\nThis reverts commit \(target.hex).\n",
                                      author: author, date: date)
            try checkout(commit: id, removeUntracked: false)
            return try commit(id)
        }
    }
}
