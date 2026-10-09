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
            // The open Markdown file, or else the project's page.
            let markdown = workspace.relativePath.flatMap { Preview.isMarkdown($0) ? $0 : nil }
            if let root = workspace.rootURL, let entry = markdown ?? Preview.entry(in: root) {
                let url = markdown.map(Preview.markdownURL(for:)) ?? Preview.url(for: entry)
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
                PreviewWebView(root: root, url: url, reloadToken: reloadToken + workspace.changeCount) { level, text in
                    #if DEBUG
                    print("[preview] \(level): \(text)")
                    #endif
                    console.append((level, text))
                    if console.count > 500 { console.removeFirst(console.count - 500) }
                } onReload: { console.removeAll() }
                .id(url)
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
                       ? "Open a project with an index.html, or a Markdown file, to preview it here."
                       : "No index.html in this project (looked in the root, public/ and src/). Open a Markdown file to preview it.")
            }
        }
        .background(palette.surface.pane.color)
    }
}

private struct PreviewWebView: UIViewRepresentable {
    let root: URL
    let url: URL
    let reloadToken: Int
    let onConsole: @MainActor (String, String) -> Void
    let onReload: () -> Void

    /// Holds the web view and loads the page only once it has a real size: pages often read
    /// innerWidth/innerHeight once at load (a three.js canvas, for one), and a zero-sized web view
    /// gives them the wrong numbers.
    final class Container: UIView {
        let webView: WKWebView
        var url: URL?
        var token = 0
        private var loaded = false

        init(webView: WKWebView) {
            self.webView = webView
            super.init(frame: .zero)
            addSubview(webView)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func layoutSubviews() {
            super.layoutSubviews()
            webView.frame = bounds
            if !loaded, bounds.width > 0, bounds.height > 0, let url {
                loaded = true
                webView.load(URLRequest(url: url))
            }
        }

        func reload() {
            guard let url, loaded else { return }
            webView.load(URLRequest(url: url))
        }
    }

    func makeUIView(context: Context) -> Container {
        let config = (try? Preview.configuration(root: root, onConsole: onConsole)) ?? WKWebViewConfiguration()
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.isInspectable = true
        let container = Container(webView: webView)
        container.url = url
        container.token = reloadToken
        return container
    }

    func updateUIView(_ container: Container, context: Context) {
        guard container.token != reloadToken else { return }
        container.token = reloadToken
        onReload()
        container.reload()
    }
}
