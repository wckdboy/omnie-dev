// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

import Foundation
import SQLite3

/// A project's SQLite database for the SQLite browser (PLAN.md §11.1). Opened read-only unless you
/// ask to write; results are capped so a large table can't stall the app.
public final class SQLiteDatabase: @unchecked Sendable {
    public struct Table: Sendable, Hashable, Identifiable {
        public var id: String { name }
        public let name: String
        public let kind: String
        public let rows: Int
    }

    public struct Result: Sendable, Equatable {
        public var columns: [String] = []
        public var rows: [[String]] = []
        /// More rows existed than were read.
        public var truncated = false
        /// Rows changed by a write.
        public var changes = 0
        public var ms = 0
    }

    public struct Failure: Error, LocalizedError, Equatable {
        public let message: String
        public var errorDescription: String? { message }
    }

    public let url: URL
    public let isReadOnly: Bool
    private var handle: OpaquePointer?
    private let lock = NSLock()

    public init(url: URL, readOnly: Bool = true) throws {
        self.url = url
        isReadOnly = readOnly
        let flags = readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE
        guard sqlite3_open_v2(url.path, &handle, flags, nil) == SQLITE_OK else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "can't open"
            sqlite3_close(handle)
            throw Failure(message: "\(url.lastPathComponent): \(message)")
        }
    }

    deinit { sqlite3_close(handle) }

    /// Database files in a project, by extension or by the SQLite file header.
    public static func files(in root: URL) -> [String] {
        var found: [String] = []
        let base = root.standardizedFileURL.resolvingSymlinksInPath()
        let e = FileManager.default.enumerator(at: base, includingPropertiesForKeys: [.isRegularFileKey])
        while let url = e?.nextObject() as? URL {
            if [".git", "node_modules", ".build"].contains(url.lastPathComponent) { e?.skipDescendants(); continue }
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            let ext = url.pathExtension.lowercased()
            let header = (try? FileHandle(forReadingFrom: url)).flatMap { h -> Data? in defer { try? h.close() }; return try? h.read(upToCount: 16) }
            if ["sqlite", "sqlite3", "db", "db3"].contains(ext) || header == Data("SQLite format 3\0".utf8) {
                found.append(String(url.standardizedFileURL.resolvingSymlinksInPath().path.dropFirst(base.path.count + 1)))
            }
        }
        return found.sorted()
    }

    public func tables() throws -> [Table] {
        let list = try query("SELECT name, type FROM sqlite_master WHERE type IN ('table', 'view') AND name NOT LIKE 'sqlite_%' ORDER BY name", limit: 10_000)
        return try list.rows.map { row in
            let count = try query("SELECT COUNT(*) FROM \(Self.quote(row[0]))", limit: 1).rows.first?.first.flatMap(Int.init) ?? 0
            return Table(name: row[0], kind: row[1], rows: count)
        }
    }

    public func preview(_ table: String, limit: Int = 200) throws -> Result {
        try query("SELECT * FROM \(Self.quote(table))", limit: limit)
    }

    /// Runs one statement. In read-only mode, writes fail with SQLite's own "readonly" error.
    public func query(_ sql: String, limit: Int = 1_000) throws -> Result {
        lock.lock()
        defer { lock.unlock() }
        let start = Date()
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { throw failure() }
        defer { sqlite3_finalize(statement) }
        var result = Result()
        let count = sqlite3_column_count(statement)
        result.columns = (0..<count).map { String(cString: sqlite3_column_name(statement, $0)) }
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else { throw failure() }
            if result.rows.count >= limit { result.truncated = true; break }
            result.rows.append((0..<count).map { Self.text(statement, $0) })
        }
        result.changes = count == 0 ? Int(sqlite3_changes(handle)) : 0
        result.ms = Int(Date().timeIntervalSince(start) * 1000)
        return result
    }

    /// The query plan, for "Explain".
    public func explain(_ sql: String) throws -> Result { try query("EXPLAIN QUERY PLAN " + sql) }

    static func text(_ statement: OpaquePointer?, _ column: Int32) -> String {
        switch sqlite3_column_type(statement, column) {
        case SQLITE_NULL: return "NULL"
        case SQLITE_BLOB: return "<\(sqlite3_column_bytes(statement, column)) bytes>"
        default: return sqlite3_column_text(statement, column).map { String(cString: $0) } ?? ""
        }
    }

    static func quote(_ name: String) -> String { "\"" + name.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }

    private func failure() -> Failure { Failure(message: String(cString: sqlite3_errmsg(handle))) }

    /// CSV of a result, RFC 4180 quoting.
    public static func csv(_ result: Result) -> String {
        func field(_ s: String) -> String { s.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" }) ? "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : s }
        return ([result.columns] + result.rows).map { $0.map(field).joined(separator: ",") }.joined(separator: "\n") + "\n"
    }
}
