// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing
@testable import WorkspaceKit

struct RecentProjectsTests {
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("recents-\(UUID().uuidString)")

    func folder(_ name: String) throws -> URL {
        let url = tmp.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func remembersNewestFirstWithoutDuplicates() throws {
        let recents = RecentProjects(fileURL: tmp.appendingPathComponent("recents.json"), limit: 2)
        let a = try folder("a"), b = try folder("b"), c = try folder("c")
        let first = try recents.remember(a, at: Date(timeIntervalSince1970: 1))
        try recents.remember(b, at: Date(timeIntervalSince1970: 2))
        let again = try recents.remember(a, at: Date(timeIntervalSince1970: 3))
        #expect(again.id == first.id)
        #expect(recents.load().map(\.name) == ["a", "b"])
        try recents.remember(c, at: Date(timeIntervalSince1970: 4))
        #expect(recents.load().map(\.name) == ["c", "a"])
        try recents.forget(again.id)
        #expect(recents.load().map(\.name) == ["c"])
    }

    @Test func sameProjectAcrossContainers() {
        let a = URL(filePath: "/private/var/mobile/Containers/Data/Application/AAAA/Documents/Projects/demo")
        let b = URL(filePath: "/private/var/mobile/Containers/Data/Application/BBBB/Documents/Projects/demo")
        let c = URL(filePath: "/private/var/mobile/Containers/Data/Application/BBBB/Documents/Projects/other")
        #expect(RecentProjects.sameProject(a, b))
        #expect(!RecentProjects.sameProject(a, c))
    }

    @Test func availableSkipsMissingFolders() throws {
        let recents = RecentProjects(fileURL: tmp.appendingPathComponent("recents.json"))
        let keep = try folder("keep"), gone = try folder("gone")
        try recents.remember(keep)
        try recents.remember(gone)
        try FileManager.default.removeItem(at: gone)
        #expect(recents.available().map(\.ref.name) == ["keep"])
    }

    @Test func bookmarksFollowAMovedFolder() throws {
        let recents = RecentProjects(fileURL: tmp.appendingPathComponent("recents.json"))
        let original = try folder("before")
        let ref = try recents.remember(original)
        let moved = tmp.appendingPathComponent("after")
        try FileManager.default.moveItem(at: original, to: moved)
        let resolved = try #require(recents.url(for: ref))
        #expect(resolved.standardizedFileURL.resolvingSymlinksInPath() == moved.standardizedFileURL.resolvingSymlinksInPath())
    }
}

struct ProjectWatcherTests {
    final class Box: @unchecked Sendable {
        let lock = NSLock()
        var changes: [Set<URL>] = []
        var saves = 0
    }

    func coordinatedWrite(_ text: String, to url: URL) {
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: nil) { target in
            try? Data(text.utf8).write(to: target, options: .atomic)
        }
    }

    /// Polls off the main actor, so the main queue stays free for the watcher's callbacks.
    func wait(_ seconds: Double, until done: () -> Bool) async {
        let end = Date().addingTimeInterval(seconds)
        while !done() && Date() < end { try? await Task.sleep(for: .milliseconds(20)) }
    }

    @Test func reportsOutsideWritesOnce() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("watch-\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("a.txt")
        try "one".write(to: file, atomically: true, encoding: .utf8)

        let box = Box()
        let watcher = ProjectWatcher(root: root, debounce: 0.1)
        watcher.onChange = { urls in box.lock.withLock { box.changes.append(urls) } }
        watcher.onSaveRequest = { box.lock.withLock { box.saves += 1 } }
        watcher.start()
        defer { watcher.stop() }

        // Another writer: we're told once (debounced), with the real paths, not the safe-save temp files.
        DispatchQueue.global().async {
            self.coordinatedWrite("two", to: file)
            self.coordinatedWrite("three", to: root.appendingPathComponent("b.txt"))
        }
        await wait(5) { box.lock.withLock { !box.changes.isEmpty } }
        await wait(0.3) { false }
        let changes = box.lock.withLock { box.changes }
        #expect(changes.count == 1)
        #expect(changes.first?.map(\.lastPathComponent).sorted() == ["a.txt", "b.txt"])

        // Our own save, made through the watcher, doesn't echo back.
        box.lock.withLock { box.changes = [] }
        try TextFile.save("mine", to: file, presenter: watcher)
        await wait(0.5) { false }
        #expect(box.lock.withLock { box.changes }.isEmpty)
        #expect(try TextFile.load(file) == "mine")
    }

    @Test func asksUsToSaveBeforeTheFolderIsRead() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("watch-\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let box = Box()
        let watcher = ProjectWatcher(root: root)
        watcher.onSaveRequest = { box.lock.withLock { box.saves += 1 } }
        watcher.start()
        defer { watcher.stop() }
        DispatchQueue.global().async {
            NSFileCoordinator().coordinate(readingItemAt: root, options: [], error: nil) { _ in }
        }
        await wait(5) { box.lock.withLock { box.saves } > 0 }
        #expect(box.lock.withLock { box.saves } == 1)
    }

    @Test func recognizesSafeSaveTempFiles() {
        #expect(ProjectWatcher.isSafeSaveTemp("a.txt.sb-4d091091-aXxzuE"))
        #expect(!ProjectWatcher.isSafeSaveTemp("a.txt"))
        #expect(!ProjectWatcher.isSafeSaveTemp("notes.sb-draft.md"))
    }
}
