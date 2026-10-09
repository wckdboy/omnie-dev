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
            ProjectButton()
            GitStatusLabel()
            if model.workspace.isDirty {
                Text("Unsaved")
            }
            SyncLabel()
            ProblemsLabel()
            Spacer()
            Button { model.showAgent() } label: {
                AgentPill(state: model.agent.pillState)
                    .id(model.agent.pillState)
            }
            .buttonStyle(.plain)
            .accessibilityHint("Shows the agent")
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
            if model.layout != .single || model.workspace.root != nil {
                LayoutToggles()
            }
        }
        .labelStyle(.titleAndIcon)
        .font(.caption2)
        .foregroundStyle(palette.text.secondary.color)
        .padding(.horizontal, 12)
        // At least the density's height; taller when Dynamic Type makes the text bigger.
        .frame(minHeight: density.statusStrip)
        .background(palette.surface.chrome.color)
        .overlay(alignment: .top) {
            Rectangle().fill(palette.surface.hairline.color).frame(height: Metrics.hairline)
        }
    }
}

/// The open project's name; a tap opens the switcher (new, open, recent, close), like the folder
/// name in VS Code's title bar.
struct ProjectButton: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Button { model.projectsOpen = true } label: {
            HStack(spacing: 3) {
                Label(model.workspace.rootURL?.lastPathComponent ?? "No project", systemImage: "folder")
                Image(systemName: "chevron.up.chevron.down").imageScale(.small)
            }
            .frame(minHeight: 24)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
        .accessibilityLabel("Project: \(model.workspace.rootURL?.lastPathComponent ?? "none")")
        .accessibilityHint("Switch, open, start or close a project")
        .accessibilityIdentifier("project-switcher")
    }
}

/// The docks at a glance, as VS Code's layout controls: each shows or hides its dock (an empty one
/// opens with its usual panel), filled while it shows.
struct LayoutToggles: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(spacing: 2) {
            ForEach([PaneLayout.Dock.left, .bottom, .right], id: \.self) { dock in
                let shown = isShown(dock)
                Button { model.toggle(dock) } label: {
                    Image(systemName: dock.hideSymbol)
                        .symbolVariant(shown ? .fill : .none)
                        .frame(width: 28, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(shown ? palette.accent.ion.color : palette.text.secondary.color)
                .hoverEffect(.highlight)
                .accessibilityLabel("Toggle \(dock.rawValue) dock")
                .accessibilityValue(shown ? "Shown" : "Hidden")
                .accessibilityIdentifier("layout-toggle-\(dock.rawValue)")
            }
        }
        .padding(.leading, 4)
    }

    private func isShown(_ dock: PaneLayout.Dock) -> Bool {
        if model.focusMode { return false }
        if model.layout == .single && dock == .left { return model.leftOverlay && !model.panes.left.isEmpty }
        return model.panes.isVisible(dock)
    }
}

/// Plain-language git state (PLAN.md §9.9). Color only when something needs you.
struct GitStatusLabel: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var palette

    var body: some View {
        let git = model.workspace.git
        // The project's name is ProjectButton's; this is its git state.
        if model.workspace.rootURL == nil {
            EmptyView()
        } else if git.isNotARepo {
            Text("not a git repo")
        } else if let status = git.status {
            Button {
                model.registry.run("git.branches")
            } label: {
                Label(status.plainLanguage, systemImage: status.head.isDetached ? "exclamationmark.triangle" : "arrow.triangle.branch")
                    .foregroundStyle(color(status))
            }
            .buttonStyle(.plain)
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
        // A comfortable target even when the pill is only a dot.
        .frame(minWidth: 44, minHeight: 24)
        .contentShape(Rectangle())
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
