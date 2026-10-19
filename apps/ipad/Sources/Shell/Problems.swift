// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

import DesignKit
import EditorKit
import RunKit
import SwiftUI

/// Problems in the project (PLAN.md §5 diagnostics): TypeScript's type errors from RunKit's
/// offline checker, and Ruff's lint for Python files. Checked when the project opens and after
/// every save, a moment after things settle.
@MainActor
@Observable
final class ProblemsModel {
    /// One folder's diagnostics. A multi-root workspace checks each folder of its own, so a problem
    /// says which folder it is in and opens the right file.
    struct Folder: Identifiable {
        let root: URL
        var type: [TypeDiagnostic] = []
        var python: [TypeDiagnostic] = []
        var failure: String?
        var id: String { root.path(percentEncoded: false) }
        var diagnostics: [TypeDiagnostic] { type + python }
    }

    /// In workspace order: the project's own folder first, then the added ones.
    private(set) var folders: [Folder] = []
    @ObservationIgnored private var linter: CodeFormatter?
    /// Shader compile errors from the Stage, until it reloads.
    var stageDiagnostics: [TypeDiagnostic] = [] { didSet { onUpdate?() } }
    var diagnostics: [TypeDiagnostic] { folders.flatMap(\.diagnostics) + stageDiagnostics }
    private(set) var isChecking = false
    /// The first folder whose check failed, if any.
    var failure: String? { folders.compactMap(\.failure).first }
    /// Every failing folder, for the sheet.
    var failures: [(root: URL, message: String)] { folders.compactMap { f in f.failure.map { (f.root, $0) } } }
    /// Called after a check, so the open file's marks can be refreshed.
    @ObservationIgnored var onUpdate: (() -> Void)?
    @ObservationIgnored private var task: Task<Void, Never>?

    var errors: Int { diagnostics.filter { $0.category == .error }.count }
    var warnings: Int { diagnostics.filter { $0.category == .warning }.count }

    func clear() {
        task?.cancel()
        folders = []
        stageDiagnostics = []
        linter?.stop()
        linter = nil
        isChecking = false
        onUpdate?()
    }

    /// Forgets a folder that has left the workspace; its problems go with it.
    func forget(root: URL) {
        folders.removeAll { $0.id == root.standardizedFileURL.path(percentEncoded: false) }
        onUpdate?()
    }

