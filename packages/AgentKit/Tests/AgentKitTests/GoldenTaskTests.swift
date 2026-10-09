// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing
@testable import AgentKit

struct GoldenTaskTests {
    func fresh(_ task: GoldenTask) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("golden-\(task.id)-\(UUID().uuidString)")
        try task.materialize(at: root)
        return root
    }

    func edit(_ root: URL, _ path: String, _ change: (String) -> String) throws {
        let url = root.appendingPathComponent(path)
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try change(text).write(to: url, atomically: true, encoding: .utf8)
    }

    @Test func everyFixtureStartsUnsolved() throws {
        // Tasks judged by the project's tests start unsolved in a way only RunKit can see.
        for task in GoldenTask.all where !task.testsMustPass {
            #expect(task.verify(at: try fresh(task)) != nil, "\(task.id)")
        }
    }

    func solve(_ task: GoldenTask, at root: URL) throws {
        switch task.id {
        case "farewell":
            try edit(root, "src/greet.ts") { $0 + "\nexport function farewell(name: string): string {\n  return `Goodbye, ${name}!`;\n}\n" }
            try edit(root, "src/index.ts") {
                $0.replacingOccurrences(of: "import { greet }", with: "import { greet, farewell }") + "console.log(farewell(\"world\"));\n"
            }
        case "rename":
            try edit(root, "src/cart.ts") { $0.replacingOccurrences(of: "total", with: "sumPrices") }
            try edit(root, "src/index.ts") { $0.replacingOccurrences(of: "total", with: "sumPrices") }
        case "fix-add":
            try edit(root, "src/math.ts") { $0.replacingOccurrences(of: "a - b", with: "a + b") }
        case "constants":
            try edit(root, "src/constants.ts") { _ in "export const MAX_ITEMS = 10;\n" }
        case "readme":
            try edit(root, "README.md") { $0 + "\n## Usage\n\nRun `npm start`.\n" }
        case "python-default":
            try edit(root, "app/greeting.py") { $0.replacingOccurrences(of: "def greet(name):", with: "def greet(name=\"world\"):") }
        case "swift-guard":
            try edit(root, "Sources/Stats.swift") {
                $0.replacingOccurrences(of: "{\n    values", with: "{\n    if values.isEmpty { return 0 }\n    return values")
            }
        case "json-script":
            try edit(root, "package.json") { $0.replacingOccurrences(of: "\"dev\": \"vite\"", with: "\"dev\": \"vite\",\n    \"test\": \"vitest\"") }
        case "css-color":
            try edit(root, "styles/main.css") { $0.replacingOccurrences(of: "#222", with: "#3dd6f5") }
        case "extract-constant":
            try edit(root, "src/retry.ts") {
                "const MAX_RETRIES = 3;\n\n" + $0.replacingOccurrences(of: "i < 3", with: "i < MAX_RETRIES")
            }
        case "todo":
            try edit(root, "src/user.ts") { $0.replacingOccurrences(of: "  // TODO: add an optional email field of type string\n", with: "  email?: string;\n") }
        case "test-case":
            try edit(root, "tests/math.test.ts") {
                $0.replacingOccurrences(of: "  });\n});", with: "  });\n  it(\"adds\", () => {\n    expect(add(2, 3)).toBe(5);\n  });\n});")
            }
        case "html-title":
            try edit(root, "index.html") { $0.replacingOccurrences(of: "Vite App", with: "Omnie Shop") }
        case "python-off-by-one":
            try edit(root, "calc.py") { $0.replacingOccurrences(of: "range(n)", with: "range(n + 1)") }
        case "optional-param":
            try edit(root, "src/greet.ts") {
                $0.replacingOccurrences(of: "(name: string)", with: "(name: string, greeting: string = \"Hello\")")
                    .replacingOccurrences(of: "`Hello,", with: "`${greeting},")
            }
        case "remove-function":
            try edit(root, "src/format.ts") { String($0[..<$0.range(of: "\nexport function legacyFormat")!.lowerBound]) }
        case "move-constant":
            try edit(root, "src/config.ts") { _ in "export const TAX_RATE = 0.2;\n" }
            try edit(root, "src/checkout.ts") { $0.replacingOccurrences(of: "const TAX_RATE = 0.2;", with: "import { TAX_RATE } from \"./config\";") }
        case "swift-enum":
            try edit(root, "Sources/Tint.swift") { $0.replacingOccurrences(of: "\n}", with: "\n    case purple = \"8E5CF7\"\n}") }
        case "ci-node":
            try edit(root, ".github/workflows/ci.yml") { $0.replacingOccurrences(of: "node-version: 18", with: "node-version: 20") }
        case "gitignore":
            try edit(root, ".gitignore") { $0 + "dist/\n" }
        case "doc-comment":
            try edit(root, "src/math.ts") { "/** Keeps value between min and max. */\n" + $0 }
        case "python-function":
            try edit(root, "utils.py") { $0 + "\n\ndef is_even(n):\n    return n % 2 == 0\n" }
        case "css-rule":
            try edit(root, "styles.css") { $0 + "\n.hidden {\n  display: none;\n}\n" }
        case "failing-test":
            try edit(root, "src/util.ts") { $0.replacingOccurrences(of: ".replace(/ /g, \"-\")", with: ".replace(/[^a-z0-9]+/g, \"-\").replace(/^-|-$/g, \"\")") }
        case "typos":
            try edit(root, "README.md") { $0.replacingOccurrences(of: "recieve", with: "receive").replacingOccurrences(of: "teh", with: "the") }
        default:
            Issue.record("no solution for \(task.id)")
        }
    }

    @Test func correctSolutionsPass() throws {
        for task in GoldenTask.all {
            let root = try fresh(task)
            try solve(task, at: root)
            #expect(task.verify(at: root) == nil, "\(task.id): \(task.verify(at: root) ?? "")")
        }
    }

    @Test func theIPadsFirstAttemptFails() throws {
        // What the 7B did on 9 Oct 2026 (docs/spikes/agent-p2.md).
        let task = GoldenTask.farewell
        let root = try fresh(task)
        try edit(root, "src/greet.ts") { $0.replacingOccurrences(of: "Hello", with: "Goodbye") }
        try edit(root, "src/index.ts") { $0 + "console.log(greet(\"user\"));\n" }
        #expect(task.verify(at: root) == "src/greet.ts has no farewell function")
    }
}
