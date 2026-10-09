// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

import DesignKit
import GitKit
import SwiftUI

/// The Stage view (PLAN.md §9.10) inside the commit composer: each file's changes not staged and
/// staged, hunk by hunk. Swipe a hunk right to stage it (left to unstage), tap lines to select
/// them and press S, or stage a whole file.
struct StagingSections: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var palette
    /// Selected lines per file, in the not-staged diff.
    @State private var selected: [String: Set<Staging.LineRef>] = [:]

    /// Long diffs show this many lines per hunk; the hunk still stages whole.
    static let lineLimit = 200

    var body: some View {
        let git = model.workspace.git
        if git.staging.isEmpty {
            Section { Text("No changes.").foregroundStyle(palette.text.secondary.color) }
        }
        ForEach(git.staging) { file in
            Section {
                if let diff = file.unstaged { hunks(diff, file: file, staged: false) }
                if let diff = file.staged { hunks(diff, file: file, staged: true) }
            } header: {
                HStack {
                    Text(file.path).font(.system(.footnote, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    if file.unstaged != nil {
                        Button("Stage file") { Task { await git.stage(file.path) } }.font(.caption)
                    }
                    if file.staged != nil {
                        Button("Unstage file") { Task { await git.unstage(file.path) } }.font(.caption)
                    }
                }
                .textCase(nil)
            }
        }
        // Always in reach while lines are selected, however long the list.
        Color.clear.frame(height: 0)
            .listRowBackground(Color.clear)
            .toolbar {
                if selected.values.contains(where: { !$0.isEmpty }) {
                    ToolbarItem(placement: .bottomBar) {
                        Button {
                            stageSelected()
                        } label: {
                            Label("Stage selected lines (\(selected.values.reduce(0) { $0 + $1.count }))", systemImage: "plus.circle")
                                .labelStyle(.titleAndIcon)
                        }
                        .keyboardShortcut("s", modifiers: [])
                        .accessibilityIdentifier("Stage selected lines")
                    }
                }
            }
    }

    @ViewBuilder
    private func hunks(_ diff: FileDiff, file: StagingFile, staged: Bool) -> some View {
        let git = model.workspace.git
        ForEach(diff.hunks) { hunk in
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text(staged ? "Staged" : "Not staged")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(staged ? palette.status.ok.color : palette.text.tertiary.color)
                    Text(hunk.header.components(separatedBy: "@@").dropFirst().first.map { "lines \($0.trimmingCharacters(in: .whitespaces))" } ?? "")
                        .font(.caption2.monospaced())
                        .foregroundStyle(palette.text.tertiary.color)
                    Spacer()
                    Button(staged ? "Unstage" : "Stage") {
                        let refs = Set(hunk.lines.indices.filter { hunk.lines[$0].hasPrefix("+") || hunk.lines[$0].hasPrefix("-") }
                            .map { Staging.LineRef(hunk: hunk.index, line: $0) })
                        Task { staged ? await git.unstage(file.path, lines: refs) : await git.stage(file.path, lines: refs) }
                    }
                    .font(.caption)
                    .buttonStyle(.bordered)
                }
                .padding(.bottom, 4)
                ForEach(Array(hunk.lines.prefix(Self.lineLimit).enumerated()), id: \.offset) { i, line in
                    lineRow(line, ref: Staging.LineRef(hunk: hunk.index, line: i), file: file.path, selectable: !staged)
                }
                if hunk.lines.count > Self.lineLimit {
                    Text("… \(hunk.lines.count - Self.lineLimit) more lines").font(.caption2).foregroundStyle(palette.text.tertiary.color)
                }
            }
            .swipeActions(edge: .leading) {
                if !staged {
                    Button("Stage") {
                        let refs = Set(hunk.lines.indices.map { Staging.LineRef(hunk: hunk.index, line: $0) })
                        Task { await git.stage(file.path, lines: refs) }
                    }
                    .tint(palette.status.ok.color)
                }
            }
            .swipeActions(edge: .trailing) {
                if staged {
                    Button("Unstage") {
                        let refs = Set(hunk.lines.indices.map { Staging.LineRef(hunk: hunk.index, line: $0) })
                        Task { await git.unstage(file.path, lines: refs) }
                    }
                }
            }
        }
    }

    private func lineRow(_ line: String, ref: Staging.LineRef, file: String, selectable: Bool) -> some View {
        let kind = line.first
        let isChange = kind == "+" || kind == "-"
        let isSelected = selected[file]?.contains(ref) == true
        return HStack(spacing: 6) {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .font(.caption2)
                .foregroundStyle(palette.accent.ion.color)
                .opacity(selectable && isChange ? 1 : 0)
            Text(line.isEmpty ? " " : line)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(kind == "+" ? palette.status.ok.color : kind == "-" ? palette.status.error.color : palette.text.secondary.color)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 1)
        .background(isSelected ? palette.accent.ion.color.opacity(0.12) : .clear)
        .contentShape(Rectangle())
        .onTapGesture {
            guard selectable, isChange else { return }
            if isSelected { selected[file]?.remove(ref) } else { selected[file, default: []].insert(ref) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel((kind == "+" ? "Added: " : kind == "-" ? "Removed: " : "") + String(line.dropFirst()))
        .accessibilityAddTraits(selectable && isChange ? [.isButton] : [])
        .accessibilityValue(isSelected ? "selected" : "")
    }

    private func stageSelected() {
        let git = model.workspace.git
        let chosen = selected.filter { !$0.value.isEmpty }
        selected = [:]
        Task {
            for (file, refs) in chosen { await git.stage(file, lines: refs) }
        }
    }
}
