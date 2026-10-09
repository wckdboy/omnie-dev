// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

import SwiftUI
import AgentKit
import CommandKit
import DesignKit
import EditorKit
import GitKit
import ModelKit
import SecretsKit

@main
struct OmnieDevApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ExperienceRoot()
                .environment(model)
                #if DEBUG
                .task {
                    // Debug-only launch arguments, for screenshots and UI tests:
                    // `-OmnieOpenFolder <path>` opens a folder (relative to Documents unless absolute); `-OmnieRunCommand <id>` (repeatable) runs a command.
                    let args = ProcessInfo.processInfo.arguments
                    // `-OmnieUIFixture`: a fresh project with one known file, open in the editor (UI tests).
                    if args.contains("-OmnieUIFixture") {
                        let folder = URL.documentsDirectory.appending(path: "uitest-fixture")
                        try? FileManager.default.removeItem(at: folder)
                        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                        try? "let alpha = 1;\nconst beta = alpha + 2;\nfunction gamma() { return beta; }\n"
                            .write(to: folder.appending(path: "main.ts"), atomically: true, encoding: .utf8)
                        model.workspace.open(folder: folder)
                        model.workspace.open(file: folder.appending(path: "main.ts"), preview: false)
                    }
                    if let i = args.firstIndex(of: "-OmnieOpenFolder"), args.indices.contains(i + 1) {
                        // Relative paths are inside Documents (handy on a device, where the container path is unknown).
                        let path = args[i + 1]
                        model.workspace.open(folder: path.hasPrefix("/") ? URL(filePath: path) : URL.documentsDirectory.appending(path: path))
                    }
                    // `-OmnieOpenFile <path relative to the folder>[:line]` opens a file in the editor.
                    if let i = args.firstIndex(of: "-OmnieOpenFile"), args.indices.contains(i + 1),
                       let root = model.workspace.rootURL {
                        // Comma-separated: each opens in a tab; the last stays a preview tab.
                        let files = args[i + 1].split(separator: ",").map(String.init)
                        for (n, file) in files.enumerated() {
                            // `path:line` puts the caret on that line.
                            if let colon = file.lastIndex(of: ":"), let line = Int(file[file.index(after: colon)...]) {
                                model.workspace.open(path: String(file[..<colon]), line: line, column: nil)
                            } else {
                                model.workspace.open(file: root.appending(path: file), preview: n == files.count - 1)
                            }
                        }
                    }
                    // `-OmnieDocs <query>` opens the docs sheet searching for it.
                    if let i = args.firstIndex(of: "-OmnieDocs"), args.indices.contains(i + 1) { model.docsQuery = args[i + 1] }
                    // `-OmnieDemoMarks` puts sample diagnostics, diff and authorship marks on the open file.
                    if args.contains("-OmnieDemoMarks") {
                        try? await Task.sleep(for: .milliseconds(600))
                        let text = model.workspace.editor.text as NSString
                        func line(_ n: Int) -> NSRange {
                            var start = 0
                            for _ in 0..<n { start = NSMaxRange(text.lineRange(for: NSRange(location: start, length: 0))) }
                            return text.lineRange(for: NSRange(location: start, length: 0))
                        }
                        let l12 = line(11), l16 = line(15), l20 = line(19)
                        model.workspace.editor.setMarks([
                            EditorMark(range: NSRange(location: l12.location + 4, length: 12), kind: .error),
                            EditorMark(range: NSRange(location: l16.location + 4, length: 10), kind: .warning),
                            EditorMark(range: l20, kind: .info),
                            EditorMark(range: NSRange(location: line(21).location, length: NSMaxRange(line(29)) - line(21).location), kind: .agentLines),
                            EditorMark(range: NSRange(location: line(21).location, length: NSMaxRange(line(29)) - line(21).location), kind: .addedText),
                            EditorMark(range: NSRange(location: line(32).location, length: NSMaxRange(line(34)) - line(32).location), kind: .modified),
                            EditorMark(range: line(36), kind: .removed),
                        ])
                    }
                    // `-OmnieEnsureSSHKey` creates the SSH key and writes its public line to Application Support.
                    if args.contains("-OmnieEnsureSSHKey") {
                        let git = model.workspace.git
                        if git.identity == nil { git.createIdentity() }
                        if let line = git.identity?.signer.authorizedKeysLine(comment: "omnie-dev-sim") {
                            try? line.write(to: AppPaths.support.appendingPathComponent("debug-ssh-public-key.txt"), atomically: true, encoding: .utf8)
                        }
                    }
                    // `-OmnieCommit <message>` commits everything in the open folder, through the secret scan.
                    if let i = args.firstIndex(of: "-OmnieCommit"), args.indices.contains(i + 1) {
                        let git = model.workspace.git
                        try? await Task.sleep(for: .milliseconds(500))
                        let author = await git.author() ?? Signature(name: "Omnie Debug", email: "debug@omnie.invalid")
                        _ = await git.commit(message: args[i + 1], author: author)
                    }
                    // `-OmnieAdoptModel <folder in Documents>` installs the Standard pack from a local copy
                    // (the model spike's), verified file by file like a download.
                    if let i = args.firstIndex(of: "-OmnieAdoptModel"), args.indices.contains(i + 1) {
                        await ModelSmoke.adopt(model, from: URL.documentsDirectory.appending(path: args[i + 1]))
                    }
                    if args.contains("-OmnieWasiConformance") { await WasiConformance.run() }
                    if args.contains("-OmniePlaneTest") { await PlaneTest.run(model) }
                    if let i = args.firstIndex(of: "-OmnieConflictDemo"), args.indices.contains(i + 1) { await ConflictDemo.run(model, folder: args[i + 1]) }
                    // `-OmnieStageSummary` prints what the agent's stage_scene tool would see.
                    if args.contains("-OmnieStageSummary") {
                        Task {
                            try? await Task.sleep(for: .seconds(10))
                            print("[stage-summary]\n" + StageSnapshot.shared.summary())
                        }
                    }
                    // `-OmnieAgentEval <label>` runs the golden task set against the local 7B.
                    if let i = args.firstIndex(of: "-OmnieAgentEval") {
                        await AgentEval.run(model, label: args.indices.contains(i + 1) ? args[i + 1] : "eval")
                    }
                    // `-OmnieRunTests` opens the Run panel and runs the project's tests.
                    if args.contains("-OmnieRunTests") || args.contains("-OmnieTerminal") { model.show(.terminal) }
                    // `-OmniePreview` opens the Preview tab.
                    if args.contains("-OmniePreview") { model.show(.preview) }
                    if args.contains("-OmnieStage") { model.show(.stage) }
                    if args.contains("-OmnieTools") { model.show(.tools) }
                    // `-OmnieAgentDemo` runs a scripted agent task in the open project (UI checks).
                    if args.contains("-OmnieAgentDemo") {
                        try? await Task.sleep(for: .milliseconds(800))
                        model.showAgent()
                        await AgentDemo.run(model)
                    }
                    // `-OmnieOnlineModel <base URL>` routes agent tasks to an OpenAI-compatible server
                    // (a local mock in tests) with the key "test".
                    if let i = args.firstIndex(of: "-OmnieOnlineModel"), args.indices.contains(i + 1), let url = URL(string: args[i + 1]) {
                        model.models.online = RemoteModelConfig(kind: .openAICompatible, provider: "custom", baseURL: url, model: "mock")
                        model.models.route = .online
                        try? APIKeys.save("test", provider: "custom")
                    }
                    // `-OmnieImportKey <file in Documents> <provider>` moves an API key from a file into the
                    // Keychain and deletes the file (so the key never appears in launch arguments or logs).
                    if let i = args.firstIndex(of: "-OmnieImportKey"), args.indices.contains(i + 2) {
                        let url = URL.documentsDirectory.appending(path: args[i + 1])
                        if let key = try? String(contentsOf: url, encoding: .utf8) {
                            try? APIKeys.save(key, provider: args[i + 2])
                            if args[i + 2] == "anthropic" { model.models.online = .anthropic }
                            print("[key] imported for \(args[i + 2]): \(APIKeys.has(provider: args[i + 2]))")
                        }
                        try? FileManager.default.removeItem(at: url)
                    }
                    // `-OmnieAgentTask <goal>` starts an agent task in the open project.
                    if let i = args.firstIndex(of: "-OmnieAgentTask"), args.indices.contains(i + 1) {
                        try? await Task.sleep(for: .milliseconds(800))
                        await model.agent.start(args[i + 1])
                    }
                    // `-OmnieModelSmoke` installs the Tiny pack (if needed), then times load, FIM and a commit draft.
                    if args.contains("-OmnieModelSmoke") {
                        await ModelSmoke.run(model)
                    }
                    // `-OmnieSketchDemo "<what it is>"` sends a wireframe drawn in code through sketch → code
                    // (needs the online key; with -OmnieTestApprove) and logs the changeset.
                    if let i = args.firstIndex(of: "-OmnieSketchDemo"), args.indices.contains(i + 1),
                       let png = SketchRender.png(drawing: SketchRender.demoDrawing()) {
                        try? png.write(to: URL.documentsDirectory.appending(path: "sketch-demo.png"))
                        // The folder's repository opens asynchronously.
                        for _ in 0..<50 where model.workspace.git.repo == nil { try? await Task.sleep(for: .milliseconds(200)) }
                        if let root = model.workspace.rootURL {
                            let context = SketchToCode.context(root: root)
                            print("[sketch] context: \(context.stack); components in \(context.componentsFolder ?? "-"); files \(context.files)")
                        }
                        let started = Date()
                        await model.agent.startSketch(png: png, source: .sketch, instruction: args[i + 1])
                        let ms = Int(Date().timeIntervalSince(started) * 1000)
                        if let error = model.agent.error {
                            print("[sketch] failed after \(ms) ms: \(error)")
                        } else if let task = model.agent.current {
                            print("[sketch] \(task.phase.rawValue) in \(ms) ms (\(png.count / 1024) KB image): \(task.summary ?? task.attention ?? "")")
                            for diff in model.agent.changes { print("[sketch] --- \(diff.path)\n\(diff.patch)") }
                        } else {
                            print("[sketch] queued (\(model.agent.queuedSketches.count) waiting)")
                        }
                    }
                    // `-OmnieClone <url>` clones and opens the result.
                    if let i = args.firstIndex(of: "-OmnieClone"), args.indices.contains(i + 1) {
                        let started = Date()
                        let folder = await model.workspace.git.clone(args[i + 1])
                        let ms = Int(Date().timeIntervalSince(started) * 1000)
                        if let folder {
                            model.workspace.open(folder: folder)
                            let files = FileManager.default.enumerator(atPath: folder.path(percentEncoded: false))?
                                .compactMap { $0 as? String }.filter { !$0.hasPrefix(".git/") && $0 != ".git" }.count ?? 0
                            let head = (try? await Repository.open(at: folder).log(limit: 1).first?.summary) ?? "?"
                            print("[clone] \(args[i + 1]) → \(folder.lastPathComponent): \(files) entries, HEAD \"\(head ?? "")\", \(ms) ms")
                        } else {
                            print("[clone] \(args[i + 1]) failed after \(ms) ms: \(model.workspace.git.error ?? "no error recorded")")
                        }
                    }
                }
                #endif
                .task {
                    // `-OmnieRunCommand <id>` (repeatable) runs palette commands at launch, in every build,
                    // so the release-build spike can be started from Xcode's scheme arguments.
                    // Runs after the debug launch helpers above have opened any folder or file.
                    try? await Task.sleep(for: .milliseconds(300))
                    let args = ProcessInfo.processInfo.arguments
                    for (i, arg) in args.enumerated() where arg == "-OmnieRunCommand" && args.indices.contains(i + 1) {
                        model.registry.run(CommandID(rawValue: args[i + 1]))
                    }
                }
        }
        .commands {
            RegistryMenus(model: model)
        }

        // A panel in a window of its own ("Open in new window" in a tab's menu).
        WindowGroup("Panel", id: PanelWindow.sceneID, for: String.self) { $panel in
            PanelWindow(panel: panel ?? UtilityTab.preview.rawValue)
                .environment(model)
        }
    }
}

/// Picks the experience by device, not window width: iPad always gets the IDE
/// (with its own single-pane layout when narrow), iPhone gets the vibecoding app.
struct ExperienceRoot: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let palette = Palette.resolve(colorScheme: colorScheme, contrast: contrast)
        Group {
            switch model.experience {
            case .ide: IDEShell()
            case .vibe: VibeShell()
            }
        }
        .environment(\.palette, palette)
        .environment(\.density, model.density)
        .tint(palette.accent.ion.color)
        .background(palette.surface.chrome.color)
    }
}
