// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

import DesignKit
import SwiftUI
import WorkspaceKit

/// Quick open (⌘P): type part of a file's name, Return opens the best match.
struct QuickOpenSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.palette) private var palette
    @State private var query = ""
    @State private var files: [ProjectSearch.ProjectFile] = []
    @FocusState private var focused: Bool

    var body: some View {
        let results = query.isEmpty ? openOrder() : FuzzyMatch.rank(query, files, by: display)
        NavigationStack {
            List(results) { file in
                Button { open(file) } label: {
                    VStack(alignment: .leading, spacing: 1) {
                        Text((file.path as NSString).lastPathComponent).font(.subheadline)
                        Text(display(file)).font(.system(.caption2, design: .monospaced)).foregroundStyle(palette.text.secondary.color)
                    }
                }
                .buttonStyle(.plain)
            }
            .listStyle(.plain)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "File name")
            .searchFocused($focused)
            .onSubmit(of: .search) { if let first = results.first { open(first) } }
            .navigationTitle("Open file")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
        .task {
            let roots = model.workspace.allRoots
            if !roots.isEmpty { files = await Task.detached { ProjectSearch.files(in: roots) }.value }
            focused = true
            #if DEBUG
            let args = ProcessInfo.processInfo.arguments
            if let i = args.firstIndex(of: "-OmnieQuickOpen"), args.indices.contains(i + 1) { query = args[i + 1] }
            #endif
        }
    }

    /// With nothing typed: the files you had open recently first, then the rest of the workspace.
    private func openOrder() -> [ProjectSearch.ProjectFile] {
        let workspace = model.workspace
        guard let root = workspace.rootURL else { return Array(files.prefix(50)) }
        let recents = workspace.recentFiles.map { root.appending(path: $0).standardizedFileURL.path }
        func rank(_ file: ProjectSearch.ProjectFile) -> Int? {
            recents.firstIndex(of: file.root.appending(path: file.path).standardizedFileURL.path)
        }
        let recent = files.filter { rank($0) != nil }.sorted { (rank($0) ?? 0) < (rank($1) ?? 0) }
        return recent + Array(files.filter { rank($0) == nil }.prefix(50))
    }

    /// Files in the project's own folder read as before; a file in an added folder is named by it.
    private func display(_ file: ProjectSearch.ProjectFile) -> String {
        let roots = model.workspace.allRoots
        guard roots.count > 1, roots.first?.path != file.root.path else { return file.path }
        return "\(file.root.lastPathComponent)/\(file.path)"
    }

    private func open(_ file: ProjectSearch.ProjectFile) {
        model.workspace.open(file: file.root.appending(path: file.path))
        dismiss()
    }
}

