import SwiftUI
import WorkspaceKit

/// The open project folder and the file in the editor.
/// Security-scoped bookmarks (reopen on launch) come with WorkspaceKit proper in P1.
@MainActor
@Observable
final class WorkspaceModel {
    var isPickingFolder = false
    private(set) var root: FileNode?
    private(set) var rootURL: URL?
    private var isAccessingRoot = false

    private(set) var openFile: URL?
    var text: String = "" {
        didSet { if text != savedText { isDirty = true } }
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

    func saveCurrent() {
        guard let openFile, isDirty else { return }
        do {
            try TextFile.save(text, to: openFile)
            savedText = text
            isDirty = false
        } catch {
            banner = "Save failed: \(error.localizedDescription). Try again."
        }
    }

    var relativePath: String? {
        guard let openFile, let rootURL else { return nil }
        let path = openFile.path(percentEncoded: false)
        let base = rootURL.path(percentEncoded: false)
        return path.hasPrefix(base) ? String(path.dropFirst(base.count)).trimmingPrefix("/").description : openFile.lastPathComponent
    }
}
