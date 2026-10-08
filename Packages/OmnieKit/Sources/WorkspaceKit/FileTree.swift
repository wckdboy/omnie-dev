import Foundation

/// One entry in the project navigator.
public struct FileNode: Identifiable, Hashable, Sendable {
    public var id: URL { url }
    public let url: URL
    public let name: String
    public let isDirectory: Bool
    /// nil for files; empty for directories with no visible children or beyond the scan depth.
    public var children: [FileNode]?

    public init(url: URL, isDirectory: Bool, children: [FileNode]? = nil) {
        self.url = url
        self.name = url.lastPathComponent
        self.isDirectory = isDirectory
        self.children = isDirectory ? (children ?? []) : nil
    }
}

public enum FileTree {
    /// Directories that are never shown in the navigator. Git internals and dependency folders
    /// are large and not something you edit by hand.
    public static let ignoredNames: Set<String> = [".git", "node_modules", ".build", "DerivedData", ".DS_Store", "__pycache__", ".venv"]

    /// Scans `root` into a tree, directories first, then case-insensitive by name.
    /// Stops descending at `maxDepth` and after `maxEntries` total entries so a huge repo can't stall the UI.
    public static func scan(_ root: URL, maxDepth: Int = 12, maxEntries: Int = 20_000) throws -> FileNode {
        var budget = maxEntries
        let children = try scanChildren(of: root, depth: 0, maxDepth: maxDepth, budget: &budget)
        return FileNode(url: root, isDirectory: true, children: children)
    }

    private static func scanChildren(of dir: URL, depth: Int, maxDepth: Int, budget: inout Int) throws -> [FileNode] {
        guard depth < maxDepth, budget > 0 else { return [] }
        let urls = try FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        )
        var nodes: [FileNode] = []
        for url in urls where !ignoredNames.contains(url.lastPathComponent) {
            guard budget > 0 else { break }
            budget -= 1
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDir {
                let kids = (try? scanChildren(of: url, depth: depth + 1, maxDepth: maxDepth, budget: &budget)) ?? []
                nodes.append(FileNode(url: url, isDirectory: true, children: kids))
            } else {
                nodes.append(FileNode(url: url, isDirectory: false))
            }
        }
        return nodes.sorted {
            $0.isDirectory != $1.isDirectory ? $0.isDirectory : $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }
}

public enum TextFile {
    public enum LoadError: Error, Equatable {
        case binary
        case tooLarge(bytes: Int)
    }

    /// Files larger than this open read-only in a later viewer, not the editor.
    public static let maxEditableBytes = 8 * 1024 * 1024

    /// Loads a file as UTF-8 text. Rejects files with NUL bytes in the first 8 KB (binary) or over the size cap.
    public static func load(_ url: URL) throws -> String {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        if data.count > maxEditableBytes { throw LoadError.tooLarge(bytes: data.count) }
        if data.prefix(8192).contains(0) { throw LoadError.binary }
        return String(decoding: data, as: UTF8.self)
    }

    /// Atomic write through a file coordinator, so other apps (Files, Working Copy) see a consistent file.
    public static func save(_ text: String, to url: URL) throws {
        var coordinationError: NSError?
        var writeError: Error?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { target in
            do { try Data(text.utf8).write(to: target, options: .atomic) } catch { writeError = error }
        }
        if let e = coordinationError { throw e }
        if let e = writeError { throw e }
    }
}

public enum TextPosition {
    /// 1-based line and column of a UTF-16-independent character offset in `text`.
    public static func lineColumn(in text: String, at index: String.Index) -> (line: Int, column: Int) {
        var line = 1
        var lineStart = text.startIndex
        var i = text.startIndex
        while i < index && i < text.endIndex {
            if text[i] == "\n" {
                line += 1
                lineStart = text.index(after: i)
            }
            i = text.index(after: i)
        }
        return (line, text.distance(from: lineStart, to: index) + 1)
    }
}
