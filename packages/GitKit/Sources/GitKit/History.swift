// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

import Clibgit2
import Foundation

/// One commit's fate in an interactive rebase (PLAN.md §9.10): keep it, change its message, fold
/// it into the one before (keeping or dropping its message), or leave it out.
public struct HistoryStep: Sendable, Hashable {
    public enum Action: Sendable, Hashable {
        case pick
        case reword(String)
        case squash
        case fixup
        case drop
    }

    public var commit: ObjectID
    public var action: Action

    public init(_ commit: ObjectID, _ action: Action = .pick) {
        self.commit = commit
        self.action = action
    }
}

public enum HistoryError: Error, Sendable, Equatable, LocalizedError {
    case uncommittedChanges(count: Int)
    /// Replaying a commit in its new place conflicted; nothing was changed.
    case conflict(summary: String, paths: [String])
    /// The first kept commit can't be squashed or fixed up: there's nothing before it to join.
    case nothingToJoin(summary: String)
    case notOnABranch
    /// The commits aren't a straight line from the base to HEAD.
    case notLinear

    public var errorDescription: String? {
        switch self {
        case .uncommittedChanges(let n): "Commit or discard your \(n) uncommitted change\(n == 1 ? "" : "s") first; editing history replaces the folder's files."
        case .conflict(let summary, let paths): "“\(summary)” doesn't apply in its new place (\(paths.joined(separator: ", "))). Nothing was changed."
        case .nothingToJoin(let summary): "“\(summary)” has no commit before it to join. Pick it, or move it down."
        case .notOnABranch: "Switch to a branch first."
        case .notLinear: "This history has merges; only a straight run of commits can be edited."
        }
    }
}

extension Repository {
    /// The commits you can edit, oldest first, and the commit they sit on: your unpushed ones when
    /// the branch has an upstream, else up to `limit` back. Stops at merges and above the root.
    public func editableHistory(limit: Int = 30) throws -> (base: ObjectID, commits: [CommitInfo])? {
        guard let branch = try head().branch, let tip = try head().commit else { return nil }
        let upstream = try upstreamCommit(of: branch)
        var commits: [CommitInfo] = []
        var current = try commit(tip)
        while commits.count < limit, current.parents.count == 1, current.id != upstream {
            if let upstream, try isAncestor(current.id, of: upstream) { break }
            commits.append(current)
            current = try commit(current.parents[0])
        }
        guard !commits.isEmpty else { return nil }
        return (current.id, commits.reversed())
    }

    /// Replays `steps` onto `base` and returns the new commits, oldest first. With `apply`, the
    /// branch moves there and the folder follows (a checkpoint first, then one undoable step);
    /// without it nothing changes: the preview. Original authors and dates are kept.
    @discardableResult
    public func rewriteHistory(base: ObjectID, steps: [HistoryStep], committer: Signature, apply: Bool) throws -> [CommitInfo] {
        guard let branch = try head().branch else { throw HistoryError.notOnABranch }
        if apply {
            let edited = try status().entries.filter { $0.kind != .untracked }
            guard edited.isEmpty else { throw HistoryError.uncommittedChanges(count: edited.count) }
        }
        // New commits so far: (id, info) with info as written.
        var made: [CommitInfo] = []
        for step in steps {
            if case .drop = step.action { continue }
            let original = try commit(step.commit)
            let onto = made.last?.id ?? base
            let tree = try cherryPickTree(step.commit, onto: onto, summary: original.summary)
            let author = Signature(name: original.authorName, email: original.authorEmail)
            switch step.action {
            case .pick, .reword:
                var message = original.message
                if case .reword(let text) = step.action { message = text.hasSuffix("\n") ? text : text + "\n" }
                let id = try createCommit(updating: nil, tree: tree, parents: [onto], message: message, author: author, date: original.date)
                made.append(try commit(id))
            case .squash, .fixup:
                guard let previous = made.popLast() else { throw HistoryError.nothingToJoin(summary: original.summary) }
                var message = previous.message
                if case .squash = step.action {
                    message = message.trimmingCharacters(in: .newlines) + "\n\n" + original.message
                }
                let id = try createCommit(updating: nil, tree: tree, parents: previous.parents, message: message,
                                          author: Signature(name: previous.authorName, email: previous.authorEmail), date: previous.date)
                made.append(try commit(id))
            case .drop:
                break
            }
        }
        guard apply else { return made }
        let newTip = made.last?.id ?? base
        let title = "Edit history (\(made.count) commit\(made.count == 1 ? "" : "s"))"
        try checkpoint(.manual)
        try recordingUndo(.history, title) {
            try setReference("refs/heads/\(branch)", to: newTip, log: "omnie: \(title.lowercased())")
            try checkoutTrackedFiles(of: try commit(newTip).tree)
        }
        return made
    }

    /// The tree of `commit`'s change applied on top of `onto`, in memory.
    private func cherryPickTree(_ commitID: ObjectID, onto: ObjectID, summary: String) throws -> ObjectID {
        var pickOid = commitID.oid, ontoOid = onto.oid
        var pick: OpaquePointer?, ours: OpaquePointer?
        try check(git_commit_lookup(&pick, pointer, &pickOid), "read commit")
        defer { git_commit_free(pick) }
        try check(git_commit_lookup(&ours, pointer, &ontoOid), "read commit")
        defer { git_commit_free(ours) }
        var index: OpaquePointer?
        try check(git_cherrypick_commit(&index, pointer, pick, ours, 0, nil), "replay \(summary)")
        defer { git_index_free(index) }
        let conflicts = try conflictedPaths(in: index!)
        guard conflicts.isEmpty else { throw HistoryError.conflict(summary: summary, paths: conflicts) }
        var treeOid = git_oid()
        try check(git_index_write_tree_to(&treeOid, index, pointer), "write tree")
        return ObjectID(treeOid)
    }

    /// Makes the tracked files match `tree` (untracked files stay), then the index.
    private func checkoutTrackedFiles(of tree: ObjectID) throws {
        var treeOid = tree.oid
        var treeObj: OpaquePointer?
        try check(git_tree_lookup(&treeObj, pointer, &treeOid), "read tree")
        defer { git_tree_free(treeObj) }
        var opts = git_checkout_options()
        git_checkout_options_init(&opts, UInt32(GIT_CHECKOUT_OPTIONS_VERSION))
        opts.checkout_strategy = GIT_CHECKOUT_FORCE.rawValue
        try check(git_checkout_tree(pointer, treeObj, &opts), "update files")
        try resetIndexToHead()
    }

    private func isAncestor(_ commit: ObjectID, of other: ObjectID) throws -> Bool {
        var a = commit.oid, b = other.oid
        return git_graph_descendant_of(pointer, &b, &a) == 1
    }
}
