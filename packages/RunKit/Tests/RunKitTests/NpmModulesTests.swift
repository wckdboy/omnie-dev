// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing
@testable import RunKit

/// File resolution inside cached packages, as bundlers do it.
struct NpmModulesTests {
    @Test func foldersPointingAtThemselvesDontLoop() throws {
        // Seen on the iPad: a package folder whose package.json says "main": "." recursed until the
        // main thread's stack ran out, crashing the preview of a React project.
        let pkg = FileManager.default.temporaryDirectory.appendingPathComponent("npm-\(UUID().uuidString)")
        for (path, text) in [
            "self/package.json": #"{"main": "."}"#, "self/index.js": "export default 1",
            "slash/package.json": #"{"main": "./"}"#, "slash/index.mjs": "export default 2",
            "loop/package.json": #"{"main": "./loop"}"#,
            "lib/package.json": #"{"main": "./dist/lib"}"#, "lib/dist/lib.js": "export default 3",
        ] {
            let url = pkg.appending(path: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        #expect(NpmModules.file("self", in: pkg) == "self/index.js")
        #expect(NpmModules.file("slash", in: pkg) == "slash/index.mjs")
        #expect(NpmModules.file("loop", in: pkg) == nil)
        #expect(NpmModules.file("lib", in: pkg) == "lib/dist/lib.js")
    }
}

extension WebKitSuites {
@MainActor
struct ExtensionlessImportTests {
    /// Vite projects import without extensions: `import App from "./App"` must reach App.tsx and be
    /// compiled as TSX (it was compiled as plain JS, and the JSX failed: the iPad tour's React preview).
    @Test func extensionlessImportsCompileByTheResolvedFile() async throws {
        let project = FileManager.default.temporaryDirectory.appendingPathComponent("ext-\(UUID().uuidString)")
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent("ext-cache-\(UUID().uuidString)")
        for (path, text) in [
            "package.json": #"{ "dependencies": { "react": "^18.3.0" } }"#,
            "src/App.tsx": "export default function App(): unknown { return <main>Hello</main>; }\n",
            "src/components/index.tsx": "export const Card = () => <section />;\n",
            "main.ts": """
                import App from "./src/App";
                import { Card } from "./src/components";
                console.log(JSON.stringify(App()), JSON.stringify(Card()));
                """,
        ] {
            let url = project.appending(path: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        // A stand-in react/jsx-runtime in a cache of its own.
        for (path, text) in [
            "react/18.3.1/package.json": #"{ "name": "react", "version": "18.3.1", "exports": { ".": "./index.js", "./jsx-runtime": "./jsx-runtime.js" } }"#,
            "react/18.3.1/index.js": "export const version = '18.3.1';\n",
            "react/18.3.1/jsx-runtime.js": "export const jsx = (type) => ({ type }); export const jsxs = jsx; export const Fragment = 'f';\n",
            // The cache's mark of a complete, verified package.
            "react/18.3.1/.omnie-npm.json": #"{"integrity": "sha512-test", "name": "react", "version": "18.3.1"}"#,
        ] {
            let url = cache.appending(path: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        NpmCache.sharedRoot = cache
        defer { NpmCache.sharedRoot = nil }
        let result = await (try JSRunner(root: project)).runFile("main.ts")
        #expect(result.output.map(\.text) == [#"{"type":"main"} {"type":"section"}"#], "\(result.report)")
    }
}
}
