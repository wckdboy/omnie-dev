// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

import DesignKit
import RunKit
import SwiftUI

/// The test explorer's results: one row per test (PLAN §11.1). Runs through RunKit's sandbox, so the
/// same vitest- and pytest-compatible subsets the terminal uses. A single file or a single test can be
/// run again without losing the other results.
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

    /// Runs every test file, one file, or one test in a file.
    func run(only file: String? = nil, name: String? = nil) async {
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
            let result = await (try JSRunner(root: root)).runAllTests(only: file, name: name)
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

    /// Runs one file again and folds its results into the list; the other files stay as they were.
    func rerun(file: String) async {
        await rerun(only: file, name: nil)
    }

    /// Runs one test again (in its file) and replaces just that row.
    func rerun(_ test: Test) async {
        await rerun(only: test.file, name: test.name)
    }

    private func rerun(only file: String, name: String?) async {
        guard let root = workspace?.rootURL else { return }
        isRunning = true
        workspace?.saveCurrent()
        if let result = try? await JSRunner(root: root).runAllTests(only: file, name: name) {
            let updated = result.tests.map(Self.test)
            if updated.isEmpty {
                status = name.map { "“\($0)” didn't run again." } ?? "No tests ran in \(file)."
            } else {
                let ids = Set(updated.map(\.id))
                tests = (tests.filter { !ids.contains($0.id) } + updated).sorted { ($0.file, $0.name) < ($1.file, $1.name) }
                status = "\(passedCount) passed, \(failedCount) failed"
            }
        } else {
            status = "Couldn't run \(file)."
        }
        isRunning = false
    }

    private static func test(_ result: RunResult.TestResult) -> Test {
        Test(file: result.file, name: result.name, passed: result.passed, error: result.error, ms: result.ms)
    }
}

/// The Tests panel: run all or just the failures, run one file or one test again, and see each test's
/// output.
struct TestsPanel: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var palette
    @State private var failuresOnly = false
    @State private var selectedID: String?

    var body: some View {
        let tests = model.tests
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button { Task { await tests.run() } } label: { Label("Run all", systemImage: "play.fill").padding(.vertical, 14) }
                    .disabled(tests.isRunning)
                Button { Task { await tests.runFailed() } } label: { Label("Run failed", systemImage: "arrow.clockwise").padding(.vertical, 14) }
                    .disabled(tests.isRunning || tests.failedCount == 0)
                Toggle(isOn: $failuresOnly) {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                }
                .toggleStyle(.button)
                .accessibilityLabel("Show failed tests only")
                .disabled(tests.failedCount == 0)
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
            } else if failuresOnly && tests.failedCount == 0 {
                NotYet(title: "All tests passed", detail: "Turn off the filter to see every test.")
            } else {
                List {
                    ForEach(groups, id: \.file) { group in
                        Section {
                            ForEach(group.tests) { row($0) }
                        } header: {
                            HStack {
                                Text(group.file)
                                Spacer()
                                Button { Task { await tests.rerun(file: group.file) } } label: {
                                    Image(systemName: "arrow.clockwise")
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Run \(group.file) again")
                            }
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
        .sheet(isPresented: Binding(get: { selectedID != nil }, set: { if !$0 { selectedID = nil } })) {
            if let id = selectedID { TestDetailSheet(id: id).sheetChrome() }
        }
    }

    private var groups: [(file: String, tests: [TestsModel.Test])] {
        Dictionary(grouping: model.tests.tests.filter { !failuresOnly || !$0.passed }, by: \.file)
            .map { (file: $0.key, tests: $0.value) }
            .sorted { $0.file < $1.file }
    }

    private func row(_ test: TestsModel.Test) -> some View {
        Button { selectedID = test.id } label: {
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
        .contextMenu {
            Button { Task { await model.tests.rerun(test) } } label: { Label("Run this test again", systemImage: "arrow.clockwise") }
            Button { open(test) } label: { Label("Open \(test.file)", systemImage: "doc.text") }
        }
    }

    private func open(_ test: TestsModel.Test) {
        guard let root = model.workspace.rootURL else { return }
        model.workspace.open(file: root.appending(path: test.file))
    }
}

/// One test's result: its full output (the assertion message and stack, not the row's four lines),
/// with Run again and Open file.
struct TestDetailSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.palette) private var palette
    /// Looked up on every render, so Run again updates what's shown here.
    let id: String

    private var test: TestsModel.Test? { model.tests.tests.first { $0.id == id } }

    var body: some View {
        NavigationStack {
            Group {
                if let test {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            Label(test.passed ? "Passed" : "Failed", systemImage: test.passed ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .font(.headline)
                                .foregroundStyle(test.passed ? palette.status.ok.color : palette.status.error.color)
                                .accessibilityLabel(test.passed ? "Passed" : "Failed")
                            Text(test.name)
                                .font(.title3.weight(.semibold))
                                .textSelection(.enabled)
                            Text("\(test.file) · \(test.ms) ms")
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(palette.text.secondary.color)
                            if let error = test.error, !error.isEmpty {
                                Text(error)
                                    .font(.system(.callout, design: .monospaced))
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(10)
                                    .background(palette.surface.raised.color, in: RoundedRectangle(cornerRadius: 8))
                            } else if test.passed {
                                Text("No output; the test passed.")
                                    .font(.footnote)
                                    .foregroundStyle(palette.text.secondary.color)
                            }
                        }
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else {
                    NotYet(title: "Not in this run", detail: "Run the tests again to see this result.")
                }
            }
            .navigationTitle("Test")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button("Run again") { if let test { Task { await model.tests.rerun(test) } } }
                        .disabled(model.tests.isRunning)
                }
            }
            .safeAreaInset(edge: .bottom) {
                if let test {
                    Button { open(test) } label: {
                        Label("Open \(test.file)", systemImage: "doc.text")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .padding(12)
                }
            }
        }
    }

    private func open(_ test: TestsModel.Test) {
        guard let root = model.workspace.rootURL else { return }
        model.workspace.open(file: root.appending(path: test.file))
        dismiss()
    }
}
