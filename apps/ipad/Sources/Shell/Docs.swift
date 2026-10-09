// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

import DesignKit
import SwiftUI
import ToolsKit
import WebKit

/// Offline docs (PLAN.md §11.1): DevDocs bundles you download once, searched and read with no
/// connection. ⇧⌘D opens them with the word at the caret.
@MainActor
@Observable
final class DocsModel {
    nonisolated static var root: URL { AppPaths.support.appendingPathComponent("docs", isDirectory: true) }

    @ObservationIgnored let store = DocsStore(root: DocsModel.root) { url in
        let (data, response) = try await URLSession.shared.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode ?? 200 < 400 else { throw URLError(.badServerResponse) }
        return data
    }
    private(set) var installed: [DocsBundle] = []
    private(set) var catalog: [DocsBundle] = []
    private(set) var progress: [String: Double] = [:]
    var error: String?
    @ObservationIgnored private let policy: PolicyModel

    init(policy: PolicyModel) {
        self.policy = policy
        refresh()
    }

    func refresh() {
        installed = store.installed()
        if catalog.isEmpty { catalog = store.cachedCatalog() }
    }

    func loadCatalog() async {
        guard !policy.planeMode else { return }
        do { catalog = try await store.catalog() } catch { self.error = "Couldn't load the docs list: \(error.localizedDescription)" }
    }

    func install(_ bundle: DocsBundle) async {
        guard await policy.authorize(.installPackage(name: "\(bundle.title) docs", fromNetwork: true)) else {
            error = "Downloading docs needs the network" + (policy.planeMode ? " (plane mode is on)." : ".")
            return
        }
        progress[bundle.slug] = 0
        defer { progress[bundle.slug] = nil }
        do {
            try await store.install(bundle) { value in Task { @MainActor in self.progress[bundle.slug] = value } }
        } catch {
            self.error = "\(bundle.title): \(error.localizedDescription)"
        }
        refresh()
    }

    func remove(_ bundle: DocsBundle) {
        Task {
            try? await store.remove(bundle.slug)
            refresh()
        }
    }
}

struct DocsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.palette) private var palette
    @State var query: String
    @State private var results: [DocsEntry] = []
    @State private var showAll = false
    @State private var path: [DocsEntry] = []
    @FocusState private var focused: Bool

    var body: some View {
        let docs = model.docs
        NavigationStack(path: $path) {
            List {
                if let error = docs.error {
                    Text(error).foregroundStyle(palette.status.error.color)
                }
                if !query.isEmpty {
                    if results.isEmpty {
                        Text(docs.installed.isEmpty ? "No docs installed yet." : "Nothing matches.").foregroundStyle(palette.text.secondary.color)
                    }
                    ForEach(results, id: \.self) { entry in
                        NavigationLink(value: entry) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(entry.name).font(.system(.subheadline, design: .monospaced))
                                Text("\(entry.type) · \(title(entry.slug))").font(.caption2).foregroundStyle(palette.text.secondary.color)
                            }
                        }
                    }
                } else {
                    Section("Installed") {
                        if docs.installed.isEmpty { Text("None yet. Download some below; they work offline after that.").foregroundStyle(palette.text.secondary.color) }
                        ForEach(docs.installed) { bundle in
                            HStack {
                                Text(bundle.title)
                                Spacer()
                                Text(size(bundle.size)).foregroundStyle(palette.text.secondary.color)
                            }
                            .swipeActions { Button("Remove", role: .destructive) { docs.remove(bundle) } }
                        }
                    }
                    Section(showAll ? "All bundles" : "Suggested") {
                        let installed = Set(docs.installed.map(\.slug))
                        let available = docs.catalog.filter { !installed.contains($0.slug) && (showAll || DocsStore.suggested.contains($0.slug)) }
                        if docs.catalog.isEmpty { Text(model.policy.planeMode ? "Plane mode is on: the list needs the network." : "Loading the list…").foregroundStyle(palette.text.secondary.color) }
                        ForEach(available) { bundle in
                            HStack {
                                Text(bundle.title)
                                Spacer()
                                if let p = docs.progress[bundle.slug] {
                                    ProgressView(value: p).frame(width: 80)
                                } else {
                                    Text(size(bundle.size)).foregroundStyle(palette.text.secondary.color)
                                    Button { Task { await docs.install(bundle) } } label: { Image(systemName: "arrow.down.circle") }
                                        .buttonStyle(.borderless)
                                        .accessibilityLabel("Download \(bundle.title)")
                                }
                            }
                        }
                        if !docs.catalog.isEmpty { Button(showAll ? "Show suggested" : "Show all \(docs.catalog.count)") { showAll.toggle() } }
                    }
                    Section {
                        Text("From DevDocs (devdocs.io). Each bundle keeps its own licence, shown with its pages.")
                            .font(.caption2).foregroundStyle(palette.text.secondary.color)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search docs")
            .searchFocused($focused)
            .navigationDestination(for: DocsEntry.self) { DocsPageView(entry: $0, attribution: bundle($0.slug)?.attribution ?? "") }
            .navigationTitle("Docs")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
        }
        .task(id: query) {
            let q = query
            results = await docs.store.search(q)
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-OmnieDocsOpenFirst"), path.isEmpty, let first = results.first { path = [first] }
            #endif
        }
        .task {
            docs.refresh()
            if docs.catalog.isEmpty || docs.installed.isEmpty { await docs.loadCatalog() }
            if query.isEmpty { focused = true }
        }
    }

    private func bundle(_ slug: String) -> DocsBundle? { model.docs.installed.first { $0.slug == slug } }
    private func title(_ slug: String) -> String { bundle(slug)?.title ?? slug }
    private func size(_ bytes: Int) -> String { ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file) }
}

