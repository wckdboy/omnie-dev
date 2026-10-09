// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing
@testable import RunKit

struct TranspilerTests {
    @Test func stripsTypesAndKeepsModules() throws {
        let js = try Transpiler().transpile("""
            import type { User } from "./user";
            import { greet } from "./greet";
            export function hello(u: User, n: number = 1): string { return greet(u.name) as string; }
            interface Point { x: number }
            enum Mode { A, B }
            """, path: "src/a.ts")
        #expect(js.contains("import { greet } from \"./greet\""))
        #expect(!js.contains("./user"))
        #expect(js.contains("export function hello(u, n = 1)"))
        #expect(!js.contains("interface"))
        #expect(js.contains("Mode"))
    }

    @Test func reportsSyntaxErrors() throws {
        #expect(throws: Transpiler.Error.self) { try Transpiler().transpile("let x: = ;", path: "bad.ts") }
    }

    @Test func handlesTSXButNotDeclarations() {
        #expect(Transpiler.handles("a.ts") && Transpiler.handles("a.tsx") && !Transpiler.handles("a.d.ts") && !Transpiler.handles("a.js"))
    }
}

struct ModuleResolverTests {
    let root: URL
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("resolver-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("src/lib"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".git"), withIntermediateDirectories: true)
        for path in ["src/greet.ts", "src/lib/index.ts", "src/data.json", "plain.js", ".git/config"] {
            try "x".write(to: root.appendingPathComponent(path), atomically: true, encoding: .utf8)
        }
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("escape"), withDestinationURL: URL(filePath: "/etc"))
    }

    @Test func resolvesLikeABundler() {
        let r = ModuleResolver(root: root)
        #expect(r.resolve("src/greet")?.lastPathComponent == "greet.ts")
        #expect(r.resolve("src/greet.ts")?.lastPathComponent == "greet.ts")
        #expect(r.resolve("src/lib")?.path.hasSuffix("src/lib/index.ts") == true)
        #expect(r.resolve("src/data.json") != nil)
        #expect(r.resolve("plain.js") != nil)
        #expect(r.resolve("src/missing") == nil)
    }

    @Test func staysInTheProject() {
        let r = ModuleResolver(root: root)
        #expect(r.resolve("../../etc/hosts") == nil)
        #expect(r.resolve("escape/hosts") == nil)
        #expect(r.resolve(".git/config") == nil)
    }
}
