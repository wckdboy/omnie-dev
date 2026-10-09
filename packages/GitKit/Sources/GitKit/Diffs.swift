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

/// One hunk of a unified diff, for reviewing a changeset hunk by hunk.
public struct DiffHunk: Sendable, Hashable, Identifiable {
    public var id: Int { index }
    public let index: Int
    public let header: String
    /// 1-based start and line count in the old and new file.
    public let oldStart: Int, oldCount: Int, newStart: Int, newCount: Int
    /// Lines with their " ", "-" or "+" prefix.
    public let lines: [String]

    public var removed: [String] { lines.filter { $0.hasPrefix("-") }.map { String($0.dropFirst()) } }
    public var added: [String] { lines.filter { $0.hasPrefix("+") }.map { String($0.dropFirst()) } }
}

extension FileDiff {
    /// The hunks in this file's patch.
    public var hunks: [DiffHunk] {
        var hunks: [DiffHunk] = []
        var current: (header: String, numbers: [Int], lines: [String])?
        func flush() {
            if let c = current, c.numbers.count == 4 {
                hunks.append(DiffHunk(index: hunks.count, header: c.header, oldStart: c.numbers[0], oldCount: c.numbers[1],
                                      newStart: c.numbers[2], newCount: c.numbers[3], lines: c.lines))
            }
        }
        for line in patch.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if line.hasPrefix("@@"), let m = line.firstMatch(of: /@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@/) {
                flush()
                current = (line, [Int(m.1)!, m.2.flatMap { Int($0) } ?? 1, Int(m.3)!, m.4.flatMap { Int($0) } ?? 1], [])
            } else if current != nil, let first = line.first, first == " " || first == "-" || first == "+" {
                current?.lines.append(line)
            }
        }
        flush()
        return hunks
    }

    /// The new file's text with the given hunks undone (their old lines put back). Hunks are undone
    /// from the bottom up, so earlier line numbers stay valid.
    public static func revert(_ hunks: [DiffHunk], in newText: String) -> String {
        let trailingNewline = newText.hasSuffix("\n")
        var lines = newText.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if trailingNewline { lines.removeLast() }
        for hunk in hunks.sorted(by: { $0.newStart > $1.newStart }) {
            // The hunk's new lines (context and additions) start at newStart; in git, a count of 0
            // means the hunk sits after line newStart.
            let start = hunk.newCount == 0 ? hunk.newStart : hunk.newStart - 1
            let newLines = hunk.lines.filter { !$0.hasPrefix("-") }.map { String($0.dropFirst()) }
            let oldLines = hunk.lines.filter { !$0.hasPrefix("+") }.map { String($0.dropFirst()) }
            let end = min(start + newLines.count, lines.count)
            lines.replaceSubrange(max(0, start)..<end, with: oldLines)
        }
        return lines.joined(separator: "\n") + (trailingNewline || lines.isEmpty ? "\n" : "")
    }
}

extension FileDiff {
    /// Two texts compared with git's diff (the diff tool, PLAN.md §11.1: same engine as reviews and
    /// the conflict resolver). `context` lines around each change.
    public static func texts(_ old: String, _ new: String, oldName: String = "a", newName: String = "b", context: Int = 3) -> FileDiff {
        _ = Libgit2.initialize
        var options = git_diff_options()
        git_diff_options_init(&options, UInt32(GIT_DIFF_OPTIONS_VERSION))
        options.context_lines = UInt32(context)
        var patch: OpaquePointer?
        let oldData = Array(old.utf8), newData = Array(new.utf8)
        let status = oldData.withUnsafeBufferPointer { o in
            newData.withUnsafeBufferPointer { n in
                git_patch_from_buffers(&patch, o.baseAddress, o.count, oldName, n.baseAddress, n.count, newName, &options)
            }
        }
        defer { git_patch_free(patch) }
        guard status == 0, let patch else {
            return FileDiff(path: newName, kind: .modified, additions: 0, deletions: 0, isBinary: false, patch: "")
        }
        var additions = 0, deletions = 0
        git_patch_line_stats(nil, &additions, &deletions, patch)
        var buf = git_buf()
        defer { git_buf_dispose(&buf) }
        let text = git_patch_to_buf(&buf, patch) == 0
            ? buf.ptr.map { String(decoding: UnsafeRawBufferPointer(start: $0, count: buf.size), as: UTF8.self) } ?? "" : ""
        return FileDiff(path: newName, kind: .modified, additions: additions, deletions: deletions, isBinary: false, patch: text)
    }
}
