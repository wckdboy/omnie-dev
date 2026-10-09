// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

import SwiftUI
import DesignKit
import EditorKit
import GitKit
import LangKit
import WorkspaceKit

/// The code editor: the Runestone-derived Core Text engine (PLAN §5.1) with tree-sitter highlighting.
struct EditorPane: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var palette
    @Environment(\.density) private var density
    @State private var scopes: [Outline.Scope] = []
    @State private var firstLine = 1

    var body: some View {
        @Bindable var workspace = model.workspace
        VStack(spacing: 0) {
            // One file: the breadcrumbs below say which (and whether it's saved).
            if workspace.tabs.count > 1 {
                TabBar()
            }

            if let banner = workspace.banner ?? workspace.git.error {
                Banner(text: banner) {
                    workspace.banner = nil
                    workspace.git.error = nil
                }
            }

            if workspace.openFile != nil {
                Breadcrumbs(scopes: scopes)
                HStack(spacing: 0) {
                    if model.showsBlame && model.layout != .single {
                        BlameStrip(controller: workspace.editor)
                            .frame(width: 168)
                    }
                    CodeEditor(controller: workspace.editor)
                        .overlay(alignment: .top) {
                            StickyScopes(scopes: Outline.enclosing(line: firstLine, in: scopes).filter { $0.startLine < firstLine && $0.endLine > firstLine })
                        }
                    // The whole file at a glance, marks included; tap or drag to scroll (PLAN.md §5.1).
                    if model.showsMinimap && model.layout != .single {
                        MinimapStrip(controller: workspace.editor)
                            .frame(width: 72)
                    }
                }
            } else if workspace.root == nil {
                StartPage()
            } else {
                Text("Pick a file in the navigator")
                    .font(.footnote)
                    .foregroundStyle(palette.text.tertiary.color)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(palette.surface.editor.color)
        .onChange(of: palette, initial: true) { workspace.applyEditorTheme(palette: palette, density: density) }
        .onChange(of: density) { workspace.applyEditorTheme(palette: palette, density: density) }
        // Blame for the open file: on open, on save, and when it's turned on.
        .task(id: "\(model.showsBlame) \(workspace.relativePath ?? "") \(workspace.changeCount)") {
            guard model.showsBlame, let path = workspace.relativePath, let repo = workspace.git.repo else { return }
            let text = workspace.editor.text
            let hunks = (try? await repo.blame(path: path, contents: text)) ?? []
            workspace.editor.setBlame(hunks.map { hunk in
                let age = hunk.date.map { $0.formatted(.relative(presentation: .numeric, unitsStyle: .abbreviated)) } ?? "not committed"
                return BlameEntry(startLine: hunk.startLine, lineCount: hunk.lineCount, label: "\(hunk.assistedBy != nil ? "Agent" : hunk.author) · \(age)",
                                  commit: hunk.commit?.hex, isAgent: hunk.assistedBy != nil)
            })
        }
        .onAppear {
            let editor = workspace.editor
            editor.onBlameTap = { hex in
                model.timelineFocus = hex
                model.show(.timeline)
            }
            editor.onStructureChange = { scopes = editor.scopes }
            editor.onFirstVisibleLine = { firstLine = $0 }
            scopes = editor.scopes
        }
    }

}

/// Where the caret is: folder › file › enclosing symbols. Symbols jump to their line.
struct Breadcrumbs: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var palette
    let scopes: [Outline.Scope]

    var body: some View {
        let workspace = model.workspace
        let path = workspace.relativePath?.split(separator: "/").map(String.init) ?? []
        let line = workspace.cursor?.line ?? 1
        let symbols = Outline.enclosing(line: line, in: scopes)
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(Array(path.enumerated()), id: \.offset) { i, part in
                    if i > 0 { chevron }
                    Text(part).foregroundStyle(i == path.count - 1 ? palette.text.primary.color : palette.text.secondary.color)
                        // The editor itself announces "Code editor, <file>".
                        .accessibilityHidden(true)
                }
                if workspace.isDirty {
                    Circle().fill(palette.text.secondary.color).frame(width: 6, height: 6)
                        .accessibilityLabel("Unsaved changes")
                }
                ForEach(symbols, id: \.symbol.offset) { scope in
                    chevron
                    Button {
                        workspace.editor.selectedRange = NSRange(location: scope.symbol.offset, length: scope.symbol.length)
                        workspace.editor.scrollRangeToVisible(NSRange(location: scope.symbol.offset, length: scope.symbol.length))
                    } label: {
                        Label(scope.symbol.name, systemImage: CommandPalette.symbolIcon(scope.symbol.kind))
                            .labelStyle(.titleAndIcon)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(palette.text.secondary.color)
                    .accessibilityHint("Selects it in the editor")
                }
            }
            .font(.caption)
            .padding(.horizontal, 12)
        }
        .frame(minHeight: 26)
        .background(palette.surface.pane.color)
        .overlay(alignment: .bottom) { Rectangle().fill(palette.surface.hairline.color).frame(height: Metrics.hairline) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Breadcrumbs")
    }

    private var chevron: some View {
        Image(systemName: "chevron.right").font(.caption2).foregroundStyle(palette.text.tertiary.color).accessibilityHidden(true)
    }
}

