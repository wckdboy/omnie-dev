// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

import DesignKit
import GitKit
import ModelKit
import RunKit
import SwiftUI

/// "Prepare for offline" (PLAN.md §13.1, before boarding): fetches every recent project's remote,
/// re-verifies the installed models against their pinned checksums, and says plainly what will and
/// won't work in the air.
struct PrepareOfflineSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.palette) private var palette

    struct Item: Identifiable {
        let id = UUID()
        let title: String
        var state: State
        enum State: Equatable { case waiting, working, done(String), failed(String) }
    }

    @State private var projects: [Item] = []
    @State private var models: [Item] = []
    @State private var running = false
    @State private var finished = false

    var body: some View {
        NavigationStack {
            List {
                if model.policy.planeMode || model.isOffline {
                    Label(model.policy.planeMode ? "Plane mode is on. Turn it off to prepare." : "You're offline. Connect to prepare.",
                          systemImage: "wifi.slash").foregroundStyle(palette.status.warn.color)
                }
                if finished { Section { Text(summary).font(.headline) } }
                Section("Projects") {
                    if projects.isEmpty { Text("No recent projects.").foregroundStyle(palette.text.secondary.color) }
                    ForEach(projects) { row($0) }
                }
                Section("Models") {
                    if models.isEmpty { Text("No models installed. Download them in Settings › Models.").foregroundStyle(palette.text.secondary.color) }
                    ForEach(models) { row($0) }
                }
                Section {
                    Label("three.js, Python, Markdown and Mermaid are built in", systemImage: "checkmark.circle")
                    Label("Tests, previews, the Stage and the tools run offline", systemImage: "checkmark.circle")
                    Label("Each project's npm and Python dependencies are cached", systemImage: "checkmark.circle")
                        .foregroundStyle(palette.text.secondary.color)
                    Label(model.docs.installed.isEmpty ? "No offline docs yet: Help › Search docs to download them" : "Offline docs: " + model.docs.installed.map(\.title).joined(separator: ", "),
                          systemImage: model.docs.installed.isEmpty ? "exclamationmark.circle" : "checkmark.circle")
                        .foregroundStyle(palette.text.secondary.color)
                } header: { Text("Offline") }
            }
            .navigationTitle("Prepare for offline")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(running ? "Preparing…" : finished ? "Again" : "Prepare") { Task { await prepare() } }
                        .disabled(running || model.policy.planeMode || model.isOffline)
                }
            }
        }
        .onAppear(perform: list)
        #if DEBUG
        .task { if ProcessInfo.processInfo.arguments.contains("-OmniePrepare") { await prepare() } }
        #endif
    }

    private var summary: String {
        let ready = projects.filter { if case .done = $0.state { true } else { false } }.count
        let modelNames = ModelPack.catalog.filter { model.models.isInstalled($0) }.map { $0.role == .tiny ? "Tiny" : "7B" }
        let problems = (projects + models).filter { if case .failed = $0.state { true } else { false } }.count
        return "Ready: \(ready) project\(ready == 1 ? "" : "s"), \(modelNames.isEmpty ? "no local models" : modelNames.joined(separator: " + "))"
            + (problems > 0 ? " · \(problems) need\(problems == 1 ? "s" : "") attention" : "")
    }

    private func row(_ item: Item) -> some View {
        HStack {
            Text(item.title)
            Spacer()
            switch item.state {
            case .waiting: Text("").foregroundStyle(palette.text.tertiary.color)
            case .working: ProgressView().controlSize(.small)
            case .done(let note): Label(note, systemImage: "checkmark").foregroundStyle(palette.status.ok.color)
            case .failed(let note): Text(note).foregroundStyle(palette.status.error.color).lineLimit(2)
            }
        }
        .font(.footnote)
    }

    private func list() {
        projects = model.workspace.recents.available().map { Item(title: $0.ref.name, state: .waiting) }
        models = ModelPack.catalog.filter { model.models.isInstalled($0) }.map { Item(title: $0.displayName, state: .waiting) }
    }

    private func prepare() async {
        running = true
        finished = false
        list()
        let auth = model.workspace.git.remoteAuth
        for (i, entry) in model.workspace.recents.available().enumerated() where i < projects.count {
            projects[i].state = .working
            let url = entry.url
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            var notes: [String] = []
            var failure: String?
            if Repository.exists(at: url) {
                do {
                    let repo = try Repository.open(at: url)
                    try await repo.fetch(auth: auth)
                    notes.append("Fetched")
                } catch {
                    let text = (error as? GitError)?.message ?? error.localizedDescription
                    if text.lowercased().contains("remote") && text.lowercased().contains("origin") { notes.append("No remote") } else { failure = text }
                }
            } else {
                notes.append("Not a git project")
            }
            // Its npm dependencies into the offline cache.
            if !NpmCache.projectDependencies(url).isEmpty {
                do {
                    let added = try await Packages.cache.installProject(url)
                    notes.append(added.isEmpty ? "Packages cached" : "\(added.count) \(added.count == 1 ? "package" : "packages") cached")
                } catch {
                    failure = failure ?? error.localizedDescription
                }
            }
            if !PyCache.projectRequirements(url).isEmpty {
                do {
                    let added = try await Packages.python.installProject(url)
                    notes.append(added.isEmpty ? "Python packages cached" : "\(added.count) Python \(added.count == 1 ? "package" : "packages") cached")
                } catch {
                    failure = failure ?? error.localizedDescription
                }
            }
            projects[i].state = failure.map { .failed($0) } ?? .done(notes.joined(separator: " · "))
        }
        for (i, pack) in ModelPack.catalog.filter({ model.models.isInstalled($0) }).enumerated() where i < models.count {
            models[i].state = .working
            let t0 = Date()
            do {
                try await model.models.store.verify(pack)
                models[i].state = .done(String(format: "Verified in %.1f s", Date().timeIntervalSince(t0)))
            } catch {
                models[i].state = .failed(error.localizedDescription)
            }
        }
        await model.models.refresh()
        running = false
        finished = true
    }
}
