// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

import AgentKit
import Foundation
import GitKit
import ModelKit
import PolicyKit
import SecretsKit

/// Agent tasks for the open project (PLAN.md §6, §9.5): each runs on its own branch and worktree,
/// so your folder is never touched while it works, and ends in a changeset you review.
@MainActor
@Observable
final class AgentModel {
    struct TaskRecord: Codable, Identifiable, Equatable {
        enum Phase: String, Codable {
            case running, review, merged, rejected, failed
        }
        let id: UUID
        let goal: String
        let branch: String
        let worktreeName: String
        let worktreePath: String
        let repoPath: String
        /// Your HEAD when the task started; the changeset is measured from here.
        let base: String
        let created: Date
        var phase: Phase
        var summary: String?
        /// Set when the task stopped early: a cap, Stop, or the model getting stuck.
        var attention: String?
        var tip: String?
    }

    private(set) var current: TaskRecord?
    private(set) var transcript: [JournalEntry] = []
    private(set) var changes: [FileDiff] = []
    private(set) var isRunning = false
    var error: String?

    @ObservationIgnored private let workspace: WorkspaceModel
    @ObservationIgnored private let models: ModelsModel
    @ObservationIgnored private let policy: PolicyModel
    @ObservationIgnored private var runner: AgentRunner?
    @ObservationIgnored private var tasks: [TaskRecord] = []
    @ObservationIgnored private let folder = AppPaths.support.appendingPathComponent("Agent", isDirectory: true)
    private var recordsURL: URL { folder.appendingPathComponent("tasks.json") }

    init(workspace: WorkspaceModel, models: ModelsModel, policy: PolicyModel) {
        self.workspace = workspace
        self.models = models
        self.policy = policy
        tasks = (try? JSONDecoder().decode([TaskRecord].self, from: Data(contentsOf: recordsURL))) ?? []
    }

    /// The status-strip pill (PLAN.md §3.8).
    var pillState: AgentState {
        guard let current else { return .idle }
        switch current.phase {
        case .running: return isRunning ? .thinking : .blocked
        case .review: return current.attention == nil ? .needsReview(changes: changes.count) : .blocked
        case .failed: return .failed(current.attention ?? "error")
        case .merged, .rejected: return .idle
        }
    }

    /// Called when a project opens: shows its latest unfinished task, and resumes one that was
    /// running when the app was closed.
    func attach(_ root: URL) {
        guard !isRunning else { return }
        current = tasks.last { $0.repoPath == root.path && ($0.phase == .running || $0.phase == .review) }
        transcript = current.map { journal(for: $0).entries() } ?? []
        changes = []
        guard let current else { return }
        if current.phase == .review { Task { await loadChanges() } }
        if current.phase == .running { Task { await run(current) } }
    }

    // MARK: Lifecycle