/// Find in project (⇧⌘F): every match, grouped by file; tapping one opens it with the match selected.
struct FindInProjectSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.palette) private var palette
    @State private var query = ""
    @State private var caseSensitive = false
    @State private var hits: [ProjectSearch.RootedHit] = []
    @State private var searching = false
    @State private var replacement = ""
    @State private var showingReplace = false
    @State private var confirmingReplace = false
    @State private var status: String?
    @FocusState private var focused: Bool

    var body: some View {
        let roots = model.workspace.allRoots
        let groups = Dictionary(grouping: hits, by: { $0.displayPath(in: roots) })
        let paths = groups.keys.sorted()
        NavigationStack {
            List {
                if !query.isEmpty && !searching {
                    Text(hits.isEmpty ? "No matches." : "\(hits.count)\(hits.count >= 1_000 ? "+" : "") \(hits.count == 1 ? "match" : "matches") in \(paths.count) \(paths.count == 1 ? "file" : "files")")
                        .font(.caption).foregroundStyle(palette.text.secondary.color)
                }
                ForEach(paths, id: \.self) { path in
                    Section(path) {
                        ForEach(groups[path] ?? []) { hit in
                            Button { open(hit) } label: {
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Text("\(hit.hit.line)").font(.system(.caption2, design: .monospaced)).foregroundStyle(palette.text.tertiary.color)
                                        .frame(minWidth: 32, alignment: .trailing)
                                    Text(hit.hit.text.trimmingCharacters(in: .whitespaces)).font(.system(.caption, design: .monospaced)).lineLimit(2)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .listStyle(.plain)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Text to find")
            .searchFocused($focused)
            .onSubmit(of: .search) { Task { await search() } }
            .task(id: query + (caseSensitive ? "1" : "0")) {
                try? await Task.sleep(for: .milliseconds(250))
                await search()
            }
            .navigationTitle("Find in project")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Toggle(isOn: $caseSensitive) { Text("Aa") }.toggleStyle(.button).accessibilityLabel("Match case")
                }
                ToolbarItem(placement: .primaryAction) {
                    Button { showingReplace.toggle() } label: {
                        Image(systemName: showingReplace ? "rectangle.and.pencil.and.ellipsis" : "arrow.2.squarepath")
                    }
                    .accessibilityLabel("Replace")
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if showingReplace {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("Replace with", text: $replacement)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    HStack(spacing: 12) {
                        Button("Replace All") { confirmingReplace = true }
                            .buttonStyle(.borderedProminent)
                            .disabled(hits.isEmpty)
                        if let status {
                            Text(status).font(.footnote).foregroundStyle(palette.text.secondary.color)
                        }
                    }
                }
                .padding(12)
                .background(palette.surface.raised.color)
            }
        }
        .confirmationDialog("Replace \(hits.count)\(hits.count >= 1_000 ? "+" : "") \(hits.count == 1 ? "match" : "matches") in \(paths.count) \(paths.count == 1 ? "file" : "files")?",
                            isPresented: $confirmingReplace, titleVisibility: .visible) {
            Button("Replace All", role: .destructive) { Task { await replaceAll() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("A snapshot is taken first, so this can be undone.")
        }
        .onAppear {
            focused = true
            #if DEBUG
            let args = ProcessInfo.processInfo.arguments
            if let i = args.firstIndex(of: "-OmnieFind"), args.indices.contains(i + 1) { query = args[i + 1] }
            #endif
        }
    }

    private func search() async {
        let roots = model.workspace.allRoots
        guard !roots.isEmpty, !query.isEmpty else { hits = []; return }
        searching = true
        status = nil
        let q = query, cs = caseSensitive
        model.workspace.saveCurrent()
        hits = await Task.detached { ProjectSearch.search(q, in: roots, caseSensitive: cs) }.value
        searching = false
    }

    /// Snapshots first (so it can be undone), then replaces every match in the workspace.
    private func replaceAll() async {
        let roots = model.workspace.allRoots
        guard !roots.isEmpty, !query.isEmpty, !hits.isEmpty else { return }
        let q = query, r = replacement, cs = caseSensitive
        model.snapshots.take(reason: "Before replacing in project")
        model.workspace.saveCurrent()
        let result = await Task.detached { ProjectSearch.replace(q, with: r, in: roots, caseSensitive: cs) }.value
        model.workspace.reloadFromDisk()
        await search()
        status = "Replaced \(result.count) in \(result.files) \(result.files == 1 ? "file" : "files")"
            + (result.skipped.isEmpty ? "." : "; skipped \(result.skipped.count).")
    }

    private func open(_ hit: ProjectSearch.RootedHit) {
        model.workspace.open(file: hit.root.appending(path: hit.hit.path), select: hit.hit.range)
        dismiss()
    }
}

/// Go to line (⌘L).
struct GoToLineSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var line = ""
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            Form {
                TextField("Line number", text: $line)
                    .keyboardType(.numberPad)
                    .focused($focused)
                    .onSubmit(go)
            }
            .navigationTitle("Go to line")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Go", action: go).disabled(Int(line) == nil) }
            }
        }
        .presentationDetents([.height(180)])
        .onAppear { focused = true }
    }

    private func go() {
        guard let n = Int(line) else { return }
        model.workspace.goToLine(n)
        dismiss()
    }
}