/// One page, with links between pages working and links out opening in Safari.
struct DocsPageView: View {
    let entry: DocsEntry
    let attribution: String
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var palette

    var body: some View {
        DocsWebView(url: URL(string: "omnie-docs://\(entry.slug)/\(entry.path)")!, store: model.docs.store,
                    attribution: attribution, dark: palette == .dark)
            .navigationTitle(entry.name)
            .navigationBarTitleDisplayMode(.inline)
            .ignoresSafeArea(edges: .bottom)
    }
}

private struct DocsWebView: UIViewRepresentable {
    let url: URL
    let store: DocsStore
    let attribution: String
    let dark: Bool

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(DocsSchemeHandler(store: store, attribution: attribution, dark: dark), forURLScheme: "omnie-docs")
        config.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            guard let url = action.request.url else { return .cancel }
            if url.scheme == "omnie-docs" { return .allow }
            // Links out leave the app (and need a connection).
            if ["http", "https"].contains(url.scheme ?? ""), action.navigationType == .linkActivated {
                await UIApplication.shared.open(url)
            }
            return .cancel
        }
    }
}

/// Serves `omnie-docs://<slug>/<path>` from the store, wrapped in a readable stylesheet. Nothing
/// else loads: no network, no scripts.
final class DocsSchemeHandler: NSObject, WKURLSchemeHandler {
    let store: DocsStore
    let attribution: String
    let dark: Bool

    init(store: DocsStore, attribution: String, dark: Bool) {
        self.store = store
        self.attribution = attribution
        self.dark = dark
    }

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url, let slug = url.host() else { return }
        let path = String(url.path(percentEncoded: false).dropFirst())
        let body = store.page(slug, path) ?? "<h1>Not in this bundle</h1><p>\(path)</p>"
        let html = """
            <!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
            <meta http-equiv="Content-Security-Policy" content="default-src omnie-docs: data:; script-src 'none'; style-src 'unsafe-inline'">
            <style>\(Self.css(dark: dark))</style></head><body>\(body)<footer>\(attribution)</footer></body></html>
            """
        let data = Data(html.utf8)
        task.didReceive(HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                        headerFields: ["Content-Type": "text/html; charset=utf-8", "Content-Length": String(data.count)])!)
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}

    static func css(dark: Bool) -> String {
        let (bg, fg, muted, code, line, link) = dark
            ? ("#111317", "#e6e8eb", "#9aa1ab", "#1b1f25", "#2a2f37", "#5ad1e6")
            : ("#ffffff", "#16181c", "#5d6470", "#f3f4f6", "#e3e5e8", "#0b7d91")
        return """
            body { background: \(bg); color: \(fg); font: 15px/1.55 -apple-system, system-ui; margin: 0; padding: 16px 20px 40px; }
            a { color: \(link); text-decoration: none; }
            h1 { font-size: 24px; } h2 { font-size: 19px; margin-top: 28px; } h3 { font-size: 16px; }
            code, pre { font: 13px/1.45 ui-monospace, SFMono-Regular, Menlo, monospace; }
            code { background: \(code); padding: 1px 4px; border-radius: 4px; }
            pre { background: \(code); padding: 12px; border-radius: 8px; overflow-x: auto; }
            pre code { background: none; padding: 0; }
            table { border-collapse: collapse; display: block; overflow-x: auto; }
            th, td { border: 1px solid \(line); padding: 6px 8px; text-align: left; vertical-align: top; }
            blockquote, .note, .notice, ._note { border-left: 3px solid \(line); margin: 12px 0; padding: 4px 12px; color: \(muted); }
            img { max-width: 100%; }
            footer { margin-top: 40px; padding-top: 12px; border-top: 1px solid \(line); color: \(muted); font-size: 12px; }
            """
    }
}