    /// Checks every folder of the workspace, one after another (one checker at a time).
    func schedule(roots: [URL], after delay: Duration = .milliseconds(700)) {
        let roots = roots.map(\.standardizedFileURL)
        guard !roots.isEmpty else { return }
        task?.cancel()
        task = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            isChecking = true
            defer { isChecking = false }
            for root in roots {
                guard !Task.isCancelled else { return }
                await check(root: root)
            }
        }
    }

    /// Checks one folder (a save, a package install).
    func schedule(root: URL, after delay: Duration = .milliseconds(700)) {
        schedule(roots: [root], after: delay)
    }

    /// Checks one folder: Ruff over its Python files, then the TypeScript checker if it has any.
    func check(root: URL) async {
        await lintPython(root: root)
        guard await Task.detached(operation: { JSRunner.hasTypeScript(root) }).value else {
            setType([], failure: nil, for: root)
            return
        }
        guard let runner = try? JSRunner(root: root) else { return }
        let result = await runner.typeCheck()
        guard !Task.isCancelled else { return }
        #if DEBUG
        print("[types] \(root.lastPathComponent): \(result.report.split(separator: "\n").last ?? "")")
        #endif
        setType(result.failure == nil ? result.diagnostics : [], failure: result.failure, for: root)
    }

    private func setType(_ diagnostics: [TypeDiagnostic], failure: String?, for root: URL) {
        let index = index(of: root) ?? append(root)
        folders[index].type = diagnostics
        folders[index].failure = failure
        onUpdate?()
    }

    private func setPython(_ diagnostics: [TypeDiagnostic], for root: URL) {
        let index = index(of: root) ?? append(root)
        folders[index].python = diagnostics
        onUpdate?()
    }

    private func index(of root: URL) -> Int? {
        folders.firstIndex { $0.id == root.standardizedFileURL.path(percentEncoded: false) }
    }

    @discardableResult
    private func append(_ root: URL) -> Int {
        folders.append(Folder(root: root.standardizedFileURL))
        return folders.count - 1
    }

    /// Ruff over the project's Python files (up to 300), outside environments and caches.
    private func lintPython(root: URL) async {
        let files = await Task.detached { Self.pythonFiles(in: root) }.value
        guard !files.isEmpty else {
            setPython([], for: root)
            return
        }
        if linter?.root != root { linter?.stop(); linter = try? CodeFormatter(root: root) }
        guard let linter else { return }
        var found: [TypeDiagnostic] = []
        for path in files {
            guard !Task.isCancelled else { return }
            guard let text = try? String(contentsOf: root.appending(path: path), encoding: .utf8) else { continue }
            found += (try? await linter.lint(text, path: path)) ?? []
        }
        setPython(found, for: root)
    }

    nonisolated static func pythonFiles(in root: URL) -> [String] {
        let skip: Set<String> = [".git", "node_modules", ".venv", "venv", "__pycache__", ".mypy_cache", ".pytest_cache", "build", "dist", ".tox"]
        var files: [String] = []
        let base = root.standardizedFileURL.path(percentEncoded: false)
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        while let url = enumerator?.nextObject() as? URL, files.count < 300 {
            if skip.contains(url.lastPathComponent) { enumerator?.skipDescendants(); continue }
            guard url.pathExtension == "py" else { continue }
            let path = url.standardizedFileURL.path(percentEncoded: false)
            files.append(String(path.dropFirst(base.hasSuffix("/") ? base.count : base.count + 1)))
        }
        return files.sorted()
    }

    /// Underlines for one file: its folder's diagnostics, by the path inside that folder.
    func marks(for url: URL?) -> [EditorMark] {
        guard let url, let folder = folders.first(where: { Self.path(of: url, inside: $0.root) != nil }),
              let path = Self.path(of: url, inside: folder.root) else { return [] }
        return folder.diagnostics.compactMap { d in
            guard d.path == path, let start = d.start else { return nil }
            let kind: EditorMark.Kind = switch d.category { case .error: .error; case .warning: .warning; case .info: .info }
            return EditorMark(range: NSRange(location: start, length: max(1, d.length ?? 1)), kind: kind)
        }
    }

    /// `url`'s path inside `folder`, or nil when it isn't inside it (a path boundary, so `/app`
    /// doesn't match `/app-old`).
    static func path(of url: URL, inside folder: URL) -> String? {
        let path = url.standardizedFileURL.path(percentEncoded: false)
        let base = folder.standardizedFileURL.path(percentEncoded: false)
        let prefix = base.hasSuffix("/") ? base : base + "/"
        return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : nil
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
                // Errors and warnings, as VS Code's status bar counts them.
                let parts = [problems.errors > 0 ? "\(problems.errors) \(problems.errors == 1 ? "error" : "errors")" : nil,
                             problems.warnings > 0 ? "\(problems.warnings) \(problems.warnings == 1 ? "warning" : "warnings")" : nil].compactMap { $0 }
                Label(parts.joined(separator: ", "), systemImage: problems.errors > 0 ? "xmark.octagon" : "exclamationmark.triangle")
                    .foregroundStyle(problems.errors > 0 ? palette.status.error.color : palette.status.warn.color)
            }
            .buttonStyle(.plain)
            .accessibilityHint("Lists the problems")
        } else if problems.isChecking {
            Text("Checking…")
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
        NavigationStack {
            List {
                ForEach(problems.failures, id: \.root) { failure in
                    Text(verbatim: "\(failure.root.lastPathComponent): type check failed: \(failure.message)")
                        .foregroundStyle(palette.status.error.color)
                }
                if problems.diagnostics.isEmpty && problems.failures.isEmpty {
                    Text(problems.isChecking ? "Checking…" : "No problems.").foregroundStyle(palette.text.secondary.color)
                }
                ForEach(rows, id: \.title) { row in
                    Section(row.title) {
                        ForEach(row.diagnostics) { d in
                            Button { open(d, in: row.root) } label: {
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Image(systemName: d.category == .error ? "xmark.octagon" : "exclamationmark.triangle")
                                        .foregroundStyle(d.category == .error ? palette.status.error.color : palette.status.warn.color)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(d.message).font(.footnote)
                                        if let line = d.line {
                                            Text(verbatim: "Line \(line), column \(d.column ?? 1)" + (d.rule.map { " · Ruff \($0)" } ?? (d.code > 0 ? " · TS\(d.code)" : " · shader")))
                                                .font(.system(.caption2, design: .monospaced))
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
                    Button("Check again") { problems.schedule(roots: model.workspace.allRoots, after: .zero) }
                        .disabled(problems.isChecking)
                }
            }
            .tint(palette.accent.ion.color)
            .toolbarBackground(palette.surface.pane.color, for: .navigationBar)
        }
    }

    /// One row per file, in workspace order. In a multi-root workspace the file is named by its folder
    /// (`notes/README.md`); the Stage's shader errors belong to the project's own folder.
    private var rows: [(title: String, root: URL, diagnostics: [TypeDiagnostic])] {
        var folders = model.workspace.problems.folders
        if !model.workspace.problems.stageDiagnostics.isEmpty, let root = model.workspace.rootURL {
            if let index = folders.firstIndex(where: { $0.root.standardizedFileURL.path == root.standardizedFileURL.path }) {
                folders[index].type += model.workspace.problems.stageDiagnostics
            } else {
                folders.append(.init(root: root, type: model.workspace.problems.stageDiagnostics))
            }
        }
        let multi = folders.count > 1
        return folders.flatMap { folder in
            Dictionary(grouping: folder.diagnostics, by: { $0.path ?? "Project" })
                .map { (title: multi ? "\(folder.root.lastPathComponent)/\($0.key)" : $0.key, root: folder.root, diagnostics: $0.value) }
        }
        .sorted { $0.title < $1.title }
    }

    private func open(_ d: TypeDiagnostic, in root: URL) {
        guard let path = d.path, let start = d.start else { return }
        model.workspace.open(file: root.appending(path: path), select: NSRange(location: start, length: d.length ?? 0))
        dismiss()
    }
}
