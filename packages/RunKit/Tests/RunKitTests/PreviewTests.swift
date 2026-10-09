// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing
import WebKit
@testable import RunKit

extension WebKitSuites {
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

    @Test func bareThreeImportsResolveOffline() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("three-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("src"), withIntermediateDirectories: true)
        try "<!doctype html><html><head><title>t</title></head><body><script type=module src=\"/src/main.ts\"></script></body></html>"
            .write(to: root.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
        try """
            import * as THREE from "three";
            import { OrbitControls } from "three/addons/controls/OrbitControls.js";
            const scene: THREE.Scene = new THREE.Scene();
            scene.add(new THREE.Mesh(new THREE.BoxGeometry(1, 1, 1), new THREE.MeshNormalMaterial()));
            console.log("three", THREE.REVISION, scene.children.length, typeof OrbitControls);
            """.write(to: root.appendingPathComponent("src/main.ts"), atomically: true, encoding: .utf8)
        var logs: [String] = []
        let config = try Preview.configuration(root: root) { level, text in logs.append("\(level): \(text)") }
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 400, height: 300), configuration: config)
        webView.load(URLRequest(url: Preview.url(for: "index.html")))
        for _ in 0..<400 where logs.isEmpty { try await Task.sleep(for: .milliseconds(25)) }
        #expect(logs == ["log: three 186 1 function"])
    }

    @Test func injectsTheImportMapOnlyWhenThePageHasNone() {
        #expect(PackageCache.inject(into: "<html><head></head></html>").contains("\"three\":"))
        let own = "<html><head><script type=\"importmap\">{\"imports\":{}}</script></head></html>"
        #expect(PackageCache.inject(into: own) == own)
    }
}
}

extension WebKitSuites {
@MainActor
struct MarkdownPreviewTests {
    @Test func rendersMarkdownWithMermaidAndEscapesHTML() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("md-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("docs"), withIntermediateDirectories: true)
        try """
            # Title

            Some *text* and a [link](other.md).

            <script>window.pwned = true</script>

            ```mermaid
            graph LR
              A --> B
            ```
            """.write(to: root.appendingPathComponent("docs/guide.md"), atomically: true, encoding: .utf8)
        var logs: [String] = []
        let config = try Preview.configuration(root: root) { level, text in logs.append("\(level): \(text)") }
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 600, height: 800), configuration: config)
        webView.load(URLRequest(url: Preview.markdownURL(for: "docs/guide.md")))
        for _ in 0..<400 where logs.isEmpty { try await Task.sleep(for: .milliseconds(25)) }
        #expect(logs == ["log: rendered docs/guide.md: 1 diagrams"])
        let h1 = try await webView.evaluateJavaScript("document.querySelector('h1').textContent") as? String
        #expect(h1 == "Title")
        let pwned = try await webView.evaluateJavaScript("String(window.pwned)") as? String
        #expect(pwned == "undefined")
        #expect(Preview.isMarkdown("README.md") && !Preview.isMarkdown("a.ts"))
    }
}
}

extension WebKitSuites {
@MainActor
struct MockRouteTests {
    @Test func previewsGetRecordedResponses() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mock-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try MockRoutes.record(MockRoute(method: "GET", path: "/api/users", status: 200, contentType: "application/json",
                                        body: "[{\"name\":\"Ada\"}]"), root: root)
        try MockRoutes.record(MockRoute(method: "GET", path: "/api/users/:id", status: 404, contentType: "application/json",
                                        body: "{\"error\":\"none\"}"), root: root)
        #expect(MockRoutes.match(method: "get", path: "/api/users/7", in: MockRoutes.load(root: root))?.status == 404)
        try """
            <!doctype html><script type=module>
            const users = await (await fetch("/api/users")).json();
            const one = await fetch("/api/users/9");
            console.log(users[0].name, one.status);
            </script>
            """.write(to: root.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
        var logs: [String] = []
        let config = try Preview.configuration(root: root) { level, text in logs.append("\(level): \(text)") }
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 300, height: 200), configuration: config)
        webView.load(URLRequest(url: Preview.url(for: "index.html")))
        for _ in 0..<200 where logs.isEmpty { try await Task.sleep(for: .milliseconds(25)) }
        #expect(logs == ["log: Ada 404"])
    }
}
}

