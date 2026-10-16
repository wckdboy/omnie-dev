// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing
@testable import WorkspaceKit

struct ProjectSearchReplaceTests {
    private func project() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "search-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root.appending(path: "sub"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appending(path: ".git"), withIntermediateDirectories: true)
        try "foo bar\nfoo\n".write(to: root.appending(path: "a.ts"), atomically: true, encoding: .utf8)
        try "x foo y\n".write(to: root.appending(path: "sub/b.js"), atomically: true, encoding: .utf8)
        try "untouched\n".write(to: root.appending(path: "c.md"), atomically: true, encoding: .utf8)
        try "foo\n".write(to: root.appending(path: ".git/config"), atomically: true, encoding: .utf8)
        return root
    }

    private func text(_ url: URL) throws -> String { try String(contentsOf: url, encoding: .utf8) }

    @Test func replacesAcrossFilesAndLeavesTheRestAlone() throws {
        let root = try project()
        let result = ProjectSearch.replace("foo", with: "baz", in: root)
        #expect(result.files == 2)
        #expect(result.count == 3)
        #expect(result.skipped.isEmpty)
        #expect(try text(root.appending(path: "a.ts")) == "baz bar\nbaz\n")
        #expect(try text(root.appending(path: "sub/b.js")) == "x baz y\n")
        #expect(try text(root.appending(path: "c.md")) == "untouched\n")
        #expect(try text(root.appending(path: ".git/config")) == "foo\n", "ignored folders are never touched")
    }

    @Test func caseInsensitiveByDefault() throws {
        let root = try project()
        try "Foo foo FOO\n".write(to: root.appending(path: "d.txt"), atomically: true, encoding: .utf8)
        let result = ProjectSearch.replace("foo", with: "z", in: root)
        #expect(try text(root.appending(path: "d.txt")) == "z z z\n")
        #expect(result.count == 6, "three in d.txt, two in a.ts, one in b.js")
    }

    @Test func anEmptyQueryChangesNothing() throws {
        let root = try project()
        let result = ProjectSearch.replace("", with: "x", in: root)
        #expect(result.count == 0 && result.files == 0)
        #expect(try text(root.appending(path: "a.ts")) == "foo bar\nfoo\n")
    }
}
