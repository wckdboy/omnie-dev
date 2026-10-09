// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

import SwiftUI
import DesignKit
import WorkspaceKit

/// Project file tree. Used by the iPad navigator and the iPhone Files tab.
struct Navigator: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var palette
    @Environment(\.density) private var density
    var onOpen: (URL) -> Void = { _ in }

    var body: some View {
        let workspace = model.workspace
        Group {
            if let root = workspace.root {
                List {
                    OutlineGroup(root.children ?? [], children: \.children) { node in
                        row(node)
                    }
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
                .environment(\.defaultMinListRowHeight, density.row)
                .refreshable { workspace.reload() }
            } else {
                EmptyProject()
            }
        }
        .background(palette.surface.pane.color)
    }

    private func row(_ node: FileNode) -> some View {
        let isOpen = model.workspace.openFile == node.url
        return Label(node.name, systemImage: node.isDirectory ? "folder" : "doc.text")
            .font(.system(size: 13))
            .foregroundStyle(isOpen ? palette.accent.ion.color : palette.text.primary.color)
            .contentShape(Rectangle())
            .onTapGesture {
                guard !node.isDirectory else { return }
                model.workspace.open(file: node.url)
                onOpen(node.url)
            }
            .contextMenu { menu(for: node) }
    }

    @ViewBuilder
    private func menu(for node: FileNode) -> some View {
        let workspace = model.workspace
        let folder = node.isDirectory ? node.url : node.url.deletingLastPathComponent()
        Button { workspace.namePrompt = .init(kind: .newFile, url: folder) } label: { Label("New File…", systemImage: "doc.badge.plus") }
        Button { workspace.namePrompt = .init(kind: .newFolder, url: folder) } label: { Label("New Folder…", systemImage: "folder.badge.plus") }
        Divider()
        Button { workspace.namePrompt = .init(kind: .rename, url: node.url) } label: { Label("Rename…", systemImage: "pencil") }
        Button { workspace.duplicate(node.url) } label: { Label("Duplicate", systemImage: "plus.square.on.square") }
        Button { UIPasteboard.general.string = workspace.relativePath(of: node.url) } label: { Label("Copy Path", systemImage: "doc.on.clipboard") }
        Divider()
        Button(role: .destructive) { workspace.pendingDelete = node.url } label: { Label("Delete", systemImage: "trash") }
    }
}

/// The prompts the navigator's file operations need: a name, or a delete confirmation.
struct FileOperationPrompts: ViewModifier {
    @Environment(AppModel.self) private var model
    @State private var name = ""

    func body(content: Content) -> some View {
        @Bindable var workspace = model.workspace
        let prompt = workspace.namePrompt
        content
            .alert(title(prompt), isPresented: Binding(get: { workspace.namePrompt != nil }, set: { if !$0 { workspace.namePrompt = nil } })) {
                TextField("Name", text: $name)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("Cancel", role: .cancel) { workspace.namePrompt = nil }
                Button(prompt?.kind == .rename ? "Rename" : "Create") {
                    guard let prompt else { return }
                    switch prompt.kind {
                    case .newFile: workspace.newFile(named: name, in: prompt.url)
                    case .newFolder: workspace.newFolder(named: name, in: prompt.url)
                    case .rename: workspace.rename(prompt.url, to: name)
                    }
                    workspace.namePrompt = nil
                }
            }
            .onChange(of: prompt?.id) { name = prompt?.kind == .rename ? prompt?.url.lastPathComponent ?? "" : "" }
            .confirmationDialog("Delete \(workspace.pendingDelete?.lastPathComponent ?? "")?",
                                isPresented: Binding(get: { workspace.pendingDelete != nil }, set: { if !$0 { workspace.pendingDelete = nil } }),
                                titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    if let url = workspace.pendingDelete { Task { await workspace.delete(url) } }
                    workspace.pendingDelete = nil
                }
            } message: {
                Text("A checkpoint is taken first, so you can restore it from the timeline.")
            }
    }

    private func title(_ prompt: WorkspaceModel.NamePrompt?) -> String {
        switch prompt?.kind {
        case .newFile: "New file in \(prompt?.url.lastPathComponent ?? "")"
        case .newFolder: "New folder in \(prompt?.url.lastPathComponent ?? "")"
        case .rename: "Rename \(prompt?.url.lastPathComponent ?? "")"
        case nil: ""
        }
    }
}

struct EmptyProject: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(spacing: 12) {
            Text("No project open")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(palette.text.primary.color)
            Text("Open a folder from Files, iCloud Drive or another app.")
                .font(.system(size: 13))
                .foregroundStyle(palette.text.secondary.color)
                .multilineTextAlignment(.center)
            HStack {
                Button("Open folder") { model.workspace.isPickingFolder = true }
                    .buttonStyle(.borderedProminent)
                Button("Clone") { model.registry.run("git.clone") }
                    .buttonStyle(.bordered)
            }
            if !model.workspace.recentProjects.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Recent")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(palette.text.secondary.color)
                        .padding(.bottom, 4)
                    ForEach(model.workspace.recentProjects) { ref in
                        Button { model.workspace.open(recent: ref) } label: {
                            Label(ref.name, systemImage: "folder")
                                .font(.system(size: 13))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(palette.text.primary.color)
                        .padding(.vertical, 4)
                        .contextMenu {
                            Button("Remove from Recent", role: .destructive) { model.workspace.forget(ref) }
                        }
                        .accessibilityHint("Opens the project")
                    }
                }
                .frame(maxWidth: 280)
                .padding(.top, 12)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Attaches the folder picker that `file.openFolder` triggers.
struct FolderPicker: ViewModifier {
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        @Bindable var workspace = model.workspace
        content.fileImporter(isPresented: $workspace.isPickingFolder, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { workspace.open(folder: url) }
        }
    }
}

extension View {
    func folderPicker() -> some View { modifier(FolderPicker()) }
}
