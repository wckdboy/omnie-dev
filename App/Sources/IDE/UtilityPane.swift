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
                case .terminal: NotYet(title: "Terminal", detail: "Shell built-ins and WASI tools arrive with RunKit and TermKit in P3.")
                case .preview: NotYet(title: "Preview", detail: "Web previews arrive with RunKit in P3.")
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

/// The agent conversation and composer. AgentKit isn't built, so sending is disabled
/// and the panel says why. Shared by the iPad utility pane and the iPhone Agent tab.
struct AgentPanel: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var palette
    @Environment(\.density) private var density
    @State private var prompt = ""

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Describe a change. The agent proposes a changeset on its own branch, and nothing lands until you review it.")
                        .font(Typography.agent(density))
                        .foregroundStyle(palette.accent.agent.color)
                    Text("Agent not set up yet. Local models and API keys arrive in P2.")
                        .font(.system(size: 13))
                        .foregroundStyle(palette.text.secondary.color)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
            }

            Rectangle().fill(palette.surface.hairline.color).frame(height: Metrics.hairline)

            HStack(alignment: .bottom, spacing: 8) {
                TextField("Ask the agent", text: $prompt, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .lineLimit(1...6)
                    .padding(10)
                    .background(palette.surface.raised.color)
                    .clipShape(RoundedRectangle(cornerRadius: Metrics.Radius.sm))
                Button {
                } label: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(palette.text.tertiary.color)
                        .frame(width: 36, height: 36)
                        .background(Circle().fill(palette.surface.raised.color))
                        .frame(width: density.hitTarget, height: density.hitTarget)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(true)
                .accessibilityLabel("Send. Unavailable until the agent is set up.")
            }
            .padding(12)
        }
        .background(palette.surface.pane.color)
    }
}
