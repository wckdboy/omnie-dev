// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

import DesignKit
import EditorKit
import GitKit
import LangKit
import PolicyKit
import SwiftUI
import WorkspaceKit

/// The open project folder and the file in the editor. Projects are remembered by bookmark and the
/// last one reopens at launch; a file presenter watches for changes made outside the app.
@MainActor
@Observable
final class WorkspaceModel {
    var isPickingFolder = false
    let git: GitModel
    @ObservationIgnored let policy: PolicyModel
    /// The code editor. It owns the text of the open file; read `editor.text` only to save (O(n)).
    @ObservationIgnored let editor = CodeEditorController(theme: EditorTheme(palette: .dark, density: .regular))
    @ObservationIgnored private var autosaveTask: Task<Void, Never>?
    private(set) var root: FileNode?
    private(set) var rootURL: URL?
    private var isAccessingRoot = false
    @ObservationIgnored let recents = RecentProjects(fileURL: AppPaths.support.appendingPathComponent("recent-projects.json"))
    private(set) var recentProjects: [ProjectRef] = []
    @ObservationIgnored private var watcher: ProjectWatcher?

    private(set) var openFile: URL?
    private(set) var language: Language?
    private(set) var isDirty = false
    /// 1-based caret position for the status strip.
    private(set) var cursor: (line: Int, column: Int)?

    /// One-line inline banner, per the brand rule: what happened and the one next action.
    var banner: String?

    init(policy: PolicyModel) {
        self.policy = policy
        git = GitModel(policy: policy)
        // Git operations that rewrite files (sync, branch switch, merge, restore) save the editor
        // first and reload it after, so a stale buffer never overwrites what git just wrote.
        git.beforeWorktreeChange = { [weak self] in self?.saveCurrent() }
        git.afterWorktreeChange = { [weak self] in self?.reloadFromDisk() }
        editor.onChange = { [weak self] in
            guard let self else { return }
            isDirty = true
            scheduleAutosave()
        }
        recentProjects = recents.load()
        editor.onSelectionChange = { [weak self] range in
            guard let self, let location = editor.textView.textLocation(at: range.location) else { return }
            cursor = (location.lineNumber + 1, location.column + 1)
        }
    }

    func open(folder url: URL) {
        if isDirty { saveCurrent() }
        watcher?.stop()
        if isAccessingRoot { rootURL?.stopAccessingSecurityScopedResource() }
        // Folders inside the app container need no grant, so false here is not an error by itself;
        // reload() reports if the folder really can't be read.
        isAccessingRoot = url.startAccessingSecurityScopedResource()
        rootURL = url
        policy.projectRoot = url
        closeFile()
        root = nil
        reload()
        guard root != nil else {
            // Unreadable: reload() set the banner. Leave nothing half-open.
            if isAccessingRoot { url.stopAccessingSecurityScopedResource() }
            isAccessingRoot = false
            rootURL = nil
            policy.projectRoot = nil
            return
        }
        _ = try? recents.remember(url)
        recentProjects = recents.load()
        startWatching(url)
        Task { await git.attach(url) }
    }

    /// Reopens a remembered project. When you pick one that's gone, it leaves the list.
    func open(recent ref: ProjectRef, forgetIfMissing: Bool = true) {
        if let url = recents.url(for: ref) { open(folder: url) }
        guard root == nil else { return }
        if forgetIfMissing {
            forget(ref)
            banner = "\(ref.name) isn't available any more. Open it again from Files."
        }
    }

    /// At launch: the project you had open last. Quietly skipped if it's unavailable right now
    /// (a disconnected drive, a provider that's signed out); it stays in Recent.
    func reopenLast() {
        guard rootURL == nil, let last = recentProjects.first else { return }
        open(recent: last, forgetIfMissing: false)
        if root == nil { banner = nil }
    }

    func forget(_ ref: ProjectRef) {
        try? recents.forget(ref.id)
        recentProjects = recents.load()
    }

