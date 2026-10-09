// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

import DesignKit
import GitKit
import SwiftUI
import WorkspaceKit

/// Switching projects while one is open, like VS Code's Open Recent (⌃R): the recent projects to
/// filter and open, and every way to start another (new, open, clone, the sample). Closing the
/// current one lives here too.
struct ProjectsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var palette
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    var body: some View {
        let workspace = model.workspace
        let current = workspace.rootURL?.lastPathComponent
        let recents = workspace.recentProjects.filter { ref in
            ref.name != current && (query.isEmpty || ref.name.localizedCaseInsensitiveContains(query))
        }
        NavigationStack {
            List {
                Section {
                    action("New project…", "plus.rectangle.on.folder", id: "projects-new") { model.newProjectOpen = true }
                    action("Open folder…", "folder", id: "projects-open") { workspace.isPickingFolder = true }
                    action("Clone repository…", "arrow.down.circle", id: "projects-clone") { model.cloneSheetOpen = true }
                    action("Try the sample project", "sparkles", id: "projects-sample") {
                        Task {
                            if let folder = try? await SampleProject.install() { workspace.open(folder: folder) }
                        }
                    }
                }
                if let current {
                    Section("Open now") {
                        HStack {
                            Label(current, systemImage: "folder.fill").foregroundStyle(palette.text.primary.color)
                            Spacer()
                            Button("Close folder") {
                                workspace.closeFolder()
                                dismiss()
                            }
                            .accessibilityIdentifier("projects-close")
                        }
                    }
                }
                Section(recents.isEmpty && query.isEmpty ? "" : "Recent") {
                    ForEach(recents) { ref in
                        Button {
                            workspace.open(recent: ref)
                            dismiss()
                        } label: {
                            HStack {
                                Label(ref.name, systemImage: "folder")
                                Spacer()
                                Text(ref.lastOpened, format: .relative(presentation: .named))
                                    .font(.caption).foregroundStyle(palette.text.tertiary.color)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(palette.text.primary.color)
                        .accessibilityIdentifier("recent-\(ref.name)")
                        .swipeActions {
                            Button("Remove", role: .destructive) { workspace.forget(ref) }
                        }
                        .contextMenu {
                            Button("Remove from Recent", systemImage: "minus.circle", role: .destructive) { workspace.forget(ref) }
                        }
                    }
                    if recents.isEmpty && !query.isEmpty {
                        Text("No recent project matches “\(query)”.").foregroundStyle(palette.text.secondary.color)
                    }
                }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Recent projects")
            .navigationTitle("Projects")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
            }
        }
    }

    /// Starting another project hands over to its own sheet or picker, so this one gets out of the way.
    private func action(_ title: String, _ symbol: String, id: String, perform: @escaping () -> Void) -> some View {
        Button {
            dismiss()
            Task {
                try? await Task.sleep(for: .milliseconds(350))
                perform()
            }
        } label: {
            Label(title, systemImage: symbol).contentShape(Rectangle())
        }
        .accessibilityIdentifier(id)
    }
}

/// What a new project starts with.
enum ProjectTemplate: String, CaseIterable, Identifiable {
    case empty, typescript, python, web

    var id: Self { self }

    var title: String {
        switch self {
        case .empty: "Empty"
        case .typescript: "TypeScript"
        case .python: "Python"
        case .web: "Web page"
        }
    }

    var detail: String {
        switch self {
        case .empty: "A README and nothing else."
        case .typescript: "A module with a Vitest test; npm test runs it on this iPad."
        case .python: "A module with pytest-style tests; run them from the terminal."
        case .web: "index.html, a stylesheet and a script, live in the preview."
        }
    }

    /// The file to open first.
    var main: String {
        switch self {
        case .empty: "README.md"
        case .typescript: "src/index.ts"
        case .python: "main.py"
        case .web: "index.html"
        }
    }

    func files(name: String) -> [String: String] {
        let readme = "# \(name)\n"
        switch self {
        case .empty:
            return ["README.md": readme]
        case .typescript:
            let package = """
                {
                  "name": "\(Self.packageName(name))",
                  "version": "0.1.0",
                  "type": "module",
                  "scripts": { "test": "vitest run" },
                  "devDependencies": { "typescript": "^5.9.0", "vitest": "^3.2.0" }
                }

                """
            return [
                "README.md": readme + "\nRun the tests with `npm test`.\n",
                "package.json": package,
                "tsconfig.json": "{\n  \"compilerOptions\": { \"target\": \"ES2022\", \"module\": \"ESNext\", \"moduleResolution\": \"Bundler\", \"strict\": true }\n}\n",
                ".gitignore": "node_modules/\ndist/\n",
                "src/index.ts": "export function greet(name: string): string {\n  return `Hello, ${name}!`;\n}\n",
                "tests/index.test.ts": "import { describe, it, expect } from \"vitest\";\nimport { greet } from \"../src/index\";\n\ndescribe(\"greet\", () => {\n  it(\"says hello\", () => {\n    expect(greet(\"iPad\")).toBe(\"Hello, iPad!\");\n  });\n});\n",
            ]
        case .python:
            return [
                "README.md": readme + "\nRun `python main.py`, or the tests with `pytest`.\n",
                ".gitignore": "__pycache__/\n.venv/\n",
                "main.py": "def greet(name: str) -> str:\n    return f\"Hello, {name}!\"\n\n\nif __name__ == \"__main__\":\n    print(greet(\"iPad\"))\n",
                "tests/test_main.py": "from main import greet\n\n\ndef test_greet():\n    assert greet(\"iPad\") == \"Hello, iPad!\"\n",
            ]
        case .web:
            return [
                "README.md": readme + "\nOpen the preview to see the page.\n",
                "index.html": "<!doctype html>\n<html lang=\"en\">\n<head>\n  <meta charset=\"utf-8\">\n  <meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n  <title>\(name)</title>\n  <link rel=\"stylesheet\" href=\"style.css\">\n</head>\n<body>\n  <h1>\(name)</h1>\n  <button id=\"count\">Clicked 0 times</button>\n  <script type=\"module\" src=\"main.js\"></script>\n</body>\n</html>\n",
                "style.css": "body { font-family: system-ui, sans-serif; margin: 3rem; }\nbutton { font-size: 1rem; padding: 0.5rem 1rem; }\n",
                "main.js": "const button = document.querySelector(\"#count\");\nlet clicks = 0;\nbutton.addEventListener(\"click\", () => {\n  clicks += 1;\n  button.textContent = `Clicked ${clicks} time${clicks === 1 ? \"\" : \"s\"}`;\n});\n",
            ]
        }
    }

    static func packageName(_ name: String) -> String {
        let slug = name.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }
        return String(slug).split(separator: "-").joined(separator: "-").ifEmpty("app")
    }

    /// Projects/<name> with the template's files, committed once when `git` is on (so the
    /// timeline and Undo work from the first edit).
    func create(name: String, git: Bool, author: Signature) async throws -> URL {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("/"), !trimmed.hasPrefix(".") else { throw ProjectError.badName }
        let folder = AppPaths.projects.appendingPathComponent(trimmed, isDirectory: true)
        guard !FileManager.default.fileExists(atPath: folder.path(percentEncoded: false)) else { throw ProjectError.exists(trimmed) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (path, text) in files(name: trimmed) {
            let url = folder.appending(path: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        if git {
            let repo = try Repository.create(at: folder)
            _ = try await repo.commitAll(message: "Start \(trimmed)\n", author: author)
        }
        return folder
    }
}

enum ProjectError: Error, LocalizedError, Equatable {
    case badName
    case exists(String)

    var errorDescription: String? {
        switch self {
        case .badName: "Give the project a name (no slashes, not starting with a dot)."
        case .exists(let name): "There's already a project called \(name). Pick another name, or open it from Projects."
        }
    }
}

private extension String {
    func ifEmpty(_ fallback: String) -> String { isEmpty ? fallback : self }
}

/// File › New Project: a name, a template, git or not; then it opens with its main file.
struct NewProjectSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var palette
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var template = ProjectTemplate.typescript
    @State private var git = true
    @State private var problem: String?
    @State private var creating = false
    @FocusState private var nameFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Project name", text: $name)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($nameFocused)
                        .submitLabel(.done)
                        .onSubmit { Task { await create() } }
                        .accessibilityIdentifier("new-project-name")
                } footer: {
                    Text("In Omnie Dev's Projects folder, which the Files app shows too.")
                }
                Section("Start with") {
                    ForEach(ProjectTemplate.allCases) { option in
                        Button {
                            template = option
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(option.title).foregroundStyle(palette.text.primary.color)
                                    Text(option.detail).font(.caption).foregroundStyle(palette.text.secondary.color)
                                }
                                Spacer()
                                if template == option { Image(systemName: "checkmark").foregroundStyle(palette.accent.ion.color) }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(template == option ? .isSelected : [])
                        .accessibilityIdentifier("template-\(option.rawValue)")
                    }
                }
                Section {
                    Toggle("Make it a git repository", isOn: $git)
                } footer: {
                    Text("Recommended: you get the timeline, Undo across saves, and the agent can work on its own branch.")
                }
                if let problem {
                    Section { Text(problem).foregroundStyle(palette.status.error.color) }
                }
            }
            .navigationTitle("New Project")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") { Task { await create() } }
                        .disabled(creating || name.trimmingCharacters(in: .whitespaces).isEmpty)
                        .accessibilityIdentifier("new-project-create")
                }
            }
            .onAppear { nameFocused = true }
        }
    }

    private func create() async {
        guard !creating else { return }
        creating = true
        defer { creating = false }
        let gitModel = model.workspace.git
        let author = Signature(name: gitModel.fallbackName.isEmpty ? "Omnie Dev" : gitModel.fallbackName,
                               email: gitModel.fallbackEmail.isEmpty ? "dev@omnie.invalid" : gitModel.fallbackEmail)
        do {
            let folder = try await template.create(name: name, git: git, author: author)
            model.workspace.open(folder: folder)
            model.workspace.open(file: folder.appending(path: template.main), preview: false)
            dismiss()
        } catch {
            problem = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}
