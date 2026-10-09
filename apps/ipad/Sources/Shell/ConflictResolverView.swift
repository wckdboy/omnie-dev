// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

import AgentKit
import SwiftUI
import DesignKit
import GitKit

/// Visual conflict resolver (PLAN.md §9.7): yours and theirs side by side over 1100 pt (stacked below),
/// an editable result, and one-tap Take mine / Take theirs / Take both per file.
struct ConflictResolverView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var palette
    @Environment(\.density) private var density
    @Environment(\.dismiss) private var dismiss
    let session: MergeSession
    @State private var results: [String: String] = [:]
    @State private var selected: String?
    @State private var narrowSide = 0
    /// Files whose result came from the model (by path → model name), until you edit them.
    @State private var proposedBy: [String: String] = [:]
    @State private var proposing: String?
    @State private var proposalNote: String?

    private var current: ConflictFile? {
        session.conflicts.first { $0.path == selected } ?? session.conflicts.first
    }

    private var unresolvedCount: Int {
        session.conflicts.filter { ConflictFile.hasMarkers(results[$0.path] ?? $0.merged) }.count
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if session.conflicts.count > 1 {
                    Picker("File", selection: Binding(get: { current?.path ?? "" }, set: { selected = $0 })) {
                        ForEach(session.conflicts) { file in
                            Text(file.path + (ConflictFile.hasMarkers(results[file.path] ?? file.merged) ? "" : " ✓")).tag(file.path)
                        }
                    }
                    .pickerStyle(.segmented)
                    .padding(12)
                }
                if let file = current {
                    editor(for: file)
                }
            }
            .background(palette.surface.editor.color)
            .navigationTitle(unresolvedCount == 0 ? "Ready to merge" : "\(unresolvedCount) \(unresolvedCount == 1 ? "conflict" : "conflicts")")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        model.workspace.git.mergeSession = nil
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Complete merge") {
                        Task {
                            let all = Dictionary(uniqueKeysWithValues: session.conflicts.map { ($0.path, results[$0.path] ?? $0.merged) })
                            let assisted = Set(proposedBy.values).sorted().joined(separator: ", ")
                            if await model.workspace.git.completeResolution(all, assistedBy: assisted.isEmpty ? nil : assisted) { dismiss() }
                        }
                    }
                    .disabled(unresolvedCount > 0)
                }
            }
        }
        .onAppear {
            for file in session.conflicts where results[file.path] == nil { results[file.path] = file.merged }
        }
    }

    @ViewBuilder
    private func editor(for file: ConflictFile) -> some View {
        GeometryReader { geo in
            let wide = geo.size.width > Metrics.fullBreakpoint
            VStack(spacing: 0) {
                if wide {
                    HStack(spacing: 0) {
                        side("Yours", file.ours, accent: palette.accent.ion.color)
                        Rectangle().fill(palette.surface.hairline.color).frame(width: Metrics.hairline)
                        side("Theirs", file.theirs, accent: palette.text.secondary.color)
                    }
                    .frame(height: geo.size.height * 0.4)
                } else {
                    Picker("Side", selection: $narrowSide) {
                        Text("Yours").tag(0)
                        Text("Theirs").tag(1)
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal, 12)
                    side(narrowSide == 0 ? "Yours" : "Theirs", narrowSide == 0 ? file.ours : file.theirs,
                         accent: narrowSide == 0 ? palette.accent.ion.color : palette.text.secondary.color)
                        .frame(height: geo.size.height * 0.35)
                }
                Rectangle().fill(palette.surface.hairline.color).frame(height: Metrics.hairline)
                HStack(spacing: 8) {
                    Text("Result").font(.caption.weight(.semibold)).foregroundStyle(palette.text.secondary.color)
                    if let by = proposedBy[file.path] {
                        Label("Proposed by \(by): review it", systemImage: "sparkles").font(.caption).foregroundStyle(palette.accent.agent.color)
                    }
                    if let note = proposalNote { Text(note).font(.caption).foregroundStyle(palette.status.warn.color) }
                    if ConflictFile.hasMarkers(results[file.path] ?? file.merged) {
                        Text("Has conflict markers").font(.caption).foregroundStyle(palette.status.error.color)
                    } else {
                        Text("Resolved").font(.caption).foregroundStyle(palette.status.ok.color)
                    }
                    Spacer()
                    // These act on the conflict blocks only; lines git merged cleanly are kept.
                    Button("Take mine") { results[file.path] = ConflictFile.resolving(file.merged, to: .ours); proposedBy[file.path] = nil }
                    Button("Take theirs") { results[file.path] = ConflictFile.resolving(file.merged, to: .theirs); proposedBy[file.path] = nil }
                    Button("Take both") { results[file.path] = ConflictFile.resolving(file.merged, to: .both); proposedBy[file.path] = nil }
                    Button("Reset") { results[file.path] = file.merged; proposedBy[file.path] = nil }
                    Button { Task { await propose(file) } } label: {
                        if proposing == file.path { ProgressView().controlSize(.small) } else { Label("Propose", systemImage: "sparkles") }
                    }
                    .disabled(proposing != nil || !ConflictFile.hasMarkers(file.merged))
                    .accessibilityHint("Asks the model to merge each conflict; you review the result")
                }
                .font(.footnote)
                .buttonStyle(.bordered)
                .padding(.horizontal, 12)
                .frame(height: max(density.hitTarget, 40))
                if file.isBinary {
                    Text("Binary file. Resolve it in the terminal for now.")
                        .font(.footnote)
                        .foregroundStyle(palette.text.secondary.color)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    TextEditor(text: Binding(get: { results[file.path] ?? file.merged }, set: { results[file.path] = $0 }))
                        .font(Typography.code(density))
                        .scrollContentBackground(.hidden)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .padding(.horizontal, 8)
                }
            }
        }
    }

    private func propose(_ file: ConflictFile) async {
        proposing = file.path
        proposalNote = nil
        defer { proposing = nil }
        let proposal = await model.proposeResolution(for: file)
        if let text = proposal.text, let by = proposal.by {
            results[file.path] = text
            proposedBy[file.path] = by
        }
        proposalNote = proposal.note
    }

    private func side(_ title: String, _ text: String?, accent: Color) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(accent)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            ScrollView {
                Text(text ?? "(deleted)")
                    .font(Typography.code(density))
                    .foregroundStyle(palette.text.primary.color)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
            }
        }
        .frame(maxWidth: .infinity)
        .background(palette.surface.pane.color)
    }
}

