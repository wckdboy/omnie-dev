// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

import Clibgit2
import Foundation

/// Timeline operations one level down (PLAN.md §9.10): tags, reset that keeps your changes, and
/// the reflog ("Show everything").
public enum RefOpError: Error, Sendable, Equatable, LocalizedError {
    case badTagName(String)
    case tagExists(String)
    /// The commits a reset would drop are on the remote already.
    case alreadyPushed
    case notOnABranch

    public var errorDescription: String? {
        switch self {
        case .badTagName(let n): "“\(n)” isn't a valid tag name."
        case .tagExists(let n): "A tag “\(n)” exists already."
        case .alreadyPushed: "Those commits are on the remote, so resetting would rewrite shared history. Revert them instead."
        case .notOnABranch: "Switch to a branch first."
        }
    }
}

/// One reflog line: where HEAD was and why.
public struct ReflogEntry: Sendable, Hashable, Identifiable {
    public var id: Int { index }
    public let index: Int
    public let commit: ObjectID
    public let message: String
    public let date: Date
}

extension Repository {
    /// Tags by the commit they point at (annotated tags peeled).
    public func tags() throws -> [ObjectID: [String]] {
        var names = git_strarray()
        try check(git_tag_list(&names, pointer), "list tags")
        defer { git_strarray_dispose(&names) }
        var result: [ObjectID: [String]] = [:]
        for i in 0..<names.count {
            guard let cName = names.strings[i] else { continue }
            let name = String(cString: cName)
            var object: OpaquePointer?
            guard git_revparse_single(&object, pointer, "refs/tags/\(name)^{commit}") == 0 else { continue }
            defer { git_object_free(object) }
            result[ObjectID(git_object_id(object)), default: []].append(name)
        }
        return result.mapValues { $0.sorted() }
    }

    /// An annotated tag on `commit` (lightweight when `message` is empty).
    public func tag(_ name: String, at commit: ObjectID, message: String = "", tagger: Signature) throws {
        var valid: Int32 = 0
        guard git_tag_name_is_valid(&valid, name) == 0, valid == 1 else { throw RefOpError.badTagName(name) }
        var oid = commit.oid
        var target: OpaquePointer?
        try check(git_object_lookup(&target, pointer, &oid, GIT_OBJECT_COMMIT), "read commit")
        defer { git_object_free(target) }
        var out = git_oid()
        let rc: Int32
        if message.isEmpty {
            rc = git_tag_create_lightweight(&out, pointer, name, target, 0)
        } else {
            var sig: UnsafeMutablePointer<git_signature>?
            try check(git_signature_now(&sig, tagger.name, tagger.email), "signature")
            defer { git_signature_free(sig) }
            rc = git_tag_create(&out, pointer, name, target, sig, message, 0)
        }
        if rc == GIT_EEXISTS.rawValue { throw RefOpError.tagExists(name) }
        try check(rc, "tag \(name)")
    }

    public func deleteTag(_ name: String) throws {
        try check(git_tag_delete(pointer, name), "delete tag \(name)")
    }

    /// Moves the branch to `commit` and keeps the folder as it is: what the dropped commits
    /// changed becomes uncommitted (`git reset --mixed`). Undoable; refuses pushed commits.
    public func resetKeepingChanges(to commit: ObjectID) throws {
        guard let branch = try head().branch, let tip = try head().commit else { throw RefOpError.notOnABranch }
        guard tip != commit else { return }
        if try isOnRemote(tip) { throw RefOpError.alreadyPushed }
        try checkpoint(.manual)
        try recordingUndo(.commit, "Reset to \(commit.short)") {
            try setReference("refs/heads/\(branch)", to: commit, log: "omnie: reset to \(commit.short)")
            try resetIndexToHead()
        }
    }

    /// Where HEAD has been, newest first (`git reflog`).
    public func reflog(limit: Int = 200) throws -> [ReflogEntry] {
        var log: OpaquePointer?
        try check(git_reflog_read(&log, pointer, "HEAD"), "read reflog")
        defer { git_reflog_free(log) }
        var result: [ReflogEntry] = []
        for i in 0..<min(git_reflog_entrycount(log), limit) {
            guard let entry = git_reflog_entry_byindex(log, i), let id = git_reflog_entry_id_new(entry) else { continue }
            let message = git_reflog_entry_message(entry).map { String(cString: $0) } ?? ""
            let when = git_reflog_entry_committer(entry)?.pointee.when.time ?? 0
            result.append(ReflogEntry(index: i, commit: ObjectID(id), message: message, date: Date(timeIntervalSince1970: TimeInterval(when))))
        }
        return result
    }
}
