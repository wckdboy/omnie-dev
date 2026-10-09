// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

import CryptoKit
import SwiftUI
import GitKit
import ModelKit
import PolicyKit
import SecretsKit

/// UI-facing git state for the open project. All git work happens on the Repository actor.
@MainActor
@Observable
final class GitModel {
    /// Push and commit-with-secrets decisions go through here (PLAN.md §12).
    @ObservationIgnored let policy: PolicyModel
    init(policy: PolicyModel) { self.policy = policy }

    private(set) var repo: Repository?
    private(set) var status: RepoStatus?
    private(set) var log: [CommitInfo] = []
    /// Tag names by commit, for the timeline.
    private(set) var tags: [ObjectID: [String]] = [:]
    private(set) var checkpoints: [Checkpoint] = []
    private(set) var isBusy = false
    /// Set when the folder is not a git repository.
    private(set) var isNotARepo = false
    var error: String?

    // Remote state
    private(set) var identity: SSHIdentity? = SSHIdentity.load()
    let knownHosts = KnownHosts(fileURL: AppPaths.support.appendingPathComponent("known_hosts.json"))
    /// A host key waiting for you to compare and trust; set when a connection hit an unknown host.
    var pendingHostKey: HostKey?
    /// An HTTPS host that needs a token before the operation can be retried.
    var pendingTokenHost: TokenRequest?
    struct TokenRequest: Identifiable, Equatable {
        let host: String
        let rejected: Bool
        var id: String { host }
    }
    @ObservationIgnored private var retryAfterTrust: (() async -> Void)?
    private(set) var isSyncing = false
    /// The last Sync's one-line result, shown in the status strip.
    private(set) var syncMessage: String?
    private(set) var queuedPushes: [PushIntent] = []
    private(set) var branches: [BranchInfo] = []
    /// What Undo would reverse, e.g. "Commit “Add page style”".
    private(set) var undoTitle: String?
    /// A merge waiting for you to resolve conflicts (PLAN.md §9.7).
    var mergeSession: MergeSession?
    @ObservationIgnored private(set) var mergeTitle = ""
    /// Set by WorkspaceModel: save the editor before git rewrites files, reload it after.
    @ObservationIgnored var beforeWorktreeChange: (() -> Void)?
    @ObservationIgnored var afterWorktreeChange: (() -> Void)?

