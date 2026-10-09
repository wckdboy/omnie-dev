// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing
@testable import RunKit

extension WebKitSuites {
@MainActor
struct TypeCheckTests {
    func project(_ files: [String: String]) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("typecheck-\(UUID().uuidString)")
        for (path, text) in files {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        return root
    }

    @Test func findsTypeErrorsAcrossFiles() async throws {
        let root = try project([
            "src/math.ts": "export function add(a: number, b: number): number { return a + b; }\n",
            "src/main.ts": "import { add } from \"./math\";\nimport * as THREE from \"three\";\nimport lodash from \"lodash\";\nconst n: string = add(1, 2);\ndocument.title = String(n);\nconsole.log(THREE, lodash);\n",
            "src/ok.tsx": "export const x = [1, 2, 3].map((n) => n * 2);\n",
        ])
        #expect(JSRunner.hasTypeScript(root))
        let result = await (try JSRunner(root: root)).typeCheck()
        #expect(result.failure == nil)
        #expect(result.files == 3)
        // "lodash" isn't installed: not reported. three isn't typed here either: not reported.
        #expect(result.diagnostics.count == 1, "\(result.report)")
        let d = try #require(result.diagnostics.first)
        #expect(d.code == 2322)
        #expect(d.path == "src/main.ts")
        #expect(d.line == 4 && d.column == 7)
        #expect(d.category == .error)
        #expect(result.report.contains("src/main.ts:4:7 error TS2322"))
    }

    @Test func filesAreModulesWithoutATsconfig() async throws {
        let root = try project(["src/app.ts": "const data: unknown = await (await fetch(\"/api\")).json();\nconsole.log(data);\n"])
        let result = await (try JSRunner(root: root)).typeCheck()
        #expect(result.diagnostics.isEmpty, "\(result.report)")
    }

    @Test func knowsTheStageAPI() async throws {
        let root = try project([
            "src/spin.stage.ts": "export default ({ scene, onFrame }: OmnieStage) => {\n  onFrame((dt) => { scene.rotation.y += dt; });\n  const n: string = 1;\n};\n",
        ])
        let result = await (try JSRunner(root: root)).typeCheck()
        #expect(result.diagnostics.map(\.code) == [2322], "\(result.report)")
    }

    @Test func readsTsconfig() async throws {
        let root = try project([
            "tsconfig.json": "{ \"compilerOptions\": { \"strict\": false }, \"include\": [\"src\"] }",
            "src/a.ts": "function f(x) { return x; }\nexport default f;\n",
            "scratch/b.ts": "const n: number = \"no\";\n",
        ])
        let result = await (try JSRunner(root: root)).typeCheck()
        #expect(result.failure == nil)
        #expect(result.diagnostics.isEmpty, "\(result.report)")
        #expect(result.report.hasPrefix("No type errors in 1 file"))
    }

    @Test func usesTypesFromCachedPackages() async throws {
        var registry = FakeRegistry()
        try registry.publish("typed-lib", versions: ["1.0.0": [
            "package.json": #"{ "name": "typed-lib", "main": "index.js", "types": "index.d.ts" }"#,
            "index.js": "export function greet(name) { return 'hi ' + name; }\n",
            "index.d.ts": "export declare function greet(name: string): string;\n",
        ]])
        let cacheRoot = FileManager.default.temporaryDirectory.appendingPathComponent("typecheck-npm-\(UUID().uuidString)")
        try await registry.cache(cacheRoot).install("typed-lib")
        let root = try project([
            "package.json": #"{ "dependencies": { "typed-lib": "^1.0.0", "not-cached": "^2" } }"#,
            "src/main.ts": "import { greet } from \"typed-lib\";\nimport other from \"not-cached\";\nconst n: number = greet(\"a\");\nconsole.log(n, other);\n",
        ])
        NpmCache.sharedRoot = cacheRoot
        defer { NpmCache.sharedRoot = nil }
        let result = await (try JSRunner(root: root)).typeCheck()
        #expect(result.diagnostics.map(\.code) == [2322], "\(result.report)")
        #expect(result.diagnostics.first?.line == 3)
    }
}
}
