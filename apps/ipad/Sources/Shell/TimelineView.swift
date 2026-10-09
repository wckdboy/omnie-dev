// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

import SwiftUI
import DesignKit
import GitKit

/// The timeline instead of `git log` (PLAN.md §9.4): checkpoints since the last commit as grey ticks,
/// your commits as Ion dots, agent commits as violet dots in the agent face.
struct TimelineView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var palette
    @Environment(\.density) private var density

    var body: some View {
        let git = model.workspace.git
        Group {
            if model.workspace.rootURL == nil {
                NotYet(title: "No project open", detail: "Open a folder to see its history.")
            } else if git.isNotARepo {
                VStack(spacing: 12) {
                    NotYet(title: "Not a git repository", detail: "Checkpoints and history need git. Nothing is uploaded; this only creates a local .git folder.")
                        .frame(maxHeight: 160)
                    Button("Initialize git repository") { model.registry.run("git.init") }
                        .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                list(git)
            }
        }
        .background(palette.surface.pane.color)
    }

    private func list(_ git: GitModel) -> some View {
        List {
            Section {
                Button {
                    model.registry.run("git.commit")
                } label: {
                    Label(commitLabel(git), systemImage: "checkmark.circle")
                        .font(.system(size: 13, weight: .semibold))
                }
                .disabled(git.status?.isClean ?? true)
                .listRowBackground(Color.clear)
                Button {
                    model.registry.run("git.sync")
                } label: {
                    Label(syncLabel(git), systemImage: "arrow.triangle.2.circlepath")
                        .font(.system(size: 13))
                }
                .disabled(git.isSyncing)
                .listRowBackground(Color.clear)
                if let undo = git.undoTitle {
                    Button {
                        model.registry.run("git.undo")
                    } label: {
                        Label("Undo \(undo)", systemImage: "arrow.uturn.backward")
                            .font(.system(size: 13))
                            .lineLimit(1)
                    }
                    .listRowBackground(Color.clear)
                }
            }

            if !git.checkpoints.isEmpty {
                Section("Since last commit") {
                    ForEach(git.checkpoints) { cp in
                        HStack(spacing: 10) {
                            Circle().fill(palette.text.tertiary.color).frame(width: 5, height: 5)
                                .frame(width: 10)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Checkpoint · \(cp.reason.label)")
                                    .font(.system(size: 13))
                                    .foregroundStyle(palette.text.secondary.color)
                                Text(cp.date, format: .relative(presentation: .named))
                                    .font(.system(size: 11))
                                    .foregroundStyle(palette.text.tertiary.color)
                            }
                            Spacer()
                            Button("Restore") {
                                Task { await model.workspace.restore(cp) }
                            }
                            .font(.system(size: 12))
                            .buttonStyle(.bordered)
                            .disabled(git.isBusy)
                        }
                        .listRowBackground(Color.clear)
                    }
                }
            }

            Section(git.status?.head.branch ?? "History") {
                if git.log.isEmpty {
                    Text("No commits yet")
                        .font(.system(size: 13))
                        .foregroundStyle(palette.text.tertiary.color)
                        .listRowBackground(Color.clear)
                }
                ForEach(git.log) { commit in
                    CommitRow(commit: commit)
                        .listRowBackground(Color.clear)
                        .contextMenu {
                            Button("Revert", systemImage: "arrow.uturn.backward") {
                                Task { await git.revert(commit) }
                            }
                            Button("Copy commit ID", systemImage: "doc.on.doc") {
                                UIPasteboard.general.string = commit.id.hex
                            }
                        }
                }
            }
        }
        .listStyle(.plain)
        .listRowSeparator(.hidden)
        .scrollContentBackground(.hidden)
        .environment(\.defaultMinListRowHeight, density.row)
        .refreshable { await git.refresh() }
    }

    private func syncLabel(_ git: GitModel) -> String {
        if model.policy.planeMode { return "Queue push for after plane mode" }
        if model.isOffline { return "Queue push for when online" }
        guard let status = git.status else { return "Sync" }
        var parts: [String] = []
        if let ahead = status.ahead, ahead > 0 { parts.append("push \(ahead)") }
        if let behind = status.behind, behind > 0 { parts.append("pull \(behind)") }
        return parts.isEmpty ? "Sync" : "Sync: " + parts.joined(separator: ", ")
    }

    private func commitLabel(_ git: GitModel) -> String {
        let n = git.status?.changedCount ?? 0
        return n == 0 ? "Nothing to commit" : "Commit \(n) \(n == 1 ? "change" : "changes")"
    }
}

struct CommitRow: View {
    @Environment(\.palette) private var palette
    @Environment(\.density) private var density
    let commit: CommitInfo

