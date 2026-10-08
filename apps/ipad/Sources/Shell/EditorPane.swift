// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

import SwiftUI
import DesignKit
import EditorKit
import WorkspaceKit

/// The code editor: the Runestone-derived Core Text engine (PLAN §5.1) with tree-sitter highlighting.
struct EditorPane: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var palette
    @Environment(\.density) private var density

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

            if let banner = workspace.banner ?? workspace.git.error {
                Banner(text: banner) {
                    workspace.banner = nil
                    workspace.git.error = nil
                }
            }

            if workspace.openFile != nil {
                CodeEditor(controller: workspace.editor)
            } else {
                Text(workspace.root == nil ? "Open a folder to start" : "Pick a file in the navigator")
                    .font(.system(size: 13))
                    .foregroundStyle(palette.text.tertiary.color)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(palette.surface.editor.color)
        .onChange(of: palette, initial: true) { workspace.applyEditorTheme(palette: palette, density: density) }
        .onChange(of: density) { workspace.applyEditorTheme(palette: palette, density: density) }
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
