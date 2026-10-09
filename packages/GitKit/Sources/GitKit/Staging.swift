// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

import Clibgit2
import Foundation

/// Hunk and line staging, the escape hatch under "commit everything" (PLAN.md §9.10): choose
/// changes into the index, then commit the index. Works on text: the index's version of a file,
/// the working version and the chosen lines give the new index version.
public enum Staging {
    /// A changed line: which hunk of the diff, which line of that hunk (counting its context lines).
    public struct LineRef: Sendable, Hashable, Comparable {
        public let hunk: Int
        public let line: Int
        public init(hunk: Int, line: Int) { self.hunk = hunk; self.line = line }
        public static func < (a: LineRef, b: LineRef) -> Bool { (a.hunk, a.line) < (b.hunk, b.line) }
    }

    /// Every changed (`+`/`-`) line of `diff`.
    public static func allChanges(_ diff: FileDiff) -> Set<LineRef> {
        var refs: Set<LineRef> = []
        for hunk in diff.hunks {
            for (i, line) in hunk.lines.enumerated() where line.hasPrefix("+") || line.hasPrefix("-") {
                refs.insert(LineRef(hunk: hunk.index, line: i))
            }
        }
        return refs
    }

    /// `base` with the `selected` changes of the diff from `base` to `target` (`FileDiff.texts`
    /// with its default context, the diff the references were taken from) applied, the rest left
    /// out: a selected `-` line goes, an unselected one stays; a selected `+` line comes in, an
    /// unselected one doesn't.
    public static func apply(base: String, target: String, selected: Set<LineRef>) -> String {
        // Same context as the diffs the line references come from (stagingStatus, stage, unstage).
        let diff = FileDiff.texts(base, target)
        let baseHasNewline = base.hasSuffix("\n") || base.isEmpty
        var lines = base.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if base.hasSuffix("\n") || base.isEmpty { lines.removeLast() }
        var result: [String] = []
        var cursor = 0 // next base line (0-based) not yet copied
        var touchedEnd = false
        for hunk in diff.hunks {
            // A hunk with no old lines sits after line oldStart; otherwise it starts at oldStart.
            let start = hunk.oldCount == 0 ? hunk.oldStart : hunk.oldStart - 1
            if start > cursor { result.append(contentsOf: lines[cursor..<min(start, lines.count)]) }
            cursor = max(cursor, start)
            for (i, line) in hunk.lines.enumerated() {
                let text = String(line.dropFirst())
                let chosen = selected.contains(LineRef(hunk: hunk.index, line: i))
                switch line.first {
                case "-":
                    if !chosen { result.append(text) } else if cursor == lines.count - 1 { touchedEnd = true }
                    cursor += 1
                case "+":
                    if chosen {
                        result.append(text)
                        if cursor >= lines.count { touchedEnd = true }
                    }
                default:
                    result.append(text)
                    cursor += 1
                }
            }
        }
        if cursor < lines.count { result.append(contentsOf: lines[cursor...]) }
        // The final newline follows the target when the change at the end of the file was taken.
        let newline = touchedEnd ? (target.hasSuffix("\n") || target.isEmpty) : baseHasNewline
        if result.isEmpty { return "" }
        return result.joined(separator: "\n") + (newline ? "\n" : "")
    }
}

/// A file with changes, split into what's staged and what isn't.
public struct StagingFile: Sendable, Hashable, Identifiable {
    public var id: String { path }
    public let path: String
    /// HEAD → index.
    public let staged: FileDiff?
    /// Index → working tree (new files: empty → their text).
    public let unstaged: FileDiff?
}

public enum StagingError: Error, Sendable, Equatable, LocalizedError {
    case binary(String)
    case nothingStaged

    public var errorDescription: String? {
        switch self {
        case .binary(let p): "\(p) is binary; stage it whole."
        case .nothingStaged: "Nothing is staged."
        }
    }
}

extension Repository {
    /// The changed files with their staged and unstaged diffs (text files; binary ones show as
    /// changed with no lines).
    public func stagingStatus() throws -> [StagingFile] {
        try status().entries.map { entry in
            let head = try text(of: entry.path, in: .head)
            let index = try text(of: entry.path, in: .index)
            let work = try text(of: entry.path, in: .workingTree)
            let staged = head == index ? nil : FileDiff.texts(head ?? "", index ?? "", oldName: entry.path, newName: entry.path)
            let unstaged = index == work ? nil : FileDiff.texts(index ?? "", work ?? "", oldName: entry.path, newName: entry.path)
            return StagingFile(path: entry.path, staged: staged, unstaged: unstaged)
        }.filter { $0.staged != nil || $0.unstaged != nil }
    }

