// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

#if DEBUG
import AgentKit
import Foundation
import RunKit
import ModelKit

/// Runs the golden task set (AgentKit.GoldenTask) against the local 7B, each task in a fresh
/// folder, and reports pass rate, steps and time. `-OmnieAgentEval` (debug builds).
@MainActor
enum AgentEval {
    struct Row: Codable {
        let task: String
        let passed: Bool
        let failure: String?
        let outcome: String
        let steps: Int
        let seconds: Double
    }

    static func run(_ app: AppModel, label: String) async {
        guard let model = await app.models.standardModel() else {
            print("[eval] no model: \(app.models.error ?? "?")")
            return
        }
        var rows: [Row] = []
        // `-OmnieEvalTasks a,b` runs only those.
        let args = ProcessInfo.processInfo.arguments
        let only = args.firstIndex(of: "-OmnieEvalTasks").flatMap { args.indices.contains($0 + 1) ? Set(args[$0 + 1].split(separator: ",").map(String.init)) : nil }
        for task in GoldenTask.all where only?.contains(task.id) ?? true {
            let root = FileManager.default.temporaryDirectory.appending(path: "eval-\(task.id)-\(UUID().uuidString.prefix(6))")
            do { try task.materialize(at: root) } catch { print("[eval] fixture failed: \(error)"); continue }
            // Outside the project, as in the app: the agent's grep must not find its own journal.
            let journal = Journal(url: root.deletingLastPathComponent().appending(path: "\(root.lastPathComponent).jsonl"))
            let runner = AgentRunner(goal: task.goal, model: model, tools: AgentModel.tools(root: root), journal: journal,
                                     authorize: { _, _ in true })
            let t0 = Date()
            let outcome = await runner.run()
            let seconds = Date().timeIntervalSince(t0)
            var failure = task.verify(at: root)
            if failure == nil, task.testsMustPass {
                let files = JSRunner.testFiles(in: root)
                let result = await (try? JSRunner(root: root))?.runTests(files)
                if result?.passed != true { failure = "the tests don't pass: \(result?.tests.filter { !$0.passed }.map(\.name).joined(separator: ", ") ?? "couldn't run")" }
            }
            let steps = journal.entries().filter { $0.kind == .assistant }.count
            let row = Row(task: task.id, passed: failure == nil, failure: failure, outcome: "\(outcome)", steps: steps, seconds: seconds)
            rows.append(row)
            if failure != nil {
                for entry in journal.entries() where entry.kind == .assistant || entry.kind == .toolResult {
                    let text = entry.text.replacingOccurrences(of: "\n", with: "⏎")
                    print("[trace:\(task.id)] \(entry.kind == .assistant ? "→" : "←") \(text.prefix(entry.kind == .assistant ? 400 : 160))")
                }
            }
            print("[eval] \(row.passed ? "PASS" : "FAIL") \(task.id) \(steps) steps \(String(format: "%.0f", seconds)) s \(failure ?? "") | \(String(describing: outcome).prefix(160))")
        }
        let passed = rows.filter(\.passed).count
        print("[eval] \(label): \(passed)/\(rows.count) passed, \(String(format: "%.0f", rows.map(\.seconds).reduce(0, +))) s total")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        struct Report: Codable { let label: String; let date: Date; let rows: [Row] }
        let url = URL.documentsDirectory.appending(path: "agent-eval-\(Int(Date().timeIntervalSince1970)).json")
        try? encoder.encode(Report(label: label, date: .now, rows: rows)).write(to: url)
        print("[eval] saved \(url.lastPathComponent)")
    }
}
#endif
