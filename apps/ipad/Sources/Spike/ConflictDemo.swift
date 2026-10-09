// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

#if DEBUG
import Foundation
import GitKit

/// `-OmnieConflictDemo <folder in Documents>`: opens a repo whose branch `theirs` conflicts with
/// `main`, starts resolving, and prints the model's proposal for each file (nothing is merged).
@MainActor
enum ConflictDemo {
    static func run(_ app: AppModel, folder: String) async {
        app.workspace.open(folder: URL.documentsDirectory.appending(path: folder))
        try? await Task.sleep(for: .seconds(1))
        let git = app.workspace.git
        guard let repo = git.repo else { print("[conflict] no repo"); return }
        let theirs = (try? await repo.branches())?.first { $0.name == "theirs" }?.tip
        do { try await git.startResolving(against: theirs, title: "Merge theirs") } catch { print("[conflict] \(error)"); return }
        guard let session = git.mergeSession else { print("[conflict] no conflicts"); return }
        // Plane mode: the local model proposes.
        let wasPlane = app.policy.planeMode
        app.policy.planeMode = true
        defer { app.policy.planeMode = wasPlane }
        for file in session.conflicts {
            let start = Date()
            let proposal = await app.proposeResolution(for: file)
            print("[conflict] \(file.path) by \(proposal.by ?? "none") in \(String(format: "%.1f", Date().timeIntervalSince(start))) s\(proposal.note.map { " (\($0))" } ?? "")")
            print("[conflict] --- proposal\n\(proposal.text ?? "(none)")\n[conflict] ---")
        }
    }
}
#endif
