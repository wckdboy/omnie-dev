// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

import SwiftUI
import DesignKit
import EditorKit
import WorkspaceKit

/// The code editor: the Runestone-derived Core Text engine (PLAN §5.1) with tree-sitter highlighting.
struct EditorPane: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var palette
    @Environment(\.density) private var density

    var body: some View {
        @Bindable var workspace = model.workspace
        VStack(spacing: 0) {
            if workspace.tabs.count > 1 {
                TabBar()
            } else if let path = workspace.relativePath {
                HStack(spacing: 6) {
                    Text(path)
                        .font(.caption)
                        // The editor itself announces "Code editor, <file>".
                        .accessibilityHidden(true)
                        .foregroundStyle(palette.text.secondary.color)
                        .lineLimit(1)
                        .truncationMode(.head)
                    if workspace.isDirty {
                        Circle().fill(palette.text.secondary.color).frame(width: 6, height: 6)
                            .accessibilityLabel("Unsaved changes")
                    }
                    Spacer()
                }
                .padding(.horizontal, 12)
                .frame(minHeight: density.tab)
                .background(palette.surface.pane.color)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(palette.surface.hairline.color).frame(height: Metrics.hairline)
                }
            }

            if let banner = workspace.banner ?? workspace.git.error {
                Banner(text: banner) {
                    workspace.banner = nil
                    workspace.git.error = nil
                }
            }

            if workspace.openFile != nil {
                HStack(spacing: 0) {
                    CodeEditor(controller: workspace.editor)
                    // The whole file at a glance, marks included; tap or drag to scroll (PLAN.md §5.1).
                    if model.showsMinimap && model.layout != .single {
                        MinimapStrip(controller: workspace.editor)
                            .frame(width: 72)
                    }
                }
            } else {
                Text(workspace.root == nil ? "Open a folder to start" : "Pick a file in the navigator")
                    .font(.footnote)
                    .foregroundStyle(palette.text.tertiary.color)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(palette.surface.editor.color)
        .onChange(of: palette, initial: true) { workspace.applyEditorTheme(palette: palette, density: density) }
        .onChange(of: density) { workspace.applyEditorTheme(palette: palette, density: density) }
    }

}

/// Inline, one line, one action. No modal alerts for recoverable errors.
struct Banner: View {
    @Environment(\.palette) private var palette
    let text: String
    let dismiss: () -> Void

    var body: some View {
        HStack {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(palette.status.warn.color)
            Text(text)
                .font(.footnote)
                .foregroundStyle(palette.text.primary.color)
            Spacer()
            Button("Dismiss", action: dismiss)
                .font(.footnote)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(palette.surface.raised.color)
    }
}

/// Editor tabs (PLAN.md §3.10): italic while previewing, a dirty dot that becomes a close button on
/// hover, the oldest folded into an overflow menu past 8. Only shown with more than one file.
struct TabBar: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var palette
    @Environment(\.density) private var density

    static let visibleLimit = 8

    var body: some View {
        let workspace = model.workspace
        let tabs = workspace.tabs
        let overflow = tabs.count > Self.visibleLimit ? Array(tabs.prefix(tabs.count - Self.visibleLimit)) : []
        let visible = Array(tabs.suffix(Self.visibleLimit))
        HStack(spacing: 0) {
            if !overflow.isEmpty {
                Menu {
                    ForEach(overflow) { tab in
                        Button(tab.url.lastPathComponent) { workspace.open(file: tab.url, preview: false) }
                    }
                } label: {
                    Image(systemName: "chevron.left.2").font(.caption2).frame(width: 28, height: density.tab)
                }
                .accessibilityLabel("\(overflow.count) more tabs")
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(visible) { tab in TabButton(tab: tab) }
                }
            }
            Spacer(minLength: 0)
        }
        .frame(minHeight: density.tab)
        .background(palette.surface.pane.color)
        .overlay(alignment: .bottom) { Rectangle().fill(palette.surface.hairline.color).frame(height: Metrics.hairline) }
    }
}

private struct TabButton: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var palette
    let tab: WorkspaceModel.EditorTab
    @State private var hovering = false

    var body: some View {
        let workspace = model.workspace
        let isCurrent = workspace.openFile == tab.url
        let dirty = isCurrent && workspace.isDirty
        HStack(spacing: 6) {
            Text(tab.url.lastPathComponent)
                .font(.caption)
                .italic(tab.isPreview)
                .accessibilityLabel("\(tab.url.lastPathComponent), \(tab.isPreview ? "preview tab" : "tab")")
                .foregroundStyle(isCurrent ? palette.text.primary.color : palette.text.secondary.color)
                .lineLimit(1)
            ZStack {
                if dirty && !hovering {
                    Circle().fill(palette.text.secondary.color).frame(width: 6, height: 6)
                } else if hovering || isCurrent {
                    Button { workspace.closeTab(tab.url) } label: {
                        Image(systemName: "xmark").font(.caption2.weight(.semibold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(palette.text.secondary.color)
                    .accessibilityLabel("Close \(tab.url.lastPathComponent)")
                }
            }
            .frame(width: 12)
        }
        .padding(.horizontal, 12)
        .frame(maxHeight: .infinity)
        .background(isCurrent ? palette.surface.editor.color : .clear)
        .overlay(alignment: .top) { if isCurrent { Rectangle().fill(palette.accent.ion.color).frame(height: 2) } }
        .overlay(alignment: .trailing) { Rectangle().fill(palette.surface.hairline.color).frame(width: Metrics.hairline) }
        .contentShape(Rectangle())
        .onTapGesture { workspace.open(file: tab.url, preview: false) }
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Close") { workspace.closeTab(tab.url) }
            Button("Close Others") { for other in workspace.tabs where other.url != tab.url { workspace.closeTab(other.url) } }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(tab.url.lastPathComponent + (tab.isPreview ? ", preview" : "") + (dirty ? ", unsaved" : ""))
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
    }
}
