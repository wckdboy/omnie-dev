import Clibgit2
import Foundation

/// One conflicted file, with all three sides and a starting result (PLAN.md §9.7).
public struct ConflictFile: Sendable, Hashable, Identifiable {
    public var id: String { path }
    public let path: String
    public let base: String?
    /// Your side.
    public let ours: String?
    public let theirs: String?
    /// A three-way merge with conflict markers where the sides disagree.
    public let merged: String
    public let isBinary: Bool

    public static let markerPrefixes = ["<<<<<<< ", "=======", ">>>>>>> "]

    public enum Side: Sendable { case ours, theirs, both }

    /// Resolves every conflict block in `text` to one side (or both, yours first), keeping
    /// everything outside the blocks: the parts git already merged cleanly from both sides.
    public static func resolving(_ text: String, to side: Side) -> String {
        enum State { case outside, ours, theirs }
        var state = State.outside
        var out: [Substring] = []
        var ours: [Substring] = [], theirs: [Substring] = []
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        for line in lines {
            switch state {
            case .outside:
                if line.hasPrefix("<<<<<<< ") { state = .ours; ours = []; theirs = [] } else { out.append(line) }
            case .ours:
                if line == "=======" { state = .theirs } else { ours.append(line) }
            case .theirs:
                if line.hasPrefix(">>>>>>> ") {
                    switch side {
                    case .ours: out += ours
                    case .theirs: out += theirs
                    case .both: out += ours + theirs
                    }
                    state = .outside
                } else {
                    theirs.append(line)
                }
            }
        }
        return out.joined(separator: "\n")
    }

    /// True while `text` still has conflict markers.
    public static func hasMarkers(_ text: String) -> Bool {
        text.split(separator: "\n", omittingEmptySubsequences: false).contains { line in
            line.hasPrefix("<<<<<<< ") || line == "=======" || line.hasPrefix(">>>>>>> ")
        }
    }
}

/// A merge computed in memory; nothing in the working tree changes until `completeMerge`.
public struct MergeSession: Sendable, Hashable {
    public let base: ObjectID
    public let ours: ObjectID
    public let theirs: ObjectID
    public let conflicts: [ConflictFile]
}

public enum ResolveError: Error, Sendable, Equatable {
    case unresolved(paths: [String])
    case stillHasMarkers(path: String)
    /// HEAD moved since the merge was prepared; prepare it again.
    case stale
}

extension Repository {
    /// Three-way merges `theirs` into HEAD in memory and returns the conflicts to resolve.
    public func prepareMerge(with theirs: ObjectID) throws -> MergeSession {
        guard let ours = try head().commit else { throw GitKitError.nothingToCommit }
        var o = ours.oid, t = theirs.oid, b = git_oid()
        try check(git_merge_base(&b, pointer, &o, &t), "find merge base")
        let base = ObjectID(b)
        let index = try mergedIndex(base: base, ours: ours, theirs: theirs)
        defer { git_index_free(index) }
        return MergeSession(base: base, ours: ours, theirs: theirs, conflicts: try readConflicts(index))
    }

    /// Writes the resolved merge as one commit on HEAD and updates the working tree.
    /// - `asMergeCommit`: true records both parents (Sync); false makes a single-parent commit (squash).
    @discardableResult
    public func completeMerge(_ session: MergeSession, resolutions: [String: String], message: String,
                              author: Signature, asMergeCommit: Bool, date: Date = .now) throws -> CommitInfo {
        guard try head().commit == session.ours else { throw ResolveError.stale }
        let missing = session.conflicts.map(\.path).filter { resolutions[$0] == nil }
        guard missing.isEmpty else { throw ResolveError.unresolved(paths: missing) }
        for (path, text) in resolutions where ConflictFile.hasMarkers(text) {
            throw ResolveError.stillHasMarkers(path: path)
        }
        let tracked = try status().entries.filter { $0.kind != .untracked }
        guard tracked.isEmpty else { throw MergeError.uncommittedChanges(count: tracked.count) }

        let index = try mergedIndex(base: session.base, ours: session.ours, theirs: session.theirs)
        defer { git_index_free(index) }
        for conflict in session.conflicts {
            let text = resolutions[conflict.path]!
            var blob = git_oid()
            try check(git_blob_create_from_buffer(&blob, pointer, text, text.utf8.count), "store \(conflict.path)")
            let mode = try conflictMode(index, conflict.path)
            try check(git_index_conflict_remove(index, conflict.path), "resolve \(conflict.path)")
            try conflict.path.withCString { cPath in
                var entry = git_index_entry()
                entry.path = cPath
                entry.mode = mode
                entry.id = blob
                try check(git_index_add(index, &entry), "add \(conflict.path)")
            }
        }
        var treeOid = git_oid()
        try check(git_index_write_tree_to(&treeOid, index, pointer), "write merged tree")

        try checkpoint(.agentApply)
        let parents = asMergeCommit ? [session.ours, session.theirs] : [session.ours]
        var text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.hasSuffix("\n") { text += "\n" }
        let id = try createCommit(updating: "HEAD", tree: ObjectID(treeOid), parents: parents,
                                  message: text, author: author, date: date)
        try checkout(commit: id, removeUntracked: false)
        return try commit(id)
    }

