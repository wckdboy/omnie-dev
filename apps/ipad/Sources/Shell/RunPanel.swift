// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

import DesignKit
import RunKit
import SwiftUI

/// Runs the project's JavaScript/TypeScript on the device (PLAN.md §8, RunKit): its tests, or the
/// open file. No network; a run that doesn't finish in 30 s is stopped. The full terminal
/// (TermKit) comes later; this is the output pane it will share.
struct RunPanel: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var palette
    @State private var result: RunResult?
    @State private var running: String?
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button { Task { await run(nil) } } label: { Label("Run tests", systemImage: "checkmark.diamond") }
                    .disabled(model.workspace.rootURL == nil || running != nil)
                Button { Task { await run(model.workspace.relativePath) } } label: { Label("Run file", systemImage: "play") }
                    .disabled(!canRunOpenFile || running != nil)
                Spacer()
                if let running { ProgressView().controlSize(.small); Text(running).font(.system(size: 12)) }
            }
            .buttonStyle(.bordered)
            .font(.system(size: 13))
            .padding(12)
            Rectangle().fill(palette.surface.hairline.color).frame(height: Metrics.hairline)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    if let error {
                        Text(error).foregroundStyle(palette.status.error.color)
                    } else if let result {
                        ForEach(Array(result.report.split(separator: "\n", omittingEmptySubsequences: false).enumerated()), id: \.offset) { _, line in
                            Text(line.isEmpty ? " " : String(line))
                                .foregroundStyle(color(for: String(line)))
                        }
                    } else {
                        Text("Runs the project's tests (*.test.ts, *.spec.js…) or the open file, on this device, with no network.")
                            .foregroundStyle(palette.text.secondary.color)
                    }
                }
                .font(.system(size: 12, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
            }
        }
        .background(palette.surface.pane.color)
        #if DEBUG
        .task {
            if ProcessInfo.processInfo.arguments.contains("-OmnieRunTests") { await run(nil) }
        }
        #endif
    }

    private var canRunOpenFile: Bool {
        guard let path = model.workspace.relativePath else { return false }
        return [".ts", ".tsx", ".js", ".mjs", ".jsx"].contains { path.hasSuffix($0) }
    }

    private func color(for line: String) -> Color {
        if line.hasPrefix("✗") || line.hasPrefix("!") || line.hasPrefix("Stopped") { return palette.status.error.color }
        if line.hasPrefix("✓") { return palette.status.ok.color }
        return palette.text.primary.color
    }

    private func run(_ file: String?) async {
        guard let root = model.workspace.rootURL else { return }
        model.workspace.saveCurrent()
        error = nil
        do {
            let runner = try JSRunner(root: root)
            if let file, !file.contains(".test.") && !file.contains(".spec.") {
                running = "Running \(file)…"
                result = await runner.runScript(file)
            } else {
                let files = file.map { [$0] } ?? JSRunner.testFiles(in: root)
                guard !files.isEmpty else { error = "No test files found (*.test.ts, *.spec.js…)."; return }
                running = "Running \(files.count) test \(files.count == 1 ? "file" : "files")…"
                result = await runner.runTests(files)
            }
        } catch {
            self.error = error.localizedDescription
        }
        running = nil
    }
}

/// RunKit for the agent's run tools: same sandbox, plain-text reports.
@MainActor
enum AgentRuns {
    static func tests(root: URL, file: String?) async -> String {
        do {
            let files = file.map { [$0] } ?? JSRunner.testFiles(in: root)
            guard !files.isEmpty else { return "No test files found (*.test.ts, *.spec.js…)." }
            return await (try JSRunner(root: root)).runTests(files).report
        } catch { return error.localizedDescription }
    }

    static func script(root: URL, file: String) async -> String {
        do { return await (try JSRunner(root: root)).runScript(file).report } catch { return error.localizedDescription }
    }
}
