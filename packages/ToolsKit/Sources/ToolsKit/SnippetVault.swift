// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

import Foundation
import SQLite3

/// The snippet vault (PLAN.md §11.1): your own patterns, in a local SQLite file, searchable with
/// full-text search, insertable at the caret, and pinnable as context for the agent.
public final class SnippetVault: @unchecked Sendable {
    public struct Snippet: Sendable, Hashable, Identifiable {
        public var id: Int64
        public var title: String
        public var language: String
        public var body: String
        public var tags: [String]
        public var pinned: Bool
        public var updated: Date

        public init(id: Int64 = 0, title: String, language: String = "", body: String, tags: [String] = [], pinned: Bool = false, updated: Date = .now) {
            self.id = id; self.title = title; self.language = language; self.body = body
            self.tags = tags; self.pinned = pinned; self.updated = updated
        }
    }

    public struct Failure: Error, LocalizedError, Equatable {
        public let message: String
        public var errorDescription: String? { message }
    }

    private var db: OpaquePointer?
    private let lock = NSLock()
    private var hasFTS = false

    public init(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            throw Failure(message: "Couldn't open the snippet vault.")
        }
        try exec("""
            CREATE TABLE IF NOT EXISTS snippets (
              id INTEGER PRIMARY KEY, title TEXT NOT NULL, language TEXT NOT NULL DEFAULT '',
              body TEXT NOT NULL, tags TEXT NOT NULL DEFAULT '', pinned INTEGER NOT NULL DEFAULT 0, updated REAL NOT NULL)
            """)
        // Full-text search where SQLite has FTS5 (it does on Apple platforms); LIKE otherwise.
        hasFTS = (try? exec("""
            CREATE VIRTUAL TABLE IF NOT EXISTS snippets_fts USING fts5(title, body, tags, content='snippets', content_rowid='id');
            CREATE TRIGGER IF NOT EXISTS snippets_ai AFTER INSERT ON snippets BEGIN
              INSERT INTO snippets_fts(rowid, title, body, tags) VALUES (new.id, new.title, new.body, new.tags); END;
            CREATE TRIGGER IF NOT EXISTS snippets_ad AFTER DELETE ON snippets BEGIN
              INSERT INTO snippets_fts(snippets_fts, rowid, title, body, tags) VALUES ('delete', old.id, old.title, old.body, old.tags); END;
            CREATE TRIGGER IF NOT EXISTS snippets_au AFTER UPDATE ON snippets BEGIN
              INSERT INTO snippets_fts(snippets_fts, rowid, title, body, tags) VALUES ('delete', old.id, old.title, old.body, old.tags);
              INSERT INTO snippets_fts(rowid, title, body, tags) VALUES (new.id, new.title, new.body, new.tags); END;
            """)) != nil
    }

    deinit { sqlite3_close(db) }

    private func exec(_ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? "SQLite error"
            sqlite3_free(error)
            throw Failure(message: message)
        }
    }

    /// Runs `sql` with bound text/number parameters, returning rows of the snippet columns.
    private func run(_ sql: String, _ params: [Any?] = []) throws -> [Snippet] {
        lock.lock(); defer { lock.unlock() }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw Failure(message: String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (i, p) in params.enumerated() {
            let index = Int32(i + 1)
            switch p {
            case let s as String: sqlite3_bind_text(statement, index, s, -1, transient)
            case let n as Int64: sqlite3_bind_int64(statement, index, n)
            case let n as Int: sqlite3_bind_int64(statement, index, Int64(n))
            case let d as Double: sqlite3_bind_double(statement, index, d)
            case let b as Bool: sqlite3_bind_int(statement, index, b ? 1 : 0)
            default: sqlite3_bind_null(statement, index)
            }
        }
        var rows: [Snippet] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else { throw Failure(message: String(cString: sqlite3_errmsg(db))) }
            guard sqlite3_column_count(statement) >= 7 else { continue }
            func text(_ i: Int32) -> String { sqlite3_column_text(statement, i).map { String(cString: $0) } ?? "" }
            rows.append(Snippet(id: sqlite3_column_int64(statement, 0), title: text(1), language: text(2), body: text(3),
                                tags: text(4).split(separator: ",").map(String.init), pinned: sqlite3_column_int(statement, 5) != 0,
                                updated: Date(timeIntervalSince1970: sqlite3_column_double(statement, 6))))
        }
        return rows
    }

    private static let columns = "id, title, language, body, tags, pinned, updated"

    @discardableResult
    public func save(_ snippet: Snippet) throws -> Snippet {
        var s = snippet
        s.updated = .now
        let tags = s.tags.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: ",")
        if s.id == 0 {
            _ = try run("INSERT INTO snippets (title, language, body, tags, pinned, updated) VALUES (?, ?, ?, ?, ?, ?)",
                        [s.title, s.language, s.body, tags, s.pinned, s.updated.timeIntervalSince1970])
            s.id = sqlite3_last_insert_rowid(db)
        } else {
            _ = try run("UPDATE snippets SET title = ?, language = ?, body = ?, tags = ?, pinned = ?, updated = ? WHERE id = ?",
                        [s.title, s.language, s.body, tags, s.pinned, s.updated.timeIntervalSince1970, s.id])
        }
        return s
    }

    public func delete(_ id: Int64) throws { _ = try run("DELETE FROM snippets WHERE id = ?", [id]) }

    /// Everything, pinned first, then newest.
    public func all() throws -> [Snippet] {
        try run("SELECT \(Self.columns) FROM snippets ORDER BY pinned DESC, updated DESC")
    }

    public func pinned() throws -> [Snippet] {
        try run("SELECT \(Self.columns) FROM snippets WHERE pinned = 1 ORDER BY updated DESC")
    }

    /// Full-text search over title, body and tags (prefix matching on each word).
    public func search(_ query: String, limit: Int = 50) throws -> [Snippet] {
        let words = query.split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "_" }).map(String.init)
        guard !words.isEmpty else { return try all() }
        if hasFTS {
            let match = words.map { "\"\($0)\"*" }.joined(separator: " ")
            return try run("""
                SELECT s.id, s.title, s.language, s.body, s.tags, s.pinned, s.updated FROM snippets_fts f
                JOIN snippets s ON s.id = f.rowid WHERE snippets_fts MATCH ? ORDER BY bm25(snippets_fts), s.pinned DESC LIMIT ?
                """, [match, limit])
        }
        let like = "%" + words.joined(separator: "%") + "%"
        return try run("SELECT \(Self.columns) FROM snippets WHERE title LIKE ? OR body LIKE ? OR tags LIKE ? LIMIT ?", [like, like, like, limit])
    }

    /// Pinned snippets as context for the agent, kept short.
    public func agentContext(maxCharacters: Int = 3_000) throws -> String? {
        let pinned = try pinned()
        guard !pinned.isEmpty else { return nil }
        var text = "Snippets the user pinned (their preferred patterns; use them where they fit):\n"
        for s in pinned {
            let block = "\n\(s.title):\n```\(s.language)\n\(s.body)\n```\n"
            if text.count + block.count > maxCharacters { break }
            text += block
        }
        return text
    }
}
