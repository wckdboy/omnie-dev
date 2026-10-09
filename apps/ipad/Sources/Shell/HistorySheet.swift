// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

import DesignKit
import GitKit
import SwiftUI

/// Interactive rebase (PLAN.md §9.10): your unpushed commits, oldest first. Drag to reorder; each
/// one can be kept, reworded, squashed or fixed up into the one above, or dropped. The result is
/// previewed as you go and applied as one step that Undo reverses.
struct HistorySheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var palette
    @Environment(\.dismiss) private var dismiss
    @State private var base: ObjectID?
    @State private var originals: [ObjectID: CommitInfo] = [:]
    @State private var order: [ObjectID] = []
    @State private var steps: [Row] = []
    @State private var preview: Result<[CommitInfo], Error>?
    @State private var loaded = false
    @State private var applying = false
    @State private var rewording: ObjectID?
    @State private var draft = ""

    struct Row: Identifiable, Equatable {
        var id: ObjectID { commit }
        let commit: ObjectID
        var action: HistoryStep.Action
    }

    var body: some View {
        NavigationStack {
            Group {
                if !loaded {
                    ProgressView()
                } else if base == nil {
                    ContentUnavailableView("Nothing to edit", systemImage: "arrow.up.arrow.down",
                                           description: Text("There are no unpushed commits on this branch (merges can't be edited here)."))
                } else {
                    List {
                        Section {
                            ForEach($steps) { $row in
                                if let info = originals[row.commit] { rowView($row, info) }
                            }
                            .onMove { steps.move(fromOffsets: $0, toOffset: $1) }
                        } header: {
                            Text("Oldest first. Drag to reorder; the menu on each picks what happens to it.")
                        }
                        Section("Result") { previewView }
                    }
                    .environment(\.editMode, .constant(.active))
                }
            }
            .navigationTitle("Edit history")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") { Task { await apply() } }
                        .disabled(!canApply || applying)
                }
            }
            .task { await load() }
            .task(id: steps) { await updatePreview() }
            .alert("Reword", isPresented: Binding(get: { rewording != nil }, set: { if !$0 { rewording = nil } })) {
                TextField("Message", text: $draft, axis: .vertical)
                Button("Done") {
                    if let id = rewording, let i = steps.firstIndex(where: { $0.commit == id }) {
                        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                        steps[i].action = text.isEmpty || text == originals[id]?.message.trimmingCharacters(in: .whitespacesAndNewlines) ? .pick : .reword(text)
                    }
                    rewording = nil
                }
                Button("Cancel", role: .cancel) { rewording = nil }
            }
        }
    }

    private func rowView(_ row: Binding<Row>, _ info: CommitInfo) -> some View {
        let action = row.wrappedValue.action
        let dropped = action == .drop
        return HStack(spacing: 10) {
            Menu {
                Button { row.wrappedValue.action = .pick } label: { Label("Keep", systemImage: "checkmark") }
                Button {
                    draft = { if case .reword(let t) = action { t } else { info.message.trimmingCharacters(in: .whitespacesAndNewlines) } }()
                    rewording = info.id
                } label: { Label("Reword…", systemImage: "pencil") }
                Button { row.wrappedValue.action = .squash } label: { Label("Squash into the one above (keep both messages)", systemImage: "arrow.up.to.line") }
                Button { row.wrappedValue.action = .fixup } label: { Label("Fix up the one above (drop this message)", systemImage: "arrow.up.to.line.compact") }
                Button(role: .destructive) { row.wrappedValue.action = .drop } label: { Label("Drop", systemImage: "trash") }
            } label: {
                Text(Self.word(action))
                    .font(.caption.weight(.semibold))
                    .frame(minWidth: 64, minHeight: 32)
                    .background(palette.surface.raised.color, in: Capsule())
            }
            .accessibilityLabel("\(Self.word(action)), change")
            VStack(alignment: .leading, spacing: 2) {
                Text({ if case .reword(let t) = action { t.split(separator: "\n").first.map(String.init) ?? t } else { info.summary } }())
                    .strikethrough(dropped)
                    .foregroundStyle(dropped ? palette.text.tertiary.color : palette.text.primary.color)
                    .lineLimit(1)
                Text("\(info.id.short) · \(info.date.formatted(.relative(presentation: .named)))")
                    .font(.caption2.monospaced())
                    .foregroundStyle(palette.text.tertiary.color)
            }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var previewView: some View {
        switch preview {
        case .none: ProgressView()
        case .success(let commits) where commits.isEmpty:
            Label("Every commit is dropped: the branch goes back to \(base?.short ?? "the base").", systemImage: "exclamationmark.triangle")
                .foregroundStyle(palette.status.warn.color).font(.footnote)
        case .success(let commits):
            ForEach(commits) { c in
                Text(c.summary).font(.footnote).lineLimit(1)
            }
            Text(unchanged ? "No change." : "\(commits.count) commit\(commits.count == 1 ? "" : "s"). Undo puts the old history back.")
                .font(.caption).foregroundStyle(palette.text.secondary.color)
        case .failure(let error):
            Label((error as? LocalizedError)?.errorDescription ?? "\(error)", systemImage: "exclamationmark.triangle")
                .foregroundStyle(palette.status.warn.color).font(.footnote)
        }
    }

    static func word(_ action: HistoryStep.Action) -> String {
        switch action {
        case .pick: "Keep"
        case .reword: "Reword"
        case .squash: "Squash"
        case .fixup: "Fix up"
        case .drop: "Drop"
        }
    }

    private var unchanged: Bool {
        steps.map(\.commit) == order && steps.allSatisfy { $0.action == .pick }
    }

    private var canApply: Bool {
        guard case .success = preview else { return false }
        return !unchanged
    }

    private func load() async {
        if let history = await model.workspace.git.editableHistory() {
            base = history.base
            originals = Dictionary(uniqueKeysWithValues: history.commits.map { ($0.id, $0) })
            order = history.commits.map(\.id)
            steps = history.commits.map { Row(commit: $0.id, action: .pick) }
        }
        loaded = true
    }

    private func updatePreview() async {
        guard let base, !steps.isEmpty else { return }
        preview = await model.workspace.git.previewHistory(base: base, steps: steps.map { HistoryStep($0.commit, $0.action) })
    }

    private func apply() async {
        guard let base else { return }
        applying = true
        defer { applying = false }
        if await model.workspace.git.applyHistory(base: base, steps: steps.map { HistoryStep($0.commit, $0.action) }) {
            dismiss()
        } else if let error = model.workspace.git.error {
            preview = .failure(NSError(domain: "history", code: 1, userInfo: [NSLocalizedDescriptionKey: error]))
            model.workspace.git.error = nil
        }
    }
}
