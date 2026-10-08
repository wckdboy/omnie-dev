import SwiftUI
import WorkspaceKit
import GitKit

/// The open project folder and the file in the editor.
/// Security-scoped bookmarks (reopen on launch) come with WorkspaceKit proper in P1.
@MainActor
@Observable
final class WorkspaceModel {
    var isPickingFolder = false
    let git = GitModel()
    @ObservationIgnored private var autosaveTask: Task<Void, Never>?
    private(set) var root: FileNode?
    private(set) var rootURL: URL?
    private var isAccessingRoot = false

    private(set) var openFile: URL?
    var text: String = "" {
        didSet {
            guard text != savedText else { return }
            isDirty = true
            scheduleAutosave()
        }
    }
    private(set) var isDirty = false
    private var savedText = ""

    /// One-line inline banner, per the brand rule: what happened and the one next action.
    var banner: String?

    func open(folder url: URL) {
        if isAccessingRoot { rootURL?.stopAccessingSecurityScopedResource() }
        // Folders inside the app container need no grant, so false here is not an error by itself;
        // reload() reports if the folder really can't be read.
        isAccessingRoot = url.startAccessingSecurityScopedResource()
        rootURL = url
        openFile = nil
        text = ""
        savedText = ""
        isDirty = false
        reload()
        Task { await git.attach(url) }
    }

    func reload() {
        guard let rootURL else { return }
        do { root = try FileTree.scan(rootURL) }
        catch { banner = "Can't read \(rootURL.lastPathComponent): \(error.localizedDescription)" }
    }

    func open(file url: URL) {
        if isDirty { saveCurrent() }
        do {
            let loaded = try TextFile.load(url)
            savedText = loaded
            text = loaded
            isDirty = false
            openFile = url
            banner = nil
        } catch TextFile.LoadError.binary {
            banner = "\(url.lastPathComponent) is a binary file. A viewer for it comes later."
        } catch TextFile.LoadError.tooLarge(let bytes) {
            banner = "\(url.lastPathComponent) is \(bytes / 1_048_576) MB, over the 8 MB editor limit."
        } catch {
            banner = "Can't open \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }

    /// Saves the open file, then checkpoints the project so nothing typed is ever lost (PLAN.md §9.3).
    func saveCurrent() {
        autosaveTask?.cancel()
        guard let openFile, isDirty else { return }
        do {
            try TextFile.save(text, to: openFile)
            savedText = text
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

    /// Restores a checkpoint and reloads the editor and navigator from disk.
    init() {
        // Git operations that rewrite files (sync, branch switch, merge, restore) save the editor
        // first and reload it after, so a stale buffer never overwrites what git just wrote.
        git.beforeWorktreeChange = { [weak self] in self?.saveCurrent() }
        git.afterWorktreeChange = { [weak self] in self?.reloadFromDisk() }
    }

    func restore(_ checkpoint: Checkpoint) async {
        _ = await git.restore(checkpoint)
    }

    /// Re-reads the navigator and the open file after something other than the editor changed files.
    func reloadFromDisk() {
        reload()
        if let openFile {
            if FileManager.default.fileExists(atPath: openFile.path(percentEncoded: false)),
               let loaded = try? TextFile.load(openFile) {
                savedText = loaded
                text = loaded
                isDirty = false
            } else {
                self.openFile = nil
                savedText = ""
                text = ""
                isDirty = false
            }
        }
    }

    var relativePath: String? {
        guard let openFile, let rootURL else { return nil }
        let path = openFile.path(percentEncoded: false)
        let base = rootURL.path(percentEncoded: false)
        return path.hasPrefix(base) ? String(path.dropFirst(base.count)).trimmingPrefix("/").description : openFile.lastPathComponent
    }
}
