import Clibgit2
import Foundation

public struct HeadInfo: Sendable, Hashable {
    /// Branch name, nil when detached.
    public let branch: String?
    /// The commit HEAD points at, nil on an unborn branch (no commits yet).
    public let commit: ObjectID?

    public var isDetached: Bool { branch == nil }
    public var isUnborn: Bool { commit == nil }
}

public struct StatusEntry: Sendable, Hashable {
    public enum Kind: Sendable, Hashable { case added, modified, deleted, renamed, typeChanged, untracked, conflicted }
    public let path: String
    public let kind: Kind
}

public struct RepoStatus: Sendable, Hashable {
    public let head: HeadInfo
    public let entries: [StatusEntry]
    /// Commits to push and to pull, nil without an upstream.
    public let ahead: Int?
    public let behind: Int?

    public var changedCount: Int { entries.filter { $0.kind != .conflicted }.count }
    public var conflictCount: Int { entries.filter { $0.kind == .conflicted }.count }
    public var isClean: Bool { entries.isEmpty }

    /// The status strip text (PLAN.md §9.9): "main", "main · 5 changed", "main · ↑2 ↓1", "Detached at a1b2c3d".
    public var plainLanguage: String {
        guard let branch = head.branch else {
            return "Detached at \(head.commit?.short ?? "unknown")"
        }
        var parts = [branch]
        if conflictCount > 0 { parts.append("\(conflictCount) \(conflictCount == 1 ? "conflict" : "conflicts")") }
        else if changedCount > 0 { parts.append("\(changedCount) changed") }
        var arrows: [String] = []
        if let ahead, ahead > 0 { arrows.append("↑\(ahead)") }
        if let behind, behind > 0 { arrows.append("↓\(behind)") }
        if !arrows.isEmpty { parts.append(arrows.joined(separator: " ")) }
        return parts.joined(separator: " · ")
    }
}

