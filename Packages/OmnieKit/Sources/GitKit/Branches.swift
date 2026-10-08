import Clibgit2
import Foundation

public struct BranchInfo: Sendable, Hashable, Identifiable {
    public var id: String { name }
    public let name: String
    public let tip: ObjectID
    public let isCurrent: Bool
    public let upstream: String?
    /// Saved uncommitted work waiting on this branch (PLAN.md §9.6).
    public let hasWorkInProgress: Bool

    /// Agent task branches are shown in violet.
    public var isAgentTask: Bool { name.hasPrefix(Repository.agentBranchPrefix) }
}

public enum BranchError: Error, Sendable, Equatable {
    case alreadyExists(String)
    case notFound(String)
    case isCurrent(String)
    /// The work saved on the target branch no longer applies cleanly; it's kept on refs/wip/<branch>.
    case workInProgressDidNotApply(branch: String)
}

extension Repository {
    public func branches() throws -> [BranchInfo] {
        let current = try head().branch
        var iterator: OpaquePointer?
        try check(git_branch_iterator_new(&iterator, pointer, GIT_BRANCH_LOCAL), "list branches")
        defer { git_branch_iterator_free(iterator) }
        var result: [BranchInfo] = []
        var ref: OpaquePointer?
        var type = GIT_BRANCH_LOCAL
        while git_branch_next(&ref, &type, iterator) == 0 {
            defer { git_reference_free(ref) }
            var namePtr: UnsafePointer<CChar>?
            guard git_branch_name(&namePtr, ref) == 0, let namePtr, let tip = git_reference_target(ref) else { continue }
            let name = String(cString: namePtr)
            var up: OpaquePointer?
            var upstreamName: String?
            if git_branch_upstream(&up, ref) == 0 {
                upstreamName = String(cString: git_reference_shorthand(up))
                git_reference_free(up)
            }
            result.append(BranchInfo(name: name, tip: ObjectID(tip), isCurrent: name == current,
                                     upstream: upstreamName,
                                     hasWorkInProgress: try resolveReference(Self.wipRef(name)) != nil))
        }
        return result.sorted { ($0.isCurrent ? 0 : 1, $0.name) < ($1.isCurrent ? 0 : 1, $1.name) }
    }

    /// Creates a branch at `start` (default HEAD) without switching to it.
    @discardableResult
    public func createBranch(_ name: String, at start: ObjectID? = nil) throws -> BranchInfo {
        guard let tip = try start ?? head().commit else { throw GitKitError.nothingToCommit }
        if try resolveReference("refs/heads/\(name)") != nil { throw BranchError.alreadyExists(name) }
        var oid = tip.oid
        var commit: OpaquePointer?
        try check(git_commit_lookup(&commit, pointer, &oid), "read commit")
        defer { git_commit_free(commit) }
        var ref: OpaquePointer?
        try check(git_branch_create(&ref, pointer, name, commit, 0), "create branch \(name)")
        git_reference_free(ref)
        return BranchInfo(name: name, tip: tip, isCurrent: false, upstream: nil, hasWorkInProgress: false)
    }

    public func deleteBranch(_ name: String) throws {
        if try head().branch == name { throw BranchError.isCurrent(name) }
        var ref: OpaquePointer?
        let rc = git_branch_lookup(&ref, pointer, name, GIT_BRANCH_LOCAL)
        if rc == GIT_ENOTFOUND.rawValue { throw BranchError.notFound(name) }
        try check(rc, "find branch \(name)")
        defer { git_reference_free(ref) }
        try check(git_branch_delete(ref), "delete branch \(name)")
        try? deleteReference(Self.wipRef(name))
    }

