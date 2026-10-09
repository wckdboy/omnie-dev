// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

import AgentKit
import DesignKit
import GitKit
import SwiftUI

/// The agent pane: transcript, changeset review and composer. Shared by the iPad utility pane and
/// the iPhone Agent tab. Agent text is violet in the agent face (PLAN.md §3.1: two visible authors).
struct AgentPanel: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var palette
    @Environment(\.density) private var density
    @State private var prompt = ""

    var body: some View {
        let agent = model.agent
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        if agent.current == nil || agent.transcript.isEmpty {
                            intro
                        }
                        ForEach(Array(agent.transcript.enumerated()), id: \.offset) { _, entry in
                            TranscriptRow(entry: entry)
                        }
                        if agent.isRunning {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text("Working in its own branch. You can keep editing.")
                            }
                            .font(.caption)
                            .foregroundStyle(palette.text.secondary.color)
                        }
                        if let current = agent.current, current.phase == .review {
                            ChangesetReview(record: current)
                        }
                        if let error = agent.error {
                            Text(error)
                                .font(.footnote)
                                .foregroundStyle(palette.status.error.color)
                        }
                        Color.clear.frame(height: 1).id("end")
                    }
                    .padding(16)
                }
                .onChange(of: agent.transcript.count) { proxy.scrollTo("end", anchor: .bottom) }
            }

            Rectangle().fill(palette.surface.hairline.color).frame(height: Metrics.hairline)
            composer
        }
        .background(palette.surface.pane.color)
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Describe a change. The agent works on its own branch, and nothing lands until you review it.")
                .agentVoice(density)
                .foregroundStyle(palette.accent.agent.color)
            if !model.models.isInstalled(.standard) {
                Text("The agent runs on this device with Qwen2.5-Coder 7B. Download it in Settings › Models (4.3 GB).")
                    .font(.footnote)
                    .foregroundStyle(palette.text.secondary.color)
                Button { model.settingsOpen = true } label: {
                    Text("Open Settings").font(.footnote).frame(minHeight: 44).contentShape(Rectangle())
                }
            } else if model.workspace.git.repo == nil {
                Text("Open a git project to start a task.")
                    .font(.footnote)
                    .foregroundStyle(palette.text.secondary.color)
            }
        }
    }

    private var canSend: Bool {
        !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !model.agent.isRunning
            && model.workspace.git.repo != nil && model.models.isInstalled(.standard)
            && model.agent.current?.phase != .review
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField(model.agent.current?.phase == .review ? "Review the changes first" : "Ask the agent",
                      text: $prompt, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.subheadline)
                .lineLimit(1...6)
                .padding(10)
                .background(palette.surface.raised.color)
                .clipShape(RoundedRectangle(cornerRadius: Metrics.Radius.sm))
                .onSubmit(send)
            if model.agent.isRunning {
                Button(action: model.agent.stop) {
                    Image(systemName: "stop.fill")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(palette.status.error.color)
                        .frame(width: 36, height: 36)
                        .background(Circle().fill(palette.surface.raised.color))
                        .frame(width: density.hitTarget, height: density.hitTarget)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(".", modifiers: .command)
                .accessibilityLabel("Stop the agent")
            } else {
                Button(action: send) {
                    Image(systemName: "arrow.up")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(canSend ? palette.surface.editor.color : palette.text.tertiary.color)
                        .frame(width: 36, height: 36)
                        .background(Circle().fill(canSend ? palette.accent.agent.color : palette.surface.raised.color))
                        .frame(width: density.hitTarget, height: density.hitTarget)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
                .accessibilityLabel("Start task")
            }
        }
        .padding(12)
    }

    private func send() {
        guard canSend else { return }
        let goal = prompt
        prompt = ""
        Task { await model.agent.start(goal) }
    }
}

/// One journal entry as the transcript shows it.
private struct TranscriptRow: View {
    @Environment(\.palette) private var palette
    @Environment(\.density) private var density
    let entry: JournalEntry
    @State private var expanded = false

    var body: some View {
        switch entry.kind {
        case .goal:
            Text(entry.text)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(palette.text.primary.color)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(palette.surface.raised.color, in: RoundedRectangle(cornerRadius: Metrics.Radius.sm))
        case .assistant:
            let parsed = ToolCallParser.parse(entry.text)
            VStack(alignment: .leading, spacing: 4) {
                if !parsed.thought.isEmpty {
                    Text(parsed.thought)
                        .agentVoice(density)
                        .foregroundStyle(palette.accent.agent.color)
                }
                if let call = parsed.call {
                    Label(Self.describe(call), systemImage: Self.symbol(call.name))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(palette.text.secondary.color)
                }
            }
        case .toolResult where entry.tool == "finish":
            // The self-review before finishing (AgentKit asks once).
            Label("Checking its changes against your request", systemImage: "checklist")
                .font(.caption)
                .foregroundStyle(palette.text.secondary.color)
                .padding(.leading, 20)
        case .toolResult:
            do {
                DisclosureGroup(isExpanded: $expanded) {
                    Text(entry.text.prefix(4_000))
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(palette.text.secondary.color)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                } label: {
                    Text(entry.isError ? "Error: \(entry.text.prefix(100))" : (entry.text.split(separator: "\n").first.map(String.init) ?? "Done"))
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(entry.isError ? palette.status.warn.color : palette.text.tertiary.color)
                        .lineLimit(1)
                }
                .padding(.leading, 20)
            }
        case .note:
            Text(entry.text)
                .font(.caption)
                .foregroundStyle(palette.text.secondary.color)
        case .outcome:
            EmptyView()
        }
    }