/// The headers of the scopes the top of the editor is inside, pinned while you scroll; tap one to
/// go to it.
struct StickyScopes: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var palette
    @Environment(\.density) private var density
    let scopes: [Outline.Scope]

    var body: some View {
        let editor = model.workspace.editor
        if !scopes.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(scopes.suffix(3), id: \.symbol.offset) { scope in
                    Button { editor.scrollToLine(scope.startLine) } label: {
                        Text(editor.scopeHeaders[scope.startLine] ?? scope.symbol.name)
                            .font(.system(size: density.codeSize, design: .monospaced))
                            .foregroundStyle(palette.text.secondary.color)
                            .lineLimit(1)
                            .padding(.leading, 44)
                            .frame(maxWidth: .infinity, minHeight: density.codeSize * 1.5, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Inside \(scope.symbol.name), line \(scope.startLine)")
                }
            }
            .background(Rectangle().fill(palette.surface.editor.color).opacity(1))
            .compositingGroup()
            .overlay(alignment: .bottom) { Rectangle().fill(palette.surface.hairline.color).frame(height: Metrics.hairline) }
            .shadow(color: .black.opacity(0.15), radius: 3, y: 2)
        }
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
            Button("Close Others") { workspace.closeTabs(except: tab.url) }
            Button("Close to the Right") { workspace.closeTabs(after: tab.url) }
            Button("Close Saved") { workspace.closeSavedTabs() }
            Button("Close All") { workspace.closeTabs() }
            Divider()
            Button("Open in Split", systemImage: "rectangle.split.2x1") {
                workspace.open(file: tab.url, preview: false)
                model.registry.run("view.split")
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(tab.url.lastPathComponent + (tab.isPreview ? ", preview" : "") + (dirty ? ", unsaved" : ""))
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
    }
}

/// No project open: VS Code's Welcome page, in the editor's place. Start something, or pick up a
/// recent project.
struct StartPage: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var palette

    var body: some View {
        let workspace = model.workspace
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("Start").font(.title2.weight(.semibold))
                VStack(alignment: .leading, spacing: 10) {
                    entry("New project", "plus.rectangle.on.folder", "⌃⌘N") { model.newProjectOpen = true }
                    entry("Open folder", "folder", "⌘O") { workspace.isPickingFolder = true }
                    entry("Clone repository", "arrow.down.circle", nil) { model.cloneSheetOpen = true }
                    entry("Try the sample project", "sparkles", nil) {
                        Task { if let folder = try? await SampleProject.install() { workspace.open(folder: folder) } }
                    }
                }
                if !workspace.recentProjects.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Recent").font(.headline)
                        ForEach(workspace.recentProjects.prefix(8)) { ref in
                            Button { workspace.open(recent: ref) } label: {
                                Label(ref.name, systemImage: "folder").frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(palette.accent.ion.color)
                            .contextMenu {
                                Button("Remove from Recent", systemImage: "minus.circle", role: .destructive) { workspace.forget(ref) }
                            }
                        }
                        Button("More…") { model.projectsOpen = true }
                            .font(.footnote)
                            .foregroundStyle(palette.text.secondary.color)
                    }
                }
            }
            .padding(32)
            .frame(maxWidth: 520, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    private func entry(_ title: String, _ symbol: String, _ keys: String?, perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            HStack {
                Label(title, systemImage: symbol)
                Spacer()
                if let keys { Text(keys).font(.caption).foregroundStyle(palette.text.tertiary.color) }
            }
            .frame(maxWidth: 360)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(palette.accent.ion.color)
    }
}
