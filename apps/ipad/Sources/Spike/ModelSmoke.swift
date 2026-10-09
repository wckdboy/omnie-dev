// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

#if DEBUG
import Foundation
import ModelKit

/// Debug check of the model path end to end: download and verify the Tiny pack, load it, run a
/// fill-in-the-middle completion and a commit-message draft, and print timings.
@MainActor
enum ModelSmoke {
    static func run(_ app: AppModel) async {
        let models = app.models
        let pack = ModelPack.tiny
        await models.refresh()
        if !models.isInstalled(pack) {
            print("[smoke] downloading \(pack.displayName), \(pack.totalBytes) bytes")
            let t0 = Date()
            models.install(pack)
            var lastReport = -1
            while !models.isInstalled(pack) && models.error == nil {
                if let d = models.downloads[pack.id] {
                    let pct = Int(d.fraction * 100)
                    if pct / 10 != lastReport / 10 { print("[smoke] \(pct)%"); lastReport = pct }
                }
                try? await Task.sleep(for: .milliseconds(500))
            }
            if let error = models.error { print("[smoke] install failed: \(error)"); return }
            print("[smoke] installed and verified in \(String(format: "%.1f", Date().timeIntervalSince(t0))) s")
        }
        var t = Date()
        guard let tiny = await models.tinyModel() else { print("[smoke] load failed: \(models.error ?? "?")"); return }
        print("[smoke] loaded in \(String(format: "%.2f", Date().timeIntervalSince(t))) s")

        let prefix = "func fibonacci(_ n: Int) -> Int {\n    if n < 2 { return n }\n    return "
        let suffix = "\n}\n"
        t = Date()
        let fim = (try? await tiny.complete(.raw(FIM.qwen(prefix: prefix, suffix: suffix)), maxTokens: 24, stop: FIM.qwenStops)) ?? "<error>"
        print("[smoke] FIM in \(String(format: "%.2f", Date().timeIntervalSince(t))) s: \(fim.debugDescription) → ghost text \(FIM.trim(fim, suffix: suffix).debugDescription)")

        if app.workspace.git.repo != nil {
            await app.workspace.git.refresh()
            t = Date()
            let draft = await app.workspace.git.draftMessage(with: tiny)
            print("[smoke] commit draft in \(String(format: "%.2f", Date().timeIntervalSince(t))) s: \(draft.debugDescription)")
            print("[smoke] template draft: \(app.workspace.git.draftMessage.debugDescription)")
        }
        print("[smoke] done")
    }
}
#endif
