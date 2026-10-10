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
    /// Type errors, for TypeScript projects.
    let problems = ProblemsModel()
    @ObservationIgnored let recents = RecentProjects(fileURL: AppPaths.support.appendingPathComponent("recent-projects.json"))
    private(set) var recentProjects: [ProjectRef] = []
    /// Files opened in this project, newest first (quick open lists them first).
    private(set) var recentFiles: [String] = []

    /// Editor tabs (PLAN.md §3.10). A preview tab is replaced by the next file you open, until
    /// you edit it.
    struct EditorTab: Identifiable, Equatable {
        var id: URL { url }
        var url: URL
        var isPreview: Bool
        /// Where the caret was, restored when you come back.
        var selection = NSRange(location: 0, length: 0)
    }
    private(set) var tabs: [EditorTab] = [] { didSet { saveSession() } }
    /// Off for launches that set up their own files (UI-test fixtures), so an earlier run's tabs
    /// don't come back into them.
    @ObservationIgnored var restoresSessions = true
    /// Off while a project opens, so clearing the last one's tabs doesn't overwrite this one's.
    @ObservationIgnored private var savesSession = true
    /// The caret in each open file, as you move it (saved with the session, not on every move).
    @ObservationIgnored private var carets: [URL: Int] = [:]
    @ObservationIgnored private var watcher: ProjectWatcher?
    /// The model for ghost text, when one is installed and suggestions are on. Set by AppModel.
    @ObservationIgnored var completionModel: (() async -> TextModel?)?
    /// Called after a project opens (the agent shows that project's tasks).
    @ObservationIgnored var onProjectOpened: ((URL) -> Void)?
    /// After each edit in the editor (completions as you type).
    @ObservationIgnored var onEdited: (() -> Void)?
    @ObservationIgnored var onProjectClosed: (() -> Void)?
    /// Whether ghost text should stay away (a completion list is showing).
    @ObservationIgnored var suppressesGhostText: () -> Bool = { false }
    @ObservationIgnored private var suggestionTask: Task<Void, Never>?
    @ObservationIgnored private var editGeneration = 0

    private(set) var openFile: URL? { didSet { saveSession() } }
    private(set) var language: Language?
    private(set) var isDirty = false
    /// 1-based caret position for the status strip.
    private(set) var cursor: (line: Int, column: Int)?

    /// Goes up whenever files on disk change: a save, a change from outside, git rewriting files.
    /// The preview reloads on it.
    private(set) var changeCount = 0

    /// One-line inline banner, per the brand rule: what happened and the one next action.
    var banner: String?
    /// A file the editor can't show, open in the binary viewer.
    var binaryFile: URL?

    init(policy: PolicyModel) {
        self.policy = policy
        git = GitModel(policy: policy)
        // Git operations that rewrite files (sync, branch switch, merge, restore) save the editor
        // first and reload it after, so a stale buffer never overwrites what git just wrote.
        git.beforeWorktreeChange = { [weak self] in self?.saveCurrent() }
        git.afterWorktreeChange = { [weak self] in self?.reloadFromDisk() }
        // New results mark the open file, unless it changed since the save they describe.
        problems.onUpdate = { [weak self] in
            guard let self, openFile != nil, !isDirty else { return }
            editor.setMarks(problems.marks(for: relativePath))
        }
        editor.onChange = { [weak self] in
            guard let self else { return }
            isDirty = true
            editGeneration += 1
            if let i = tabs.firstIndex(where: { $0.url == openFile }), tabs[i].isPreview { tabs[i].isPreview = false }
            scheduleAutosave()
            scheduleSuggestion()
            onEdited?()
            // The selection change that follows an edit is the edit's own, not a move.
            justEdited = true
            DispatchQueue.main.async { [weak self] in self?.justEdited = false }
        }
        recentProjects = recents.available().map(\.ref)
        editor.onSelectionChange = { [weak self] range in
            guard let self, let location = editor.textView.textLocation(at: range.location) else { return }
            cursor = (location.lineNumber + 1, location.column + 1)
            if let openFile, !editor.isLoading { carets[openFile] = range.location }
            // Moving the caret (a tap, an arrow) goes back to one cursor, as in VS Code.
            if !justEdited, !extraCaretsJustSet, !editor.textView.additionalCaretLocations.isEmpty {
                editor.textView.additionalCaretLocations = []
            }
        }
        // Where the caret is, kept when the app goes to the background.
        NotificationCenter.default.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.saveSession() }
        }
    }

    // MARK: Session (open tabs, the open file and its caret, per project)

    struct Session: Codable, Equatable {
        struct Tab: Codable, Equatable {
            var path: String
            var isPreview: Bool
            var location: Int
        }
        var tabs: [Tab]
        var open: String?
    }

    nonisolated static func sessionKey(for root: URL) -> String {
        AppModel.layoutKey(for: root).replacingOccurrences(of: AppModel.panesKey + "@", with: "tabs.v1@")
    }

    func saveSession() {
        guard let rootURL, restoresSessions, savesSession else { return }
        let session = Session(
            tabs: tabs.map { Session.Tab(path: relativePath(of: $0.url), isPreview: $0.isPreview, location: carets[$0.url] ?? $0.selection.location) },
            open: openFile.map(relativePath(of:)))
        if let data = try? JSONEncoder().encode(session) { UserDefaults.standard.set(data, forKey: Self.sessionKey(for: rootURL)) }
    }

    /// Brings back the tabs a project had, the open file last, with the caret where it was.
    /// Files that are gone are skipped.
    private func restoreSession(_ root: URL) {
        guard restoresSessions, let data = UserDefaults.standard.data(forKey: Self.sessionKey(for: root)),
              let session = try? JSONDecoder().decode(Session.self, from: data) else { return }
        let restored = session.tabs.compactMap { tab -> EditorTab? in
            let url = root.appending(path: tab.path)
            guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else { return nil }
            return EditorTab(url: url, isPreview: tab.isPreview, selection: NSRange(location: tab.location, length: 0))
        }
        guard !restored.isEmpty else { return }
        tabs = restored
        for tab in restored { carets[tab.url] = tab.selection.location }
        let current = session.open.flatMap { path in restored.first { relativePath(of: $0.url) == path } } ?? restored.last!
        open(file: current.url, preview: current.isPreview)
    }

    func open(folder url: URL) {
        if isDirty { saveCurrent() }
        saveSession()
        savesSession = false
        defer { savesSession = true }
        carets = [:]
        watcher?.stop()
        if isAccessingRoot { rootURL?.stopAccessingSecurityScopedResource() }
        // Folders inside the app container need no grant, so false here is not an error by itself;
        // reload() reports if the folder really can't be read.
        isAccessingRoot = url.startAccessingSecurityScopedResource()
        rootURL = url
        policy.projectRoot = url
        closeFile()
        recentFiles = []
        tabs = []
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
        recentProjects = recents.available().map(\.ref)
        startWatching(url)
        savesSession = true
        restoreSession(url)
        problems.clear()
        problems.schedule(root: url, after: .milliseconds(300))
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
        recentProjects = recents.available().map(\.ref)
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
        if let rootURL { problems.schedule(root: rootURL) }
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
        if openFile == url, !editor.isLoading {
            // Already loaded: select now.
            let length = (editor.text as NSString).length
            let clamped = NSRange(location: min(range.location, length), length: min(range.length, max(0, length - range.location)))
            editor.selectedRange = clamped
            editor.scrollRangeToVisible(clamped)
            return
        }
        // Not open yet, or still loading (opened a moment ago): select once its text is in.
        if openFile != url { open(file: url) }
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
            func moved(_ u: URL) -> URL? {
                guard u.path == url.path || u.path.hasPrefix(url.path + "/") else { return nil }
                return URL(filePath: renamed.path + String(u.path.dropFirst(url.path.count)))
            }
            if let openFile, let new = moved(openFile) { self.openFile = new }
            for i in tabs.indices { if let new = moved(tabs[i].url) { tabs[i].url = new } }
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
            let gone = { (u: URL) in u.path == url.path || u.path.hasPrefix(url.path + "/") }
            if let openFile, gone(openFile) { closeFile() }
            tabs.removeAll { gone($0.url) }
            if openFile == nil, let next = tabs.first { open(file: next.url, preview: false) }
            reload()
            banner = "Deleted \(url.lastPathComponent). It's in the timeline's checkpoints if you need it back."
        } catch { banner = error.localizedDescription }
    }

    /// Selects the start of a 1-based line in the open file.
    /// Opens a project file at a 1-based line and column (jump to source from output).
    func open(path: String, line: Int, column: Int?) {
        guard let rootURL else { return }
        let url = rootURL.appending(path: path)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        let ns = text as NSString
        var location = 0
        for _ in 1..<max(1, line) {
            let next = ns.range(of: "\n", options: [], range: NSRange(location: location, length: ns.length - location))
            guard next.location != NSNotFound else { break }
            location = next.location + 1
        }
        location = min(ns.length, location + max(0, (column ?? 1) - 1))
        open(file: url, select: NSRange(location: location, length: 0))
    }

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

    func open(file url: URL, preview: Bool = true) {
        if let current = openFile, current == url {
            if !preview, let i = tabs.firstIndex(where: { $0.url == url }) { tabs[i].isPreview = false }
            return
        }
        if let current = openFile, let i = tabs.firstIndex(where: { $0.url == current }) { tabs[i].selection = editor.selectedRange }
        if isDirty { saveCurrent() }
        do {
            let loaded = try TextFile.load(url, presenter: watcher)
            language = Language(url: url)
            editor.load(loaded, language: language, marks: problems.marks(for: relativePath(of: url)))
            editor.textView.accessibilityLabel = "Code editor, \(url.lastPathComponent)"
            isDirty = false
            openFile = url
            if let i = tabs.firstIndex(where: { $0.url == url }) {
                if !preview { tabs[i].isPreview = false }
                let selection = tabs[i].selection
                if selection.location > 0 {
                    editor.onLoaded = { [weak self] in
                        guard let self else { return }
                        let length = (editor.text as NSString).length
                        let r = NSRange(location: min(selection.location, length), length: 0)
                        editor.selectedRange = r
                        editor.scrollRangeToVisible(r)
                        editor.onLoaded = nil
                    }
                }
            } else if preview, let i = tabs.firstIndex(where: \.isPreview) {
                tabs[i] = EditorTab(url: url, isPreview: true)
            } else {
                tabs.append(EditorTab(url: url, isPreview: preview))
            }
            if let path = relativePath {
                recentFiles.removeAll { $0 == path }
                recentFiles.insert(path, at: 0)
                if recentFiles.count > 20 { recentFiles.removeLast() }
            }
            cursor = (1, 1)
            banner = nil
        } catch TextFile.LoadError.binary {
            binaryFile = url
        } catch TextFile.LoadError.tooLarge {
            // Over the editor's 8 MB: the byte view still opens it.
            binaryFile = url
        } catch {
            banner = "Can't open \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }

    // MARK: Multiple cursors (engine patch 0012: carets, typing and backspace at each)

    @ObservationIgnored private var justEdited = false
    @ObservationIgnored private var extraCaretsJustSet = false

    var hasExtraCarets: Bool { !editor.textView.additionalCaretLocations.isEmpty }

    /// ⌥⌘↓ / ⌥⌘↑: one more caret on the next line down (up), at the same column.
    func addCursor(above: Bool) {
        guard openFile != nil else { return }
        let carets = editor.textView.additionalCaretLocations + [editor.selectedRange.location]
        guard let next = MultiCaret.adjacent(in: editor.text, carets: carets, above: above) else { return }
        setExtraCarets(editor.textView.additionalCaretLocations + [next])
    }

    /// ⇧⌘L: every whole-word occurrence of the word at the caret (or the selection) removed, with a
    /// caret where each was, so what you type goes in everywhere. ⌘Z brings the word back.
    func changeAllOccurrences() {
        guard openFile != nil else { return }
        let text = editor.text
        let selection = editor.selectedRange
        guard let target = selection.length > 0 ? selection : MultiCaret.word(in: text, at: selection.location) else { return }
        let needle = (text as NSString).substring(with: target)
        let ranges = MultiCaret.occurrences(of: needle, in: text)
        guard ranges.count > 1 else {
            banner = "“\(needle)” appears only once here."
            return
        }
        let (_, carets) = MultiCaret.removing(ranges, from: text)
        // One edit per occurrence, from the end, so earlier offsets stay put; then the carets.
        for r in ranges.reversed() { editor.replace(r, with: "") }
        let primaryIndex = ranges.firstIndex { NSLocationInRange(selection.location, NSRange(location: $0.location, length: $0.length + 1)) } ?? 0
        extraCaretsJustSet = true
        editor.selectedRange = NSRange(location: carets[primaryIndex], length: 0)
        var others = carets
        others.remove(at: primaryIndex)
        setExtraCarets(others)
        banner = "\(ranges.count) cursors: type to replace “\(needle)” everywhere; Esc for one cursor."
    }

    func clearExtraCarets() {
        editor.textView.additionalCaretLocations = []
    }

    private func setExtraCarets(_ locations: [Int]) {
        extraCaretsJustSet = true
        editor.textView.additionalCaretLocations = locations
        DispatchQueue.main.async { [weak self] in self?.extraCaretsJustSet = false }
    }

    /// Recently closed tabs, newest last (⌥⌘T reopens them).
    @ObservationIgnored private var closedTabs: [URL] = []

    /// Closes a tab, moving to its neighbor if it was the open one.
    func closeTab(_ url: URL) {
        guard let i = tabs.firstIndex(where: { $0.url == url }) else { return }
        closedTabs.removeAll { $0 == url }
        closedTabs.append(url)
        if closedTabs.count > 30 { closedTabs.removeFirst() }
        if openFile == url {
            if isDirty { saveCurrent() }
            tabs.remove(at: i)
            if tabs.isEmpty { closeFile() } else { open(file: tabs[min(i, tabs.count - 1)].url, preview: false) }
        } else {
            tabs.remove(at: i)
        }
    }

    /// Closes every tab but `keep`'s (all of them when nil).
    func closeTabs(except keep: URL? = nil) {
        for tab in tabs where tab.url != keep { closeTab(tab.url) }
    }

    /// Closes the tabs after `url`'s, as VS Code's "Close to the Right".
    func closeTabs(after url: URL) {
        guard let i = tabs.firstIndex(where: { $0.url == url }) else { return }
        for tab in tabs[(i + 1)...] { closeTab(tab.url) }
    }

    /// Closes the tabs with nothing unsaved (only the open file can be).
    func closeSavedTabs() {
        for tab in tabs where !(tab.url == openFile && isDirty) { closeTab(tab.url) }
    }

    /// Reopens the last closed tab that still exists.
    func reopenClosedTab() {
        while let url = closedTabs.popLast() {
            if FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
                open(file: url, preview: false)
                return
            }
        }
    }

    /// Closes the project: saved first, then nothing open (the welcome and recent list show).
    func closeFolder() {
        if isDirty { saveCurrent() }
        saveSession()
        watcher?.stop()
        watcher = nil
        if isAccessingRoot { rootURL?.stopAccessingSecurityScopedResource() }
        isAccessingRoot = false
        savesSession = false
        closeFile()
        tabs = []
        closedTabs = []
        carets = [:]
        savesSession = true
        rootURL = nil
        root = nil
        policy.projectRoot = nil
        recentFiles = []
        problems.clear()
        onProjectClosed?()
        Task { await git.detach() }
    }

    /// ⌃Tab / ⌃⇧Tab.
    func cycleTab(by step: Int) {
        guard tabs.count > 1, let current = openFile, let i = tabs.firstIndex(where: { $0.url == current }) else { return }
        open(file: tabs[(i + step + tabs.count) % tabs.count].url, preview: false)
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
            if let rootURL { problems.schedule(root: rootURL) }
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
            if !suggestion.isEmpty, !suppressesGhostText() { editor.showGhostText(suggestion, at: selection.location) }
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

    /// Throws away unsaved edits: the file as it is on disk.
    func revertFile() {
        autosaveTask?.cancel()
        isDirty = false
        reloadFromDisk()
    }

    /// Re-reads the navigator and the open file after something other than the editor changed files.
    func reloadFromDisk() {
        changeCount += 1
        if let rootURL { problems.schedule(root: rootURL) }
        reload()
        guard let openFile else { return }
        if FileManager.default.fileExists(atPath: openFile.path(percentEncoded: false)),
           let loaded = try? TextFile.load(openFile, presenter: watcher) {
            // The editor keeps the caret where it is now (clamped), not where it was when this began.
            editor.load(loaded, language: language, marks: problems.marks(for: relativePath))
            isDirty = false
        } else {
            closeFile()
        }
    }

    /// The second editor saved the open file: show its text, unless there are unsaved edits here.
    func reloadOpenFileIfClean() {
        guard let openFile, !isDirty, let loaded = try? TextFile.load(openFile, presenter: watcher), loaded != editor.text else { return }
        // The editor keeps the caret where it is now (clamped), not where it was when this began.
        editor.load(loaded, language: language, marks: problems.marks(for: relativePath))
        changeCount += 1
    }

    /// Re-themes the editor when the appearance or density changes.
    /// The editor's text size relative to the density's (⌘+ / ⌘− / ⌘0), kept across launches.
    var fontScale: CGFloat = UserDefaults.standard.object(forKey: "editor.fontScale") as? CGFloat ?? 1 {
        didSet {
            fontScale = min(2.5, max(0.6, fontScale))
            UserDefaults.standard.set(fontScale, forKey: "editor.fontScale")
            applyEditorTheme(palette: editor.theme.palette, density: editor.theme.density)
            onThemeChange?()
        }
    }
    /// Set by the split editor so it follows the main one's theme and size.
    @ObservationIgnored var onThemeChange: (() -> Void)?

    func applyEditorTheme(palette: Palette, density: Density) {
        guard editor.theme.palette != palette || editor.theme.density != density || editor.theme.scale != fontScale else { return }
        editor.theme = EditorTheme(palette: palette, density: density, scale: fontScale)
    }

    // MARK: Line commands (VS Code's ⌘/, ⌥↑↓, ⇧⌥↑↓, ⇧⌘K, ⌘] ⌘[)

    func perform(_ edit: LineEdit) {
        guard openFile != nil else { return }
        let indent = (try? String(contentsOf: rootURL?.appending(path: ".editorconfig") ?? URL(filePath: "/nonexistent"), encoding: .utf8))
            .flatMap { $0.contains("indent_style = tab") ? "\t" : nil } ?? Self.indentUnit(in: editor.text)
        editor.perform(edit, comment: Self.commentStyle(for: openFile!), indentUnit: indent)
    }

    /// How the file's language comments a line, from its extension (`//` when unknown).
    nonisolated static func commentStyle(for url: URL) -> LineEdit.CommentStyle {
        let name = url.lastPathComponent.lowercased()
        switch url.pathExtension.lowercased() {
        case "md", "markdown", "html", "htm", "xml", "svg", "vue", "svelte": return .block("<!--", "-->")
        case "css", "scss", "less": return .block("/*", "*/")
        case "py", "pyi", "sh", "bash", "zsh", "fish", "rb", "yaml", "yml", "toml", "r", "pl", "conf", "ini", "env", "gitignore":
            return .line("#")
        case "sql", "lua", "hs": return .line("--")
        default:
            if ["makefile", "dockerfile", ".gitignore", ".env", ".editorconfig"].contains(name) { return .line("#") }
            return .line("//")
        }
    }

    /// The file's own indent: a tab, or the smallest run of leading spaces (2 when there's none).
    nonisolated static func indentUnit(in text: String) -> String {
        var smallest = Int.max
        for line in text.split(separator: "\n", omittingEmptySubsequences: true).prefix(400) {
            if line.hasPrefix("\t") { return "\t" }
            let spaces = line.prefix { $0 == " " }.count
            if spaces > 0, spaces < smallest { smallest = spaces }
        }
        return String(repeating: " ", count: smallest == Int.max ? 2 : min(smallest, 8))
    }

    /// The identifier at or just before the caret (for looking it up), or nil.
    var wordAtCaret: String? {
        guard openFile != nil else { return nil }
        let text = editor.text as NSString
        let caret = min(editor.selectedRange.location, text.length)
        if editor.selectedRange.length > 0, editor.selectedRange.length < 80 { return text.substring(with: editor.selectedRange) }
        func isWord(_ i: Int) -> Bool {
            guard i >= 0, i < text.length, let scalar = UnicodeScalar(text.character(at: i)) else { return false }
            return CharacterSet.alphanumerics.contains(scalar) || scalar == "_" || scalar == "$"
        }
        var start = caret, end = caret
        while isWord(start - 1) { start -= 1 }
        while isWord(end) { end += 1 }
        return end > start ? text.substring(with: NSRange(location: start, length: end - start)) : nil
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
