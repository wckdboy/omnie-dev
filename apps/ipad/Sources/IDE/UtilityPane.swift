// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

import SwiftUI
import DesignKit

/// Right-hand pane: agent, terminal, preview, Stage, tools. Each tab says plainly what isn't built yet.
struct UtilityPane: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var palette
    @Environment(\.density) private var density

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(UtilityTab.allCases) { tab in
                    Button {
                        model.utilityTab = tab
                    } label: {
                        Image(systemName: tab.symbol)
                            .frame(maxWidth: .infinity, minHeight: density.tab)
                            .foregroundStyle(model.utilityTab == tab ? palette.accent.ion.color : palette.text.secondary.color)
                            .overlay(alignment: .bottom) {
                                if model.utilityTab == tab {
                                    Rectangle().fill(palette.accent.ion.color).frame(height: Metrics.focusStroke)
                                }
                            }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(tab.rawValue)
                    .hoverEffect(.highlight)
                }
            }
            .background(palette.surface.pane.color)
            .overlay(alignment: .bottom) {
                Rectangle().fill(palette.surface.hairline.color).frame(height: Metrics.hairline)
            }

            Group {
                switch model.utilityTab {
                case .agent: AgentPanel()
                case .timeline: TimelineView()
                case .terminal: TerminalPanel()
                case .preview: PreviewPanel()
                case .stage: NotYet(title: "Stage", detail: "The three.js viewer and playground arrive in P3.")
                case .tools: NotYet(title: "Tools", detail: "HTTP client, SQLite browser, Patterns and the rest arrive in P3.")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(palette.surface.pane.color)
    }
}

struct NotYet: View {
    @Environment(\.palette) private var palette
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: 8) {
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(palette.text.primary.color)
            Text(detail)
                .font(.system(size: 13))
                .foregroundStyle(palette.text.secondary.color)
                .multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
