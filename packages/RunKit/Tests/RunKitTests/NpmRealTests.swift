// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing
@testable import RunKit

extension WebKitSuites {
@MainActor
struct NpmRealTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["OMNIE_NPM_REAL"] != nil))
    func realPackages() async throws {
        let cacheRoot = URL(filePath: "/tmp/claude-501/npm-real-cache")
        let cache = NpmCache(root: cacheRoot) { url in try await URLSession.shared.data(from: url).0 }
        let project = FileManager.default.temporaryDirectory.appendingPathComponent("npm-real-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try #"{ "dependencies": { "react": "^18.3.0", "react-dom": "^18.3.0", "zod": "^3.23.0", "date-fns": "^3.6.0", "nanoid": "^5.0.0" } }"#
            .write(to: project.appending(path: "package.json"), atomically: true, encoding: .utf8)
        let installed = try await cache.installProject(project) { print($0) }
        print("installed", installed.map { "\($0.name)@\($0.version)" })
        try """
            import React, { useState, createElement } from "react";
            import { renderToStaticMarkup } from "react-dom/server.browser";
            import { z } from "zod";
            import { format } from "date-fns";
            import { nanoid } from "nanoid";
            const App = () => { const [n] = useState(2); return createElement("p", null, "n=", n); };
            console.log(renderToStaticMarkup(createElement(App)), typeof React.Component);
            console.log(z.object({ a: z.number() }).safeParse({ a: 1 }).success, format(new Date(2026, 0, 2), "yyyy-MM-dd"), nanoid().length);
            """.write(to: project.appending(path: "main.js"), atomically: true, encoding: .utf8)
        NpmCache.sharedRoot = cacheRoot
        defer { NpmCache.sharedRoot = nil }
        let result = await (try JSRunner(root: project)).runFile("main.js")
        print(result.report)
        #expect(result.output.map(\.text) == ["<p>n=2</p> function", "true 2026-01-02 21"])
        // The type checker sees the cached packages' own declarations.
        try """
            import { z } from "zod";
            import { format } from "date-fns";
            const User = z.object({ name: z.string() });
            const u: { name: number } = User.parse({ name: "a" });
            const d: number = format(new Date(), "yyyy");
            console.log(u, d);
            """.write(to: project.appending(path: "types.ts"), atomically: true, encoding: .utf8)
        let types = await (try JSRunner(root: project)).typeCheck()
        print(types.report)
        #expect(types.diagnostics.map(\.code) == [2322, 2322])
    }
}
}
