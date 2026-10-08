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