    func start(_ goal: String) async {
        let goal = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !goal.isEmpty, !isRunning else { return }
        guard let repo = workspace.git.repo, let root = workspace.rootURL else {
            error = "Open a git project first."
            return
        }
        guard models.isInstalled(.standard) else {
            error = "The agent runs on \(ModelPack.standard.displayName). Download it in Settings › Models."
            return
        }
        workspace.saveCurrent()
        do {
            guard let base = try await repo.head().commit else {
                error = "Commit something first; the agent starts from your last commit."
                return
            }
            let id = UUID()
            let slug = Self.slug(goal) + "-" + id.uuidString.prefix(4).lowercased()
            let path = folder.appendingPathComponent("worktrees/\(id.uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            let worktree = try await repo.createTaskWorktree(slug: slug, at: path)
            let record = TaskRecord(id: id, goal: goal, branch: worktree.branch, worktreeName: worktree.name,
                                    worktreePath: worktree.path.path, repoPath: root.path, base: base.hex,
                                    created: .now, phase: .running)
            tasks.append(record)
            save()
            current = record
            transcript = []
            changes = []
            error = nil
            await run(record)
        } catch {
            self.error = "Couldn't start the task: \(error.localizedDescription)"
        }
    }

    private func run(_ record: TaskRecord) async {
        guard let model = await models.standardModel() else {
            error = models.error ?? "The model isn't available."
            return
        }
        let policy = policy
        let runner = AgentRunner(
            goal: record.goal, model: model, tools: standardTools(root: URL(filePath: record.worktreePath)),
            journal: journal(for: record),
            authorize: { action, artifact in await policy.authorize(action, by: .agent, artifact: artifact) },
            onEntry: { entry in
                Task { @MainActor [weak self] in
                    self?.transcript.append(entry)
                    #if DEBUG
                    print("[agent] \(entry.kind.rawValue)\(entry.tool.map { " \($0)" } ?? ""): \(entry.text.prefix(300))")
                    #endif
                }
            })
        self.runner = runner
        isRunning = true
        let outcome = await runner.run()
        isRunning = false
        self.runner = nil
        // Give the memory back (and ghost text its model) once the task stops.
        models.unload()
        await finish(record, outcome)
    }

    func stop() {
        Task { await runner?.stop() }
    }

    /// Commits what the agent did in its worktree and shows the changeset. Stopped or stuck tasks
    /// keep their partial changeset (PLAN.md §6.1: kept, never half-applied).
    private func finish(_ record: TaskRecord, _ outcome: AgentOutcome) async {
        var record = record
        switch outcome {
        case .finished(let summary): record.summary = summary
        case .needsInput(let reason): record.attention = reason
        case .stopped: record.attention = "Stopped by you."
        case .failed(let reason):
            record.attention = reason
            record.phase = .failed
            update(record)
            return
        }
        do {
            let worktree = try Repository.open(at: URL(filePath: record.worktreePath))
            let message = record.summary.flatMap(CommitDraft.clean) ?? "Agent: \(record.goal.prefix(60))"
            do {
                let commit = try await worktree.commitAll(message: message + "\n",
                                                          author: Signature(name: "Omnie Dev agent", email: "agent@omnie.invalid"))
                record.tip = commit.id.hex
            } catch GitKitError.nothingToCommit {
                record.tip = record.base
            }
            record.phase = .review
        } catch {
            record.phase = .failed
            record.attention = "Couldn't record the changes: \(error.localizedDescription)"
        }
        update(record)
        await loadChanges()
    }

    private func loadChanges() async {
        guard let record = current, let repo = workspace.git.repo,
              let base = ObjectID(hex: record.base), let tip = record.tip.flatMap(ObjectID.init(hex:)) else { return }
        changes = (try? await repo.diff(from: base, to: tip)) ?? []
    }

    /// Lands the changeset on your branch as one commit, after a secret scan.
    func accept() async {
        guard let record = current, record.phase == .review, let repo = workspace.git.repo else { return }
        guard !changes.isEmpty else { await reject(); return }
        let added = changes.flatMap { file in
            file.patch.split(separator: "\n").enumerated()
                .filter { $0.element.hasPrefix("+") && !$0.element.hasPrefix("+++") }
                .map { (path: file.path, line: $0.offset, text: String($0.element.dropFirst())) }
        }
        let findings = SecretScanner().scan(added)
        if !findings.isEmpty {
            let described = findings.map { "\($0.path)  \($0.rule)  \($0.redacted)" }
            guard await policy.authorize(.commitWithSuspectedSecrets(findings: described), artifact: described.joined(separator: "\n"))
            else { return }
        }
        workspace.saveCurrent()
        guard let author = await workspace.git.author() else {
            error = "Set your name and email in Settings first."
            return
        }
        let message = record.summary.flatMap(CommitDraft.clean) ?? "Agent: \(record.goal.prefix(60))"
        do {
            try await repo.squashMerge(record.branch, message: message, author: author, assistedBy: ModelPack.standard.displayName)
            if let worktree = try await repo.taskWorktrees().first(where: { $0.name == record.worktreeName }) {
                try await repo.removeTaskWorktree(worktree, deleteBranch: true)
            }
            var done = record
            done.phase = .merged
            update(done)
            workspace.reloadFromDisk()
            await workspace.git.refresh()
        } catch MergeError.uncommittedChanges(let count) {
            error = "Commit your \(count) changed \(count == 1 ? "file" : "files") first; the merge lands on top of your last commit."
        } catch MergeError.conflicts(let paths) {
            error = "The changes conflict with yours in \(paths.joined(separator: ", ")). Nothing was changed."
        } catch {
            self.error = "Merge failed: \(error.localizedDescription)"
        }
    }

    /// Drops the changeset. The branch stays, so the work isn't lost (PLAN.md §9.5).
    func reject() async {
        guard let record = current, let repo = workspace.git.repo else { return }
        if let worktree = try? await repo.taskWorktrees().first(where: { $0.name == record.worktreeName }) {
            try? await repo.removeTaskWorktree(worktree, deleteBranch: false)
        }
        var done = record
        done.phase = .rejected
        update(done)
        changes = []
    }

    // MARK: Helpers

    private func journal(for record: TaskRecord) -> Journal {
        Journal(url: folder.appendingPathComponent("\(record.id.uuidString).jsonl"))
    }

    private func update(_ record: TaskRecord) {
        if let i = tasks.firstIndex(where: { $0.id == record.id }) { tasks[i] = record }
        if current?.id == record.id { current = record }
        save()
    }

    private func save() {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? JSONEncoder().encode(tasks).write(to: recordsURL, options: .atomic)
    }

    /// "Add a dark mode toggle" → "add-dark-mode-toggle".
    nonisolated static func slug(_ goal: String) -> String {
        let words = goal.lowercased().split { !$0.isLetter && !$0.isNumber }.prefix(5)
        let slug = words.joined(separator: "-")
        return slug.isEmpty ? "task" : String(slug.prefix(40))
    }
}