    /// Switches branches without a stash (PLAN.md §9.6). Uncommitted work on the current branch is
    /// saved to refs/wip/<current> and the working tree is switched cleanly; if the target branch has
    /// saved work, it's put back on top. Nothing is ever discarded: a checkpoint is taken first.
    public func switchBranch(to target: String, recordUndo: Bool = true) throws {
        if try head().branch == target { return }
        if recordUndo {
            try recordingUndo(.switchBranch, "Switch to \(target)", switchedTo: target) { try performSwitch(to: target) }
        } else {
            try performSwitch(to: target)
        }
    }

    private func performSwitch(to target: String) throws {
        guard let targetTip = try resolveReference("refs/heads/\(target)") else { throw BranchError.notFound(target) }
        let head = try head()
        if head.branch == target { return }

        // 1. Save work in progress on the branch we're leaving.
        if let current = head.branch, let base = head.commit {
            try checkpoint(.branchSwitch)
            let tree = try snapshotTree()
            if tree != (try treeOf(base)) {
                let wip = try createCommit(updating: nil, tree: tree, parents: [base],
                                           message: "wip: \(current)\n", author: .checkpoint, date: .now)
                try setReference(Self.wipRef(current), to: wip, log: "wip: save \(current)")
            } else {
                try? deleteReference(Self.wipRef(current))
            }
        }

        // 2. Switch the working tree, index and HEAD to the target branch.
        try checkout(commit: targetTip, removeUntracked: true)
        try check(git_repository_set_head(pointer, "refs/heads/\(target)"), "switch to \(target)")

        // 3. Bring back the target's saved work as uncommitted changes.
        if let wip = try resolveReference(Self.wipRef(target)) {
            let wipCommit = try commit(wip)
            guard let wipBase = wipCommit.parents.first else { return }
            do {
                try applyToWorkdir(from: try treeOf(wipBase), to: wipCommit.tree)
                try deleteReference(Self.wipRef(target))
            } catch {
                throw BranchError.workInProgressDidNotApply(branch: target)
            }
        }
    }

    static func wipRef(_ branch: String) -> String { "refs/wip/\(branch)" }

    /// Forces the working tree and index to `commit`'s tree. Ignored files are left alone.
    func checkout(commit id: ObjectID, removeUntracked: Bool) throws {
        var oid = id.oid
        var commit: OpaquePointer?
        try check(git_commit_lookup(&commit, pointer, &oid), "read commit")
        defer { git_commit_free(commit) }
        var opts = git_checkout_options()
        git_checkout_options_init(&opts, UInt32(GIT_CHECKOUT_OPTIONS_VERSION))
        opts.checkout_strategy = GIT_CHECKOUT_FORCE.rawValue | (removeUntracked ? GIT_CHECKOUT_REMOVE_UNTRACKED.rawValue : 0)
        try check(git_checkout_tree(pointer, commit, &opts), "check out \(id.short)")
    }

    /// Applies the difference between two trees to the working directory only (index untouched).
    func applyToWorkdir(from old: ObjectID, to new: ObjectID) throws {
        var oldOid = old.oid, newOid = new.oid
        var oldTree: OpaquePointer?, newTree: OpaquePointer?
        try check(git_tree_lookup(&oldTree, pointer, &oldOid), "read tree")
        defer { git_tree_free(oldTree) }
        try check(git_tree_lookup(&newTree, pointer, &newOid), "read tree")
        defer { git_tree_free(newTree) }
        var diff: OpaquePointer?
        try check(git_diff_tree_to_tree(&diff, pointer, oldTree, newTree, nil), "diff")
        defer { git_diff_free(diff) }
        try check(git_apply(pointer, diff, GIT_APPLY_LOCATION_WORKDIR, nil), "apply changes")
    }

    func deleteReference(_ name: String) throws {
        var ref: OpaquePointer?
        let rc = git_reference_lookup(&ref, pointer, name)
        if rc == GIT_ENOTFOUND.rawValue { return }
        try check(rc, "find \(name)")
        defer { git_reference_free(ref) }
        try check(git_reference_delete(ref), "delete \(name)")
    }
}
