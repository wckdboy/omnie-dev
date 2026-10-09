// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing
@testable import ToolsKit

struct SnippetVaultTests {
    @Test func savesSearchesPinsAndDeletes() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("vault-\(UUID().uuidString)/snippets.sqlite")
        let vault = try SnippetVault(url: url)
        var fetch = try vault.save(.init(title: "Fetch JSON with a timeout", language: "ts",
                                         body: "const r = await fetch(url, { signal: AbortSignal.timeout(5000) });", tags: ["web", "fetch"]))
        try vault.save(.init(title: "Python dataclass", language: "py", body: "@dataclass\nclass Point:\n    x: float", tags: ["python"]))
        // Quotes and SQL in the text are just text.
        try vault.save(.init(title: "It's '; DROP TABLE snippets; --", body: "x"))
        #expect(try vault.all().count == 3)
        #expect(try vault.search("timeout").map(\.title) == ["Fetch JSON with a timeout"])
        #expect(try vault.search("datacl").first?.language == "py")      // prefix match
        #expect(try vault.search("web").count == 1)                       // tags
        #expect(try vault.search("DROP").count == 1)
        #expect(try vault.agentContext() == nil)
        fetch.pinned = true
        try vault.save(fetch)
        #expect(try vault.all().first?.pinned == true)
        let context = try #require(try vault.agentContext())
        #expect(context.contains("Fetch JSON with a timeout:\n```ts\nconst r = await fetch"))
        try vault.delete(fetch.id)
        #expect(try vault.search("timeout").isEmpty)
        // It persists.
        #expect(try SnippetVault(url: url).all().count == 2)
    }
}
