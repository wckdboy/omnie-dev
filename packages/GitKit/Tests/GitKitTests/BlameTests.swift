// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing
@testable import GitKit

struct BlameTests {
    @Test func linesKnowTheirCommitAndTheAgent() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("blame-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let repo = try Repository.create(at: dir)
        let me = Signature(name: "Pad", email: "pad@example.com")
        let agent = Signature(name: "Omnie Dev agent", email: "agent@omnie.invalid")
        try "one\ntwo\nthree\n".write(to: dir.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        let first = try await repo.commitAll(message: "Start\n", author: me)
        try "one\nTWO\nthree\nfour\n".write(to: dir.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        let second = try await repo.commitAll(message: "Agent: louder\n\nAssisted-by: qwen2.5-coder-7b\n", author: agent)

        let hunks = try await repo.blame(path: "a.txt")
        func at(_ line: Int) -> BlameHunk? { hunks.first { $0.lines.contains(line) } }
        #expect(at(1)?.commit == first.id && at(1)?.author == "Pad" && at(1)?.assistedBy == nil)
        #expect(at(2)?.commit == second.id && at(2)?.summary == "Agent: louder" && at(2)?.assistedBy == "qwen2.5-coder-7b")
        #expect(at(3)?.commit == first.id)
        #expect(at(4)?.commit == second.id)

        // The editor's unsaved text: the new line has no commit yet.
        let live = try await repo.blame(path: "a.txt", contents: "one\nTWO\nnew\nthree\nfour\n")
        let fresh = try #require(live.first { $0.lines.contains(3) })
        #expect(fresh.commit == nil && fresh.author == "You")
        #expect(live.first { $0.lines.contains(4) }?.commit == first.id)
    }
}
