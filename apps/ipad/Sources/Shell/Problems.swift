// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

import DesignKit
import EditorKit
import RunKit
import SwiftUI

/// Type errors in a TypeScript project (PLAN.md §5 diagnostics), from RunKit's offline checker.
/// Checked when the project opens and after every save, a moment after things settle.
@MainActor
@Observable
final class ProblemsModel {
    private(set) var diagnostics: [TypeDiagnostic] = []
    private(set) var isChecking = false
    private(set) var failure: String?
    /// Called after a check, so the open file's marks can be refreshed.
    @ObservationIgnored var onUpdate: (() -> Void)?
    @ObservationIgnored private var task: Task<Void, Never>?

    var errors: Int { diagnostics.filter { $0.category == .error }.count }
    var warnings: Int { diagnostics.filter { $0.category == .warning }.count }

    func clear() {
        task?.cancel()
        diagnostics = []
        failure = nil
        isChecking = false
        onUpdate?()
    }

    func schedule(root: URL, after delay: Duration = .milliseconds(700)) {
        task?.cancel()
        task = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            await check(root: root)
        }
    }

    func check(root: URL) async {
        guard await Task.detached(operation: { JSRunner.hasTypeScript(root) }).value else {
            if !diagnostics.isEmpty { diagnostics = []; onUpdate?() }
            return
        }
        isChecking = true
        defer { isChecking = false }
        guard let runner = try? JSRunner(root: root) else { return }
        let result = await runner.typeCheck()
        guard !Task.isCancelled else { return }
        failure = result.failure
        if result.failure == nil { diagnostics = result.diagnostics }
        onUpdate?()
    }

    /// Underlines for one file (a path relative to the project).
    func marks(for path: String?) -> [EditorMark] {
        guard let path else { return [] }
        return diagnostics.compactMap { d in
            guard d.path == path, let start = d.start else { return nil }
            let kind: EditorMark.Kind = switch d.category { case .error: .error; case .warning: .warning; case .info: .info }
            return EditorMark(range: NSRange(location: start, length: max(1, d.length ?? 1)), kind: kind)
        }
    }
}

/// The status strip's problem count; tapping it lists them.
struct ProblemsLabel: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var palette

    var body: some View {
        let problems = model.workspace.problems
        if problems.errors + problems.warnings > 0 {
            Button { model.problemsOpen = true } label: {
                Label("\(problems.errors) \(problems.errors == 1 ? "error" : "errors")", systemImage: "xmark.octagon")
                    .foregroundStyle(problems.errors > 0 ? palette.status.error.color : palette.status.warn.color)
            }
            .buttonStyle(.plain)
            .accessibilityHint("Lists type errors")
        } else if problems.isChecking {
            Text("Checking types…")
        }
    }
}

/// Every problem, by file; tapping one opens the file with it selected.
struct ProblemsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.palette) private var palette

    var body: some View {
        let problems = model.workspace.problems
        let files = Dictionary(grouping: problems.diagnostics, by: { $0.path ?? "Project" })
        NavigationStack {
            List {
                if let failure = problems.failure {
                    Text("Type check failed: \(failure)").foregroundStyle(palette.status.error.color)
                }
                if problems.diagnostics.isEmpty && problems.failure == nil {
                    Text(problems.isChecking ? "Checking…" : "No type errors.").foregroundStyle(palette.text.secondary.color)
                }
                ForEach(files.keys.sorted(), id: \.self) { path in
                    Section(path) {
                        ForEach(files[path] ?? []) { d in
                            Button { open(d) } label: {
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Image(systemName: d.category == .error ? "xmark.octagon" : "exclamationmark.triangle")
                                        .foregroundStyle(d.category == .error ? palette.status.error.color : palette.status.warn.color)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(d.message).font(.system(size: 13))
                                        if let line = d.line {
                                            Text(verbatim: "Line \(line), column \(d.column ?? 1) · TS\(d.code)")
                                                .font(.system(size: 11, design: .monospaced))
                                                .foregroundStyle(palette.text.secondary.color)
                                        }
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                            .disabled(d.path == nil)
                        }
                    }
                }
            }
            .listStyle(.plain)
            .navigationTitle("Problems")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button("Check again") { if let root = model.workspace.rootURL { problems.schedule(root: root, after: .zero) } }
                        .disabled(problems.isChecking)
                }
            }
        }
    }

    private func open(_ d: TypeDiagnostic) {
        guard let root = model.workspace.rootURL, let path = d.path, let start = d.start else { return }
        model.workspace.open(file: root.appending(path: path), select: NSRange(location: start, length: d.length ?? 0))
        dismiss()
    }
}
