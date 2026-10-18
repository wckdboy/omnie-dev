// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing
@testable import WorkspaceKit

/// A workspace with more than one folder (a multi-root project): search, quick open and replace
/// span every folder, and each result says which folder it came from.
struct MultiRootSearchTests {
    private func folder(_ name: String, _ files: [String: String]) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "\(name)-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for (path, text) in files {
            let url = root.appending(path: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        return root.standardizedFileURL
    }

    private func text(_ url: URL) throws -> String { try String(contentsOf: url, encoding: .utf8) }

    @Test func searchSpansEveryFolderAndSaysWhichOne() throws {
        let one = try folder("one", ["a.ts": "foo\n", "b.ts": "bar\n"])
        let two = try folder("two", ["c.js": "foo foo\n"])
        let hits = ProjectSearch.search("foo", in: [one, two])
        #expect(hits.count == 3)
        #expect(hits.filter { $0.root == one }.count == 1)
        #expect(hits.filter { $0.root == two }.count == 2)
        #expect(Set(hits.map(\.hit.path)) == ["a.ts", "c.js"])
    }

    @Test func theLimitIsOverTheWholeWorkspace() throws {
        let one = try folder("one", ["a.ts": "foo\nfoo\nfoo\n"])
        let two = try folder("two", ["b.ts": "foo\n"])
        let hits = ProjectSearch.search("foo", in: [one, two], limit: 2)
        #expect(hits.count == 2)
        #expect(hits.allSatisfy { $0.root == one }, "the first folder is searched first")
    }

    @Test func filesAreTaggedWithTheirFolder() throws {
        let one = try folder("one", ["a.ts": ""])
        let two = try folder("two", ["sub/b.ts": ""])
        let files = ProjectSearch.files(in: [one, two])
        #expect(files.map(\.path) == ["a.ts", "sub/b.ts"])
        #expect(files.map(\.root) == [one, two])
        #expect(files[0].id != files[1].id)
    }

    @Test func replaceAppliesInEveryFolder() throws {
        let one = try folder("one", ["a.ts": "foo\n"])
        let two = try folder("two", ["b.ts": "foo foo\n"])
        let result = ProjectSearch.replace("foo", with: "bar", in: [one, two])
        #expect(result.files == 2 && result.count == 3)
        #expect(try text(one.appending(path: "a.ts")) == "bar\n")
        #expect(try text(two.appending(path: "b.ts")) == "bar bar\n")
    }

    @Test func aHitsPathNamesItsFolderOnlyWhenThatFolderWasAdded() throws {
        let one = try folder("one", ["a.ts": "foo\n"])
        let two = try folder("two", ["a.ts": "foo\n"])
        let hits = ProjectSearch.search("foo", in: [one, two])
        #expect(hits.count == 2)
        #expect(hits[0].root == one)
        #expect(hits[0].displayPath(in: [one]) == "a.ts")
        #expect(hits[0].displayPath(in: [one, two]) == "a.ts", "the project's own folder needs no prefix")
        #expect(hits[1].displayPath(in: [one, two]) == "\(two.lastPathComponent)/a.ts")
    }

    @Test func rankingKeepsRicherItems() {
        struct Item: Equatable { var path: String }
        let items = [Item(path: "app/main.ts"), Item(path: "util.ts")]
        #expect(FuzzyMatch.rank("mn", items, by: \.path).first?.path == "app/main.ts")
    }
}
