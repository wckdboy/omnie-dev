// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

import Clibgit2
import Foundation

/// An agent task's isolated checkout (PLAN.md §9.5): its own branch and working tree,
/// so the agent never touches the folder you're typing in.
public struct TaskWorktree: Sendable, Hashable, Identifiable {
    public var id: String { name }
    /// libgit2 worktree name, e.g. "agent-fix-auth".
    public let name: String
    public let branch: String
    public let path: URL
}

public enum MergeError: Error, Sendable, Equatable {
    /// The task's changes conflict with your branch. Nothing was changed.
    case conflicts(paths: [String])
    /// Your working tree has uncommitted changes to tracked files. Commit them first.
    case uncommittedChanges(count: Int)
    case nothingToMerge
}

extension Repository {
    public static let agentBranchPrefix = "agent/"

    /// Creates `agent/<slug>` at HEAD and checks it out in a new worktree at `path`.
    public func createTaskWorktree(slug: String, at path: URL) throws -> TaskWorktree {
        let branch = Self.agentBranchPrefix + slug
        let name = "agent-" + slug
        try createBranch(branch)

        var branchRef: OpaquePointer?
        try check(git_reference_lookup(&branchRef, pointer, "refs/heads/\(branch)"), "find \(branch)")
        defer { git_reference_free(branchRef) }

        var opts = git_worktree_add_options()
        git_worktree_add_options_init(&opts, UInt32(GIT_WORKTREE_ADD_OPTIONS_VERSION))
        opts.ref = branchRef
        var worktree: OpaquePointer?
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try check(git_worktree_add(&worktree, pointer, name, path.path(percentEncoded: false), &opts), "create worktree")
        defer { git_worktree_free(worktree) }
        // Report the path as libgit2 stores it (resolved symlinks), so it matches taskWorktrees().
        let stored = URL(filePath: String(cString: git_worktree_path(worktree)), directoryHint: .isDirectory)
        return TaskWorktree(name: name, branch: branch, path: stored)
    }

    public func taskWorktrees() throws -> [TaskWorktree] {
        var names = git_strarray()
        try check(git_worktree_list(&names, pointer), "list worktrees")
        defer { git_strarray_dispose(&names) }
        return try (0..<names.count).compactMap { i -> TaskWorktree? in
            guard let cName = names.strings[i] else { return nil }
            let name = String(cString: cName)
            guard name.hasPrefix("agent-") else { return nil }
            var wt: OpaquePointer?
            try check(git_worktree_lookup(&wt, pointer, cName), "read worktree \(name)")
            defer { git_worktree_free(wt) }
            let path = URL(filePath: String(cString: git_worktree_path(wt)), directoryHint: .isDirectory)
            return TaskWorktree(name: name, branch: Self.agentBranchPrefix + name.dropFirst("agent-".count), path: path)
        }
    }

    /// Removes the worktree directory and its metadata. The branch is kept unless `deleteBranch`
    /// (rejected tasks keep theirs for a while so they can be revisited).
    public func removeTaskWorktree(_ task: TaskWorktree, deleteBranch: Bool) throws {
        var wt: OpaquePointer?
        try check(git_worktree_lookup(&wt, pointer, task.name), "find worktree \(task.name)")
        defer { git_worktree_free(wt) }
        var opts = git_worktree_prune_options()
        git_worktree_prune_options_init(&opts, UInt32(GIT_WORKTREE_PRUNE_OPTIONS_VERSION))
        opts.flags = GIT_WORKTREE_PRUNE_VALID.rawValue | GIT_WORKTREE_PRUNE_WORKING_TREE.rawValue
        try check(git_worktree_prune(wt, &opts), "remove worktree \(task.name)")
        if deleteBranch { try self.deleteBranch(task.branch) }
    }

    /// Squash-merges `branch` into the current branch as one commit (the default way an agent task
    /// lands). If your branch moved since the task started, the changes are three-way merged;
    /// conflicts abort with nothing changed. `assistedBy` adds the trailer that colors it violet.
    @discardableResult
    public func squashMerge(_ branch: String, message: String, author: Signature,
                            assistedBy model: String?, date: Date = .now) throws -> CommitInfo {
        try recordingUndo(.merge, "Merge \(branch)") {
            try squashMergeUnrecorded(branch, message: message, author: author, assistedBy: model, date: date)
        }
    }

    private func squashMergeUnrecorded(_ branch: String, message: String, author: Signature,
                                       assistedBy model: String?, date: Date) throws -> CommitInfo {
        guard let ours = try head().commit else { throw GitKitError.nothingToCommit }
        guard let theirs = try resolveReference("refs/heads/\(branch)") else { throw BranchError.notFound(branch) }
        let tracked = try status().entries.filter { $0.kind != .untracked }
        guard tracked.isEmpty else { throw MergeError.uncommittedChanges(count: tracked.count) }

        var oursOid = ours.oid, theirsOid = theirs.oid, baseOid = git_oid()
        try check(git_merge_base(&baseOid, pointer, &oursOid, &theirsOid), "find merge base")
        let base = ObjectID(baseOid)
        if base == theirs { throw MergeError.nothingToMerge }

        let tree: ObjectID
        if base == ours {
            tree = try treeOf(theirs)  // your branch didn't move: the task's tree is the result
        } else {
            tree = try mergeTrees(base: try treeOf(base), ours: try treeOf(ours), theirs: try treeOf(theirs))
        }
        if tree == (try treeOf(ours)) { throw MergeError.nothingToMerge }

        try checkpoint(.agentApply)
        var text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        if let model { text += "\n\nAssisted-by: \(model)" }
        text += "\n"
        let id = try createCommit(updating: "HEAD", tree: tree, parents: [ours], message: text, author: author, date: date)
        try checkout(commit: id, removeUntracked: false)
        return try commit(id)
    }

    func mergeTrees(base: ObjectID, ours: ObjectID, theirs: ObjectID) throws -> ObjectID {
        var b = base.oid, o = ours.oid, t = theirs.oid
        var baseTree: OpaquePointer?, ourTree: OpaquePointer?, theirTree: OpaquePointer?
        try check(git_tree_lookup(&baseTree, pointer, &b), "read tree")
        defer { git_tree_free(baseTree) }
        try check(git_tree_lookup(&ourTree, pointer, &o), "read tree")
        defer { git_tree_free(ourTree) }
        try check(git_tree_lookup(&theirTree, pointer, &t), "read tree")
        defer { git_tree_free(theirTree) }

        var index: OpaquePointer?
        try check(git_merge_trees(&index, pointer, baseTree, ourTree, theirTree, nil), "merge")
        defer { git_index_free(index) }
        if git_index_has_conflicts(index) == 1 {
            throw MergeError.conflicts(paths: try conflictedPaths(in: index!))
        }
        var oid = git_oid()
        try check(git_index_write_tree_to(&oid, index, pointer), "write merged tree")
        return ObjectID(oid)
    }
}
