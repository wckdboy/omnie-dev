// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing
@testable import GitKit

struct RefOpsTests {
    let dir: URL
    let me = Signature(name: "Pad", email: "pad@example.com")

    init() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("refops-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    func write(_ path: String, _ text: String) throws {
        try text.write(to: dir.appendingPathComponent(path), atomically: true, encoding: .utf8)
    }

    @Test func tagsResetAndReflog() async throws {
        let repo = try Repository.create(at: dir)
        try write("a.txt", "1\n")
        let first = try await repo.commitAll(message: "First\n", author: me)
        try write("a.txt", "2\n")
        let second = try await repo.commitAll(message: "Second\n", author: me)

        try await repo.tag("v1.0", at: first.id, message: "Release 1.0", tagger: me)
        try await repo.tag("latest", at: second.id, tagger: me)
        #expect(try await repo.tags() == [first.id: ["v1.0"], second.id: ["latest"]])
        await #expect(throws: RefOpError.tagExists("v1.0")) { try await repo.tag("v1.0", at: second.id, tagger: me) }
        await #expect(throws: RefOpError.badTagName("bad name")) { try await repo.tag("bad name", at: second.id, tagger: me) }
        try await repo.deleteTag("latest")
        #expect(try await repo.tags() == [first.id: ["v1.0"]])

        // Reset keeps the folder: Second's change is uncommitted now.
        try await repo.resetKeepingChanges(to: first.id)
        #expect(try await repo.head().commit == first.id)
        #expect(try String(contentsOf: dir.appendingPathComponent("a.txt"), encoding: .utf8) == "2\n")
        #expect(try await repo.status().entries.map(\.path) == ["a.txt"])
        // And Undo brings the commit back.
        let undone = try await repo.undo()
        #expect(undone.title == "Reset to \(first.id.short)")
        #expect(try await repo.head().commit == second.id)

        let log = try await repo.reflog()
        #expect(log.first?.commit == second.id)
        #expect(log.contains { $0.message.contains("reset to \(first.id.short)") })
    }
}