/// One git repository. All libgit2 access for a repo goes through this actor,
/// because libgit2 objects for one repository must not be used from two threads at once.
public actor Repository {
    private let handle: Handle
    public nonisolated let workdir: URL

    /// libgit2 calls block (network, disk), so each repository runs on its own serial queue
    /// rather than on Swift's shared cooperative pool.
    private nonisolated let queue = DispatchSerialQueue(label: "ai.wckd.omniedev.git")
    public nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    /// Owns the git_repository and frees it. Only ever used from the actor, hence @unchecked.
    private final class Handle: @unchecked Sendable {
        let raw: OpaquePointer
        init(_ raw: OpaquePointer) { self.raw = raw }
        deinit { git_repository_free(raw) }
    }

    var pointer: OpaquePointer { handle.raw }

    init(adopting pointer: OpaquePointer) {
        self.handle = Handle(pointer)
        let path = git_repository_workdir(pointer).map { String(cString: $0) } ?? ""
        self.workdir = URL(filePath: path, directoryHint: .isDirectory)
    }

    public static func open(at url: URL) throws -> Repository {
        Libgit2.initialize
        var repo: OpaquePointer?
        try check(git_repository_open(&repo, url.path(percentEncoded: false)), "open \(url.lastPathComponent)")
        return Repository(adopting: repo!)
    }

    /// `git init` with `initialBranch` as the unborn HEAD.
    public static func create(at url: URL, initialBranch: String = "main") throws -> Repository {
        Libgit2.initialize
        var opts = git_repository_init_options()
        git_repository_init_options_init(&opts, UInt32(GIT_REPOSITORY_INIT_OPTIONS_VERSION))
        opts.flags = GIT_REPOSITORY_INIT_MKPATH.rawValue
        var repo: OpaquePointer?
        try initialBranch.withCString { branch in
            opts.initial_head = branch
            try check(git_repository_init_ext(&repo, url.path(percentEncoded: false), &opts), "init \(url.lastPathComponent)")
        }
        return Repository(adopting: repo!)
    }

    // MARK: HEAD and status

    public func head() throws -> HeadInfo {
        var ref: OpaquePointer?
        let rc = git_repository_head(&ref, pointer)
        if rc == GIT_EUNBORNBRANCH.rawValue || rc == GIT_ENOTFOUND.rawValue {
            var headRef: OpaquePointer?
            try check(git_reference_lookup(&headRef, pointer, "HEAD"), "read HEAD")
            defer { git_reference_free(headRef) }
            let target = git_reference_symbolic_target(headRef).map { String(cString: $0) }
            return HeadInfo(branch: target.map { $0.hasPrefix("refs/heads/") ? String($0.dropFirst(11)) : $0 }, commit: nil)
        }
        try check(rc, "read HEAD")
        defer { git_reference_free(ref) }
        let commit = git_reference_target(ref).map(ObjectID.init)
        let detached = git_repository_head_detached(pointer) == 1
        let branch = detached ? nil : String(cString: git_reference_shorthand(ref))
        return HeadInfo(branch: branch, commit: commit)
    }

    public func status() throws -> RepoStatus {
        let head = try head()

        var opts = git_status_options()
        git_status_options_init(&opts, UInt32(GIT_STATUS_OPTIONS_VERSION))
        opts.show = GIT_STATUS_SHOW_INDEX_AND_WORKDIR
        opts.flags = GIT_STATUS_OPT_INCLUDE_UNTRACKED.rawValue
            | GIT_STATUS_OPT_RECURSE_UNTRACKED_DIRS.rawValue
            | GIT_STATUS_OPT_RENAMES_HEAD_TO_INDEX.rawValue
        var list: OpaquePointer?
        try check(git_status_list_new(&list, pointer, &opts), "status")
        defer { git_status_list_free(list) }

        var entries: [StatusEntry] = []
        for i in 0..<git_status_list_entrycount(list) {
            guard let e = git_status_byindex(list, i)?.pointee else { continue }
            let flags = e.status.rawValue
            let delta = e.index_to_workdir ?? e.head_to_index
            let path = delta?.pointee.new_file.path.map { String(cString: $0) } ?? ""
            entries.append(StatusEntry(path: path, kind: Self.kind(flags)))
        }

        var ahead: Int?
        var behind: Int?
        if let branch = head.branch, let local = head.commit, let upstream = try upstreamCommit(of: branch) {
            var a = 0, b = 0
            var l = local.oid, u = upstream.oid
            try check(git_graph_ahead_behind(&a, &b, pointer, &l, &u), "ahead/behind")
            (ahead, behind) = (a, b)
        }
        return RepoStatus(head: head, entries: entries, ahead: ahead, behind: behind)
    }

    private static func kind(_ flags: UInt32) -> StatusEntry.Kind {
        func has(_ f: git_status_t) -> Bool { flags & f.rawValue != 0 }
        if has(GIT_STATUS_CONFLICTED) { return .conflicted }
        if has(GIT_STATUS_WT_NEW) && !has(GIT_STATUS_INDEX_NEW) { return .untracked }
        if has(GIT_STATUS_INDEX_NEW) { return .added }
        if has(GIT_STATUS_INDEX_RENAMED) || has(GIT_STATUS_WT_RENAMED) { return .renamed }
        if has(GIT_STATUS_INDEX_DELETED) || has(GIT_STATUS_WT_DELETED) { return .deleted }
        if has(GIT_STATUS_INDEX_TYPECHANGE) || has(GIT_STATUS_WT_TYPECHANGE) { return .typeChanged }
        return .modified
    }

    func upstreamCommit(of branch: String) throws -> ObjectID? {
        var local: OpaquePointer?
        try check(git_branch_lookup(&local, pointer, branch, GIT_BRANCH_LOCAL), "find branch \(branch)")
        defer { git_reference_free(local) }
        var upstream: OpaquePointer?
        let rc = git_branch_upstream(&upstream, local)
        if rc == GIT_ENOTFOUND.rawValue { return nil }
        try check(rc, "find upstream of \(branch)")
        defer { git_reference_free(upstream) }
        return git_reference_target(upstream).map(ObjectID.init)
    }

    // MARK: Commits

    /// Commits everything that changed, with no staging step (PLAN.md §9.1 opinion 3).
    @discardableResult
    public func commitAll(message: String, author: Signature, date: Date = .now) throws -> CommitInfo {
        let summary = message.split(separator: "\n").first.map(String.init) ?? ""
        return try recordingUndo(.commit, "Commit “\(summary)”") {
            try commitAllUnrecorded(message: message, author: author, date: date)
        }
    }

    private func commitAllUnrecorded(message: String, author: Signature, date: Date) throws -> CommitInfo {
        let head = try head()
        let index = try repositoryIndex()
        defer { git_index_free(index) }
        try check(git_index_read(index, 1), "read index")
        try stageEverything(index)
        let tree = try writeTree(index)
        if tree == (try head.commit.map(treeOf) ?? .emptyTree) {
            try check(git_index_read(index, 1), "reset index")
            throw GitKitError.nothingToCommit
        }
        try check(git_index_write(index), "write index")
        let id = try createCommit(updating: "HEAD", tree: tree, parents: head.commit.map { [$0] } ?? [],
                                  message: message, author: author, date: date)
        return try commit(id)
    }

    public func commit(_ id: ObjectID) throws -> CommitInfo {
        var oid = id.oid
        var c: OpaquePointer?
        try check(git_commit_lookup(&c, pointer, &oid), "read commit \(id.short)")
        defer { git_commit_free(c) }
        let author = git_commit_author(c)!.pointee
        let parents = (0..<git_commit_parentcount(c)).compactMap { git_commit_parent_id(c, $0).map(ObjectID.init) }
        return CommitInfo(
            id: id,
            tree: ObjectID(git_commit_tree_id(c)!),
            parents: parents,
            message: git_commit_message(c).map { String(cString: $0) } ?? "",
            authorName: author.name.map { String(cString: $0) } ?? "",
            authorEmail: author.email.map { String(cString: $0) } ?? "",
            // Author time, like `git log`; it survives rebases and cherry-picks.
            date: Date(timeIntervalSince1970: TimeInterval(author.when.time))
        )
    }

    /// Commits reachable from HEAD, newest first.
    public func log(limit: Int = 100) throws -> [CommitInfo] {
        guard try head().commit != nil else { return [] }
        var walk: OpaquePointer?
        try check(git_revwalk_new(&walk, pointer), "log")
        defer { git_revwalk_free(walk) }
        git_revwalk_sorting(walk, GIT_SORT_TIME.rawValue | GIT_SORT_TOPOLOGICAL.rawValue)
        try check(git_revwalk_push_head(walk), "log")
        var result: [CommitInfo] = []
        var oid = git_oid()
        while result.count < limit, git_revwalk_next(&oid, walk) == 0 {
            result.append(try commit(ObjectID(oid)))
        }
        return result
    }

    // MARK: Shared helpers

    func repositoryIndex() throws -> OpaquePointer {
        var index: OpaquePointer?
        try check(git_repository_index(&index, pointer), "open index")
        return index!
    }

    /// Adds new and modified files and removes deleted ones, respecting .gitignore. In memory only.
    func stageEverything(_ index: OpaquePointer) throws {
        try check(git_index_add_all(index, nil, GIT_INDEX_ADD_DEFAULT.rawValue, nil, nil), "add files")
        try check(git_index_update_all(index, nil, nil, nil), "update files")
    }

    func writeTree(_ index: OpaquePointer) throws -> ObjectID {
        var oid = git_oid()
        try check(git_index_write_tree(&oid, index), "write tree")
        return ObjectID(oid)
    }

    func treeOf(_ commit: ObjectID) throws -> ObjectID {
        try self.commit(commit).tree
    }

    /// Writes a commit. `updating` moves that ref (only valid when the ref's tip is the first parent);
    /// pass nil and move the ref yourself otherwise.
    func createCommit(updating ref: String?, tree: ObjectID, parents: [ObjectID],
                      message: String, author: Signature, date: Date) throws -> ObjectID {
        var treeOid = tree.oid
        var treeObj: OpaquePointer?
        try check(git_tree_lookup(&treeObj, pointer, &treeOid), "read tree")
        defer { git_tree_free(treeObj) }

        var parentObjs: [OpaquePointer?] = []
        defer { parentObjs.forEach { git_commit_free($0) } }
        for parent in parents {
            var p = parent.oid
            var obj: OpaquePointer?
            try check(git_commit_lookup(&obj, pointer, &p), "read parent \(parent.short)")
            parentObjs.append(obj)
        }

        var sig: UnsafeMutablePointer<git_signature>?
        try check(git_signature_new(&sig, author.name, author.email, git_time_t(date.timeIntervalSince1970),
                                    Int32(TimeZone.current.secondsFromGMT(for: date) / 60)), "signature")
        defer { git_signature_free(sig) }

        var oid = git_oid()
        try check(git_commit_create(&oid, pointer, ref, sig, sig, "UTF-8", message, treeObj,
                                    parentObjs.count, &parentObjs), "commit")
        return ObjectID(oid)
    }

    func setReference(_ name: String, to id: ObjectID, log: String) throws {
        var oid = id.oid
        var ref: OpaquePointer?
        try check(git_reference_create(&ref, pointer, name, &oid, 1, log), "update \(name)")
        git_reference_free(ref)
    }

    func resolveReference(_ name: String) throws -> ObjectID? {
        var oid = git_oid()
        let rc = git_reference_name_to_id(&oid, pointer, name)
        if rc == GIT_ENOTFOUND.rawValue { return nil }
        try check(rc, "resolve \(name)")
        return ObjectID(oid)
    }
}

extension Repository {
    /// user.name / user.email from git config, nil if either is missing.
    public func configuredSignature() -> Signature? {
        var sig: UnsafeMutablePointer<git_signature>?
        guard git_signature_default(&sig, pointer) == 0, let s = sig else { return nil }
        defer { git_signature_free(s) }
        return Signature(name: String(cString: s.pointee.name), email: String(cString: s.pointee.email))
    }

    /// True if `url` is inside a git working tree.
    public static func exists(at url: URL) -> Bool {
        Libgit2.initialize
        var buf = git_buf()
        defer { git_buf_dispose(&buf) }
        return git_repository_discover(&buf, url.path(percentEncoded: false), 0, nil) == 0
    }
}
