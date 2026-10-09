// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

import SwiftUI
import DesignKit

/// One panel's content, wherever its tab lives (PaneLayout).
struct PanelContent: View {
    @Environment(AppModel.self) private var model
    let tab: UtilityTab

    var body: some View {
        switch tab {
        case .files:
            Navigator(onOpen: { _ in
                // Under 700 pt the left dock is an overlay: opening a file puts it away.
                if model.layout == .single { withAnimation(Motion.pane) { model.leftOverlay = false } }
            })
        case .agent: AgentPanel()
        case .editor2: SplitEditorPanel()
        case .timeline: TimelineView()
        case .terminal: TerminalPanel()
        case .preview: PreviewPanel()
        case .stage: StagePanel()
        case .tools: ToolsPanel()
        }
    }
}

struct NotYet: View {
    @Environment(\.palette) private var palette
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(palette.text.primary.color)
            Text(detail)
                .font(.footnote)
                .foregroundStyle(palette.text.secondary.color)
                .multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
