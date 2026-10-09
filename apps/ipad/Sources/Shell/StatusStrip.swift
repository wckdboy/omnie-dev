// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

import SwiftUI
import DesignKit
import GitKit
import LangKit

/// One line, grey unless something needs you. Left to right: git, diagnostics, agent, network, cursor.
struct StatusStrip: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var palette
    @Environment(\.density) private var density

    var body: some View {
        HStack(spacing: 12) {
            GitStatusLabel()
            if model.workspace.isDirty {
                Text("Unsaved")
            }
            SyncLabel()
            Spacer()
            AgentPill(state: model.agent.pillState)
                .id(model.agent.pillState)
            if model.policy.planeMode {
                Label("Plane mode", systemImage: "airplane")
                    .accessibilityLabel("Plane mode: network actions are blocked")
            } else if model.isOffline {
                Label("Offline", systemImage: "wifi.slash")
                    .accessibilityLabel("Offline")
            }
            if let language = model.workspace.language {
                Text(language.displayName)
            }
            if let cursor = model.workspace.cursor {
                Text("Ln \(cursor.line), Col \(cursor.column)")
                    .monospacedDigit()
            }
        }
        .labelStyle(.titleAndIcon)
        .font(.system(size: 11))
        .foregroundStyle(palette.text.secondary.color)
        .padding(.horizontal, 12)
        .frame(height: density.statusStrip)
        .background(palette.surface.chrome.color)
        .overlay(alignment: .top) {
            Rectangle().fill(palette.surface.hairline.color).frame(height: Metrics.hairline)
        }
    }
}

/// Plain-language git state (PLAN.md §9.9). Color only when something needs you.
struct GitStatusLabel: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var palette

    var body: some View {
        let git = model.workspace.git
        if model.workspace.rootURL == nil {
            Label("No project", systemImage: "folder")
        } else if git.isNotARepo {
            Label("\(model.workspace.rootURL!.lastPathComponent) · not a git repo", systemImage: "folder")
        } else if let status = git.status {
            Button {
                model.registry.run("git.branches")
            } label: {
                Label(status.plainLanguage, systemImage: status.head.isDetached ? "exclamationmark.triangle" : "arrow.triangle.branch")
                    .foregroundStyle(color(status))
            }
            .buttonStyle(.plain)
        } else {
            Label(model.workspace.rootURL!.lastPathComponent, systemImage: "folder")
        }
    }

    private func color(_ status: RepoStatus) -> Color {
        if status.conflictCount > 0 { return palette.status.error.color }
        if status.head.isDetached { return palette.status.warn.color }
        return palette.text.secondary.color
    }
}

/// Sync progress and result: "Syncing" in Ion, "Queued, sends when online" in grey.
struct SyncLabel: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var palette

    var body: some View {
        let git = model.workspace.git
        if git.isSyncing {
            Label("Syncing", systemImage: "arrow.triangle.2.circlepath")
                .foregroundStyle(palette.accent.ion.color)
        } else if !git.queuedPushes.isEmpty {
            Label("Queued, sends when online", systemImage: "clock")
        } else if let message = git.syncMessage {
            Text(message)
        }
    }
}

/// The agent's canonical states (PLAN.md §3.8). Only `thinking` animates.
enum AgentState: Hashable {
    case idle, thinking, editing(files: Int), needsReview(changes: Int), blocked, offline, queued, failed(String)
}

struct AgentPill: View {
    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let state: AgentState
    @State private var breathe = false

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
                .opacity(state == .thinking && breathe ? 0.35 : 1)
            if let label {
                Text(label).foregroundStyle(color)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Agent: \(label ?? "idle")")
        .onAppear {
            guard state == .thinking, !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) { breathe = true }
        }
    }

    private var color: Color {
        switch state {
        case .idle: palette.text.tertiary.color
        case .thinking, .editing, .needsReview: palette.accent.agent.color
        case .blocked: palette.status.warn.color
        case .offline, .queued: palette.text.secondary.color
        case .failed: palette.status.error.color
        }
    }

    private var label: String? {
        switch state {
        case .idle, .thinking: nil
        case .editing(let n): "Editing \(n) \(n == 1 ? "file" : "files")"
        case .needsReview(let n): "\(n) \(n == 1 ? "change" : "changes") to review"
        case .blocked: "Needs your input"
        case .offline: "Offline, local model"
        case .queued: "Queued, sends when online"
        case .failed(let reason): "Agent stopped: \(reason)"
        }
    }
}
