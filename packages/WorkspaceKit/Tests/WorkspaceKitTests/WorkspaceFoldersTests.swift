// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing
@testable import WorkspaceKit

/// The folders a project has added to its workspace, remembered by bookmark per project.
struct WorkspaceFoldersTests {
    private func store() -> WorkspaceFolders {
        WorkspaceFolders(fileURL: FileManager.default.temporaryDirectory.appending(path: "folders-\(UUID().uuidString).json"))
    }

    private func folder(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "\(name)-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func remembersFoldersPerProjectInOrder() throws {
        let store = store()
        let one = try folder("one"), two = try folder("two")
        try store.remember(one, for: "project-a")
        try store.remember(two, for: "project-a")
        let available = store.available(for: "project-a")
        #expect(available.count == 2)
        #expect(available[0].path == one.standardizedFileURL.path)
        #expect(available[1].path == two.standardizedFileURL.path)
        #expect(store.available(for: "project-b").isEmpty, "folders belong to their project")
    }

    @Test func rememberingTheSameFolderAgainKeepsOneEntry() throws {
        let store = store()
        let one = try folder("one")
        let first = try store.remember(one, for: "project-a")
        let again = try store.remember(one, for: "project-a")
        #expect(store.folders(for: "project-a").count == 1)
        #expect(again.id == first.id, "the same folder keeps its identity")
    }

    @Test func forgetRemovesIt() throws {
        let store = store()
        let one = try folder("one"), two = try folder("two")
        try store.remember(one, for: "project-a")
        try store.remember(two, for: "project-a")
        try store.forget(one, for: "project-a")
        let available = store.available(for: "project-a")
        #expect(available.map(\.lastPathComponent) == [two.lastPathComponent])
    }

    @Test func aFolderThatHasGoneIsNotAvailable() throws {
        let store = store()
        let one = try folder("one")
        try store.remember(one, for: "project-a")
        try FileManager.default.removeItem(at: one)
        #expect(store.available(for: "project-a").isEmpty)
        #expect(store.folders(for: "project-a").count == 1, "the entry is kept, in case it comes back")
    }

    @Test func forgetKeepsOtherProjectsAlone() throws {
        let store = store()
        let one = try folder("one")
        try store.remember(one, for: "project-a")
        try store.remember(one, for: "project-b")
        try store.forget(one, for: "project-a")
        #expect(store.available(for: "project-a").isEmpty)
        #expect(store.available(for: "project-b").count == 1)
    }
}
