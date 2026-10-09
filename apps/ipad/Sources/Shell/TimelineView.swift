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
    @State private var tagging: CommitInfo?
    @State private var tagName = ""
    @State private var tagMessage = ""
    @State private var resetting: CommitInfo?
    @State private var showEverything = false
    @State private var reflog: [ReflogEntry] = []

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
        .alert("Tag \(tagging?.id.short ?? "")", isPresented: Binding(get: { tagging != nil }, set: { if !$0 { tagging = nil } })) {
            TextField("v1.0", text: $tagName)
            TextField("Message (optional)", text: $tagMessage)
            Button("Tag") {
                if let commit = tagging { Task { await git.tag(tagName, at: commit, message: tagMessage) } }
                tagging = nil
            }
            Button("Cancel", role: .cancel) { tagging = nil }
        }
        .confirmationDialog("Reset to “\(resetting?.summary ?? "")”?", isPresented: Binding(get: { resetting != nil }, set: { if !$0 { resetting = nil } }),
                            titleVisibility: .visible) {
            Button("Reset, keep the changes") {
                if let commit = resetting { Task { await git.reset(to: commit) } }
                resetting = nil
            }
        } message: {
            Text("The commits after it are taken off the branch; what they changed stays in your files, uncommitted. Undo puts them back.")
        }
        .task(id: "\(showEverything) \(git.log.first?.id.hex ?? "")") {
            reflog = showEverything ? await git.reflog() : []
        }
    }

    private func list(_ git: GitModel) -> some View {
        ScrollViewReader { proxy in
        List {
            Section {
                Button {
                    model.registry.run("git.commit")
                } label: {
                    Label(commitLabel(git), systemImage: "checkmark.circle")
                        .font(.footnote.weight(.semibold))
                }
                .disabled(git.status?.isClean ?? true)
                .listRowBackground(Color.clear)
                Button {
                    model.registry.run("git.sync")
                } label: {
                    Label(syncLabel(git), systemImage: "arrow.triangle.2.circlepath")
                        .font(.footnote)
                }
                .disabled(git.isSyncing)
                .listRowBackground(Color.clear)
                Button {
                    model.registry.run("git.editHistory")
                } label: {
                    Label("Edit history…", systemImage: "arrow.up.arrow.down")
                        .font(.footnote)
                }
                .listRowBackground(Color.clear)
                if let undo = git.undoTitle {
                    Button {
                        model.registry.run("git.undo")
                    } label: {
                        Label("Undo \(undo)", systemImage: "arrow.uturn.backward")
                            .font(.footnote)
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
                                    .font(.footnote)
                                    .foregroundStyle(palette.text.secondary.color)
                                Text(cp.date, format: .relative(presentation: .named))
                                    .font(.caption2)
                                    .foregroundStyle(palette.text.tertiary.color)
                            }
                            Spacer()
                            Button("Restore") {
                                Task { await model.workspace.restore(cp) }
                            }
                            .font(.caption)
                            .buttonStyle(.bordered)
                            .disabled(git.isBusy)
                        }
                        .listRowBackground(Color.clear)
                    }
                }
            }

            Section {
                Toggle("Show everything (reflog)", isOn: $showEverything)
                    .font(.footnote)
                    .listRowBackground(Color.clear)
                if showEverything {
                    ForEach(reflog) { entry in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.message.isEmpty ? "(no message)" : entry.message).font(.footnote).lineLimit(2)
                            HStack(spacing: 6) {
                                Text(entry.commit.short).monospaced()
                                Text(entry.date, format: .relative(presentation: .named))
                            }
                            .font(.caption2)
                            .foregroundStyle(palette.text.tertiary.color)
                        }
                        .listRowBackground(Color.clear)
                        .contextMenu {
                            Button("Copy commit ID", systemImage: "doc.on.doc") { UIPasteboard.general.string = entry.commit.hex }
                        }
                    }
                }
            }

            Section(git.status?.head.branch ?? "History") {
                if git.log.isEmpty {
                    Text("No commits yet")
                        .font(.footnote)
                        .foregroundStyle(palette.text.tertiary.color)
                        .listRowBackground(Color.clear)
                }
                ForEach(git.log) { commit in
                    CommitRow(commit: commit, tags: git.tags[commit.id] ?? [])
                        .id(commit.id)
                        // A commit opened from blame is marked.
                        .listRowBackground(model.timelineFocus == commit.id.hex ? palette.accent.ion.color.opacity(0.15) : Color.clear)
                        .contextMenu {
                            Button("Revert", systemImage: "arrow.uturn.backward") {
                                Task { await git.revert(commit) }
                            }
                            Button("Copy commit ID", systemImage: "doc.on.doc") {
                                UIPasteboard.general.string = commit.id.hex
                            }
                            Button("Tag…", systemImage: "tag") {
                                tagging = commit
                                tagName = ""
                            }
                            ForEach(git.tags[commit.id] ?? [], id: \.self) { name in
                                Button("Delete tag “\(name)”", systemImage: "tag.slash", role: .destructive) {
                                    Task { await git.deleteTag(name) }
                                }
                            }
                            if commit.id != git.log.first?.id {
                                Button("Reset to here (keep changes)", systemImage: "arrow.counterclockwise") {
                                    resetting = commit
                                }
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
        .onChange(of: model.timelineFocus, initial: true) {
            guard let hex = model.timelineFocus, let id = ObjectID(hex: hex) else { return }
            withAnimation { proxy.scrollTo(id, anchor: .center) }
        }
        }
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
    var tags: [String] = []

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
                    .agentVoice(density, when: isAgent, otherwise: .footnote)
                    .foregroundStyle(isAgent ? palette.accent.agent.color : palette.text.primary.color)
                    .lineLimit(2)
                HStack(spacing: 6) {
                    ForEach(tags, id: \.self) { tag in
                        Label(tag, systemImage: "tag.fill")
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(palette.accent.ion.color.opacity(0.15), in: Capsule())
                            .foregroundStyle(palette.accent.ion.color)
                    }
                    Text(commit.id.short).monospaced()
                    Text(commit.authorName)
                    if let model = commit.assistedBy { Text("· \(model)") }
                    Text(commit.date, format: .relative(presentation: .named))
                }
                .font(.caption2)
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
                        .font(.subheadline)
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
                                Text(entry.path).font(.system(.footnote, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                                Spacer()
                                Text(entry.kind.label).font(.caption).foregroundStyle(palette.text.secondary.color)
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
