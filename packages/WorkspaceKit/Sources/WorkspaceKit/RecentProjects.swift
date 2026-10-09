// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// A project you've opened, remembered by bookmark so a folder from another provider (Files,
/// Working Copy, an external drive) can be reopened after relaunch without picking it again.
public struct ProjectRef: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var bookmark: Data
    public var lastOpened: Date

    public init(id: UUID = UUID(), name: String, bookmark: Data, lastOpened: Date) {
        self.id = id
        self.name = name
        self.bookmark = bookmark
        self.lastOpened = lastOpened
    }
}

/// The recent-projects list, newest first, stored as JSON (PLAN.md §15: bookmarks are app state).
public struct RecentProjects: Sendable {
    public let fileURL: URL
    public let limit: Int

    public init(fileURL: URL, limit: Int = 12) {
        self.fileURL = fileURL
        self.limit = limit
    }

    public func load() -> [ProjectRef] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return ((try? JSONDecoder().decode([ProjectRef].self, from: data)) ?? []).sorted { $0.lastOpened > $1.lastOpened }
    }

    /// Records `url` as just opened. Call while you have access to it (inside the security scope).
    @discardableResult
    public func remember(_ url: URL, at date: Date = .now) throws -> ProjectRef {
        let bookmark = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        var list = load()
        // Same folder, opened again: keep its identity.
        let existing = list.firstIndex { Self.resolve($0.bookmark)?.url.standardizedFileURL == url.standardizedFileURL }
        let ref = ProjectRef(id: existing.map { list[$0].id } ?? UUID(), name: url.lastPathComponent,
                             bookmark: bookmark, lastOpened: date)
        if let existing { list.remove(at: existing) }
        list.insert(ref, at: 0)
        try save(Array(list.prefix(limit)))
        return ref
    }

    public func forget(_ id: UUID) throws {
        try save(load().filter { $0.id != id })
    }

    /// The folder a bookmark points to now. Refreshes a stale bookmark in place.
    public func url(for ref: ProjectRef) -> URL? {
        guard let (url, stale) = Self.resolve(ref.bookmark) else { return nil }
        if stale, let fresh = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
            var list = load()
            if let i = list.firstIndex(where: { $0.id == ref.id }) {
                list[i].bookmark = fresh
                try? save(list)
            }
        }
        return url
    }

    static func resolve(_ bookmark: Data) -> (url: URL, stale: Bool)? {
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &stale)
        else { return nil }
        return (url, stale)
    }

    private func save(_ list: [ProjectRef]) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(list).write(to: fileURL, options: .atomic)
    }
}
