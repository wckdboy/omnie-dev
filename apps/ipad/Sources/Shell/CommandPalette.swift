// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

import SwiftUI
import CommandKit
import DesignKit
import LangKit
import WorkspaceKit

/// Top-center popover, 640 pt wide (PLAN.md §3.10). Prefixes: `>` commands (the default), `@`
/// symbols in the open file, `?` a task for the agent, `:` a line number.
struct CommandPalette: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var palette
    @Environment(\.density) private var density
    @State private var query = ""
    @State private var selection = 0
    @FocusState private var fieldFocused: Bool

    enum Row: Identifiable {
        case command(Command)
        case symbol(Outline.Symbol)
        case agent(String)
        case line(Int)

        var id: String {
            switch self {
            case .command(let c): "c:" + c.id.rawValue
            case .symbol(let s): "s:\(s.offset)"
            case .agent: "agent"
            case .line(let n): "l:\(n)"
            }
        }
    }

    private var results: [Row] {
        if query.hasPrefix("@") {
            let q = String(query.dropFirst()).trimmingCharacters(in: .whitespaces)
            guard let language = model.workspace.language else { return [] }
            let symbols = Outline.symbols(in: model.workspace.editor.text, language: language)
            let ranked = q.isEmpty ? symbols : symbols.compactMap { s in FuzzyMatch.score(q, s.name).map { (s, $0) } }
                .sorted { $0.1 > $1.1 }.map(\.0)
            return ranked.prefix(40).map(Row.symbol)
        }
        if query.hasPrefix("?") {
            let task = String(query.dropFirst()).trimmingCharacters(in: .whitespaces)
            return task.isEmpty ? [] : [.agent(task)]
        }
        if query.hasPrefix(":") {
            return Int(query.dropFirst().trimmingCharacters(in: .whitespaces)).map { [.line($0)] } ?? []
        }
        let q = query.hasPrefix(">") ? String(query.dropFirst()) : query
        return model.registry.search(q, surface: model.experience.surface).prefix(12).map(Row.command)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "command")
                    .foregroundStyle(palette.text.tertiary.color)
                TextField("Command, @symbol, ?task for the agent, :line", text: $query)
                    .textFieldStyle(.plain)
                    .font(.subheadline)
                    .foregroundStyle(palette.text.primary.color)
                    .focused($fieldFocused)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .onSubmit(runSelected)
                    .onKeyPress(.downArrow) { move(1); return .handled }
                    .onKeyPress(.upArrow) { move(-1); return .handled }
                    .onKeyPress(.escape) { close(); return .handled }
            }
            .padding(.horizontal, 12)
            .frame(height: max(density.hitTarget, 40))

            Rectangle().fill(palette.surface.hairline.color).frame(height: Metrics.hairline)

            if results.isEmpty {
                Text(emptyText)
                    .font(.footnote)
                    .foregroundStyle(palette.text.tertiary.color)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(results.enumerated()), id: \.element.id) { index, item in
                            row(item, selected: index == selection)
                                .onTapGesture { run(item) }
                        }
                    }
                }
                .frame(maxHeight: 12 * density.row)
            }
        }
        .frame(maxWidth: Metrics.paletteWidth)
        .background(.ultraThinMaterial)
        .background(palette.surface.raised.color.opacity(0.85))
        .clipShape(RoundedRectangle(cornerRadius: Metrics.Radius.md))
        .overlay(RoundedRectangle(cornerRadius: Metrics.Radius.md).stroke(palette.surface.hairline.color, lineWidth: Metrics.hairline))
        .shadow(color: .black.opacity(0.24), radius: 12, y: 4)
        .onAppear {
            fieldFocused = true
            if !model.paletteSeed.isEmpty { query = model.paletteSeed; model.paletteSeed = "" }
            #if DEBUG
            let args = ProcessInfo.processInfo.arguments
            if let i = args.firstIndex(of: "-OmniePalette"), args.indices.contains(i + 1) { query = args[i + 1] }
            #endif
        }
        .onChange(of: query) { selection = 0 }
    }

    private var emptyText: String {
        if query.hasPrefix("@") { return model.workspace.language == nil ? "Open a code file to see its symbols" : "No matching symbols" }
        if query.hasPrefix("?") { return "Describe a change for the agent, then press Return" }
        if query.hasPrefix(":") { return "Type a line number" }
        return "No matching commands"
    }

    @ViewBuilder
    private func row(_ item: Row, selected: Bool) -> some View {
        switch item {
        case .command(let command): commandRow(command, selected: selected)
        case .symbol(let symbol):
            simpleRow(selected: selected) {
                Image(systemName: Self.symbolIcon(symbol.kind)).font(.caption2).foregroundStyle(palette.text.tertiary.color).frame(width: 16)
                Text(String(repeating: "  ", count: min(symbol.indent / 2, 4)) + symbol.name)
                    .font(.system(.footnote, design: .monospaced)).foregroundStyle(palette.text.primary.color)
                Spacer()
                Text("line \(symbol.line)").font(.caption).foregroundStyle(palette.text.tertiary.color)
            }
        case .agent(let task):
            simpleRow(selected: selected) {
                Image(systemName: "text.bubble").foregroundStyle(palette.accent.agent.color)
                Text("Ask the agent: \(task)").font(.footnote).foregroundStyle(palette.accent.agent.color).lineLimit(1)
                Spacer()
                Text("↩").font(.system(.caption, design: .monospaced)).foregroundStyle(palette.text.secondary.color)
            }
        case .line(let n):
            simpleRow(selected: selected) {
                Image(systemName: "arrow.right.to.line").font(.caption2).foregroundStyle(palette.text.tertiary.color)
                Text("Go to line \(n)").font(.footnote).foregroundStyle(palette.text.primary.color)
                Spacer()
            }
        }
    }

    private func simpleRow<Content: View>(selected: Bool, @ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 8) { content() }
            .padding(.horizontal, 12)
            .frame(height: density.row)
            .background(selected ? palette.surface.selection.color : .clear)
            .contentShape(Rectangle())
    }

    static func symbolIcon(_ kind: Outline.Symbol.Kind) -> String {
        switch kind {
        case .function, .method: "function"
        case .class: "c.square"
        case .interface: "i.square"
        case .type: "t.square"
        case .enum: "e.square"
        case .variable: "v.square"
        case .selector: "number"
        case .element: "chevron.left.forwardslash.chevron.right"
        }
    }

    private func commandRow(_ command: Command, selected: Bool) -> some View {
        HStack {
            Text(command.title)
                .font(.footnote)
                .foregroundStyle(palette.text.primary.color)
            if command.tier != .auto {
                Image(systemName: command.tier == .askBiometric ? "faceid" : "hand.raised")
                    .font(.caption2)
                    .foregroundStyle(palette.text.tertiary.color)
                    .accessibilityLabel(command.tier == .askBiometric ? "Needs Face ID" : "Asks first")
            }
            Spacer()
            Text(command.menu)
                .font(.caption)
                .foregroundStyle(palette.text.tertiary.color)
            if let shortcut = command.shortcut {
                Text(shortcut.description)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(palette.text.secondary.color)
                    .frame(minWidth: 44, alignment: .trailing)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: density.row)
        .background(selected ? palette.surface.selection.color : .clear)
        .contentShape(Rectangle())
    }

    private func move(_ delta: Int) {
        guard !results.isEmpty else { return }
        selection = (selection + delta + results.count) % results.count
    }

    private func runSelected() {
        guard results.indices.contains(selection) else { return }
        run(results[selection])
    }

    private func run(_ item: Row) {
        close()
        // Let the palette dismiss before acting.
        Task { @MainActor in
            switch item {
            case .command(let command): model.registry.run(command.id)
            case .symbol(let symbol):
                if let file = model.workspace.openFile {
                    model.workspace.open(file: file, select: NSRange(location: symbol.offset, length: symbol.length))
                }
            case .agent(let task):
                model.showAgent()
                await model.agent.start(task)
            case .line(let n): model.workspace.goToLine(n)
            }
        }
    }

    private func close() {
        query = ""
        model.paletteOpen = false
    }
}
