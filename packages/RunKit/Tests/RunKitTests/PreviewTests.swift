// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing
import WebKit
@testable import RunKit

@MainActor
struct PreviewTests {
    @Test func servesAPageWithTypeScriptAndCSS() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("preview-\(UUID().uuidString)")
        let files = [
            "index.html": "<!doctype html><link rel=stylesheet href=\"/style.css\"><h1 id=title>…</h1><script type=module src=\"/src/main.ts\"></script>",
            "style.css": "h1 { color: rgb(61, 214, 245); }",
            "src/main.ts": "import { title } from \"./title\";\nconst h: HTMLElement = document.getElementById(\"title\")!;\nh.textContent = title(\"Omnie\");\nconsole.log(\"rendered\", getComputedStyle(h).color);\n",
            "src/title.ts": "export const title = (name: string): string => `Hello ${name}`;\n",
        ]
        for (path, text) in files {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        #expect(Preview.entry(in: root) == "index.html")

        var logs: [String] = []
        let config = try Preview.configuration(root: root) { level, text in logs.append("\(level): \(text)") }
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 400, height: 300), configuration: config)
        webView.load(URLRequest(url: Preview.url(for: "index.html")))
        for _ in 0..<200 where logs.isEmpty { try await Task.sleep(for: .milliseconds(25)) }
        #expect(logs == ["log: rendered rgb(61, 214, 245)"])
        let text = try await webView.evaluateJavaScript("document.getElementById('title').textContent") as? String
        #expect(text == "Hello Omnie")
    }
}
