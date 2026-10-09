// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

import DesignKit
import SwiftUI
import ToolsKit

/// The snippet vault (PLAN.md §11.1): search, edit, insert at the caret, and pin for the agent.
struct SnippetsTool: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var palette
    @State private var query = ""
    @State private var list: [SnippetVault.Snippet] = []
    @State private var editing: SnippetVault.Snippet?
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("Search snippets", text: $query)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                Button { editing = .init(title: "New snippet", language: model.workspace.language?.rawValue ?? "", body: "") } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("New snippet")
            }
            .font(.footnote)
            if let error { Text(error).font(.caption).foregroundStyle(palette.status.error.color) }
            if let snippet = editing {
                editor(snippet)
            } else {
                if list.isEmpty {
                    Text(query.isEmpty ? "No snippets yet. Select code and use \"Save selection as snippet\", or tap +." : "Nothing matches.")
                        .font(.caption).foregroundStyle(palette.text.secondary.color)
                }
                List(list) { snippet in
                    Button { editing = snippet } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                if snippet.pinned { Image(systemName: "pin.fill").foregroundStyle(palette.accent.agent.color).font(.caption2) }
                                Text(snippet.title).font(.footnote)
                                Spacer()
                                Text(([snippet.language] + snippet.tags.filter { $0.lowercased() != snippet.language.lowercased() }).filter { !$0.isEmpty }.joined(separator: " · "))
                                    .font(.caption2).foregroundStyle(palette.text.secondary.color)
                            }
                            Text(snippet.body.split(separator: "\n").first.map(String.init) ?? "")
                                .font(.system(.caption2, design: .monospaced)).foregroundStyle(palette.text.secondary.color).lineLimit(1)
                        }
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(Color.clear)
                    .swipeActions {
                        Button("Insert") { insert(snippet) }.tint(palette.accent.ion.color)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
        .padding(12)
        .task(id: query) {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-OmnieSeedSnippets"), (try? model.snippets?.all().isEmpty) == true {
                try? model.snippets?.save(.init(title: "Fetch JSON with a timeout", language: "typescript",
                                                body: "const res = await fetch(url, { signal: AbortSignal.timeout(5000) });\nconst data = await res.json();",
                                                tags: ["web", "fetch"], pinned: true))
                try? model.snippets?.save(.init(title: "Python dataclass", language: "python", body: "@dataclass\nclass Point:\n    x: float\n    y: float", tags: ["python"]))
            }
            #endif
            reload()
        }
        .onChange(of: model.snippetRequest) { takeRequest() }
        .onAppear(perform: takeRequest)
    }

    private func editor(_ snippet: SnippetVault.Snippet) -> some View {
        let binding = Binding(get: { editing ?? snippet }, set: { editing = $0 })
        return VStack(alignment: .leading, spacing: 6) {
            TextField("Title", text: binding.title).font(.footnote.weight(.semibold))
            HStack {
                TextField("Language", text: binding.language).frame(width: 110)
                TextField("Tags, comma-separated", text: Binding(get: { binding.wrappedValue.tags.joined(separator: ", ") },
                                                                  set: { binding.wrappedValue.tags = $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } }))
                Toggle("Pin for the agent", isOn: binding.pinned).fixedSize()
            }
            .font(.caption)
            .textInputAutocapitalization(.never).autocorrectionDisabled()
            TextEditor(text: binding.body)
                .font(.system(.caption, design: .monospaced))
                .frame(minHeight: 140)
                .scrollContentBackground(.hidden)
                .background(palette.surface.raised.color, in: RoundedRectangle(cornerRadius: Metrics.Radius.sm))
                .autocorrectionDisabled().textInputAutocapitalization(.never)
            HStack {
                Button("Done") { save(); editing = nil }.buttonStyle(.borderedProminent)
                Button("Insert at caret") { save(); if let s = editing { insert(s) } }.buttonStyle(.bordered)
                    .disabled(model.workspace.openFile == nil)
                Spacer()
                if snippet.id != 0 {
                    Button("Delete", role: .destructive) {
                        try? model.snippets?.delete(snippet.id); editing = nil; reload()
                    }
                }
            }
            .font(.footnote)
            Text(binding.wrappedValue.pinned ? "Pinned: the agent gets this with every task." : "Unpinned: the agent can still find it with snippets_search.")
                .font(.caption2).foregroundStyle(palette.text.secondary.color)
        }
    }

    private func reload() {
        guard let vault = model.snippets else { error = "The snippet vault couldn't be opened."; return }
        do { list = try vault.search(query) } catch { self.error = error.localizedDescription }
    }

    private func save() {
        guard let vault = model.snippets, let snippet = editing else { return }
        do { editing = try vault.save(snippet); reload() } catch { self.error = error.localizedDescription }
    }

    private func insert(_ snippet: SnippetVault.Snippet) {
        let editor = model.workspace.editor
        guard model.workspace.openFile != nil else { return }
        editor.textView.replace(editor.selectedRange, withText: snippet.body)
    }

    /// "Save selection as snippet" in the palette.
    private func takeRequest() {
        guard let request = model.snippetRequest else { return }
        model.snippetRequest = nil
        editing = request
    }
}
