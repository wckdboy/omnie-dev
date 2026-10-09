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
    @State private var files: [String] = []
    @FocusState private var focused: Bool

    var body: some View {
        let results = query.isEmpty
            ? model.workspace.recentFiles.filter(files.contains) + files.filter { !model.workspace.recentFiles.contains($0) }.prefix(50)
            : FuzzyMatch.rank(query, files)
        NavigationStack {
            List(results, id: \.self) { path in
                Button { open(path) } label: {
                    VStack(alignment: .leading, spacing: 1) {
                        Text((path as NSString).lastPathComponent).font(.system(size: 14))
                        Text(path).font(.system(size: 11, design: .monospaced)).foregroundStyle(palette.text.secondary.color)
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
            if let root = model.workspace.rootURL { files = await Task.detached { ProjectSearch.files(in: root) }.value }
            focused = true
            #if DEBUG
            let args = ProcessInfo.processInfo.arguments
            if let i = args.firstIndex(of: "-OmnieQuickOpen"), args.indices.contains(i + 1) { query = args[i + 1] }
            #endif
        }
    }

    private func open(_ path: String) {
        guard let root = model.workspace.rootURL else { return }
        model.workspace.open(file: root.appending(path: path))
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
    @State private var hits: [ProjectSearch.Hit] = []
    @State private var searching = false
    @FocusState private var focused: Bool

    var body: some View {
        let groups = Dictionary(grouping: hits, by: \.path)
        let paths = groups.keys.sorted()
        NavigationStack {
            List {
                if !query.isEmpty && !searching {
                    Text(hits.isEmpty ? "No matches." : "\(hits.count)\(hits.count >= 1_000 ? "+" : "") \(hits.count == 1 ? "match" : "matches") in \(paths.count) \(paths.count == 1 ? "file" : "files")")
                        .font(.system(size: 12)).foregroundStyle(palette.text.secondary.color)
                }
                ForEach(paths, id: \.self) { path in
                    Section(path) {
                        ForEach(groups[path] ?? []) { hit in
                            Button { open(hit) } label: {
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Text("\(hit.line)").font(.system(size: 11, design: .monospaced)).foregroundStyle(palette.text.tertiary.color)
                                        .frame(minWidth: 32, alignment: .trailing)
                                    Text(hit.text.trimmingCharacters(in: .whitespaces)).font(.system(size: 12, design: .monospaced)).lineLimit(2)
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
            }
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
        guard let root = model.workspace.rootURL, !query.isEmpty else { hits = []; return }
        searching = true
        let q = query, cs = caseSensitive
        model.workspace.saveCurrent()
        hits = await Task.detached { ProjectSearch.search(q, in: root, caseSensitive: cs) }.value
        searching = false
    }

    private func open(_ hit: ProjectSearch.Hit) {
        guard let root = model.workspace.rootURL else { return }
        model.workspace.open(file: root.appending(path: hit.path), select: hit.range)
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
