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

    /// Git LFS from a real forge (Gitea), anonymous: clone, download the large files, check them.
    @Test(.enabled(if: enabled))
    func clonesWithLFSFiles() async throws {
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent("lfs-live-\(UUID().uuidString)")
        let auth = RemoteAuth(credential: { _ in nil }, checkHostKey: { _ in .trusted })
        let started = Date()
        let repo = try await Repository.clone(from: "https://gitea.com/jkelroy/lfs-example-2.git", to: dest, auth: auth)
        #expect(await repo.usesLFS())
        let pointers = try await repo.lfsPointers()
        let count = try await repo.lfsPull(auth: auth)
        print("[forge] LFS: \(pointers.count) pointers, \(count) downloaded in \(Int(Date().timeIntervalSince(started) * 1000)) ms")
        #expect(!pointers.isEmpty && count == Set(pointers.values).count)
        for (path, pointer) in pointers {
            let data = try Data(contentsOf: dest.appending(path: path))
            #expect(LFS.Pointer(content: data) == pointer, "\(path) has its real content")
        }
        #expect(try await repo.status().entries.isEmpty)
    }
}
