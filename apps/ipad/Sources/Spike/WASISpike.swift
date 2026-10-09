// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

import SwiftUI
import UniformTypeIdentifiers
import WebKit

/// P0 spike 3 (PLAN §8, §25): WASI programs in a WKWebView (JavaScriptCore's JIT, out of process).
/// Runs the wasi-testsuite wasm32-wasip1 tests through browser_wasi_shim, each in its own module
/// Worker with a timeout. Inputs come from scripts/vendor-wasi-spike.py; results are saved in Documents.
struct WASISpikeView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var lines: [String] = ["Running…"]

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Host(onMessage: { message in
                    print("[wasi]", message)
                    if message.hasPrefix("{") {
                        let url = URL.documentsDirectory.appendingPathComponent("wasi-spike-\(Int(Date().timeIntervalSince1970)).json")
                        try? message.write(to: url, atomically: true, encoding: .utf8)
                        print("[wasi] saved \(url.lastPathComponent)")
                        if let data = message.data(using: .utf8),
                           let summary = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                            lines.append("Done: \(summary["passed"] ?? "?") of \(summary["total"] ?? "?") passed in \(summary["totalMs"] ?? "?") ms")
                        }
                    } else {
                        lines.append(message)
                    }
                })
                .frame(height: 1)
                ScrollView {
                    Text(lines.joined(separator: "\n"))
                        .font(.system(size: 12, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding()
                }
            }
            .navigationTitle("WASI spike (P0)")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Close") { dismiss() } } }
        }
    }

    private struct Host: UIViewRepresentable {
        let onMessage: (String) -> Void

        func makeCoordinator() -> Coordinator { Coordinator(onMessage: onMessage) }

        func makeUIView(context: Context) -> WKWebView {
            let config = WKWebViewConfiguration()
            config.userContentController.add(context.coordinator, name: "spike")
            config.setURLSchemeHandler(BundleSchemeHandler(), forURLScheme: BundleSchemeHandler.scheme)
            let view = WKWebView(frame: .zero, configuration: config)
            view.isInspectable = true
            view.load(URLRequest(url: URL(string: "\(BundleSchemeHandler.scheme)://spike/app/index.html")!))
            return view
        }

        func updateUIView(_ uiView: WKWebView, context: Context) {}

        final class Coordinator: NSObject, WKScriptMessageHandler {
            let onMessage: (String) -> Void
            init(onMessage: @escaping (String) -> Void) { self.onMessage = onMessage }
            func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
                onMessage(String(describing: message.body))
            }
        }
    }
}

/// Serves `app/…` from the committed WASISpikeApp folder and `vendor/…` from the vendored WASISpike
/// folder, with the right MIME types (application/wasm, text/javascript) and cross-origin isolation headers.
final class BundleSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "omnie-wasi"

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url else { return }
        var parts = url.path.split(separator: "/").map(String.init)
        let folder = parts.first == "vendor" ? "WASISpike" : "WASISpikeApp"
        if !parts.isEmpty { parts.removeFirst() }
        guard let base = Bundle.main.url(forResource: folder, withExtension: nil) else {
            task.didFailWithError(URLError(.fileDoesNotExist)); return
        }
        let file = parts.reduce(base) { $0.appendingPathComponent($1) }
        // Stay inside the bundle folder.
        guard file.standardizedFileURL.path.hasPrefix(base.standardizedFileURL.path),
              let data = try? Data(contentsOf: file) else {
            task.didReceive(HTTPURLResponse(url: url, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: nil)!)
            task.didFinish(); return
        }
        let mime: String = switch file.pathExtension {
        case "wasm": "application/wasm"
        case "js": "text/javascript"
        case "json": "application/json"
        case "html": "text/html"
        default: UTType(filenameExtension: file.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": mime, "Content-Length": String(data.count),
                                                      // Cross-origin isolation, so SharedArrayBuffer (WASI threads) is available.
                                                      "Cross-Origin-Opener-Policy": "same-origin",
                                                      "Cross-Origin-Embedder-Policy": "require-corp"])!
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}
}
