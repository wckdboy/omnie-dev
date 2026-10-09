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
        await ghost(app)
        print("[smoke] done")
    }

    /// Installs the Standard pack from a folder on the device instead of downloading 4.3 GB again.
    static func adopt(_ app: AppModel, from folder: URL) async {
        struct LocalFetcher: ModelFetcher {
            let folder: URL
            func fetch(_ url: URL, to destination: URL, progress: @escaping @Sendable (Int64) -> Void) async throws {
                try FileManager.default.copyItem(at: folder.appending(path: url.lastPathComponent), to: destination)
            }
        }
        let store = ModelStore(root: app.models.store.root, fetcher: LocalFetcher(folder: folder))
        let t0 = Date()
        do {
            try await store.install(.standard)
            print("[smoke] adopted \(ModelPack.standard.displayName) from \(folder.lastPathComponent), verified in \(String(format: "%.1f", Date().timeIntervalSince(t0))) s")
        } catch {
            print("[smoke] adopt failed: \(error)")
        }
        await app.models.refresh()
    }

    /// Types "return " at the end of a line, the way you would, and times the ghost text.
    static func ghost(_ app: AppModel) async {
        let folder = URL.documentsDirectory.appending(path: "ghost-demo")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appending(path: "Fib.swift")
        try? "func fibonacci(_ n: Int) -> Int {\n    if n < 2 { return n }\n    \n}\n".write(to: file, atomically: true, encoding: .utf8)
        app.workspace.open(folder: folder)
        app.workspace.open(file: file)
        try? await Task.sleep(for: .milliseconds(800))
        let editor = app.workspace.editor
        editor.selectedRange = NSRange(location: (editor.text as NSString).range(of: "    \n}").location + 4, length: 0)
        for (i, ch) in "return ".enumerated() {
            editor.textView.insertText(String(ch))
            if i < 6 { try? await Task.sleep(for: .milliseconds(90)) }
        }
        let typed = Date()
        while editor.ghostText == nil && Date().timeIntervalSince(typed) < 5 { try? await Task.sleep(for: .milliseconds(5)) }
        let ms = Int(Date().timeIntervalSince(typed) * 1000)
        print("[smoke] ghost text \(ms) ms after the last keystroke (300 ms of that is the idle pause): \(editor.ghostText.debugDescription)")
        editor.textView.insertText("\t")
        try? await Task.sleep(for: .milliseconds(100))
        print("[smoke] after Tab: \(editor.text.split(separator: "\n")[2].debugDescription)")
        app.workspace.saveCurrent()
    }
}
#endif
