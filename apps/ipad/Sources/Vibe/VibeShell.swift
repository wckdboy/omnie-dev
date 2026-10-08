// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

import SwiftUI
import DesignKit

/// iPhone: vibecoding, agent first. You describe, review and preview here; deep editing lives on iPad.
/// Tabs follow the loop: Agent → Changes → Preview, with Files for a quick look or a small fix.
struct VibeShell: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var palette
    @State private var tab: VibeTab = .agent
    @State private var editingFile = false
    @State private var cursor: (line: Int, column: Int)?

    enum VibeTab: Hashable { case agent, changes, preview, files }

    var body: some View {
        TabView(selection: $tab) {
            Tab("Agent", systemImage: "text.bubble", value: .agent) {
                NavigationStack {
                    AgentPanel()
                        .navigationTitle(model.workspace.rootURL?.lastPathComponent ?? "Omnie-dev")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar { projectMenu }
                }
            }
            Tab("Changes", systemImage: "plusminus", value: .changes) {
                NavigationStack {
                    // Agent changesets (violet hunks, swipe to accept or reject) join this list in P2.
                    TimelineView()
                        .navigationTitle("Changes")
                        .navigationBarTitleDisplayMode(.inline)
                }
            }
            Tab("Preview", systemImage: "safari", value: .preview) {
                NavigationStack {
                    NotYet(title: "Preview", detail: "Run the project's dev task and see it here. Arrives with RunKit in P3.")
                        .background(palette.surface.pane.color)
                        .navigationTitle("Preview")
                        .navigationBarTitleDisplayMode(.inline)
                }
            }
            Tab("Files", systemImage: "folder", value: .files) {
                NavigationStack {
                    Navigator(onOpen: { _ in editingFile = true })
                        .navigationTitle("Files")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar { projectMenu }
                        .navigationDestination(isPresented: $editingFile) {
                            EditorPane(cursor: $cursor)
                                .navigationTitle(model.workspace.openFile?.lastPathComponent ?? "")
                                .navigationBarTitleDisplayMode(.inline)
                                .toolbar {
                                    ToolbarItem(placement: .confirmationAction) {
                                        Button("Save") { model.registry.run("file.save") }
                                            .disabled(!model.workspace.isDirty)
                                    }
                                }
                        }
                }
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if model.isOffline {
                Label("Offline", systemImage: "airplane")
                    .font(.system(size: 12))
                    .foregroundStyle(palette.text.secondary.color)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
                    .background(palette.surface.chrome.color)
            }
        }
        .overlay(alignment: .top) {
            if model.paletteOpen {
                CommandPalette()
                    .padding(.top, 8)
                    .padding(.horizontal, 16)
            }
        }
        .folderPicker()
        .gitSheets(model)
    }

    @ToolbarContentBuilder
    private var projectMenu: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button("Open folder", systemImage: "folder.badge.plus") { model.registry.run("file.openFolder") }
                Button("Clone repository", systemImage: "square.and.arrow.down") { model.registry.run("git.clone") }
                Button("Sync", systemImage: "arrow.triangle.2.circlepath") { model.registry.run("git.sync") }
                Button("Branches", systemImage: "arrow.triangle.branch") { model.registry.run("git.branches") }
                Button("SSH key", systemImage: "key") { model.registry.run("git.sshKey") }
                Button("Commands", systemImage: "command") { model.registry.run("palette.open") }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .accessibilityLabel("Project")
        }
    }
}
