// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

import DesignKit
import RunKit
import SwiftUI
import WebKit

/// The Stage tab (PLAN.md §10): a model from the project (glTF/GLB, OBJ, STL) in the bundled
/// three.js, with orbit controls and a native performance HUD.
struct StagePanel: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var palette
    @State private var selected: String?
    @State private var stats: Stage.Stats?
    @State private var status: String?
    @State private var isError = false

    var body: some View {
        let root = model.workspace.rootURL
        let models = root.map { Stage.models(in: $0) } ?? []
        VStack(spacing: 0) {
            if let root, !models.isEmpty {
                let current = selected.flatMap { models.contains($0) ? $0 : nil } ?? models[0]
                HStack(spacing: 10) {
                    Menu {
                        ForEach(models, id: \.self) { path in Button(path) { selected = path; stats = nil; status = nil } }
                    } label: {
                        Label(current, systemImage: "cube").font(.system(size: 12, design: .monospaced)).lineLimit(1)
                    }
                    Spacer()
                }
                .font(.system(size: 13))
                .padding(.horizontal, 12).padding(.vertical, 8)
                Rectangle().fill(palette.surface.hairline.color).frame(height: Metrics.hairline)
                StageWebView(root: root, model: current) { event in
                    #if DEBUG
                    print("[stage] \(event)")
                    #endif
                    switch event {
                    case .loaded(let meshes, let animations):
                        status = "\(meshes) \(meshes == 1 ? "mesh" : "meshes")" + (animations > 0 ? ", \(animations) animation\(animations == 1 ? "" : "s")" : "")
                        isError = false
                    case .stats(let s): stats = s
                    case .error(let text): status = text; isError = true
                    }
                }
                .id(current)
                Rectangle().fill(palette.surface.hairline.color).frame(height: Metrics.hairline)
                hud
            } else {
                NotYet(title: "Stage", detail: root == nil
                       ? "Open a project to view its 3D models here."
                       : "No 3D models in this project (glTF, GLB, OBJ or STL). three.js scenes run in Preview.")
            }
        }
        .background(palette.surface.pane.color)
    }

    private var hud: some View {
        HStack(spacing: 12) {
            if let status {
                Text(status).foregroundStyle(isError ? palette.status.error.color : palette.text.secondary.color).lineLimit(2)
            }
            Spacer()
            if let stats {
                Text("\(stats.fps) fps").foregroundStyle(stats.fps < 50 ? palette.status.warn.color : palette.text.secondary.color)
                Text(String(format: "%.1f ms max", stats.worstFrameMs))
                Text("\(stats.triangles.formatted()) tris")
                Text("\(stats.drawCalls) calls")
                Text("\(stats.textures) tex · \(stats.programs) prog")
            }
        }
        .font(.system(size: 11, design: .monospaced))
        .foregroundStyle(palette.text.secondary.color)
        .padding(.horizontal, 12).padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }
}

private struct StageWebView: UIViewRepresentable {
    let root: URL
    let model: String
    let onEvent: @MainActor (Stage.Event) -> Void

    /// Loads once the view has a size, and reloads if WebKit's content process is killed (§10.3).
    final class Container: UIView, WKNavigationDelegate {
        let webView: WKWebView
        let url: URL
        let onEvent: @MainActor (Stage.Event) -> Void
        private var loaded = false

        init(webView: WKWebView, url: URL, onEvent: @escaping @MainActor (Stage.Event) -> Void) {
            self.webView = webView
            self.url = url
            self.onEvent = onEvent
            super.init(frame: .zero)
            addSubview(webView)
            webView.navigationDelegate = self
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func layoutSubviews() {
            super.layoutSubviews()
            webView.frame = bounds
            if !loaded, bounds.width > 0, bounds.height > 0 {
                loaded = true
                webView.load(URLRequest(url: url))
            }
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            onEvent(.error("Stage reloaded: the system stopped it, usually for memory."))
            webView.load(URLRequest(url: url))
        }
    }

    func makeUIView(context: Context) -> Container {
        let config = (try? Stage.configuration(root: root, onEvent: onEvent)) ?? WKWebViewConfiguration()
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.isInspectable = true
        return Container(webView: webView, url: Stage.url(for: model), onEvent: onEvent)
    }

    func updateUIView(_ container: Container, context: Context) {}
}
