// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

import Foundation
import SQLite3
import Testing
@testable import ToolsKit

struct SQLiteTests {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("sqlite-\(UUID().uuidString)")
    var url: URL { root.appendingPathComponent("data/app.db") }

    init() throws {
        try FileManager.default.createDirectory(at: root.appendingPathComponent("data"), withIntermediateDirectories: true)
    }

    func makeDatabase() throws -> SQLiteDatabase {
        var raw: OpaquePointer?
        sqlite3_open(url.path, &raw)
        sqlite3_exec(raw, """
            CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT, email TEXT, avatar BLOB);
            INSERT INTO users (name, email, avatar) VALUES ('Ada', 'ada@example.com', x'0102'), ('Grace', NULL, NULL), ('Lin, "the" dev', 'lin@example.com', NULL);
            CREATE VIEW named AS SELECT name FROM users;
            """, nil, nil, nil)
        sqlite3_close(raw)
        return try SQLiteDatabase(url: url)
    }

    @Test func listsTablesAndPreviews() throws {
        let db = try makeDatabase()
        #expect(SQLiteDatabase.files(in: root) == ["data/app.db"])
        #expect(try db.tables() == [.init(name: "named", kind: "view", rows: 3), .init(name: "users", kind: "table", rows: 3)])
        let preview = try db.preview("users")
        #expect(preview.columns == ["id", "name", "email", "avatar"])
        #expect(preview.rows[0] == ["1", "Ada", "ada@example.com", "<2 bytes>"])
        #expect(preview.rows[1][2] == "NULL")
        #expect(try db.query("SELECT name FROM users", limit: 2).truncated)
        #expect(SQLiteDatabase.csv(try db.query("SELECT name, email FROM users WHERE id = 3")) == "name,email\n\"Lin, \"\"the\"\" dev\",lin@example.com\n")
    }

    @Test func readOnlyRefusesWrites() throws {
        let db = try makeDatabase()
        #expect(throws: SQLiteDatabase.Failure.self) { try db.query("DELETE FROM users") }
        #expect(try db.query("SELECT COUNT(*) FROM users").rows == [["3"]])
        let writable = try SQLiteDatabase(url: url, readOnly: false)
        #expect(try writable.query("UPDATE users SET email = 'g@example.com' WHERE name = 'Grace'").changes == 1)
        #expect(throws: SQLiteDatabase.Failure.self) { try db.query("SELEC nope") }
        #expect(try db.explain("SELECT * FROM users WHERE id = 1").rows.isEmpty == false)
    }
}

struct PatternsTests {
    @Test func formatsAndLocatesJSONErrors() {
        #expect(Patterns.json("{\"b\":1,\"a\":[1,2]}").formatted == "{\n  \"b\": 1,\n  \"a\": [\n    1,\n    2\n  ]\n}")
        let bad = Patterns.json("{\n  \"a\": 1,\n  \"b\": }")
        #expect(bad.formatted == nil)
        #expect(bad.error != nil)
    }

    @Test func regexBothFlavors() {
        let text = "id=42, ID=7, idx=x"
        for flavor in Patterns.Flavor.allCases {
            let report = Patterns.regex(#"id=(\d+)"#, flags: "i", in: text, flavor: flavor)
            #expect(report.error == nil, "\(flavor)")
            #expect(report.matches.map(\.text) == ["id=42", "ID=7"], "\(flavor)")
            #expect(report.matches.map(\.groups) == [["42"], ["7"]], "\(flavor)")
            #expect(report.matches.first?.range == 0..<5, "\(flavor)")
        }
        // Lookbehind and named groups work in JS; a bad pattern says why.
        #expect(Patterns.regex(#"(?<=\$)(?<n>\d+)"#, in: "cost $15", flavor: .javascript).matches.map(\.text) == ["15"])
        #expect(Patterns.regex("(", in: "x", flavor: .javascript).error != nil)
        #expect(Patterns.regex("(", in: "x", flavor: .swift).error != nil)
        // Offsets count characters, not UTF-16 units.
        #expect(Patterns.regex("b", in: "👩‍💻b", flavor: .javascript).matches.first?.range == 1..<2)
    }
}
