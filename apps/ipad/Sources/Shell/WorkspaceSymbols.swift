// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

import DesignKit
import Foundation
import LangKit
import SwiftUI
import WorkspaceKit

/// Every symbol in the project, gathered from each file's outline. `Outline.symbols` is
/// line-pattern based, so this is a regex pass per file, not a parse — cheap enough to run on
/// demand, off the main thread, with generous caps.
enum WorkspaceSearch {
    struct Symbol: Sendable, Hashable {
        let path: String
        let symbol: Outline.Symbol
    }

    static func symbols(in root: URL, limit: Int = 8_000) -> [Symbol] {
        var out: [Symbol] = []
        for path in ProjectSearch.files(in: root) {
            guard out.count < limit, let language = Language(fileExtension: (path as NSString).pathExtension) else { continue }
            let url = root.appending(path: path)
            guard let data = try? Data(contentsOf: url), data.count < 1_000_000, !data.prefix(4096).contains(0) else { continue }
            let text = String(decoding: data, as: UTF8.self)
            out += Outline.symbols(in: text, language: language).map { Symbol(path: path, symbol: $0) }
        }
        return out
    }
}

/// Go to symbol in workspace (⌘T): symbols from every file, best fuzzy match first.
struct WorkspaceSymbolSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.palette) private var palette
    @State private var query = ""
    @State private var symbols: [WorkspaceSearch.Symbol] = []
    @State private var loading = true
    @FocusState private var focused: Bool

    var body: some View {
        let results = ranked
        NavigationStack {
            List(results, id: \.self) { entry in
                Button { open(entry) } label: {
                    HStack(spacing: 8) {
                        Image(systemName: CommandPalette.symbolIcon(entry.symbol.kind))
                            .font(.caption).frame(width: 16).foregroundStyle(palette.accent.ion.color)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(entry.symbol.name).font(.subheadline)
                            Text("\(entry.path):\(entry.symbol.line)")
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(palette.text.secondary.color)
                        }
                        Spacer()
                    }
                }
                .buttonStyle(.plain)
            }
            .listStyle(.plain)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Symbol name")
            .searchFocused($focused)
            .onSubmit(of: .search) { if let first = results.first { open(first) } }
            .navigationTitle(loading ? "Indexing…" : "Go to symbol")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
        }
        .task {
            guard let root = model.workspace.rootURL else { loading = false; return }
            symbols = await Task.detached { WorkspaceSearch.symbols(in: root) }.value
            loading = false
            focused = true
        }
    }

    private var ranked: [WorkspaceSearch.Symbol] {
        guard !query.isEmpty else { return Array(symbols.prefix(400)) }
        var scored: [(entry: WorkspaceSearch.Symbol, score: Int)] = []
        for entry in symbols {
            if let score = FuzzyMatch.score(query, entry.symbol.name) { scored.append((entry, score)) }
        }
        scored.sort { a, b in
            if a.score != b.score { return a.score > b.score }
            return a.entry.symbol.name < b.entry.symbol.name
        }
        return scored.prefix(400).map(\.entry)
    }

    private func open(_ entry: WorkspaceSearch.Symbol) {
        guard let root = model.workspace.rootURL else { return }
        model.workspace.open(file: root.appending(path: entry.path),
                             select: NSRange(location: entry.symbol.offset, length: entry.symbol.length))
        dismiss()
    }
}
