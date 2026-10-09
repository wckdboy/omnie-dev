// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

import DesignKit
import EditorKit
import LangKit
import SwiftUI
import WorkspaceKit

/// A second editor (PLAN.md §5 "split editors"): a panel like any other, so it docks beside, below
/// or in its own window. It has its own file and saves on its own (3 s after typing, and when it
/// switches file); the same file open in both stays in step through saves.
@MainActor
@Observable
final class SplitEditorModel {
    @ObservationIgnored let editor = CodeEditorController(theme: EditorTheme(palette: .dark, density: .regular))
    private(set) var file: URL?
    private(set) var isDirty = false
    var error: String?
    @ObservationIgnored private var autosave: Task<Void, Never>?
    @ObservationIgnored private var loadedText = ""
    @ObservationIgnored weak var workspace: WorkspaceModel?

    init() {
        editor.onChange = { [weak self] in
            guard let self else { return }
            isDirty = true
            autosave?.cancel()
            autosave = Task { [weak self] in
                try? await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled else { return }
                self?.save()
            }
        }
    }

    func open(_ url: URL) {
        guard url != file else { return }
        save()
        // Look like the main editor (its theme follows appearance and density).
        if let theme = workspace?.editor.theme { editor.theme = theme }
        do {
            let text = try TextFile.load(url)
            editor.load(text, language: Language(url: url))
            editor.textView.accessibilityLabel = "Second editor, \(url.lastPathComponent)"
            loadedText = text
            file = url
            isDirty = false
            error = nil
        } catch {
            self.error = "Can't open \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }

    func close() {
        save()
        file = nil
        editor.load("", language: nil)
    }

    func save() {
        autosave?.cancel()
        guard let file, isDirty else { return }
        let text = editor.text
        do {
            try TextFile.save(text, to: file)
            loadedText = text
            isDirty = false
            // The main editor reloads the same file through the project watcher; this makes it now.
            if workspace?.openFile == file { workspace?.reloadOpenFileIfClean() }
        } catch {
            self.error = "Save failed: \(error.localizedDescription)"
        }
    }

    /// Something else saved: take the file's new text unless there are unsaved edits here.
    func refreshFromDisk() {
        guard let file, !isDirty, let text = try? TextFile.load(file), text != loadedText else { return }
        let selection = editor.selectedRange
        editor.load(text, language: Language(url: file))
        loadedText = text
        editor.onLoaded = { [weak self] in
            guard let self else { return }
            editor.selectedRange = NSRange(location: min(selection.location, (text as NSString).length), length: 0)
            editor.onLoaded = nil
        }
    }
}

/// The Editor 2 panel: a file picker above the second editor.
struct SplitEditorPanel: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var palette
    @Environment(\.density) private var density

    var body: some View {
        let split = model.split
        let workspace = model.workspace
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Menu {
                    if let current = workspace.openFile {
                        Button("The file in the main editor (\(current.lastPathComponent))") { split.open(current) }
                    }
                    Section("Open tabs") {
                        ForEach(workspace.tabs.map(\.url), id: \.self) { url in
                            Button(workspace.relativePath(of: url)) { split.open(url) }
                        }
                    }
                    Section("Recent") {
                        ForEach(workspace.recentFiles.prefix(10), id: \.self) { path in
                            if let root = workspace.rootURL { Button(path) { split.open(root.appending(path: path)) } }
                        }
                    }
                } label: {
                    Label(split.file.map { workspace.relativePath(of: $0) } ?? "Choose a file", systemImage: "doc.text")
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                .accessibilityLabel(split.file.map { "Second editor file: \($0.lastPathComponent). Change" } ?? "Choose a file for the second editor")
                if split.isDirty {
                    Circle().fill(palette.text.secondary.color).frame(width: 6, height: 6).accessibilityLabel("Unsaved changes")
                }
                Spacer()
                if split.file != nil {
                    Button { split.close() } label: { Image(systemName: "xmark") }
                        .accessibilityLabel("Close the file")
                        .font(.caption)
                }
            }
            .padding(.horizontal, 12)
            .frame(minHeight: density.tab)
            .background(palette.surface.pane.color)
            .overlay(alignment: .bottom) { Rectangle().fill(palette.surface.hairline.color).frame(height: Metrics.hairline) }
            if let error = split.error {
                Banner(text: error) { split.error = nil }
            }
            if split.file != nil {
                CodeEditor(controller: split.editor)
            } else {
                NotYet(title: "Editor 2", detail: "A second editor. Pick a file above, or use “Open in split” (⌘\\) for the file you're editing.")
            }
        }
        .background(palette.surface.editor.color)
        .onChange(of: palette, initial: true) { applyTheme() }
        .onChange(of: density) { applyTheme() }
        // Another save (the main editor's, the agent's, a tool's): refresh unless edited here.
        .onChange(of: workspace.changeCount) { split.refreshFromDisk() }
        .onDisappear { split.save() }
    }

    /// The main editor's theme, so both read alike.
    private func applyTheme() {
        model.workspace.applyEditorTheme(palette: palette, density: density)
        model.split.editor.theme = model.workspace.editor.theme
    }
}