    /// Author to use when the repo has no user.name/user.email (iOS has no global gitconfig).
    var fallbackName: String {
        get { UserDefaults.standard.string(forKey: "git.authorName") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "git.authorName") }
    }
    var fallbackEmail: String {
        get { UserDefaults.standard.string(forKey: "git.authorEmail") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "git.authorEmail") }
    }

    func attach(_ folder: URL) async {
        repo = nil
        status = nil
        log = []
        checkpoints = []
        isNotARepo = !Repository.exists(at: folder)
        guard !isNotARepo else { return }
        do {
            repo = try Repository.open(at: folder)
            loadQueue()
            await refresh()
        } catch {
            self.error = "Can't read git repository: \(describe(error))"
        }
    }

    /// No project: forget the last one's repository.
    func detach() async {
        repo = nil
        status = nil
        log = []
        tags = [:]
        checkpoints = []
        branches = []
        remotes = []
        isNotARepo = false
        syncMessage = nil
        undoTitle = nil
    }

    // MARK: Remote

    func createIdentity() {
        do { identity = try SSHIdentity.create() }
        catch { self.error = "Can't create SSH key: \(error.localizedDescription)" }
    }

    func trustPendingHostKey() async {
        guard let key = pendingHostKey else { return }
        do { try knownHosts.trust(key) } catch { self.error = "Can't save host key: \(error.localizedDescription)"; return }
        pendingHostKey = nil
        let retry = retryAfterTrust
        retryAfterTrust = nil
        await retry?()
    }

    func rejectPendingHostKey() {
        pendingHostKey = nil
        retryAfterTrust = nil
    }

    func saveToken(_ token: HTTPSToken) async {
        guard let request = pendingTokenHost else { return }
        do { try HTTPSToken.save(token, host: request.host) } catch {
            self.error = "Can't save token: \(error.localizedDescription)"
            return
        }
        pendingTokenHost = nil
        let retry = retryAfterTrust
        retryAfterTrust = nil
        await retry?()
    }

    /// Asks for `host`'s token (the token sheet), then runs `retry`: for forge calls, which aren't
    /// git operations but use the same per-host token.
    func askForToken(host: String, rejected: Bool, retry: @escaping () async -> Void) {
        pendingTokenHost = TokenRequest(host: host, rejected: rejected)
        retryAfterTrust = retry
    }

    func cancelTokenRequest() {
        pendingTokenHost = nil
        retryAfterTrust = nil
    }

    nonisolated static func host(of url: String) -> String? {
        URL(string: url)?.host()
    }

    var remoteAuth: RemoteAuth {
        let signer = identity?.signer
        let hosts = knownHosts
        return RemoteAuth(
            credential: { url in
                if Self.isSSH(url) {
                    return signer.map { .sshSigner(username: "git", signer: $0) }
                }
                // HTTPS: a per-host token from the Keychain. Read here, used for this operation only.
                guard let host = Self.host(of: url), let token = HTTPSToken.load(host: host) else { return nil }
                return .token(username: token.username, token: token.token)
            },
            checkHostKey: { hosts.check($0) })
    }

    nonisolated static func isSSH(_ url: String) -> Bool {
        url.hasPrefix("ssh://") || (!url.contains("://") && url.contains("@") && url.contains(":"))
    }

    /// Runs a network operation; turns host-key and auth failures into something you can act on.
    private func network(_ retry: @escaping () async -> Void, _ body: () async throws -> Void) async {
        do {
            try await body()
        } catch GitKitError.unknownHostKey(let key) {
            pendingHostKey = key
            retryAfterTrust = retry
        } catch GitKitError.hostKeyChanged(let key, let expected) {
            error = "Host key for \(key.host) changed (now \(key.fingerprint), was \(expected)). Not connecting; this can mean the connection is being intercepted."
        } catch GitKitError.noCredential(let url) {
            if Self.isSSH(url) {
                error = "No SSH key yet. Create one in SSH key, add it to your forge, then retry."
            } else if let host = Self.host(of: url) {
                pendingTokenHost = TokenRequest(host: host, rejected: false)
                retryAfterTrust = retry
            }
        } catch GitKitError.authenticationFailed(let url) {
            if !Self.isSSH(url), let host = Self.host(of: url) {
                pendingTokenHost = TokenRequest(host: host, rejected: true)
                retryAfterTrust = retry
            } else {
                error = "\(url) refused the SSH key. Add the key shown in SSH key to your forge account."
            }
        } catch let e as SyncError {
            error = Self.describe(e)
        } catch {
            self.error = describe(error)
        }
    }

    /// Fetch, integrate, push, behind one Face ID. Offline, the push is authorized now and queued.
    func sync(isOffline: Bool) async {
        guard let repo, !isSyncing else { return }
        guard let committer = await author() else {
            error = "Set your name and email (Commit asks for them) before syncing."
            return
        }
        // Offline or in plane mode the push is queued, so it's authorized for later.
        guard await policy.authorize(await pushAction(), later: isOffline) else {
            if let reason = policy.lastRefusal, reason != "Not approved" { error = reason }
            return
        }
        if isOffline {
            do {
                let intent = try await repo.makePushIntent()
                queuedPushes.removeAll { $0.branch == intent.branch }
                queuedPushes.append(intent)
                saveQueue()
                syncMessage = "Queued, sends when online"
            } catch {
                self.error = describe(error)
            }
            return
        }
        isSyncing = true
        defer { isSyncing = false }
        let auth = remoteAuth
        beforeWorktreeChange?()
        await network({ [weak self] in await self?.sync(isOffline: false) }) {
            do {
                let lfsRemote = (try await repo.upstreamName())?.split(separator: "/").first.map(String.init) ?? "origin"
                let lfs = await repo.usesLFS()
                // Large files go up before the commits that point at them, and new ones come down after.
                if lfs { try await repo.lfsPush(remote: lfsRemote, auth: auth) }
                let result = try await repo.sync(auth: auth, committer: committer)
                if lfs { try await repo.lfsPull(remote: lfsRemote, auth: auth) }
                syncMessage = result.summary
            } catch SyncError.conflicts {
                // Fetched already; open the resolver against upstream instead of a dead end.
                try await startResolving(against: try await repo.upstreamTip(),
                                         title: "Merge \(try await repo.upstreamName() ?? "upstream")")
            }
        }
        afterWorktreeChange?()
        await refresh()
    }

    /// Sends queued pushes once the network is back. No prompt: each was authorized when queued.
    func flushQueue() async {
        guard let repo, !queuedPushes.isEmpty else { return }
        let auth = remoteAuth
        for intent in queuedPushes {
            await network({}) {
                if await repo.usesLFS() { try await repo.lfsPush(auth: auth) }
                switch try await repo.flush(intent, auth: auth) {
                case .pushed:
                    queuedPushes.removeAll { $0.id == intent.id }
                    syncMessage = "Synced: pushed \(intent.branch)"
                case .needsYou(let reason):
                    queuedPushes.removeAll { $0.id == intent.id }
                    error = "Queued push not sent: \(reason). Sync again to push."
                }
            }
        }
        saveQueue()
        await refresh()
    }

    /// Clones into Documents/Projects/<name> and returns the folder.
    func clone(_ url: String) async -> URL? {
        let name = Self.projectName(from: url)
        var destination = AppPaths.projects.appendingPathComponent(name, isDirectory: true)
        var n = 2
        while FileManager.default.fileExists(atPath: destination.path(percentEncoded: false)) {
            destination = AppPaths.projects.appendingPathComponent("\(name)-\(n)", isDirectory: true)
            n += 1
        }
        isBusy = true
        defer { isBusy = false }
        var cloned: URL?
        let auth = remoteAuth
        await network({ [weak self] in _ = await self?.clone(url) }) {
            let repo = try await Repository.clone(from: url, to: destination, auth: auth)
            cloned = destination
            // Large files (Git LFS) come down with the clone; a failure there doesn't undo it.
            if await repo.usesLFS() {
                do {
                    let count = try await repo.lfsPull(auth: auth)
                    syncMessage = "Cloned, with \(count) large file\(count == 1 ? "" : "s") (Git LFS)"
                } catch {
                    self.error = "Cloned, but its Git LFS files didn't download: \((error as? LocalizedError)?.errorDescription ?? "\(error)"). Git › Download Git LFS files tries again."
                }
            }
        }
        return cloned
    }

    nonisolated static func projectName(from url: String) -> String {
        let last = url.split(whereSeparator: { $0 == "/" || $0 == ":" }).last.map(String.init) ?? "project"
        let name = last.hasSuffix(".git") ? String(last.dropLast(4)) : last
        return name.isEmpty ? "project" : name
    }

    // MARK: Conflicts

    func startResolving(against theirs: ObjectID?, title: String) async throws {
        guard let repo, let theirs else { return }
        let session = try await repo.prepareMerge(with: theirs)
        guard !session.conflicts.isEmpty else { return }
        mergeTitle = title
        mergeSession = session
    }

    /// Writes the resolved merge, then syncs again to push it.
    func completeResolution(_ resolutions: [String: String], assistedBy: String? = nil) async -> Bool {
        guard let repo, let session = mergeSession, let author = await author() else { return false }
        beforeWorktreeChange?()
        defer { afterWorktreeChange?() }
        do {
            // Proposals you accepted are credited, like agent tasks (PLAN.md §9).
            let message = assistedBy.map { "\(mergeTitle)\n\nAssisted-by: \($0)" } ?? mergeTitle
            try await repo.completeMerge(session, resolutions: resolutions, message: message,
                                         author: author, asMergeCommit: true)
            mergeSession = nil
            syncMessage = "Merged. Sync to push."
            await refresh()
            return true
        } catch let e as ResolveError {
            error = switch e {
            case .stale: "The branch changed while resolving. Sync again."
            case .stillHasMarkers(let path): "\(path) still has conflict markers."
            case .unresolved(let paths): "Still unresolved: \(paths.joined(separator: ", "))."
            }
            return false
        } catch {
            self.error = describe(error)
            return false
        }
    }

    // MARK: Undo and revert

    func undo() async {
        guard let repo else { return }
        beforeWorktreeChange?()
        do {
            let entry = try await repo.undo()
            syncMessage = "Undid: \(entry.title)"
        } catch let e as UndoError {
            error = switch e {
            case .nothingToUndo: "Nothing to undo."
            case .changedSince: "Can't undo: the branch changed since. Use the timeline to restore a checkpoint."
            case .alreadyPushed: "Already pushed, so undo would rewrite shared history. Use Revert on the commit instead."
            case .uncommittedChanges(let n): "Undo would overwrite \(n) \(n == 1 ? "edit" : "edits") made since. Commit or restore them first."
            }
        } catch {
            self.error = describe(error)
        }
        afterWorktreeChange?()
        await refresh()
    }

    func revert(_ commit: CommitInfo) async {
        guard let repo, let author = await author() else {
            error = "Set your name and email (Commit asks for them) first."
            return
        }
        beforeWorktreeChange?()
        do {
            try await repo.revert(commit.id, author: author)
        } catch MergeError.uncommittedChanges(let n) {
            error = "Commit your \(n) \(n == 1 ? "change" : "changes") first, then revert."
        } catch MergeError.conflicts(let paths) {
            error = "Reverting conflicts with later changes in \(paths.joined(separator: ", ")). Nothing was changed."
        } catch {
            self.error = describe(error)
        }
        afterWorktreeChange?()
        await refresh()
    }

    // MARK: Git LFS

    /// Downloads the large files HEAD needs (Git › Download Git LFS files).
    func lfsPull(isOffline: Bool) async {
        guard let repo else { return }
        guard !isOffline else { error = "Downloading Git LFS files needs the network."; return }
        isSyncing = true
        defer { isSyncing = false }
        let auth = remoteAuth
        let remote = ((try? await repo.upstreamName()) ?? nil)?.split(separator: "/").first.map(String.init) ?? "origin"
        beforeWorktreeChange?()
        await network({ [weak self] in await self?.lfsPull(isOffline: false) }) {
            let count = try await repo.lfsPull(remote: remote, auth: auth)
            syncMessage = count == 0 ? "Git LFS files are all here" : "Downloaded \(count) Git LFS file\(count == 1 ? "" : "s")"
        }
        afterWorktreeChange?()
        await refresh()
    }

    // MARK: Remotes and moving a repo (PLAN.md §9.10, §9.11)

    private(set) var remotes: [RemoteInfo] = []

    func refreshRemotes() async {
        remotes = (try? await repo?.remotes()) ?? []
    }

    /// Runs a local remote change, reporting what went wrong.
    func editRemotes(_ change: @escaping (Repository) async throws -> Void) async {
        guard let repo else { return }
        do { try await change(repo) } catch { self.error = (error as? LocalizedError)?.errorDescription ?? describe(error) }
        await refreshRemotes()
        await refresh()
    }

    func migrationPlan(from old: String, to name: String, url: String) async -> Result<MigrationPlan, Error> {
        guard let repo else { return .failure(MigrationError.noSuchRemote(old)) }
        do { return .success(try await repo.migrationPlan(from: old, to: name, url: url)) } catch { return .failure(error) }
    }

    /// Moves the repo to another forge. A push, so it's approved like one; it needs the network.
    func migrate(_ plan: MigrationPlan, isOffline: Bool) async -> Bool {
        guard let repo else { return false }
        if isOffline {
            error = "Moving a repo needs the network: it pushes everything to \(RemoteInfo.host(of: plan.url) ?? plan.url)."
            return false
        }
        let what = "\(plan.branches.count) branches, \(plan.tags.count) tags"
        guard await policy.authorize(.gitPush(remote: plan.to, branch: what, force: false)) else {
            if let reason = policy.lastRefusal, reason != "Not approved" { error = reason }
            return false
        }
        isSyncing = true
        defer { isSyncing = false }
        let auth = remoteAuth
        var done = false
        await network({ [weak self] in _ = await self?.migrate(plan, isOffline: false) }) {
            try await repo.migrate(plan, auth: auth)
            done = true
            syncMessage = "Moved to \(plan.to): \(what); \(plan.from) is read-only now"
        }
        await refreshRemotes()
        await refresh()
        return done
    }

    // MARK: Staging (PLAN.md §9.10: hunks and lines, then commit the index)

    private(set) var staging: [StagingFile] = []

    func refreshStaging() async {
        guard let repo else { staging = []; return }
        staging = (try? await repo.stagingStatus()) ?? []
    }

    /// Stages lines (or the whole file) of the not-staged diff.
    func stage(_ path: String, lines: Set<Staging.LineRef>? = nil) async {
        guard let repo else { return }
        do { try await repo.stage(path, lines: lines) } catch { self.error = (error as? LocalizedError)?.errorDescription ?? describe(error) }
        await refreshStaging()
    }

    func unstage(_ path: String, lines: Set<Staging.LineRef>? = nil) async {
        guard let repo else { return }
        do { try await repo.unstage(path, lines: lines) } catch { self.error = (error as? LocalizedError)?.errorDescription ?? describe(error) }
        await refreshStaging()
    }

    /// Commits only what's staged.
    func commitStaged(message: String, author: Signature) async -> Bool {
        guard let repo else { return false }
        isBusy = true
        defer { isBusy = false }
        do {
            let commit = try await repo.commitIndex(message: message, author: author)
            syncMessage = "Committed “\(commit.summary)”"
            await refresh()
            await refreshStaging()
            return true
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? describe(error)
            return false
        }
    }

    // MARK: Tags, reset, reflog (PLAN.md §9.10)

    func tag(_ name: String, at commit: CommitInfo, message: String) async {
        guard let repo, let author = await author() else {
            error = "Set your name and email (Commit asks for them) first."
            return
        }
        do {
            try await repo.tag(name.trimmingCharacters(in: .whitespaces), at: commit.id, message: message, tagger: author)
            syncMessage = "Tagged \(commit.id.short) “\(name)”"
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? describe(error)
        }
        await refresh()
    }

    func deleteTag(_ name: String) async {
        guard let repo else { return }
        do { try await repo.deleteTag(name) } catch { self.error = describe(error) }
        await refresh()
    }

    /// Moves the branch back to `commit`; what came after stays in the folder, uncommitted.
    func reset(to commit: CommitInfo) async {
        guard let repo else { return }
        beforeWorktreeChange?()
        do {
            try await repo.resetKeepingChanges(to: commit.id)
            syncMessage = "Reset to \(commit.id.short); later changes are uncommitted"
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? describe(error)
        }
        afterWorktreeChange?()
        await refresh()
    }

    func reflog() async -> [ReflogEntry] {
        guard let repo else { return [] }
        return (try? await repo.reflog()) ?? []
    }

    // MARK: History (interactive rebase, PLAN.md §9.10)

    /// The commits "Edit history" offers: unpushed, or the last 30.
    func editableHistory() async -> (base: ObjectID, commits: [CommitInfo])? {
        guard let repo else { return nil }
        return (try? await repo.editableHistory()) ?? nil
    }

    /// The result of `steps` without changing anything.
    func previewHistory(base: ObjectID, steps: [HistoryStep]) async -> Result<[CommitInfo], Error> {
        guard let repo, let author = await author() else { return .failure(HistoryError.notOnABranch) }
        do { return .success(try await repo.rewriteHistory(base: base, steps: steps, committer: author, apply: false)) }
        catch { return .failure(error) }
    }

    /// Rewrites the branch; one Undo puts it back.
    func applyHistory(base: ObjectID, steps: [HistoryStep]) async -> Bool {
        guard let repo, let author = await author() else {
            error = "Set your name and email (Commit asks for them) first."
            return false
        }
        beforeWorktreeChange?()
        defer { afterWorktreeChange?() }
        do {
            let made = try await repo.rewriteHistory(base: base, steps: steps, committer: author, apply: true)
            syncMessage = "History edited: \(made.count) commit\(made.count == 1 ? "" : "s")"
            await refresh()
            return true
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? describe(error)
            await refresh()
            return false
        }
    }

    // MARK: Branches

    func switchBranch(_ name: String) async {
        guard let repo else { return }
        beforeWorktreeChange?()
        do {
            try await repo.switchBranch(to: name)
        } catch BranchError.workInProgressDidNotApply(let branch) {
            error = "Switched to \(branch), but its saved changes no longer apply cleanly. They're kept on refs/wip/\(branch)."
        } catch {
            self.error = describe(error)
        }
        afterWorktreeChange?()
        await refresh()
    }

    func createBranch(_ name: String, switchTo: Bool) async {
        guard let repo else { return }
        do {
            try await repo.createBranch(name)
            if switchTo { await switchBranch(name) } else { await refresh() }
        } catch BranchError.alreadyExists(let n) {
            error = "A branch named \(n) already exists."
        } catch {
            self.error = describe(error)
        }
    }

    // Queue persistence, per repository.
    private var queueURL: URL? {
        // A stable digest of the path; hashValue is reseeded on every launch.
        repo.map { repo in
            let digest = SHA256.hash(data: Data(repo.workdir.path(percentEncoded: false).utf8))
            let id = digest.prefix(8).map { String(format: "%02x", $0) }.joined()
            return AppPaths.support.appendingPathComponent("push-queue-\(id).json")
        }
    }

    private func loadQueue() {
        guard let queueURL, let data = try? Data(contentsOf: queueURL) else { queuedPushes = []; return }
        queuedPushes = (try? JSONDecoder().decode([PushIntent].self, from: data)) ?? []
    }

    private func saveQueue() {
        guard let queueURL else { return }
        try? JSONEncoder().encode(queuedPushes).write(to: queueURL, options: [.atomic, .completeFileProtection])
    }

    static func describe(_ error: SyncError) -> String {
        switch error {
        case .noRemote: "No remote to sync with. Add one, or clone from a forge."
        case .localChangesBlock(let paths): "Upstream changed \(paths.joined(separator: ", ")), which you've edited. Commit first, then sync."
        case .uncommittedChanges(let n): "Commit your \(n) \(n == 1 ? "change" : "changes") first, then sync."
        case .conflicts(let paths): "Your commits conflict with upstream in \(paths.joined(separator: ", "))."
        }
    }

    func initialize(_ folder: URL) async {
        do {
            repo = try Repository.create(at: folder)
            isNotARepo = false
            await refresh()
        } catch {
            self.error = "Can't create git repository: \(describe(error))"
        }
    }

    func refresh() async {
        guard let repo else { return }
        do {
            status = try await repo.status()
            branches = try await repo.branches()
            undoTitle = await repo.undoStack().last?.title
            log = try await repo.log(limit: 200)
            checkpoints = try await repo.checkpointsSinceHead()
            tags = (try? await repo.tags()) ?? [:]
        } catch {
            self.error = "Git status failed: \(describe(error))"
        }
    }

    func checkpoint(_ reason: CheckpointReason) async {
        guard let repo else { return }
        do {
            try await repo.checkpoint(reason)
            await refresh()
        } catch {
            // Checkpoints are a safety net; failing one shouldn't interrupt typing.
            self.error = "Checkpoint failed: \(describe(error))"
        }
    }

    func restore(_ checkpoint: Checkpoint) async -> Bool {
        guard let repo else { return false }
        isBusy = true
        defer { isBusy = false }
        beforeWorktreeChange?()
        do {
            try await repo.restore(checkpoint)
            afterWorktreeChange?()
            await refresh()
            return true
        } catch {
            self.error = "Restore failed: \(describe(error))"
            return false
        }
    }

    func author() async -> Signature? {
        if let configured = await repo?.configuredSignature() { return configured }
        guard !fallbackName.isEmpty, !fallbackEmail.isEmpty else { return nil }
        return Signature(name: fallbackName, email: fallbackEmail)
    }

    func commit(message: String, author: Signature) async -> Bool {
        guard let repo else { return false }
        isBusy = true
        defer { isBusy = false }
        // Secret scan before commit (PLAN.md §12). A finding needs your explicit OK, which is audited.
        if let lines = try? await repo.pendingAddedLines() {
            let findings = SecretScanner().scan(lines.map { (path: $0.path, line: $0.line, text: $0.text) })
            if !findings.isEmpty {
                let described = findings.map { "\($0.path):\($0.line)  \($0.rule)  \($0.redacted)" }
                guard await policy.authorize(.commitWithSuspectedSecrets(findings: described),
                                             artifact: described.joined(separator: "\n")
                                                + "\n\nRemove them, or add omnie:allow-secret on the line if it's a test value.")
                else { return false }
            }
        }
        do {
            try await repo.commitAll(message: message, author: author)
            await refresh()
            return true
        } catch GitKitError.nothingToCommit {
            error = "Nothing to commit."
            return false
        } catch {
            self.error = "Commit failed: \(describe(error))"
            return false
        }
    }

    /// Template message until the local model drafts them (PLAN.md §9.3, P1 uses templates).
    var draftMessage: String {
        guard let entries = status?.entries, !entries.isEmpty else { return "" }
        let names = entries.map { ($0.path as NSString).lastPathComponent }
        let verb: String
        if entries.allSatisfy({ $0.kind == .untracked || $0.kind == .added }) { verb = "Add" }
        else if entries.allSatisfy({ $0.kind == .deleted }) { verb = "Remove" }
        else { verb = "Update" }
        let list = names.count <= 3 ? names.joined(separator: ", ") : "\(names.prefix(2).joined(separator: ", ")) and \(names.count - 2) more"
        return "\(verb) \(list)"
    }

    /// A subject line from the local model, written from the changed files and the lines they add.
    /// nil when the model gives nothing usable; the template draft stays.
    func draftMessage(with model: TextModel) async -> String? {
        guard let repo, let entries = status?.entries, !entries.isEmpty else { return nil }
        let changes = entries.map { CommitDraft.Change(path: $0.path, kind: Self.word(for: $0.kind)) }
        let added = ((try? await repo.pendingAddedLines(limit: 4_000)) ?? []).map { (path: $0.path, text: $0.text) }
        let prompt = CommitDraft.prompt(changes: changes, added: added)
        let raw = try? await model.complete(.chat(system: CommitDraft.system, user: prompt), maxTokens: 40,
                                            stop: ["\n\n"])
        return raw.flatMap(CommitDraft.clean)
    }

    nonisolated static func word(for kind: StatusEntry.Kind) -> String {
        switch kind {
        case .added, .untracked: "added"
        case .deleted: "deleted"
        case .renamed: "renamed"
        default: "modified"
        }
    }

    /// The push a Sync would make, for the policy decision and the audit log.
    private func pushAction() async -> Action {
        let branch = (try? await repo?.head().branch) ?? nil
        let upstream = (try? await repo?.upstreamName()) ?? nil
        let remote = upstream.flatMap { $0.split(separator: "/").first.map(String.init) } ?? "origin"
        return .gitPush(remote: remote, branch: branch ?? "HEAD", force: false)
    }

    private func describe(_ error: Error) -> String {
        (error as? GitError)?.message ?? error.localizedDescription
    }
}
