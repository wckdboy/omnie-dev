import SwiftUI
import DesignKit

/// One line, grey unless something needs you. Left to right: git, diagnostics, agent, network, cursor.
struct StatusStrip: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var palette
    @Environment(\.density) private var density
    var cursor: (line: Int, column: Int)?

    var body: some View {
        HStack(spacing: 12) {
            // GitKit isn't built yet, so there is no branch to show.
            Label(model.workspace.rootURL == nil ? "No project" : model.workspace.rootURL!.lastPathComponent,
                  systemImage: "folder")
            if model.workspace.isDirty {
                Text("Unsaved")
            }
            Spacer()
            AgentPill(state: .idle)
            if model.isOffline {
                Label("Offline", systemImage: "airplane")
                    .accessibilityLabel("Offline")
            }
            if let cursor {
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

/// The agent's canonical states (PLAN.md §3.8). Only `thinking` animates.
enum AgentState: Equatable {
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
