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

    public static let all: [GoldenTask] = [farewell, rename, fixAdd, constants, readme,
                                           pythonDefault, swiftGuard, jsonScript, cssColor, extractConstant, todoComment, testCase]

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

    static let pythonDefault = GoldenTask(
        id: "python-default",
        goal: "In app/greeting.py, give the name parameter of greet a default value of \"world\"",
        files: ["app/greeting.py": "def greet(name):\n    return f\"Hello, {name}!\"\n\n\nif __name__ == \"__main__\":\n    print(greet(\"you\"))\n"],
        check: { read in
            let py = (read("app/greeting.py") ?? "").replacingOccurrences(of: "'", with: "\"")
            return firstFailure(
                expect(py.contains("def greet(name=\"world\")") || py.contains("def greet(name: str = \"world\")")
                       || py.contains("def greet(name = \"world\")"), "greet's name has no \"world\" default"),
                expect(py.contains("print(greet(\"you\"))"), "the main block changed"))
        })

    static let swiftGuard = GoldenTask(
        id: "swift-guard",
        goal: "average(of:) in Sources/Stats.swift crashes on an empty array. Make it return 0 for an empty array.",
        files: ["Sources/Stats.swift": "func average(of values: [Double]) -> Double {\n    values.reduce(0, +) / Double(values.count)\n}\n"],
        check: { read in
            let swift = read("Sources/Stats.swift") ?? ""
            return firstFailure(
                expect(swift.contains("isEmpty") || swift.contains("count == 0"), "there's no empty check"),
                expect(swift.contains("return 0"), "it doesn't return 0 for an empty array"),
                expect(swift.contains("reduce(0, +)"), "the average itself was lost"))
        })

    static let jsonScript = GoldenTask(
        id: "json-script",
        goal: "Add a test script to package.json that runs vitest",
        files: ["package.json": "{\n  \"name\": \"web\",\n  \"scripts\": {\n    \"dev\": \"vite\"\n  }\n}\n"],
        check: { read in
            guard let text = read("package.json"), let data = text.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return "package.json isn't valid JSON" }
            let scripts = json["scripts"] as? [String: String] ?? [:]
            return firstFailure(
                expect(scripts["test"]?.contains("vitest") == true, "there's no test script running vitest"),
                expect(scripts["dev"] == "vite", "the dev script changed"))
        })

    static let cssColor = GoldenTask(
        id: "css-color",
        goal: "Change the button background color in styles/main.css to #3dd6f5",
        files: ["styles/main.css": "body {\n  margin: 0;\n}\n\n.button {\n  background: #222;\n  color: white;\n}\n"],
        check: { read in
            let css = (read("styles/main.css") ?? "").lowercased()
            return firstFailure(
                expect(css.contains("#3dd6f5"), "the color isn't #3dd6f5"),
                expect(!css.contains("#222"), "the old color is still there"),
                expect(css.contains("margin: 0") && css.contains("color: white"), "other rules changed"))
        })

    static let extractConstant = GoldenTask(
        id: "extract-constant",
        goal: "In src/retry.ts, replace the magic number 3 with a named constant MAX_RETRIES",
        files: ["src/retry.ts": "export async function retry<T>(fn: () => Promise<T>): Promise<T> {\n  for (let i = 0; i < 3; i++) {\n    try {\n      return await fn();\n    } catch {}\n  }\n  throw new Error(\"failed after 3 tries\");\n}\n"],
        check: { read in
            let ts = read("src/retry.ts") ?? ""
            return firstFailure(
                expect(ts.contains("MAX_RETRIES = 3"), "MAX_RETRIES isn't defined as 3"),
                expect(ts.contains("i < MAX_RETRIES"), "the loop still uses the number"),
                expect(ts.contains("return await fn()"), "the retry logic changed"))
        })

    static let todoComment = GoldenTask(
        id: "todo",
        goal: "Find the TODO comment in the project and do what it says",
        files: [
            "src/user.ts": "export interface User {\n  name: string;\n  // TODO: add an optional email field of type string\n}\n",
            "src/index.ts": "import type { User } from \"./user\";\n\nconst u: User = { name: \"Ada\" };\nconsole.log(u.name);\n",
        ],
        check: { read in
            let user = (read("src/user.ts") ?? "").replacingOccurrences(of: " ", with: "")
            return firstFailure(
                expect(user.contains("email?:string"), "User has no optional email: string"),
                expect(user.contains("name:string"), "name was changed"))
        })

    static let testCase = GoldenTask(
        id: "test-case",
        goal: "Add a test to tests/math.test.ts that checks add(2, 3) is 5",
        files: [
            "src/math.ts": "export function add(a: number, b: number): number {\n  return a + b;\n}\n",
            "tests/math.test.ts": "import { describe, it, expect } from \"vitest\";\nimport { add } from \"../src/math\";\n\ndescribe(\"add\", () => {\n  it(\"adds zero\", () => {\n    expect(add(1, 0)).toBe(1);\n  });\n});\n",
        ],
        check: { read in
            let test = (read("tests/math.test.ts") ?? "").replacingOccurrences(of: " ", with: "")
            return firstFailure(
                expect(test.contains("add(2,3)"), "there's no test calling add(2, 3)"),
                expect(test.contains(").toBe(5)") || test.contains(").toEqual(5)"), "it doesn't expect 5"),
                expect(test.contains("expect(add(1,0)).toBe(1)"), "the existing test was removed"))
        })
}
