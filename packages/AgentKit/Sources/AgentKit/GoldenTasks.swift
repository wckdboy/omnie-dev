// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// The golden task set (PLAN.md §22, P2: "the agent completes the golden task set at an agreed pass
/// rate"). Each task is a tiny project, a goal, and a check of the files afterwards. The checks look
/// at outcomes, not at how the agent got there.
public struct GoldenTask: Sendable, Identifiable {
    public let id: String
    public let goal: String
    public let files: [String: String]
    /// Returns nil when the result is right, or what's wrong.
    public let check: @Sendable (_ read: (String) -> String?) -> String?

    /// Writes the fixture into `root` (which must be empty or missing).
    public func materialize(at root: URL) throws {
        for (path, text) in files {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    /// Checks the files under `root`.
    public func verify(at root: URL) -> String? {
        check { try? String(contentsOf: root.appendingPathComponent($0), encoding: .utf8) }
    }
}

extension GoldenTask {
    static func expect(_ condition: Bool, _ failure: String) -> String? { condition ? nil : failure }

    static func firstFailure(_ checks: String?...) -> String? { checks.compactMap { $0 }.first }

    public static let all: [GoldenTask] = [farewell, rename, fixAdd, constants, readme]

    static let farewell = GoldenTask(
        id: "farewell",
        goal: "Add a farewell function to src/greet.ts that returns Goodbye, name! and use it in src/index.ts",
        files: [
            "src/greet.ts": "export function greet(name: string): string {\n  return `Hello, ${name}!`;\n}\n",
            "src/index.ts": "import { greet } from \"./greet\";\n\nconsole.log(greet(\"world\"));\n",
        ],
        check: { read in
            let greet = read("src/greet.ts") ?? "", index = read("src/index.ts") ?? ""
            return firstFailure(
                expect(greet.contains("function farewell"), "src/greet.ts has no farewell function"),
                expect(greet.contains("Goodbye"), "farewell doesn't say Goodbye"),
                expect(greet.contains("function greet") && greet.contains("Hello"), "greet was removed or changed"),
                expect(index.contains("farewell("), "src/index.ts doesn't call farewell"),
                expect(index.contains("greet(\"world\")"), "the existing greet call was removed"))
        })

    static let rename = GoldenTask(
        id: "rename",
        goal: "Rename the function total to sumPrices in src/cart.ts and update every place that uses it",
        files: [
            "src/cart.ts": "export function total(prices: number[]): number {\n  return prices.reduce((a, b) => a + b, 0);\n}\n",
            "src/index.ts": "import { total } from \"./cart\";\n\nconsole.log(total([1, 2, 3]));\n",
        ],
        check: { read in
            let cart = read("src/cart.ts") ?? "", index = read("src/index.ts") ?? ""
            return firstFailure(
                expect(cart.contains("function sumPrices"), "src/cart.ts doesn't define sumPrices"),
                expect(!cart.contains("function total"), "total is still defined"),
                expect(index.contains("sumPrices") && !index.contains("total"), "src/index.ts still uses total"),
                expect(cart.contains("reduce"), "the function body was lost"))
        })

    static let fixAdd = GoldenTask(
        id: "fix-add",
        goal: "add() in src/math.ts returns the wrong result. Fix it.",
        files: [
            "src/math.ts": "export function add(a: number, b: number): number {\n  return a - b;\n}\n\nexport function double(n: number): number {\n  return n * 2;\n}\n",
        ],
        check: { read in
            let math = read("src/math.ts") ?? ""
            return firstFailure(
                expect(math.contains("a + b"), "add still doesn't add"),
                expect(!math.contains("a - b"), "the subtraction is still there"),
                expect(math.contains("n * 2"), "double was changed"))
        })

    static let constants = GoldenTask(
        id: "constants",
        goal: "Create src/constants.ts that exports a constant MAX_ITEMS equal to 10",
        files: ["src/index.ts": "console.log(\"start\");\n"],
        check: { read in
            guard let text = read("src/constants.ts") else { return "src/constants.ts wasn't created" }
            let compact = text.replacingOccurrences(of: " ", with: "")
            return firstFailure(
                expect(compact.contains("exportconstMAX_ITEMS"), "MAX_ITEMS isn't an exported const"),
                expect(compact.contains("MAX_ITEMS=10") || compact.contains("MAX_ITEMS:number=10"), "MAX_ITEMS isn't 10"))
        })

    static let readme = GoldenTask(
        id: "readme",
        goal: "Add a Usage section to README.md that tells people to run npm start",
        files: ["README.md": "# shop\n\nA tiny shop backend.\n", "package.json": "{\n  \"name\": \"shop\",\n  \"scripts\": { \"start\": \"node index.js\" }\n}\n"],
        check: { read in
            let readme = read("README.md") ?? ""
            return firstFailure(
                expect(readme.contains("# shop") && readme.contains("A tiny shop backend."), "the existing README text was lost"),
                expect(readme.range(of: "#+ +Usage", options: .regularExpression) != nil, "there's no Usage heading"),
                expect(readme.contains("npm start"), "it doesn't mention npm start"))
        })
}
