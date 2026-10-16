// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// A point-in-time copy of a project folder. Snapshots live outside the project (Application
/// Support), so they work in any folder and don't touch git; restore puts the files back.
public struct ProjectSnapshot: Identifiable, Hashable, Sendable, Codable {
    public var id: String
    public var date: Date
    public var reason: String
    public var fileCount: Int
    public var byteCount: Int
}

/// Takes, lists, restores and prunes snapshots of one project, under `base/<project key>/`.
///
/// What's captured: every regular file under the project, except the navigator's ignored folders
/// (`.git`, `node_modules`, `.build`, …) and files over `maxFileBytes` (recorded as skipped so a
/// restore never deletes something it didn't copy). Restore is itself undoable: it snapshots the
/// current state first.
public struct SnapshotStore: Sendable {
    public enum Failure: Error, Equatable, LocalizedError {
        case missing(String)
        case badName(String)

        public var errorDescription: String? {
            switch self {
            case .missing(let id): "That snapshot (\(id)) is gone."
            case .badName(let name): "\"\(name)\" isn't a safe path inside the project."
            }
        }
    }

    public let root: URL
    public let base: URL
    public let maxFileBytes: Int

    public init(root: URL, base: URL, maxFileBytes: Int = 8 * 1024 * 1024) {
        self.root = root.standardizedFileURL
        self.base = base.standardizedFileURL
        self.maxFileBytes = maxFileBytes
    }

    /// Where this project's snapshots live.
    public var folder: URL { base.appending(path: Self.key(for: root), directoryHint: .isDirectory) }

    /// A filesystem-safe, stable key for a project path (FNV-1a of the path + its folder name).
    public static func key(for root: URL) -> String {
        var path = root.standardizedFileURL.path(percentEncoded: false)
        // A folder reopened from a bookmark can end in "/"; the key must not depend on that.
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in path.utf8 { hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211 }
        let name = root.lastPathComponent.isEmpty ? "project" : root.lastPathComponent
        let safe = String(name.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "-" })
        return "\(safe)-\(String(hash, radix: 16))"
    }

    // MARK: Taking

    @discardableResult
    public func take(reason: String, keeping limit: Int = 20, at date: Date = .now) throws -> ProjectSnapshot {
        let id = Self.identifier(for: date)
        let snapshotFolder = folder.appending(path: id, directoryHint: .isDirectory)
        let files = snapshotFolder.appending(path: "files", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)

        var entries: [Entry] = []
        var skipped: [String] = []
        var total = 0
        for url in try projectFiles() {
            let path = relativePath(of: url)
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            guard size <= maxFileBytes else { skipped.append(path); continue }
            let data = try Data(contentsOf: url)
            let target = files.appending(path: path)
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: target, options: .atomic)
            entries.append(Entry(path: path, bytes: data.count))
            total += data.count
        }
        let manifest = Manifest(date: date, reason: reason, files: entries, skipped: skipped, bytes: total)
        try Self.encoder.encode(manifest).write(to: snapshotFolder.appending(path: "manifest.json"), options: .atomic)
        prune(keeping: limit)
        return ProjectSnapshot(id: id, date: date, reason: reason, fileCount: entries.count, byteCount: total)
    }

    // MARK: Listing

    /// Newest first.
    public func list() -> [ProjectSnapshot] {
        let ids = (try? FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false))) ?? []
        return ids.compactMap { id in
            guard let manifest = readManifest(id) else { return nil }
            return ProjectSnapshot(id: id, date: manifest.date, reason: manifest.reason,
                                   fileCount: manifest.files.count, byteCount: manifest.bytes)
        }.sorted { $0.date > $1.date }
    }

    /// The directories a snapshot occupies, biggest first (for an "older are pruned" hint).
    public func totalBytes() -> Int {
        list().reduce(0) { $0 + $1.byteCount }
    }

    // MARK: Restoring

    /// Puts the snapshot's files back and removes the files added since. Snapshots the current state
    /// first, so the restore itself can be undone; returns that safety snapshot.
    @discardableResult
    public func restore(_ snapshot: ProjectSnapshot, keeping limit: Int = 20) throws -> ProjectSnapshot? {
        guard let manifest = readManifest(snapshot.id) else { throw Failure.missing(snapshot.id) }
        let safety = try? take(reason: "Before restoring \(snapshot.id)", keeping: limit)
        let files = folder.appending(path: snapshot.id).appending(path: "files")

        // Delete files that weren't in the snapshot (skipped ones are left alone).
        let protected = Set(manifest.files.map(\.path)).union(manifest.skipped)
        for url in try projectFiles() where !protected.contains(relativePath(of: url)) {
            try? FileOperations.delete(url)
        }
        // Put the snapshot's files back.
        for entry in manifest.files {
            let target = root.appending(path: entry.path)
            guard isInside(target) else { throw Failure.badName(entry.path) }
            let data = try Data(contentsOf: files.appending(path: entry.path))
            try FileOperations.coordinate(writing: target, options: .forReplacing) { url in
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: url, options: .atomic)
            }
        }
        return safety
    }

    public func delete(_ snapshot: ProjectSnapshot) throws {
        try FileManager.default.removeItem(at: folder.appending(path: snapshot.id))
    }

    // MARK: Internals

    struct Entry: Codable, Sendable, Hashable { var path: String; var bytes: Int }

    struct Manifest: Codable, Sendable {
        var date: Date
        var reason: String
        var files: [Entry]
        var skipped: [String]
        var bytes: Int
    }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return e
    }()
    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    private func readManifest(_ id: String) -> Manifest? {
        guard let data = try? Data(contentsOf: folder.appending(path: id).appending(path: "manifest.json")) else { return nil }
        return try? Self.decoder.decode(Manifest.self, from: data)
    }

    /// Snapshot ids are millisecond timestamps, so they sort and read by time.
    static func identifier(for date: Date) -> String {
        String(format: "%.0f", (date.timeIntervalSince1970 * 1000).rounded())
    }

    private func prune(keeping limit: Int) {
        guard limit > 0 else { return }
        for old in list().dropFirst(limit) {
            try? FileManager.default.removeItem(at: folder.appending(path: old.id))
        }
    }

    /// Every regular file under the project, skipping the navigator's ignored folders and symlinks.
    private func projectFiles() throws -> [URL] {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: Array(keys),
                                              options: [], errorHandler: { _, _ in true }) else { return [] }
        var out: [URL] = []
        for case let url as URL in walker {
            let name = url.lastPathComponent
            let values = try? url.resourceValues(forKeys: keys)
            if values?.isDirectory == true {
                if FileTree.ignoredNames.contains(name) { walker.skipDescendants() }
                continue
            }
            if FileTree.ignoredNames.contains(name) { continue }
            if values?.isSymbolicLink == true { continue }
            guard values?.isRegularFile ?? true else { continue }
            out.append(url)
        }
        return out
    }

    private func relativePath(of url: URL) -> String {
        let base = root.path(percentEncoded: false)
        let path = url.standardizedFileURL.path(percentEncoded: false)
        let prefix = base.hasSuffix("/") ? base : base + "/"
        return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : url.lastPathComponent
    }

    private func isInside(_ url: URL) -> Bool {
        let base = root.resolvingSymlinksInPath().path
        let path = url.resolvingSymlinksInPath().path
        return path == base || path.hasPrefix(base + "/")
    }
}
