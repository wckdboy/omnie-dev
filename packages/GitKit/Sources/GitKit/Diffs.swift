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