    /// Stages `lines` of the index → working-tree diff of `path` (all of it when nil).
    public func stage(_ path: String, lines: Set<Staging.LineRef>? = nil) throws {
        let index = try text(of: path, in: .index)
        let work = try text(of: path, in: .workingTree)
        guard let lines else {
            try setIndexEntry(path, to: work)
            return
        }
        let diff = FileDiff.texts(index ?? "", work ?? "")
        let chosen = lines.intersection(Staging.allChanges(diff))
        try setIndexEntry(path, to: Staging.apply(base: index ?? "", target: work ?? "", selected: chosen))
    }

    /// Takes `lines` of the staged (HEAD → index) diff of `path` back out (all of it when nil).
    public func unstage(_ path: String, lines: Set<Staging.LineRef>? = nil) throws {
        let head = try text(of: path, in: .head)
        let index = try text(of: path, in: .index)
        guard let lines else {
            try setIndexEntry(path, to: head)
            return
        }
        // Unstaging a change = staging its reverse: from the index back towards HEAD.
        let diff = FileDiff.texts(head ?? "", index ?? "")
        let keep = Staging.allChanges(diff).subtracting(lines)
        try setIndexEntry(path, to: Staging.apply(base: head ?? "", target: index ?? "", selected: keep))
    }

    /// Commits what's staged, and only that (the rest stays in the folder, unstaged). Undoable.
    @discardableResult
    public func commitIndex(message: String, author: Signature, date: Date = .now) throws -> CommitInfo {
        let summary = message.split(separator: "\n").first.map(String.init) ?? ""
        return try recordingUndo(.commit, "Commit “\(summary)”") {
            let head = try head()
            let index = try repositoryIndex()
            defer { git_index_free(index) }
            try check(git_index_read(index, 1), "read index")
            let tree = try writeTree(index)
            guard tree != (try head.commit.map(treeOf) ?? .emptyTree) else { throw StagingError.nothingStaged }
            let id = try createCommit(updating: "HEAD", tree: tree, parents: head.commit.map { [$0] } ?? [],
                                      message: message, author: author, date: date)
            return try commit(id)
        }
    }

    // MARK: Text of a file in HEAD, the index or the folder

    public enum Place: Sendable { case head, index, workingTree }

    /// nil when the file isn't there.
    public func text(of path: String, in place: Place) throws -> String? {
        let data: Data?
        switch place {
        case .workingTree:
            data = FileManager.default.contents(atPath: workdir.appending(path: path).path(percentEncoded: false))
        case .index:
            let index = try repositoryIndex()
            defer { git_index_free(index) }
            try check(git_index_read(index, 1), "read index")
            guard let entry = git_index_get_bypath(index, path, 0) else { return nil }
            data = try blobData(ObjectID(entry.pointee.id))
        case .head:
            guard let commit = try head().commit else { return nil }
            var treeOid = try treeOf(commit).oid
            var tree: OpaquePointer?
            try check(git_tree_lookup(&tree, pointer, &treeOid), "read tree")
            defer { git_tree_free(tree) }
            var entry: OpaquePointer?
            guard git_tree_entry_bypath(&entry, tree, path) == 0 else { return nil }
            defer { git_tree_entry_free(entry) }
            data = try blobData(ObjectID(git_tree_entry_id(entry)!))
        }
        guard let data else { return nil }
        if data.prefix(8000).contains(0) { throw StagingError.binary(path) }
        return String(decoding: data, as: UTF8.self)
    }

    private func blobData(_ id: ObjectID) throws -> Data {
        var oid = id.oid
        var blob: OpaquePointer?
        try check(git_blob_lookup(&blob, pointer, &oid), "read blob")
        defer { git_blob_free(blob) }
        return Data(bytes: git_blob_rawcontent(blob), count: Int(git_blob_rawsize(blob)))
    }

    /// Puts `text` in the index for `path` (nil removes it), keeping the entry's mode.
    private func setIndexEntry(_ path: String, to text: String?) throws {
        let index = try repositoryIndex()
        defer { git_index_free(index) }
        try check(git_index_read(index, 1), "read index")
        guard let text else {
            if git_index_get_bypath(index, path, 0) != nil { try check(git_index_remove_bypath(index, path), "unstage \(path)") }
            try check(git_index_write(index), "write index")
            return
        }
        var entry = git_index_entry()
        if let existing = git_index_get_bypath(index, path, 0) {
            entry = existing.pointee
        } else {
            entry.mode = GIT_FILEMODE_BLOB.rawValue
        }
        let bytes = Array(text.utf8)
        try path.withCString { cPath in
            entry.path = cPath
            try check(git_index_add_from_buffer(index, &entry, bytes, bytes.count), "stage \(path)")
        }
        try check(git_index_write(index), "write index")
    }
}
