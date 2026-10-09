// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing
@testable import ToolsKit

struct DocsTests {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("docs-\(UUID().uuidString)")

    func store() -> DocsStore {
        let catalog = #"[{"name": "JavaScript", "slug": "javascript", "release": "", "db_size": 100, "mtime": 7, "attribution": "&copy; MDN, CC-BY-SA 2.5"}]"#
        let index = #"{"entries": [{"name": "Array.prototype.map()", "path": "global_objects/array/map", "type": "Array"}, {"name": "Map", "path": "global_objects/map", "type": "Global Objects"}, {"name": "Array.prototype.flatMap()", "path": "global_objects/array/flatmap", "type": "Array"}, {"name": "Array", "path": "global_objects/array", "type": "Global Objects"}]}"#
        let db = #"{"global_objects/array/map": "<h1>Array.prototype.map()</h1><p>The <code>map()</code> method creates a new array &amp; returns it.</p><pre>[1, 2].map((x) =&gt; x * 2)</pre>", "global_objects/map": "<h1>Map</h1>", "global_objects/array/flatmap": "<h1>flatMap</h1>", "global_objects/array": "<h1>Array</h1>", "../escape": "x"}"#
        let responses = [
            "https://devdocs.io/docs.json": catalog,
            "https://documents.devdocs.io/javascript/index.json?7": index,
            "https://documents.devdocs.io/javascript/db.json?7": db,
        ]
        return DocsStore(root: root) { url in
            guard let text = responses[url.absoluteString] else { throw URLError(.fileDoesNotExist) }
            return Data(text.utf8)
        }
    }

    @Test func installsSearchesAndReads() async throws {
        let docs = store()
        let catalog = try await docs.catalog()
        #expect(catalog.map(\.slug) == ["javascript"] && catalog[0].release == nil)
        #expect(docs.cachedCatalog().count == 1)
        try await docs.install(catalog[0])
        #expect(docs.installed().map(\.slug) == ["javascript"])
        #expect(!FileManager.default.fileExists(atPath: root.deletingLastPathComponent().appending(path: "escape.html").path))

        #expect(await docs.search("map").map(\.name).prefix(2) == ["Map", "Array.prototype.map()"])
        #expect(await docs.search("array map").first?.name == "Array.prototype.map()")
        #expect(await docs.search("zzz").isEmpty)
        #expect(docs.page("javascript", "global_objects/array/map#syntax")?.contains("<h1>") == true)

        let text = await docs.lookup("Array.prototype.map")
        #expect(text.hasPrefix("Array.prototype.map() — javascript"))
        #expect(text.contains("creates a new array & returns it.") && text.contains("[1, 2].map((x) => x * 2)"))
        try await docs.remove("javascript")
        #expect(docs.installed().isEmpty)
        #expect(await docs.lookup("map") == "No docs are installed (Settings › Docs).")
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["OMNIE_DOCS_REAL"] != nil))
    func realThreeJS() async throws {
        let target = ProcessInfo.processInfo.environment["OMNIE_DOCS_ROOT"].map { URL(filePath: $0) } ?? root
        let docs = DocsStore(root: target) { url in try await URLSession.shared.data(from: url).0 }
        let catalog = try await docs.catalog()
        let bundle = try #require(catalog.first { $0.slug == "threejs" })
        if let js = catalog.first(where: { $0.slug == "javascript" }), target != root {
            let start = Date()
            try await docs.install(js)
            print("installed \(js.title) in \(Date().timeIntervalSince(start)) s")
        }
        let start = Date()
        try await docs.install(bundle)
        print("installed \(bundle.title) in \(Date().timeIntervalSince(start)) s")
        let hits = await docs.search("vector3")
        print(hits.prefix(3).map(\.name))
        #expect(hits.first?.name.lowercased().contains("vector3") == true)
        print(await docs.lookup("Vector3").prefix(400))
    }
}
