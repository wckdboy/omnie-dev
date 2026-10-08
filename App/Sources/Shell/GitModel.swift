import SwiftUI
import GitKit

/// UI-facing git state for the open project. All git work happens on the Repository actor.
@MainActor
@Observable
final class GitModel {
    private(set) var repo: Repository?
    private(set) var status: RepoStatus?
    private(set) var log: [CommitInfo] = []
    private(set) var checkpoints: [Checkpoint] = []
    private(set) var isBusy = false
    /// Set when the folder is not a git repository.
    private(set) var isNotARepo = false
    var error: String?

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
            await refresh()
        } catch {
            self.error = "Can't read git repository: \(describe(error))"
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
            log = try await repo.log(limit: 200)
            checkpoints = try await repo.checkpointsSinceHead()
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
        do {
            try await repo.restore(checkpoint)
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

    private func describe(_ error: Error) -> String {
        (error as? GitError)?.message ?? error.localizedDescription
    }
}
