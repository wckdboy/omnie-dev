// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing
@testable import GitKit
import Clibgit2

/// Clones public repositories from forges other than GitHub over the network. Opt-in:
/// `OMNIE_LIVE_FORGES=1 swift test --filter LiveForgeTests`.
struct LiveForgeTests {
    static let enabled = ProcessInfo.processInfo.environment["OMNIE_LIVE_FORGES"] != nil

    @Test(.enabled(if: enabled), arguments: [
        "https://codeberg.org/Codeberg/avatars.git",   // Forgejo
        "https://gitlab.com/pages/plain-html.git",     // GitLab
    ])
    func clonesPublicRepository(url: String) async throws {
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent("forge-\(UUID().uuidString)")
        if ProcessInfo.processInfo.environment["OMNIE_GIT_TRACE"] != nil {
            _ = Libgit2.initialize
            git_trace_set(GIT_TRACE_TRACE) { level, message in
                let t = Date().timeIntervalSince1970
                print(String(format: "[trace %.3f] ", t.truncatingRemainder(dividingBy: 1000)) + String(cString: message!))
            }
        }
        let started = Date()
        let repo = try await Repository.clone(from: url, to: dest, auth: RemoteAuth(credential: { _ in nil }, checkHostKey: { _ in .trusted }))
        let log = try await repo.log(limit: 1)
        print("[forge] \(url): \(Int(Date().timeIntervalSince(started) * 1000)) ms, HEAD \(log.first?.summary ?? "?")")
        #expect(!log.isEmpty)
    }
}
