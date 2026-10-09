// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

import Clibgit2
import Foundation

/// A run of lines last changed by one commit (PLAN.md §9.10 blame).
public struct BlameHunk: Sendable, Hashable {
    /// 1-based first line, and how many.
    public let startLine: Int
    public let lineCount: Int
    /// nil for lines that aren't committed yet.
    public let commit: ObjectID?
    public let author: String
    public let date: Date?
    public let summary: String
    /// The model id when the commit came from the agent (its `Assisted-by` trailer).
    public let assistedBy: String?

    public var lines: ClosedRange<Int> { startLine...(startLine + max(lineCount, 1) - 1) }
}

extension Repository {
    /// Who last changed each line of `path`. With `contents` (the editor's text), lines you
    /// haven't committed come back with no commit.
    public func blame(path: String, contents: String? = nil) throws -> [BlameHunk] {
        guard try head().commit != nil else { return [] }
        var opts = git_blame_options()
        git_blame_options_init(&opts, UInt32(GIT_BLAME_OPTIONS_VERSION))
        var blame: OpaquePointer?
        try check(git_blame_file(&blame, pointer, path, &opts), "blame \(path)")
        if let contents {
            // The committed blame, re-applied to the editor's text (libgit2 1.9 has no
            // blame-from-buffer of its own).
            var live: OpaquePointer?
            let bytes = Array(contents.utf8CString)
            let rc = git_blame_buffer(&live, blame, bytes, bytes.count - 1)
            git_blame_free(blame)
            try check(rc, "blame \(path)")
            blame = live
        }
        defer { git_blame_free(blame) }
        var messages: [ObjectID: CommitInfo] = [:]
        var result: [BlameHunk] = []
        for i in 0..<git_blame_hunkcount(blame) {
            guard let hunk = git_blame_hunk_byindex(blame, i)?.pointee else { continue }
            let id = ObjectID(hunk.final_commit_id)
            let committed = !id.isZero
            var info: CommitInfo?
            if committed {
                info = messages[id] ?? (try? commit(id))
                messages[id] = info
            }
            let author = committed ? (hunk.final_signature.map { String(cString: $0.pointee.name) } ?? info?.authorName ?? "?") : "You"
            result.append(BlameHunk(startLine: Int(hunk.final_start_line_number), lineCount: Int(hunk.lines_in_hunk),
                                    commit: committed ? id : nil, author: author, date: info?.date,
                                    summary: info?.summary ?? "Not committed yet", assistedBy: info?.assistedBy))
        }
        return result
    }
}
