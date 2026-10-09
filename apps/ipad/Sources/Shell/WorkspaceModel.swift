// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

import DesignKit
import EditorKit
import GitKit
import LangKit
import ModelKit
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
    /// Files opened in this project, newest first (quick open lists them first).
    private(set) var recentFiles: [String] = []
    @ObservationIgnored private var watcher: ProjectWatcher?
    /// The model for ghost text, when one is installed and suggestions are on. Set by AppModel.
    @ObservationIgnored var completionModel: (() async -> TextModel?)?
    /// Called after a project opens (the agent shows that project's tasks).
    @ObservationIgnored var onProjectOpened: ((URL) -> Void)?
    @ObservationIgnored private var suggestionTask: Task<Void, Never>?
    @ObservationIgnored private var editGeneration = 0

    private(set) var openFile: URL?
    private(set) var language: Language?
    private(set) var isDirty = false
    /// 1-based caret position for the status strip.
    private(set) var cursor: (line: Int, column: Int)?

    /// Goes up whenever files on disk change: a save, a change from outside, git rewriting files.
    /// The preview reloads on it.
    private(set) var changeCount = 0

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
            editGeneration += 1
            scheduleAutosave()
            scheduleSuggestion()
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
        recentFiles = []
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
        Task {
            await git.attach(url)
            onProjectOpened?(url)
        }
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
        changeCount += 1
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

    /// Opens a file and, once it's loaded, selects `range` and scrolls to it.
    func open(file url: URL, select range: NSRange) {
        open(file: url)
        guard openFile == url else { return }
        editor.onLoaded = { [weak self] in
            guard let self else { return }
            let length = (editor.text as NSString).length
            let clamped = NSRange(location: min(range.location, length), length: min(range.length, max(0, length - range.location)))
            editor.selectedRange = clamped
            editor.scrollRangeToVisible(clamped)
            editor.onLoaded = nil
        }
    }

    // MARK: File operations (navigator)

    /// A name being asked for (new file, new folder, rename); the navigator shows the prompt.
    struct NamePrompt: Identifiable {
        enum Kind { case newFile, newFolder, rename }
        let id = UUID()
        let kind: Kind
        /// The folder to create in, or the item to rename.
        let url: URL
    }
    var namePrompt: NamePrompt?
    /// An item waiting for delete confirmation.
    var pendingDelete: URL?

    /// The folder new files go in: the open file's folder, else the project root.
    var currentFolder: URL? {
        openFile?.deletingLastPathComponent() ?? rootURL
    }

    /// Creates an empty file and opens it.
    func newFile(named name: String, in folder: URL) {
        do {
            let url = try FileOperations.createFile(named: name, in: folder)
            reload()
            open(file: url)
        } catch { banner = error.localizedDescription }
    }

    func newFolder(named name: String, in folder: URL) {
        do { try FileOperations.createFolder(named: name, in: folder); reload() } catch { banner = error.localizedDescription }
    }

    func rename(_ url: URL, to name: String) {
        if isDirty { saveCurrent() }
        do {
            let renamed = try FileOperations.rename(url, to: name)
            // Keep the editor on the file (or on a file inside a renamed folder).
            if let openFile, openFile.path.hasPrefix(url.path) {
                let rest = String(openFile.path.dropFirst(url.path.count))
                self.openFile = URL(filePath: renamed.path + rest)
            }
            reload()
        } catch { banner = error.localizedDescription }
    }

    func duplicate(_ url: URL) {
        do { try FileOperations.duplicate(url); reload() } catch { banner = error.localizedDescription }
    }

    /// Deletes after a checkpoint, so even an untracked file can be brought back from the timeline.
    func delete(_ url: URL) async {
        if isDirty { saveCurrent() }
        await git.checkpoint(.delete)
        do {
            try FileOperations.delete(url)
            if let openFile, openFile.path.hasPrefix(url.path) { closeFile() }
            reload()
            banner = "Deleted \(url.lastPathComponent). It's in the timeline's checkpoints if you need it back."
        } catch { banner = error.localizedDescription }
    }

    /// Selects the start of a 1-based line in the open file.
    func goToLine(_ line: Int) {
        let text = editor.text as NSString
        var location = 0
        for _ in 1..<max(1, line) {
            let next = text.range(of: "\n", options: [], range: NSRange(location: location, length: text.length - location))
            guard next.location != NSNotFound else { break }
            location = next.location + 1
        }
        let range = NSRange(location: location, length: 0)
        editor.selectedRange = range
        editor.scrollRangeToVisible(range)
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
            if let path = relativePath {
                recentFiles.removeAll { $0 == path }
                recentFiles.insert(path, at: 0)
                if recentFiles.count > 20 { recentFiles.removeLast() }
            }
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
            changeCount += 1
        } catch {
            banner = "Save failed: \(error.localizedDescription). Try again."
            return
        }
        Task { await git.checkpoint(.save) }
    }

    /// Ghost text (PLAN.md §7): after a 300 ms pause with the caret at the end of a line, ask the
    /// local model for the rest of the line. Shown only if nothing changed while it thought.
    private func scheduleSuggestion() {
        suggestionTask?.cancel()
        guard completionModel != nil else { return }
        let generation = editGeneration
        suggestionTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, let self, let model = await completionModel?() else { return }
            let selection = editor.selectedRange
            let text = editor.text as NSString
            guard selection.length == 0, text.length < 2_000_000,
                  CodeEditorController.restOfLineIsBlank(text, from: selection.location) else { return }
            let prefix = text.substring(to: selection.location)
            let suffix = text.substring(from: selection.location)
            // Nothing to complete on a blank line.
            guard let lastLine = prefix.split(separator: "\n", omittingEmptySubsequences: false).last,
                  !lastLine.allSatisfy(\.isWhitespace) else { return }
            let raw = try? await model.complete(.raw(FIM.qwen(prefix: prefix, suffix: suffix)), maxTokens: 32,
                                                stop: FIM.qwenStops + ["\n"])
            guard !Task.isCancelled, generation == editGeneration, let raw else { return }
            let suggestion = FIM.trim(raw, suffix: suffix)
            if !suggestion.isEmpty { editor.showGhostText(suggestion, at: selection.location) }
        }
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
        changeCount += 1
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

    func relativePath(of url: URL) -> String {
        guard let rootURL else { return url.lastPathComponent }
        let path = url.path(percentEncoded: false), base = rootURL.path(percentEncoded: false)
        return path.hasPrefix(base) ? String(path.dropFirst(base.count)).trimmingPrefix("/").description : url.lastPathComponent
    }

    var relativePath: String? {
        guard let openFile, let rootURL else { return nil }
        let path = openFile.path(percentEncoded: false)
        let base = rootURL.path(percentEncoded: false)
        return path.hasPrefix(base) ? String(path.dropFirst(base.count)).trimmingPrefix("/").description : openFile.lastPathComponent
    }
}