    static func describe(_ call: ToolCall) -> String {
        let path = call.arguments["path"]?.string
        switch call.name {
        case "list": return "list \(path ?? ".")"
        case "read": return "read \(path ?? "")"
        case "grep": return "grep \"\(call.arguments["text"]?.string ?? "")\"" + (path.map { " in \($0)" } ?? "")
        case "patch": return "patch \(path ?? "")"
        case "create_file": return "create \(path ?? "")"
        case "append_to_file": return "append to \(path ?? "")"
        case "finish": return "finish"
        default: return call.name
        }
    }

    static func symbol(_ name: String) -> String {
        switch name {
        case "list": "list.bullet"
        case "read": "doc.text"
        case "grep": "magnifyingglass"
        case "patch": "pencil"
        case "create_file": "doc.badge.plus"
        case "append_to_file": "text.append"
        case "finish": "checkmark"
        default: "wrench"
        }
    }
}

/// The task's changeset against your branch: files, diffs, Accept (squash merge) or Reject.
struct ChangesetReview: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var palette
    let record: AgentModel.TaskRecord
    @State private var working = false

    var body: some View {
        let changes = model.agent.changes
        VStack(alignment: .leading, spacing: 10) {
            if let attention = record.attention {
                Label(attention, systemImage: "exclamationmark.circle")
                    .font(.footnote)
                    .foregroundStyle(palette.status.warn.color)
            }
            if let summary = record.summary {
                Text(summary)
                    .font(.subheadline)
                    .foregroundStyle(palette.text.primary.color)
            }
            if changes.isEmpty {
                Text("No file changes.")
                    .font(.footnote)
                    .foregroundStyle(palette.text.secondary.color)
            }
            ForEach(changes) { file in
                FileDiffRow(file: file)
            }
            HStack {
                Button(changes.isEmpty ? "Close" : "Reject") {
                    working = true
                    Task { await model.agent.reject(); working = false }
                }
                .buttonStyle(.bordered)
                Spacer()
                if !changes.isEmpty {
                    Button("Accept and commit") {
                        working = true
                        Task { await model.agent.accept(); working = false }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(palette.accent.agent.color)
                }
            }
            .disabled(working)
            Text("Accepting squash-merges \(record.branch) into your branch as one commit with an Assisted-by trailer. Rejecting keeps the branch.")
                .font(.caption2)
                .foregroundStyle(palette.text.tertiary.color)
        }
        .padding(12)
        .background(palette.surface.raised.color.opacity(0.5), in: RoundedRectangle(cornerRadius: Metrics.Radius.sm))
    }
}

private struct FileDiffRow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var palette
    let file: FileDiff
    @State private var expanded = true

    var body: some View {
        let agent = model.agent
        let hunks = file.hunks
        let rejectedHere = agent.rejected[file.path] ?? []
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(hunks) { hunk in
                    let isRejected = rejectedHere.contains(hunk.index)
                    VStack(alignment: .leading, spacing: 0) {
                        HStack {
                            Text(hunk.header.components(separatedBy: "@@").dropFirst().first.map { "@@\($0)@@" } ?? hunk.header)
                                .font(.system(.caption2, design: .monospaced)).foregroundStyle(palette.text.tertiary.color)
                            Spacer()
                            Button {
                                var set = rejectedHere
                                if isRejected { set.remove(hunk.index) } else { set.insert(hunk.index) }
                                agent.rejected[file.path] = set
                            } label: {
                                Label(isRejected ? "Rejected" : "Accepted", systemImage: isRejected ? "xmark.circle" : "checkmark.circle.fill")
                                    .font(.caption2)
                                    .foregroundStyle(isRejected ? palette.status.error.color : palette.accent.agent.color)
                            }
                            .buttonStyle(.plain)
                            .accessibilityHint(isRejected ? "Accept this hunk" : "Reject this hunk")
                        }
                        ForEach(Array(hunk.lines.prefix(200).enumerated()), id: \.offset) { _, line in
                            Text(line.isEmpty ? " " : line)
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(palette.text.primary.color)
                                .strikethrough(isRejected && line.hasPrefix("+"))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(background(for: line))
                        }
                    }
                    .opacity(isRejected ? 0.5 : 1)
                    .overlay(alignment: .leading) {
                        Rectangle().fill(isRejected ? Color.clear : palette.accent.agent.color).frame(width: 2).offset(x: -6)
                    }
                }
            }
        } label: {
            HStack {
                Text(file.path).font(.system(.footnote, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                Spacer()
                if !rejectedHere.isEmpty {
                    Text("\(hunks.count - rejectedHere.count)/\(hunks.count)").foregroundStyle(palette.text.secondary.color)
                }
                Text("+\(file.additions)").foregroundStyle(palette.status.ok.color)
                Text("−\(file.deletions)").foregroundStyle(palette.status.error.color)
            }
            .font(.caption)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(file.path), \(file.additions) added, \(file.deletions) removed")
        }
    }

    private func background(for line: String) -> Color {
        if line.hasPrefix("+") { return palette.diff.addedBg.color }
        if line.hasPrefix("-") { return palette.diff.removedBg.color }
        return .clear
    }
}
