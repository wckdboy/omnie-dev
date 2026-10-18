// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

import DesignKit
import RunKit
import SwiftUI

/// The last test run's results, one row per test (PLAN §11.1 test explorer). Runs through RunKit's
/// sandbox, so the same vitest- and pytest-compatible subsets the terminal uses.
@MainActor
@Observable
final class TestsModel {
    struct Test: Identifiable, Hashable {
        var id: String { "\(file):\(name)" }
        let file: String
        let name: String
        let passed: Bool
        let error: String?
        let ms: Int
    }

    private(set) var tests: [Test] = []
    private(set) var isRunning = false
    private(set) var status: String?

    @ObservationIgnored weak var workspace: WorkspaceModel?

    var passedCount: Int { tests.filter(\.passed).count }
    var failedCount: Int { tests.filter { !$0.passed }.count }

    var hasTestFiles: Bool {
        guard let root = workspace?.rootURL else { return false }
        return !JSRunner.testFiles(in: root).isEmpty || !JSRunner.pythonTestFiles(in: root).isEmpty
    }

    /// Runs every test file, or one file when `only` is set.
    func run(only file: String? = nil) async {
        guard let root = workspace?.rootURL else { status = "Open a folder first."; return }
        guard file != nil || hasTestFiles else {
            tests = []
            status = "No test files found (*.test.ts, *.spec.js, test_*.py…)."
            return
        }
        isRunning = true
        status = nil
        workspace?.saveCurrent()
        do {
            let result = await (try JSRunner(root: root)).runAllTests(only: file)
            tests = result.tests.map(Self.test).sorted { ($0.file, $0.name) < ($1.file, $1.name) }
            status = tests.isEmpty ? "No tests ran." : "\(passedCount) passed, \(failedCount) failed"
        } catch {
            tests = []
            status = error.localizedDescription
        }
        isRunning = false
    }

    /// Re-runs the files that had a failure, keeping the other files' results.
    func runFailed() async {
        let failing = Set(tests.filter { !$0.passed }.map(\.file)).sorted()
        guard !failing.isEmpty, let root = workspace?.rootURL else { return }
        isRunning = true
        var merged = tests.filter { !failing.contains($0.file) }
        for file in failing {
            if let result = try? await JSRunner(root: root).runAllTests(only: file) {
                merged += result.tests.map(Self.test)
            }
        }
        tests = merged.sorted { ($0.file, $0.name) < ($1.file, $1.name) }
        status = "\(passedCount) passed, \(failedCount) failed"
        isRunning = false
    }

    private static func test(_ result: RunResult.TestResult) -> Test {
        Test(file: result.file, name: result.name, passed: result.passed, error: result.error, ms: result.ms)
    }
}

/// The Tests panel: run all or just the failures, and see each test's result.
struct TestsPanel: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var palette

    var body: some View {
        let tests = model.tests
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button { Task { await tests.run() } } label: { Label("Run all", systemImage: "play.fill").padding(.vertical, 14) }
                    .disabled(tests.isRunning)
                Button { Task { await tests.runFailed() } } label: { Label("Run failed", systemImage: "arrow.clockwise").padding(.vertical, 14) }
                    .disabled(tests.isRunning || tests.failedCount == 0)
                if tests.isRunning { ProgressView().controlSize(.small) }
                Spacer()
                if let status = tests.status {
                    Text(status).font(.caption).foregroundStyle(palette.text.secondary.color).lineLimit(1)
                }
            }
            .font(.footnote)
            .padding(.horizontal, 10)
            .frame(minHeight: 34)
            .background(palette.surface.pane.color)
            .overlay(alignment: .bottom) { Rectangle().fill(palette.surface.hairline.color).frame(height: Metrics.hairline) }

            if tests.tests.isEmpty {
                NotYet(title: "No tests yet",
                       detail: tests.hasTestFiles ? "Run all to see each test's result here." : "No test files found (*.test.ts, *.spec.js, test_*.py…).")
            } else {
                List {
                    ForEach(groups, id: \.file) { group in
                        Section(group.file) { ForEach(group.tests) { row($0) } }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
    }

    private var groups: [(file: String, tests: [TestsModel.Test])] {
        Dictionary(grouping: model.tests.tests, by: \.file)
            .map { (file: $0.key, tests: $0.value) }
            .sorted { $0.file < $1.file }
    }

    private func row(_ test: TestsModel.Test) -> some View {
        Button { open(test) } label: {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: test.passed ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .font(.callout)
                    .foregroundStyle(test.passed ? palette.status.ok.color : palette.status.error.color)
                    .accessibilityLabel(test.passed ? "Passed" : "Failed")
                VStack(alignment: .leading, spacing: 2) {
                    Text(test.name).font(.callout).lineLimit(1)
                    if let error = test.error, !error.isEmpty {
                        Text(error).font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(palette.text.secondary.color).lineLimit(4)
                    }
                }
                Spacer(minLength: 4)
                if test.ms > 0 { Text("\(test.ms) ms").font(.caption2).foregroundStyle(palette.text.tertiary.color) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func open(_ test: TestsModel.Test) {
        guard let root = model.workspace.rootURL else { return }
        model.workspace.open(file: root.appending(path: test.file))
    }
}
