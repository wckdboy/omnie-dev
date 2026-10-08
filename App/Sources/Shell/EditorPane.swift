import SwiftUI
import DesignKit
import WorkspaceKit

/// Stand-in editor until the P0 spike picks the Runestone fork or TextKit 2 (PLAN.md §5).
/// It edits real files, but has no highlighting, gutter or multi-cursor yet.
struct EditorPane: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var palette
    @Environment(\.density) private var density
    @Binding var cursor: (line: Int, column: Int)?
    @State private var selection: TextSelection?

    var body: some View {
        @Bindable var workspace = model.workspace
        VStack(spacing: 0) {
            if let path = workspace.relativePath {
                HStack(spacing: 6) {
                    Text(path)
                        .font(.system(size: 12))
                        .foregroundStyle(palette.text.secondary.color)
                        .lineLimit(1)
                        .truncationMode(.head)
                    if workspace.isDirty {
                        Circle().fill(palette.text.secondary.color).frame(width: 6, height: 6)
                            .accessibilityLabel("Unsaved changes")
                    }
                    Spacer()
                }
                .padding(.horizontal, 12)
                .frame(height: density.tab)
                .background(palette.surface.pane.color)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(palette.surface.hairline.color).frame(height: Metrics.hairline)
                }
            }

            if let banner = workspace.banner {
                Banner(text: banner) { workspace.banner = nil }
            }

            if workspace.openFile != nil {
                TextEditor(text: $workspace.text, selection: $selection)
                    .font(Typography.code(density))
                    .foregroundStyle(palette.syntax.plain.color)
                    .scrollContentBackground(.hidden)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .keyboardType(.asciiCapable)
                    .padding(.leading, 8)
                    .onChange(of: selection) { updateCursor() }
                    .onChange(of: workspace.text) { updateCursor() }
            } else {
                Text(workspace.root == nil ? "Open a folder to start" : "Pick a file in the navigator")
                    .font(.system(size: 13))
                    .foregroundStyle(palette.text.tertiary.color)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(palette.surface.editor.color)
    }

    private func updateCursor() {
        let text = model.workspace.text
        guard case .selection(let range) = selection?.indices,
              range.lowerBound <= text.endIndex else {
            cursor = model.workspace.openFile == nil ? nil : (1, 1)
            return
        }
        cursor = TextPosition.lineColumn(in: text, at: range.lowerBound)
    }
}

/// Inline, one line, one action. No modal alerts for recoverable errors.
struct Banner: View {
    @Environment(\.palette) private var palette
    let text: String
    let dismiss: () -> Void

    var body: some View {
        HStack {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(palette.status.warn.color)
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(palette.text.primary.color)
            Spacer()
            Button("Dismiss", action: dismiss)
                .font(.system(size: 13))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(palette.surface.raised.color)
    }
}