/// One-tap branch switching with no stash dialog (PLAN.md §9.6).
struct BranchSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var palette
    @Environment(\.dismiss) private var dismiss
    @State private var newName = ""

    var body: some View {
        let git = model.workspace.git
        NavigationStack {
            List {
                Section {
                    HStack {
                        TextField("New branch", text: $newName)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .onSubmit(create)
                        Button("Create", action: create)
                            .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                } footer: {
                    Text("Switching keeps your uncommitted changes with the branch you leave and brings them back when you return.")
                }
                Section("Branches") {
                    ForEach(git.branches) { branch in
                        Button {
                            Task {
                                await git.switchBranch(branch.name)
                                dismiss()
                            }
                        } label: {
                            HStack {
                                Image(systemName: branch.isCurrent ? "checkmark" : "arrow.triangle.branch")
                                    .frame(width: 20)
                                    .foregroundStyle(branch.isCurrent ? palette.accent.ion.color : palette.text.tertiary.color)
                                Text(branch.name)
                                    .font(branch.isAgentTask ? Typography.agent(.regular) : .subheadline)
                                    .foregroundStyle(branch.isAgentTask ? palette.accent.agent.color : palette.text.primary.color)
                                Spacer()
                                if branch.hasWorkInProgress {
                                    Text("Unsaved work kept").font(.caption).foregroundStyle(palette.text.secondary.color)
                                }
                                if let upstream = branch.upstream {
                                    Text(upstream).font(.caption).foregroundStyle(palette.text.tertiary.color)
                                }
                            }
                        }
                        .disabled(branch.isCurrent)
                    }
                }
            }
            .navigationTitle("Branches")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }

    private func create() {
        let name = newName.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: " ", with: "-")
        guard !name.isEmpty else { return }
        Task {
            await model.workspace.git.createBranch(name, switchTo: true)
            dismiss()
        }
    }
}

extension MergeSession: @retroactive Identifiable {
    public var id: String { ours.hex + theirs.hex }
}

extension AppModel {
    struct ResolutionProposal { var text: String?; var by: String?; var note: String? }

    /// Asks the model (the agent's router: local in plane mode, consent for online) to merge each
    /// conflict block of `file`. Nothing is written; the resolver shows it for review.
    func proposeResolution(for file: ConflictFile) async -> ResolutionProposal {
        guard let root = workspace.rootURL else { return ResolutionProposal(note: "No project open.") }
        guard let chosen = await agent.chooseModel(root: root, purpose: "Conflict proposals") else {
            return ResolutionProposal(note: agent.error ?? "No model available.")
        }
        let conflicts = ConflictFile.blocks(file.merged).map {
            MergeProposer.Conflict(ours: $0.ours, theirs: $0.theirs, before: $0.before, after: $0.after)
        }
        do {
            let resolutions = try await MergeProposer.propose(path: file.path, conflicts: conflicts, model: chosen.model)
            let left = resolutions.filter { $0 == nil }.count
            return ResolutionProposal(text: ConflictFile.replacingBlocks(file.merged, with: resolutions), by: chosen.name,
                                      note: left > 0 ? "\(left) of \(conflicts.count) left for you" : nil)
        } catch {
            return ResolutionProposal(note: "Couldn't propose: \(error.localizedDescription)")
        }
    }
}
