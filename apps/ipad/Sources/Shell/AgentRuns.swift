// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

import Foundation
import RunKit

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

    static func types(root: URL) async -> String {
        do { return await (try JSRunner(root: root)).typeCheck().report } catch { return error.localizedDescription }
    }

    static func script(root: URL, file: String) async -> String {
        do { return await (try JSRunner(root: root)).runFile(file).report } catch { return error.localizedDescription }
    }
}