    var body: some View {
        let isAgent = commit.assistedBy != nil
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(isAgent ? palette.accent.agent.color : palette.accent.ion.color)
                .frame(width: 8, height: 8)
                .padding(.top, 5)
                .frame(width: 10)
            VStack(alignment: .leading, spacing: 2) {
                Text(commit.summary)
                    .font(isAgent ? Typography.agent(density) : .system(size: 13))
                    .foregroundStyle(isAgent ? palette.accent.agent.color : palette.text.primary.color)
                    .lineLimit(2)
                HStack(spacing: 6) {
                    Text(commit.id.short).monospaced()
                    Text(commit.authorName)
                    if let model = commit.assistedBy { Text("· \(model)") }
                    Text(commit.date, format: .relative(presentation: .named))
                }
                .font(.system(size: 11))
                .foregroundStyle(palette.text.tertiary.color)
                .lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityHint(isAgent ? "Written by agent" : "")
    }
}

extension CheckpointReason {
    var label: String {
        switch self {
        case .save: "saved"
        case .agentApply: "before agent apply"
        case .run: "before run"
        case .branchSwitch: "branch switch"
        case .interval: "5 min"
        case .restore: "before restore"
        case .sync: "before sync"
        case .undo: "before undo"
        case .manual: "manual"
        case .delete: "before delete"
        }
    }
}

/// Commit composer: everything that changed becomes one commit, with a drafted message you edit.
struct CommitSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var palette
    @Environment(\.dismiss) private var dismiss
    @State private var message = ""
    @State private var name = ""
    @State private var email = ""
    @State private var needsIdentity = false
    @State private var isDrafting = false

    var body: some View {
        let git = model.workspace.git
        NavigationStack {
            Form {
                Section {
                    TextField("Message", text: $message, axis: .vertical)
                        .lineLimit(3...10)
                        .font(.system(size: 15))
                } header: {
                    Text("\(git.status?.changedCount ?? 0) changed on \(git.status?.head.branch ?? "HEAD")")
                } footer: {
                    if model.models.isInstalled(.tiny) {
                        HStack {
                            Text(isDrafting ? "Drafting on this device…" : "Drafted from the changed files. Edit it to say why.")
                            Spacer()
                            Button("Draft with local model") { Task { await draft() } }
                                .font(.footnote)
                                .disabled(isDrafting)
                        }
                    } else {
                        Text("Drafted from the changed files. Edit it to say why. A local model (Settings › Models) can draft it from the diff.")
                    }
                }
                if needsIdentity {
                    Section {
                        TextField("Name", text: $name)
                            .textContentType(.name)
                        TextField("Email", text: $email)
                            .textContentType(.emailAddress)
                            .keyboardType(.emailAddress)
                            .textInputAutocapitalization(.never)
                    } header: {
                        Text("Author")
                    } footer: {
                        Text("This repository has no user.name or user.email. Saved on this device for future commits.")
                    }
                }
                if let changed = git.status?.entries, !changed.isEmpty {
                    Section("Files") {
                        ForEach(changed, id: \.path) { entry in
                            HStack {
                                Text(entry.path).font(.system(size: 13, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                                Spacer()
                                Text(entry.kind.label).font(.system(size: 12)).foregroundStyle(palette.text.secondary.color)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Commit")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Commit") { Task { await commit() } }
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(!canCommit || git.isBusy)
                }
            }
        }
        .task {
            model.workspace.saveCurrent()
            await git.refresh()
            message = git.draftMessage
            name = git.fallbackName
            email = git.fallbackEmail
            needsIdentity = await git.repo?.configuredSignature() == nil
        }
    }

    /// Replaces the message with the local model's draft. Nothing leaves the device.
    private func draft() async {
        isDrafting = true
        defer { isDrafting = false }
        guard let tiny = await model.models.tinyModel() else { return }
        if let drafted = await model.workspace.git.draftMessage(with: tiny) { message = drafted }
    }

    private var canCommit: Bool {
        !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (!needsIdentity || (!name.isEmpty && email.contains("@")))
    }

    private func commit() async {
        let git = model.workspace.git
        if needsIdentity {
            git.fallbackName = name
            git.fallbackEmail = email
        }
        guard let author = await git.author() else { return }
        var text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.hasSuffix("\n") { text += "\n" }
        if await git.commit(message: text, author: author) { dismiss() }
    }
}

extension StatusEntry.Kind {
    var label: String {
        switch self {
        case .added: "Added"
        case .modified: "Modified"
        case .deleted: "Deleted"
        case .renamed: "Renamed"
        case .typeChanged: "Type changed"
        case .untracked: "New"
        case .conflicted: "Conflict"
        }
    }
}
