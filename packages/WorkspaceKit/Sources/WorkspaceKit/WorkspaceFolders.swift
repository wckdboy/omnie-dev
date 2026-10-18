// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// The folders a project has added to its workspace beyond the one it was opened on (a multi-root
/// workspace), remembered by bookmark so a folder from another provider comes back after relaunch.
///
/// Keyed by the project (see `AppModel.layoutKey`), the same way a project's session is: folders
/// belong to the project they were added to, and opening another project shows its own set.
public struct WorkspaceFolders: Sendable {
    public struct Entry: Codable, Identifiable, Hashable, Sendable {
        public var id: UUID
        public var name: String
        public var bookmark: Data

        public init(id: UUID = UUID(), name: String, bookmark: Data) {
            self.id = id
            self.name = name
            self.bookmark = bookmark
        }
    }

    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// The folders added to `project`, in the order they were added.
    public func folders(for project: String) -> [Entry] {
        load()[project] ?? []
    }

    /// Records `url` as part of `project`'s workspace. Call while you have access to it (inside the
    /// security scope). Adding the same folder again keeps its place rather than duplicating it.
    @discardableResult
    public func remember(_ url: URL, for project: String) throws -> Entry {
        let bookmark = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        var map = load()
        var list = map[project] ?? []
        let existing = list.firstIndex { entry in Self.resolve(entry.bookmark).map { RecentProjects.sameProject($0.url, url) } ?? false }
        let entry = Entry(id: existing.map { list[$0].id } ?? UUID(), name: url.lastPathComponent, bookmark: bookmark)
        if let existing { list.remove(at: existing) }
        list.append(entry)
        map[project] = list
        try save(map)
        return entry
    }

    /// Drops `url` from `project`'s workspace; a no-op when it isn't there.
    public func forget(_ url: URL, for project: String) throws {
        var map = load()
        guard var list = map[project] else { return }
        list.removeAll { entry in Self.resolve(entry.bookmark).map { RecentProjects.sameProject($0.url, url) } ?? false }
        map[project] = list
        try save(map)
    }

    /// The folder an entry points to now, or nil if it has gone.
    public func url(for entry: Entry) -> URL? {
        Self.resolve(entry.bookmark)?.url
    }

    /// `project`'s folders that still exist, in the order they were added, deduplicated.
    public func available(for project: String) -> [URL] {
        var seen: [URL] = []
        return folders(for: project).compactMap { entry in
            guard let url = url(for: entry)?.standardizedFileURL, FileManager.default.fileExists(atPath: url.path),
                  !seen.contains(where: { RecentProjects.sameProject($0, url) }) else { return nil }
            seen.append(url)
            return url
        }
    }

    static func resolve(_ bookmark: Data) -> (url: URL, stale: Bool)? {
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &stale)
        else { return nil }
        return (url, stale)
    }

    private func load() -> [String: [Entry]] {
        guard let data = try? Data(contentsOf: fileURL) else { return [:] }
        return (try? JSONDecoder().decode([String: [Entry]].self, from: data)) ?? [:]
    }

    private func save(_ map: [String: [Entry]]) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(map).write(to: fileURL, options: .atomic)
    }
}
