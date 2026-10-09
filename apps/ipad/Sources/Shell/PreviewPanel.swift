// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

import DesignKit
import RunKit
import SwiftUI
import WebKit

/// The project's web page, live (PLAN.md §8 Preview): served from the project by RunKit with
/// TypeScript transpiled on the fly, reloaded when you save. No network; bare npm imports need the
/// offline package cache (later).
struct PreviewPanel: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var palette
    @State private var console: [(level: String, text: String)] = []
    @State private var showConsole = false
    @State private var reloadToken = 0

    var body: some View {
        let workspace = model.workspace
        VStack(spacing: 0) {
            if let root = workspace.rootURL, let entry = Preview.entry(in: root) {
                HStack(spacing: 12) {
                    Button { reloadToken += 1 } label: { Image(systemName: "arrow.clockwise") }
                        .accessibilityLabel("Reload")
                    Text(entry).font(.system(size: 12, design: .monospaced)).foregroundStyle(palette.text.secondary.color)
                    Spacer()
                    Button { showConsole.toggle() } label: {
                        Label("\(console.filter { $0.level == "error" }.count)", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(console.contains { $0.level == "error" } ? palette.status.error.color : palette.text.secondary.color)
                    }
                    .accessibilityLabel("Console, \(console.count) messages")
                }
                .font(.system(size: 13))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                Rectangle().fill(palette.surface.hairline.color).frame(height: Metrics.hairline)
                PreviewWebView(root: root, entry: entry, reloadToken: reloadToken + workspace.changeCount) { level, text in
                    console.append((level, text))
                    if console.count > 500 { console.removeFirst(console.count - 500) }
                } onReload: { console.removeAll() }
                if showConsole {
                    Rectangle().fill(palette.surface.hairline.color).frame(height: Metrics.hairline)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(console.enumerated()), id: \.offset) { _, line in
                                Text(line.text)
                                    .foregroundStyle(line.level == "error" ? palette.status.error.color
                                                     : line.level == "warn" ? palette.status.warn.color : palette.text.primary.color)
                            }
                        }
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                    }
                    .frame(maxHeight: 180)
                }
            } else {
                NotYet(title: "Preview", detail: workspace.rootURL == nil
                       ? "Open a project with an index.html to preview it here."
                       : "No index.html in this project (looked in the root, public/ and src/).")
            }
        }
        .background(palette.surface.pane.color)
    }
}

private struct PreviewWebView: UIViewRepresentable {
    let root: URL
    let entry: String
    let reloadToken: Int
    let onConsole: @MainActor (String, String) -> Void
    let onReload: () -> Void

    final class Coordinator {
        var token = 0
        var root: URL?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let config = (try? Preview.configuration(root: root, onConsole: onConsole)) ?? WKWebViewConfiguration()
        let view = WKWebView(frame: .zero, configuration: config)
        view.isInspectable = true
        view.load(URLRequest(url: Preview.url(for: entry)))
        context.coordinator.token = reloadToken
        context.coordinator.root = root
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        guard context.coordinator.token != reloadToken else { return }
        context.coordinator.token = reloadToken
        onReload()
        view.load(URLRequest(url: Preview.url(for: entry)))
    }
}
