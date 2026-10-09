// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

import DesignKit
import GitKit
import SwiftUI

/// Remotes (PLAN.md §9.10) and "Move this repo" (§9.11): remotes labeled by host, added, renamed,
/// re-pointed or removed; and a move to another forge previewed step by step before it runs.
struct RemotesSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var palette
    @Environment(\.dismiss) private var dismiss
    @State private var newName = ""
    @State private var newURL = ""
    @State private var renaming: RemoteInfo?
    @State private var editingURL: RemoteInfo?
    @State private var removing: RemoteInfo?
    @State private var draft = ""
    // Move this repo.
    @State private var moveFrom = ""
    @State private var moveName = ""
    @State private var moveURL = ""
    @State private var plan: Result<MigrationPlan, Error>?
    @State private var moving = false

    var body: some View {
        let git = model.workspace.git
        NavigationStack {
            Form {
                Section("Remotes") {
                    if git.remotes.isEmpty { Text("No remotes. Add one below to push and sync.").foregroundStyle(palette.text.secondary.color) }
                    ForEach(git.remotes, id: \.name) { remote in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(remote.label).font(.subheadline.weight(.semibold))
                                if remote.isReadOnly {
                                    Text("fetch only").font(.caption2).padding(.horizontal, 6).padding(.vertical, 1)
                                        .background(palette.surface.raised.color, in: Capsule())
                                        .foregroundStyle(palette.text.secondary.color)
                                }
                            }
                            Text(remote.url).font(.caption.monospaced()).foregroundStyle(palette.text.tertiary.color).lineLimit(1).truncationMode(.middle)
                        }
                        .accessibilityElement(children: .combine)
                        .contextMenu {
                            Button("Rename…", systemImage: "pencil") { renaming = remote; draft = remote.name }
                            Button("Change URL…", systemImage: "link") { editingURL = remote; draft = remote.url }
                            if remote.isReadOnly {
                                Button("Allow pushes again", systemImage: "arrow.up") { Task { await git.editRemotes { try await $0.allowPushes(to: remote.name) } } }
                            }
                            Button("Remove", systemImage: "trash", role: .destructive) { removing = remote }
                        }
                    }
                }
                Section {
                    TextField("Name", text: $newName).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("URL (https:// or git@host:path)", text: $newURL).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    Button("Add remote") {
                        let (name, url) = (newName.trimmingCharacters(in: .whitespaces), newURL.trimmingCharacters(in: .whitespaces))
                        Task { await git.editRemotes { try await $0.addRemote(name: name, url: url) } }
                        newName = ""; newURL = ""
                    }
                    .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty || newURL.trimmingCharacters(in: .whitespaces).isEmpty)
                } header: { Text("Add a remote") }

                if !git.remotes.isEmpty {
                    Section {
                        Picker("From", selection: $moveFrom) {
                            ForEach(git.remotes, id: \.name) { Text($0.label).tag($0.name) }
                        }
                        TextField("New remote's name (e.g. forgejo)", text: $moveName).textInputAutocapitalization(.never).autocorrectionDisabled()
                        TextField("New forge URL", text: $moveURL).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                        switch plan {
                        case .success(let plan):
                            ForEach(Array(plan.steps.enumerated()), id: \.offset) { i, step in
                                Label(step, systemImage: "\(i + 1).circle").font(.footnote)
                            }
                            Button {
                                Task {
                                    moving = true
                                    defer { moving = false }
                                    if await git.migrate(plan, isOffline: model.networkUnavailable) { dismiss() }
                                }
                            } label: {
                                if moving { ProgressView() } else { Text("Move") }
                            }
                            .disabled(moving)
                        case .failure(let error):
                            Label((error as? LocalizedError)?.errorDescription ?? "\(error)", systemImage: "exclamationmark.triangle")
                                .foregroundStyle(palette.status.warn.color).font(.footnote)
                        case nil:
                            EmptyView()
                        }
                    } header: {
                        Text("Move this repo")
                    } footer: {
                        Text("Pushes your branches and tags to the new forge, makes your branches track it, and keeps the old remote for fetching only. Each step can run again if the network drops.")
                    }
                }
            }
            .navigationTitle("Remotes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task {
                await git.refreshRemotes()
                moveFrom = (try? await git.repo?.upstreamName())?.flatMap { $0.split(separator: "/").first.map(String.init) } ?? git.remotes.first?.name ?? ""
            }
            .task(id: "\(moveFrom)|\(moveName)|\(moveURL)") { await updatePlan() }
            .alert("Rename \(renaming?.name ?? "")", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField("Name", text: $draft)
                Button("Rename") {
                    if let r = renaming { let to = draft; Task { await git.editRemotes { try await $0.renameRemote(r.name, to: to) } } }
                    renaming = nil
                }
                Button("Cancel", role: .cancel) { renaming = nil }
            }
            .alert("URL of \(editingURL?.name ?? "")", isPresented: Binding(get: { editingURL != nil }, set: { if !$0 { editingURL = nil } })) {
                TextField("URL", text: $draft)
                Button("Save") {
                    if let r = editingURL { let url = draft; Task { await git.editRemotes { try await $0.setRemoteURL(r.name, url) } } }
                    editingURL = nil
                }
                Button("Cancel", role: .cancel) { editingURL = nil }
            }
            .confirmationDialog("Remove “\(removing?.name ?? "")”?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), titleVisibility: .visible) {
                Button("Remove", role: .destructive) {
                    if let r = removing { Task { await git.editRemotes { try await $0.removeRemote(r.name) } } }
                    removing = nil
                }
            } message: {
                Text("Only the link to it goes; nothing on the forge changes, and your commits stay.")
            }
        }
    }

    private func updatePlan() async {
        let name = moveName.trimmingCharacters(in: .whitespaces), url = moveURL.trimmingCharacters(in: .whitespaces)
        guard !moveFrom.isEmpty, !name.isEmpty, !url.isEmpty else { plan = nil; return }
        plan = await model.workspace.git.migrationPlan(from: moveFrom, to: name, url: url)
    }
}