    private func startWatching(_ url: URL) {
        let watcher = ProjectWatcher(root: url)
        watcher.onSaveRequest = { [weak self] in
            MainActor.assumeIsolated { self?.saveCurrent() }
        }
        watcher.onChange = { [weak self] urls in
            MainActor.assumeIsolated { self?.changedOutside(urls) }
        }
        watcher.start()
        self.watcher = watcher
    }

    /// Something outside Omnie-dev changed files: refresh the navigator, and the open file if it's
    /// clean. Unsaved edits are never overwritten; you're told instead.
    private func changedOutside(_ urls: Set<URL>) {
        reload()
        Task { await git.refresh() }
        guard let openFile, urls.contains(openFile.standardizedFileURL) else { return }
        if isDirty {
            banner = "\(openFile.lastPathComponent) changed outside Omnie-dev. Your unsaved edits are kept; saving replaces the other version."
        } else {
            reloadFromDisk()
        }
    }

    func reload() {
        guard let rootURL else { return }
        do { root = try FileTree.scan(rootURL) }
        catch { banner = "Can't read \(rootURL.lastPathComponent): \(error.localizedDescription)" }
    }

    func open(file url: URL) {
        if isDirty { saveCurrent() }
        do {
            let loaded = try TextFile.load(url, presenter: watcher)
            language = Language(url: url)
            editor.load(loaded, language: language)
            editor.textView.accessibilityLabel = "Code editor, \(url.lastPathComponent)"
            isDirty = false
            openFile = url
            cursor = (1, 1)
            banner = nil
        } catch TextFile.LoadError.binary {
            banner = "\(url.lastPathComponent) is a binary file. A viewer for it comes later."
        } catch TextFile.LoadError.tooLarge(let bytes) {
            banner = "\(url.lastPathComponent) is \(bytes / 1_048_576) MB, over the 8 MB editor limit."
        } catch {
            banner = "Can't open \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }

    private func closeFile() {
        openFile = nil
        language = nil
        cursor = nil
        isDirty = false
        editor.load("", language: nil)
    }

    /// Saves the open file, then checkpoints the project so nothing typed is ever lost (PLAN.md §9.3).
    func saveCurrent() {
        autosaveTask?.cancel()
        guard let openFile, isDirty else { return }
        do {
            try TextFile.save(editor.text, to: openFile, presenter: watcher)
            isDirty = false
        } catch {
            banner = "Save failed: \(error.localizedDescription). Try again."
            return
        }
        Task { await git.checkpoint(.save) }
    }

    /// Save after 3 s without typing.
    private func scheduleAutosave() {
        autosaveTask?.cancel()
        autosaveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            self?.saveCurrent()
        }
    }

    func restore(_ checkpoint: Checkpoint) async {
        _ = await git.restore(checkpoint)
    }

    /// Re-reads the navigator and the open file after something other than the editor changed files.
    func reloadFromDisk() {
        reload()
        guard let openFile else { return }
        if FileManager.default.fileExists(atPath: openFile.path(percentEncoded: false)),
           let loaded = try? TextFile.load(openFile, presenter: watcher) {
            let selection = editor.selectedRange
            editor.load(loaded, language: language)
            isDirty = false
            editor.onLoaded = { [weak self] in
                guard let self else { return }
                let length = (loaded as NSString).length
                editor.selectedRange = NSRange(location: min(selection.location, length), length: 0)
                editor.onLoaded = nil
            }
        } else {
            closeFile()
        }
    }

    /// Re-themes the editor when the appearance or density changes.
    func applyEditorTheme(palette: Palette, density: Density) {
        guard editor.theme.palette != palette || editor.theme.density != density else { return }
        editor.theme = EditorTheme(palette: palette, density: density)
    }

    var relativePath: String? {
        guard let openFile, let rootURL else { return nil }
        let path = openFile.path(percentEncoded: false)
        let base = rootURL.path(percentEncoded: false)
        return path.hasPrefix(base) ? String(path.dropFirst(base.count)).trimmingPrefix("/").description : openFile.lastPathComponent
    }
}
