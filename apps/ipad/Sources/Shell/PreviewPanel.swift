// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

import DesignKit
import RunKit
import SwiftUI
import WebKit

/// The project's web page, live (PLAN.md §8 Preview): served from the project by RunKit with
/// TypeScript transpiled on the fly, reloaded when you save. No network. DevTools-lite (§11.1)
/// below it: the console, every request the page made, and the DOM with an element inspector.
struct PreviewPanel: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var palette
    @State private var console: [(level: String, text: String)] = []
    @State private var network: [RunKit.Preview.NetworkEntry] = []
    @State private var drawer: Drawer?
    @State private var reloadToken = 0
    @State private var webViewRef = WebViewRef()
    @State private var dom: [(node: RunKit.Preview.DOMNode, depth: Int)] = []
    @State private var inspected: RunKit.Preview.ElementInfo?
    @State private var inspectedPath: [Int]?

    enum Drawer: String, CaseIterable { case console = "Console", network = "Network", elements = "Elements" }

    var body: some View {
        let workspace = model.workspace
        VStack(spacing: 0) {
            // The open Markdown file, or else the project's page.
            let markdown = workspace.relativePath.flatMap { RunKit.Preview.isMarkdown($0) ? $0 : nil }
            if let root = workspace.rootURL, let entry = markdown ?? RunKit.Preview.entry(in: root) {
                let url = markdown.map(RunKit.Preview.markdownURL(for:)) ?? RunKit.Preview.url(for: entry)
                let errors = console.filter { $0.level == "error" }.count + network.filter { $0.status == 0 || $0.status >= 400 }.count
                HStack(spacing: 12) {
                    Button { reloadToken += 1 } label: { Image(systemName: "arrow.clockwise") }
                        .accessibilityLabel("Reload")
                    Text(entry).font(.system(.caption, design: .monospaced)).foregroundStyle(palette.text.secondary.color)
                    Spacer()
                    if markdown != nil {
                        Button { exportPDF(for: entry) } label: { Label("PDF", systemImage: "doc.richtext") }
                            .accessibilityLabel("Export as PDF next to the file")
                    }
                    Button { drawer = drawer == nil ? .console : nil } label: {
                        Label("\(errors)", systemImage: drawer == nil ? "wrench.and.screwdriver" : "chevron.down")
                            .foregroundStyle(errors > 0 ? palette.status.error.color : palette.text.secondary.color)
                    }
                    .accessibilityLabel(drawer == nil ? "Show DevTools, \(errors) problems" : "Hide DevTools")
                }
                .font(.footnote)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                Rectangle().fill(palette.surface.hairline.color).frame(height: Metrics.hairline)
                PreviewWebView(root: root, url: url, reloadToken: reloadToken + workspace.changeCount, ref: webViewRef) { level, text in
                    if level == "network" {
                        if let entry = try? JSONDecoder().decode(RunKit.Preview.NetworkEntry.self, from: Data(text.utf8)) {
                            network.append(entry)
                            if network.count > 500 { network.removeFirst(network.count - 500) }
                        }
                        return
                    }
                    #if DEBUG
                    print("[preview] \(level): \(text)")
                    #endif
                    console.append((level, text))
                    if console.count > 500 { console.removeFirst(console.count - 500) }
                } onReload: {
                    console.removeAll(); network.removeAll(); dom = []; inspected = nil; inspectedPath = nil
                }
                .id(url)
                // A Markdown preview follows the caret: the block holding its line scrolls into view.
                .onChange(of: workspace.cursor?.line) { _, line in
                    guard markdown != nil, let line else { return }
                    webViewRef.webView?.evaluateJavaScript("window.__omnieScrollToLine?.(\(line))", completionHandler: nil)
                }
                if let current = drawer {
                    Rectangle().fill(palette.surface.hairline.color).frame(height: Metrics.hairline)
                    VStack(spacing: 0) {
                        Picker("DevTools", selection: Binding(get: { current }, set: { drawer = $0 })) {
                            ForEach(Drawer.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .padding(8)
                        switch current {
                        case .console: consoleList
                        case .network: networkList
                        case .elements: elementsList
                        }
                    }
                    .frame(height: 240)
                    .task(id: current) { if current == .elements { await loadDOM() } }
                }
            } else {
                NotYet(title: "Preview", detail: workspace.rootURL == nil
                       ? "Open a project with an index.html, or a Markdown file, to preview it here."
                       : "No index.html in this project (looked in the root, public/ and src/). Open a Markdown file to preview it.")
            }
        }
        .background(palette.surface.pane.color)
        #if DEBUG
        .task {
            // `-OmniePreviewDevTools Network|Elements` opens that drawer.
            let args = ProcessInfo.processInfo.arguments
            if args.contains("-OmnieExportPDF") {
                for _ in 0..<50 where model.workspace.relativePath == nil { try? await Task.sleep(for: .milliseconds(100)) }
                try? await Task.sleep(for: .seconds(3))
                if let path = model.workspace.relativePath, RunKit.Preview.isMarkdown(path) { exportPDF(for: path) }
            }
            if let i = args.firstIndex(of: "-OmniePreviewDevTools"), args.indices.contains(i + 1), let d = Drawer(rawValue: args[i + 1]) {
                try? await Task.sleep(for: .seconds(2))
                drawer = d
                if d == .elements {
                    try? await Task.sleep(for: .milliseconds(500))
                    if let row = dom.first(where: { $0.node.tag == "h1" || $0.node.tag == "main" || $0.node.tag == "canvas" }) { await inspect(row.node.path) }
                }
            }
        }
        #endif
    }

    private var consoleList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                if console.isEmpty { Text("Nothing logged.").foregroundStyle(palette.text.secondary.color) }
                ForEach(Array(console.enumerated()), id: \.offset) { _, line in
                    Text(line.text)
                        .foregroundStyle(line.level == "error" ? palette.status.error.color
                                         : line.level == "warn" ? palette.status.warn.color : palette.text.primary.color)
                }
            }
            .font(.system(.caption2, design: .monospaced))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
        }
    }

    private var networkList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 3) {
                if network.isEmpty { Text("No requests yet.").foregroundStyle(palette.text.secondary.color) }
                ForEach(Array(network.enumerated()), id: \.offset) { _, entry in
                    HStack(spacing: 8) {
                        Text(entry.status == 0 ? "—" : "\(entry.status)")
                            .foregroundStyle(entry.status == 0 || entry.status >= 400 ? palette.status.error.color : palette.status.ok.color)
                            .frame(width: 30, alignment: .leading)
                        Text(entry.method).frame(width: 40, alignment: .leading).foregroundStyle(palette.text.secondary.color)
                        Text(entry.url).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 4)
                        if entry.mock == true { Text("mock").foregroundStyle(palette.accent.ion.color) }
                        if let error = entry.error { Text(error).foregroundStyle(palette.status.error.color).lineLimit(1) }
                        Text(entry.kind).foregroundStyle(palette.text.secondary.color)
                        if let bytes = entry.bytes { Text(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)).foregroundStyle(palette.text.secondary.color) }
                        Text("\(entry.ms) ms").foregroundStyle(palette.text.secondary.color)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            .font(.system(.caption2, design: .monospaced))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
        }
    }

    private var elementsList: some View {
        HStack(alignment: .top, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    if dom.isEmpty { Text("Loading…").foregroundStyle(palette.text.secondary.color) }
                    ForEach(Array(dom.enumerated()), id: \.offset) { _, row in
                        Button { Task { await inspect(row.node.path) } } label: {
                            Text(row.node.summary)
                                .lineLimit(1)
                                .padding(.leading, CGFloat(row.depth) * 10)
                                .foregroundStyle(row.node.path == inspectedPath ? palette.accent.ion.color : palette.text.primary.color)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .font(.system(.caption2, design: .monospaced))
                .padding(8)
            }
            if let info = inspected {
                Rectangle().fill(palette.surface.hairline.color).frame(width: Metrics.hairline)
                ScrollView {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("<\(info.tag)>  \(info.width) × \(info.height)").fontWeight(.semibold)
                        Text("display \(info.display), position \(info.position)")
                        Text("font \(info.font)")
                        Text("color \(info.color)")
                        Text("background \(info.background)")
                        Text("margin \(info.margin)")
                        Text("padding \(info.padding)")
                        ForEach(info.attributes.keys.sorted(), id: \.self) { key in
                            Text("\(key)=\"\(info.attributes[key] ?? "")\"").foregroundStyle(palette.text.secondary.color)
                        }
                    }
                    .font(.system(.caption2, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(8)
                }
                .frame(maxWidth: 260)
            }
        }
        .onDisappear { webViewRef.webView?.evaluateJavaScript(RunKit.Preview.clearInspectScript, completionHandler: nil) }
    }

    /// Prints the rendered Markdown to an A4 PDF beside the file ("README.md" → "README.pdf").
    private func exportPDF(for path: String) {
        guard let webView = webViewRef.webView, let root = model.workspace.rootURL else { return }
        let renderer = UIPrintPageRenderer()
        renderer.addPrintFormatter(webView.viewPrintFormatter(), startingAtPageAt: 0)
        let page = CGRect(x: 0, y: 0, width: 595.2, height: 841.8)  // A4 in points
        renderer.setValue(page, forKey: "paperRect")
        renderer.setValue(page.insetBy(dx: 40, dy: 48), forKey: "printableRect")
        let data = NSMutableData()
        UIGraphicsBeginPDFContextToData(data, page, nil)
        for index in 0..<renderer.numberOfPages {
            UIGraphicsBeginPDFPage()
            renderer.drawPage(at: index, in: UIGraphicsGetPDFContextBounds())
        }
        UIGraphicsEndPDFContext()
        let target = root.appending(path: (path as NSString).deletingPathExtension + ".pdf")
        do {
            try (data as Data).write(to: target, options: .atomic)
            model.workspace.reload()
            model.workspace.banner = "Saved \(target.lastPathComponent): \(renderer.numberOfPages) \(renderer.numberOfPages == 1 ? "page" : "pages")."
        } catch {
            model.workspace.banner = "Couldn't save the PDF: \(error.localizedDescription)"
        }
    }

    private func loadDOM() async {
        guard let webView = webViewRef.webView,
              let json = try? await webView.evaluateJavaScript(RunKit.Preview.domScript) as? String,
              let tree = try? JSONDecoder().decode(RunKit.Preview.DOMNode.self, from: Data(json.utf8)) else { return }
        dom = tree.flattened()
    }

    private func inspect(_ path: [Int]) async {
        guard let webView = webViewRef.webView,
              let json = try? await webView.evaluateJavaScript(RunKit.Preview.inspectScript(path)) as? String,
              let info = try? JSONDecoder().decode(RunKit.Preview.ElementInfo.self, from: Data(json.utf8)) else { return }
        inspectedPath = path
        inspected = info
    }
}

/// The preview's web view, for DevTools to evaluate in.
@MainActor
final class WebViewRef {
    weak var webView: WKWebView?
}

private struct PreviewWebView: UIViewRepresentable {
    let root: URL
    let url: URL
    let reloadToken: Int
    let ref: WebViewRef
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
        let config = (try? RunKit.Preview.configuration(root: root, onConsole: onConsole)) ?? WKWebViewConfiguration()
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.isInspectable = true
        ref.webView = webView
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
