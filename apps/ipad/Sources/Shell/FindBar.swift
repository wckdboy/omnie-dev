// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

import DesignKit
import EditorKit
import SwiftUI

/// Find & replace in the open file (VS Code's ⌘F): the query, the match list and where you are in
/// it. The editor draws the matches; this owns the state and the commands.
@MainActor
@Observable
final class FindModel {
    var isOpen = false
    var query = ""
    var replacement = ""
    var caseSensitive = false
    var showsReplace = false
    private(set) var matches: [NSRange] = []
    private(set) var index = 0
    private(set) var truncated = false

    @ObservationIgnored weak var workspace: WorkspaceModel?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?

    static let limit = 20_000

    var countLabel: String {
        if query.isEmpty { return "" }
        if matches.isEmpty { return truncated ? "> \(Self.limit)" : "No results" }
        return "\(index + 1) of \(matches.count)\(truncated ? "+" : "")"
    }

    /// ⌘F: opens, seeding the field with the selection when there is one.
    func open(seed: String?) {
        isOpen = true
        if let seed, !seed.isEmpty, !seed.contains("\n") { query = seed }
        refresh(startingAtCaret: true)
    }

    func close() {
        isOpen = false
        matches = []
        index = 0
        refreshTask?.cancel()
        workspace?.editor.clearSearchHighlights()
    }

    /// The query or the case toggle changed: recompute now, from the caret.
    func queryChanged() { refresh(startingAtCaret: true) }

    /// The file changed under us: recompute soon, not on every keystroke.
    func textChanged() {
        guard isOpen else { return }
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            self?.refresh(startingAtCaret: false)
        }
    }

    /// Another file opened: wait for its text to be in the view, then search it from the top.
    func fileChanged() {
        guard isOpen else { return }
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            guard let self else { return }
            for _ in 0..<100 where self.workspace?.editor.isLoading == true {
                try? await Task.sleep(for: .milliseconds(20))
            }
            guard !Task.isCancelled else { return }
            self.refresh(startingAtCaret: true)
        }
    }

    func next() { move(1) }
    func previous() { move(-1) }

    private func move(_ delta: Int) {
        guard !matches.isEmpty else { return }
        index = (index + delta + matches.count) % matches.count
        applyCurrent(scroll: true)
    }

    func replaceCurrent() {
        guard matches.indices.contains(index), let editor = workspace?.editor else { return }
        let at = matches[index].location
        guard editor.replace(matches[index], with: replacement) else { return }
        refresh(startingAtCaret: false, preferredLocation: at + (replacement as NSString).length)
    }

    func replaceAll() {
        guard let editor = workspace?.editor, !matches.isEmpty else { return }
        _ = editor.replaceAll(matches, with: replacement)
        refresh(startingAtCaret: false)
    }

    private func refresh(startingAtCaret: Bool, preferredLocation: Int? = nil) {
        guard let editor = workspace?.editor else { return }
        matches = editor.searchRanges(query, caseSensitive: caseSensitive)
        truncated = matches.count >= Self.limit
        guard !matches.isEmpty else {
            index = 0
            editor.clearSearchHighlights()
            return
        }
        if let preferredLocation, let at = matches.firstIndex(where: { $0.location >= preferredLocation }) {
            index = at
        } else if startingAtCaret || index >= matches.count {
            let caret = editor.selectedRange.location
            index = matches.firstIndex(where: { $0.location >= caret }) ?? 0
        }
        applyCurrent(scroll: startingAtCaret || preferredLocation != nil)
    }

    private func applyCurrent(scroll: Bool) {
        guard let editor = workspace?.editor, matches.indices.contains(index) else { return }
        editor.setSearchHighlights(matches, current: index)
        editor.selectedRange = matches[index]
        if scroll { editor.scrollRangeToVisible(matches[index]) }
    }
}

/// The find/replace bar above the editor.
struct FindBar: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var palette
    @FocusState private var focus: Field?

    private enum Field { case find, replace }

    var body: some View {
        let find = model.find
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").font(.caption).foregroundStyle(palette.text.secondary.color)
                field("Find", text: Binding(get: { find.query }, set: { find.query = $0; find.queryChanged() }), target: .find)
                    .onSubmit { find.next() }
                Text(find.countLabel).font(.caption).foregroundStyle(palette.text.tertiary.color)
                    .frame(minWidth: 56, alignment: .leading)
                iconButton("chevron.up", "Previous match") { find.previous() }
                iconButton("chevron.down", "Next match") { find.next() }
                Toggle("Aa", isOn: Binding(get: { find.caseSensitive }, set: { find.caseSensitive = $0; find.queryChanged() }))
                    .toggleStyle(.button).font(.caption)
                    .help("Match case")
                iconButton(find.showsReplace ? "chevron.down" : "chevron.right", "Show replace") { find.showsReplace.toggle() }
                iconButton("xmark", "Close find") { find.close() }
            }
            .padding(.horizontal, 10)
            .frame(height: 32)

            if find.showsReplace {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.2.squarepath").font(.caption).foregroundStyle(palette.text.secondary.color)
                    field("Replace", text: Binding(get: { find.replacement }, set: { find.replacement = $0 }), target: .replace)
                        .onSubmit { find.replaceCurrent() }
                    Button("Replace") { find.replaceCurrent() }
                        .buttonStyle(.plain).font(.footnote).foregroundStyle(palette.accent.ion.color)
                        .disabled(find.matches.isEmpty)
                    Button("Replace All") { find.replaceAll() }
                        .buttonStyle(.plain).font(.footnote).foregroundStyle(palette.accent.ion.color)
                        .disabled(find.matches.isEmpty)
                }
                .padding(.horizontal, 10)
                .frame(height: 32)
            }
        }
        .background(palette.surface.raised.color)
        .overlay(alignment: .bottom) { Rectangle().fill(palette.surface.hairline.color).frame(height: Metrics.hairline) }
        .onAppear { focus = .find }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Find and replace")
    }

    private func field(_ placeholder: String, text: Binding<String>, target: Field) -> some View {
        TextField(placeholder, text: text)
            .textFieldStyle(.plain)
            .font(.system(.callout, design: .monospaced))
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .focused($focus, equals: target)
            .accessibilityLabel(placeholder)
    }

    private func iconButton(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).font(.caption).frame(width: 22, height: 22) }
            .buttonStyle(.plain)
            .foregroundStyle(palette.text.secondary.color)
            .accessibilityLabel(label)
    }
}
