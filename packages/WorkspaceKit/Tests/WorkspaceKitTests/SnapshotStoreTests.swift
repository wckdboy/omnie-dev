// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing
@testable import WorkspaceKit

struct SnapshotStoreTests {
    /// A throwaway project with two real files and two ignored folders.
    private func makeProject() throws -> (root: URL, base: URL) {
        let tmp = FileManager.default.temporaryDirectory.appending(path: "snap-\(UUID().uuidString)", directoryHint: .isDirectory)
        let root = tmp.appending(path: "project", directoryHint: .isDirectory)
        let base = tmp.appending(path: "store", directoryHint: .isDirectory)
        for dir in ["src", ".git", "node_modules"] {
            try FileManager.default.createDirectory(at: root.appending(path: dir), withIntermediateDirectories: true)
        }
        try "one\n".write(to: root.appending(path: "a.txt"), atomically: true, encoding: .utf8)
        try "two\n".write(to: root.appending(path: "src/b.ts"), atomically: true, encoding: .utf8)
        try "config\n".write(to: root.appending(path: ".git/config"), atomically: true, encoding: .utf8)
        try "dep\n".write(to: root.appending(path: "node_modules/x.js"), atomically: true, encoding: .utf8)
        return (root, base)
    }

    private func text(_ url: URL) throws -> String { try String(contentsOf: url, encoding: .utf8) }

    @Test func takesListsAndRestores() throws {
        let (root, base) = try makeProject()
        let store = SnapshotStore(root: root, base: base)

        let snapshot = try store.take(reason: "Test")
        #expect(snapshot.fileCount == 2, "only the two real files, not .git or node_modules")
        #expect(store.list().map(\.id) == [snapshot.id])

        // Edit one file, add another, delete a third.
        try "changed\n".write(to: root.appending(path: "a.txt"), atomically: true, encoding: .utf8)
        try "new\n".write(to: root.appending(path: "c.txt"), atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(at: root.appending(path: "src/b.ts"))

        let safety = try store.restore(snapshot)
        #expect(safety != nil, "restore snapshots the current state first, so it's undoable")
        #expect(try text(root.appending(path: "a.txt")) == "one\n")
        #expect(try text(root.appending(path: "src/b.ts")) == "two\n")
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: "c.txt").path))
        #expect(try text(root.appending(path: ".git/config")) == "config\n", "ignored folders are untouched")
        #expect(store.list().count == 2)
    }

    @Test func keepsOnlyTheLimit() throws {
        let (root, base) = try makeProject()
        let store = SnapshotStore(root: root, base: base)
        for i in 0..<4 {
            _ = try store.take(reason: "r\(i)", keeping: 2, at: Date(timeIntervalSince1970: 1_000 + Double(i)))
        }
        let list = store.list()
        #expect(list.count == 2)
        #expect(list[0].date > list[1].date, "newest first")
    }

    @Test func leavesSkippedLargeFilesAlone() throws {
        let (root, base) = try makeProject()
        let big = root.appending(path: "big.bin")
        try Data(repeating: 7, count: 64).write(to: big)

        let store = SnapshotStore(root: root, base: base, maxFileBytes: 16)
        let snapshot = try store.take(reason: "Test")
        #expect(snapshot.fileCount == 2, "the large file is skipped")

        // Rewrite it after the snapshot: a restore must not delete or overwrite what it didn't copy.
        try Data(repeating: 9, count: 64).write(to: big)
        _ = try store.restore(snapshot)
        #expect(try Data(contentsOf: big) == Data(repeating: 9, count: 64))
    }

    @Test func keysAreStablePerPath() {
        let a = URL(filePath: "/tmp/one/app")
        #expect(SnapshotStore.key(for: a) == SnapshotStore.key(for: URL(filePath: "/tmp/one/app/")))
        #expect(SnapshotStore.key(for: a) != SnapshotStore.key(for: URL(filePath: "/tmp/two/app")))
    }
}
