// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing
@testable import RunKit

extension WebKitSuites {
@MainActor
struct CodeFormatterTests {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("fmt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    @Test func formatsByLanguageWithTheProjectsOptions() async throws {
        let formatter = try CodeFormatter(root: root)
        defer { formatter.stop() }
        let ts = try await formatter.format("const  x:number=1;function f( a ){return a*2}\n", path: "src/a.ts")
        #expect(ts.text == "const x: number = 1;\nfunction f(a) {\n  return a * 2;\n}\n")
        let css = try await formatter.format("a{color:red;margin:0}", path: "style.css")
        #expect(css.text == "a {\n  color: red;\n  margin: 0;\n}\n")
        let json = try await formatter.format("{\"a\":1,\"b\":[1,2]}", path: "data.json")
        #expect(json.text == "{ \"a\": 1, \"b\": [1, 2] }\n")
        // The caret follows its code.
        let moved = try await formatter.format("let   value=1\n", path: "a.js", cursor: 6)
        #expect(moved.text == "let value = 1;\n" && moved.cursor == 4)

        // The project's options win: single quotes, no semicolons.
        try "{ \"singleQuote\": true, \"semi\": false }".write(to: root.appendingPathComponent(".prettierrc"), atomically: true, encoding: .utf8)
        let styled = try await formatter.format("const s = \"hi\";\n", path: "b.ts")
        #expect(styled.text == "const s = 'hi'\n")

        // A syntax error says so instead of mangling the file.
        await #expect(throws: LanguageServiceError.self) { try await formatter.format("const = ;", path: "c.ts") }
        #expect(CodeFormatter.handles("README.md") && CodeFormatter.handles("main.py") && !CodeFormatter.handles("main.swift"))
    }

    @Test func formatsPythonWithRuff() async throws {
        let formatter = try CodeFormatter(root: root)
        defer { formatter.stop() }
        let py = try await formatter.format("def f( a,b ):\n  return {'x':a,'y':b}\n", path: "app.py", cursor: 0)
        #expect(py.text == "def f(a, b):\n    return {\"x\": a, \"y\": b}\n")
        // pyproject.toml's line length.
        try "[tool.ruff]\nline-length = 20\n".write(to: root.appendingPathComponent("pyproject.toml"), atomically: true, encoding: .utf8)
        let narrow = try await formatter.format("result = some_function(argument_one, argument_two)\n", path: "b.py")
        #expect(narrow.text.contains("(\n    argument_one,\n"), "\(narrow.text)")
        await #expect(throws: LanguageServiceError.self) { try await formatter.format("def (:\n", path: "c.py") }

        // Lint: an unused import (a warning) and an undefined name (an error), where they are.
        let text = "import os\nprint(missing)\n"
        let problems = try await formatter.lint(text, path: "d.py")
        #expect(problems.map(\.rule) == ["F401", "F821"], "\(problems)")
        #expect(problems.map(\.category) == [.warning, .error])
        #expect(problems[1].line == 2 && problems[1].start == 16 && problems[1].length == 7)
    }
}
}