    // MARK: Helpers

    func mergedIndex(base: ObjectID, ours: ObjectID, theirs: ObjectID) throws -> OpaquePointer {
        var trees: [OpaquePointer?] = []
        defer { trees.forEach { git_tree_free($0) } }
        for commit in [base, ours, theirs] {
            var oid = try treeOf(commit).oid
            var tree: OpaquePointer?
            try check(git_tree_lookup(&tree, pointer, &oid), "read tree")
            trees.append(tree)
        }
        var index: OpaquePointer?
        try check(git_merge_trees(&index, pointer, trees[0], trees[1], trees[2], nil), "merge")
        return index!
    }

    private func conflictMode(_ index: OpaquePointer, _ path: String) throws -> UInt32 {
        var a: UnsafePointer<git_index_entry>?, o: UnsafePointer<git_index_entry>?, t: UnsafePointer<git_index_entry>?
        try check(git_index_conflict_get(&a, &o, &t, index, path), "read conflict \(path)")
        return (o ?? t ?? a)?.pointee.mode ?? GIT_FILEMODE_BLOB.rawValue
    }

    private func readConflicts(_ index: OpaquePointer) throws -> [ConflictFile] {
        guard git_index_has_conflicts(index) == 1 else { return [] }
        var iterator: OpaquePointer?
        try check(git_index_conflict_iterator_new(&iterator, index), "read conflicts")
        defer { git_index_conflict_iterator_free(iterator) }

        var result: [ConflictFile] = []
        var a: UnsafePointer<git_index_entry>?, o: UnsafePointer<git_index_entry>?, t: UnsafePointer<git_index_entry>?
        while git_index_conflict_next(&a, &o, &t, iterator) == 0 {
            guard let entry = (o ?? t ?? a)?.pointee, let cPath = entry.path else { continue }
            let path = String(cString: cPath)
            let sides = try [a, o, t].map { try $0.map { try blobData($0.pointee.id) } }
            let isBinary = sides.contains { $0?.contains(0) == true }
            let text = sides.map { $0.map { String(decoding: $0, as: UTF8.self) } }
            let merged = isBinary ? "" : try Self.mergeFile(path: path, base: sides[0], ours: sides[1], theirs: sides[2])
            result.append(ConflictFile(path: path, base: text[0], ours: text[1], theirs: text[2],
                                       merged: merged, isBinary: isBinary))
        }
        return result.sorted { $0.path < $1.path }
    }

    private func blobData(_ id: git_oid) throws -> Data {
        var oid = id
        var blob: OpaquePointer?
        try check(git_blob_lookup(&blob, pointer, &oid), "read blob")
        defer { git_blob_free(blob) }
        return Data(bytes: git_blob_rawcontent(blob), count: Int(git_blob_rawsize(blob)))
    }

    /// Line-level three-way merge with markers labeled "Yours" and "Theirs". Pure: needs no repository.
    private nonisolated static func mergeFile(path: String, base: Data?, ours: Data?, theirs: Data?) throws -> String {
        let b = base ?? Data(), o = ours ?? Data(), t = theirs ?? Data()
        return try b.withUnsafeBytes { bRaw in
            try o.withUnsafeBytes { oRaw in
                try t.withUnsafeBytes { tRaw in
                    var inputs = [bRaw, oRaw, tRaw].map { raw -> git_merge_file_input in
                        var input = git_merge_file_input()
                        git_merge_file_input_init(&input, UInt32(GIT_MERGE_FILE_INPUT_VERSION))
                        input.ptr = raw.baseAddress?.assumingMemoryBound(to: CChar.self)
                        input.size = raw.count
                        input.mode = GIT_FILEMODE_BLOB.rawValue
                        return input
                    }
                    var opts = git_merge_file_options()
                    git_merge_file_options_init(&opts, UInt32(GIT_MERGE_FILE_OPTIONS_VERSION))
                    let ourLabel = strdup("Yours"), theirLabel = strdup("Theirs")
                    defer { free(ourLabel); free(theirLabel) }
                    opts.our_label = UnsafePointer(ourLabel)
                    opts.their_label = UnsafePointer(theirLabel)
                    var result = git_merge_file_result()
                    try check(git_merge_file(&result, &inputs[0], &inputs[1], &inputs[2], &opts), "merge \(path)")
                    defer { git_merge_file_result_free(&result) }
                    guard let ptr = result.ptr else { return "" }
                    return String(decoding: UnsafeRawBufferPointer(start: ptr, count: result.len), as: UTF8.self)
                }
            }
        }
    }
}
