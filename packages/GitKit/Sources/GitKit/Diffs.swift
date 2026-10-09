// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

import Clibgit2
import Foundation

/// A line that the next commit-all would add.
public struct AddedLine: Sendable, Hashable {
    public let path: String
    /// 1-based line number in the new file.
    public let line: Int
    public let text: String
}

extension Repository {
    /// Every line the next `commitAll` would add: the working tree (untracked files included,
    /// ignored files not) against HEAD. Binary files are skipped. Used to scan for secrets before
    /// commit (PLAN.md §12). Stops after `limit` lines so a huge generated file can't stall the check.
    public func pendingAddedLines(limit: Int = 200_000) throws -> [AddedLine] {
        var tree: OpaquePointer?
        if let commit = try head().commit {
            var oid = try treeOf(commit).oid
            try check(git_tree_lookup(&tree, pointer, &oid), "read tree")
        }
        defer { git_tree_free(tree) }

        var opts = git_diff_options()
        git_diff_options_init(&opts, UInt32(GIT_DIFF_OPTIONS_VERSION))
        opts.flags = GIT_DIFF_INCLUDE_UNTRACKED.rawValue | GIT_DIFF_RECURSE_UNTRACKED_DIRS.rawValue
            | GIT_DIFF_SHOW_UNTRACKED_CONTENT.rawValue
        opts.context_lines = 0
        var diff: OpaquePointer?
        try check(git_diff_tree_to_workdir_with_index(&diff, pointer, tree, &opts), "diff working tree")
        defer { git_diff_free(diff) }

        final class Collector {
            var lines: [AddedLine] = []
            let limit: Int
            init(limit: Int) { self.limit = limit }
        }
        let collector = Collector(limit: limit)
        let payload = Unmanaged.passUnretained(collector).toOpaque()
        let rc = git_diff_foreach(diff, nil, nil, nil, { delta, _, line, payload in
            guard let delta, let line, let payload else { return 0 }
            let collector = Unmanaged<Collector>.fromOpaque(payload).takeUnretainedValue()
            guard line.pointee.origin == CChar(UInt8(ascii: "+")) else { return 0 }
            if collector.lines.count >= collector.limit { return 1 }   // stop early
            let path = delta.pointee.new_file.path.map { String(cString: $0) } ?? ""
            let bytes = UnsafeRawBufferPointer(start: line.pointee.content, count: line.pointee.content_len)
            var text = String(decoding: bytes, as: UTF8.self)
            if text.hasSuffix("\n") { text.removeLast() }
            collector.lines.append(AddedLine(path: path, line: Int(line.pointee.new_lineno), text: text))
            return 0
        }, payload)
        // 1 is our own early stop, not an error.
        if rc != 1 { try check(rc, "read diff") }
        return collector.lines
    }
}

/// One file's change between two commits, for reviewing an agent's changeset.
public struct FileDiff: Sendable, Hashable, Identifiable {
    public enum Kind: String, Sendable { case added, modified, deleted, renamed }
    public var id: String { path }
    public let path: String
    public let kind: Kind
    public let additions: Int
    public let deletions: Int
    public let isBinary: Bool
    /// The unified diff for this file (`diff --git` header and hunks).
    public let patch: String
}

extension Repository {
    /// What changed from `old` (nil: an empty tree) to `new`, file by file.
    public func diff(from old: ObjectID?, to new: ObjectID) throws -> [FileDiff] {
        func tree(_ commit: ObjectID?) throws -> OpaquePointer? {
            guard let commit else { return nil }
            var oid = try treeOf(commit).oid
            var tree: OpaquePointer?
            try check(git_tree_lookup(&tree, pointer, &oid), "read tree")
            return tree
        }
        let oldTree = try tree(old), newTree = try tree(new)
        defer { git_tree_free(oldTree); git_tree_free(newTree) }
        var diff: OpaquePointer?
        try check(git_diff_tree_to_tree(&diff, pointer, oldTree, newTree, nil), "diff")
        defer { git_diff_free(diff) }
        var findOptions = git_diff_find_options()
        git_diff_find_options_init(&findOptions, UInt32(GIT_DIFF_FIND_OPTIONS_VERSION))
        try check(git_diff_find_similar(diff, &findOptions), "find renames")

        var files: [FileDiff] = []
        for i in 0..<git_diff_num_deltas(diff) {
            guard let delta = git_diff_get_delta(diff, i) else { continue }
            let path = (delta.pointee.new_file.path ?? delta.pointee.old_file.path).map { String(cString: $0) } ?? ""
            let kind: FileDiff.Kind = switch delta.pointee.status {
            case GIT_DELTA_ADDED: .added
            case GIT_DELTA_DELETED: .deleted
            case GIT_DELTA_RENAMED: .renamed
            default: .modified
            }
            var patch: OpaquePointer?
            try check(git_patch_from_diff(&patch, diff, i), "read patch")
            defer { git_patch_free(patch) }
            var additions = 0, deletions = 0
            git_patch_line_stats(nil, &additions, &deletions, patch)
            var buf = git_buf()
            try check(git_patch_to_buf(&buf, patch), "print patch")
            defer { git_buf_dispose(&buf) }
            let text = buf.ptr.map { String(decoding: UnsafeRawBufferPointer(start: $0, count: buf.size), as: UTF8.self) } ?? ""
            files.append(FileDiff(path: path, kind: kind, additions: additions, deletions: deletions,
                                  isBinary: delta.pointee.flags & GIT_DIFF_FLAG_BINARY.rawValue != 0, patch: text))
        }
        return files
    }
}
