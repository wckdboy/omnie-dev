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
                        Text("Runs the project's tests (*.test.ts, *.spec.js, test_*.py…) or the open file (JavaScript, TypeScript or Python) on this device, with no network.")
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
        return [".ts", ".tsx", ".js", ".mjs", ".jsx", ".py"].contains { path.hasSuffix($0) }
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
            if let file, !Self.isTest(file) {
                running = "Running \(file)…"
                result = await runner.runFile(file)
            } else {
                let count = file == nil ? JSRunner.testFiles(in: root).count + JSRunner.pythonTestFiles(in: root).count : 1
                guard count > 0 else { error = "No test files found (*.test.ts, *.spec.js, test_*.py…)."; running = nil; return }
                running = "Running \(count) test \(count == 1 ? "file" : "files")…"
                result = await runner.runAllTests(only: file)
            }
        } catch {
            self.error = error.localizedDescription
        }
        running = nil
    }
}

extension RunPanel {
    static func isTest(_ path: String) -> Bool {
        let name = (path as NSString).lastPathComponent
        return name.contains(".test.") || name.contains(".spec.") || (name.hasSuffix(".py") && (name.hasPrefix("test_") || name.hasSuffix("_test.py")))
    }
}

/// RunKit for the agent's run tools: same sandbox, plain-text reports.
@MainActor
enum AgentRuns {
    static func tests(root: URL, file: String?) async -> String {
        guard file != nil || !JSRunner.testFiles(in: root).isEmpty || !JSRunner.pythonTestFiles(in: root).isEmpty else {
            return "No test files found (*.test.ts, *.spec.js, test_*.py…)."
        }
        do {
            let result = await (try JSRunner(root: root)).runAllTests(only: file)
            return result.report + codeUnderTest(result, root: root)
        } catch { return error.localizedDescription }
    }

    /// For failing test files, the project files they import, so the agent looks at the code and
    /// not only the test (on the device it kept editing the test file instead).
    static func codeUnderTest(_ result: RunResult, root: URL) -> String {
        let failing = Set(result.tests.filter { !$0.passed }.map(\.file))
        var lines: [String] = []
        for file in failing.sorted() {
            guard let text = try? String(contentsOf: root.appending(path: file), encoding: .utf8) else { continue }
            let dir = (file as NSString).deletingLastPathComponent
            var imports: [String] = []
            for match in text.matches(of: /from\s+["'](\.{1,2}\/[^"']+)["']/) {
                let joined = ((dir as NSString).appendingPathComponent(String(match.1)) as NSString).standardizingPath
                let found = ["", ".ts", ".tsx", ".js", ".mjs", "/index.ts", "/index.js"].map { joined + $0 }
                    .first { FileManager.default.fileExists(atPath: root.appending(path: $0).path) && !$0.isEmpty }
                if let found { imports.append(found) }
            }
            for match in text.matches(of: /^\s*(?:from\s+([\w.]+)\s+import|import\s+([\w.]+))/.anchorsMatchLineEndings()) {
                let module = String(match.1 ?? match.2 ?? "")
                let path = module.replacingOccurrences(of: ".", with: "/") + ".py"
                if FileManager.default.fileExists(atPath: root.appending(path: path).path) { imports.append(path) }
            }
            if !imports.isEmpty { lines.append("\(file) tests: \(imports.joined(separator: ", "))") }
        }
        return lines.isEmpty ? "" : "\nCode under test (read it before changing anything):\n" + lines.joined(separator: "\n")
    }

    static func script(root: URL, file: String) async -> String {
        do { return await (try JSRunner(root: root)).runFile(file).report } catch { return error.localizedDescription }
    }
}
