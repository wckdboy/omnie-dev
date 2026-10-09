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
    /// The project's own tests must pass afterwards (checked by the app with RunKit).
    public var testsMustPass = false

    public init(id: String, goal: String, files: [String: String], testsMustPass: Bool = false,
                check: @escaping @Sendable (_ read: (String) -> String?) -> String?) {
        self.id = id
        self.goal = goal
        self.files = files
        self.testsMustPass = testsMustPass
        self.check = check
    }

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
                                           pythonDefault, swiftGuard, jsonScript, cssColor, extractConstant, todoComment, testCase,
                                           htmlTitle, pythonOffByOne, optionalParam, removeFunction, moveConstant, swiftEnum,
                                           ciNode, gitignore, docComment, pythonFunction, cssRule, typos, failingTest]

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

    static let htmlTitle = GoldenTask(
        id: "html-title",
        goal: "Change the page title in index.html to Omnie Shop",
        files: ["index.html": "<!doctype html>\n<html>\n  <head>\n    <title>Vite App</title>\n  </head>\n  <body>\n    <div id=\"app\"></div>\n  </body>\n</html>\n"],
        check: { read in
            let html = read("index.html") ?? ""
            return firstFailure(
                expect(html.contains("<title>Omnie Shop</title>"), "the title isn't Omnie Shop"),
                expect(!html.contains("Vite App"), "the old title is still there"),
                expect(html.contains("<div id=\"app\"></div>"), "the body changed"))
        })

    static let pythonOffByOne = GoldenTask(
        id: "python-off-by-one",
        goal: "total_up_to(n) in calc.py should include n itself (total_up_to(3) is 6) but it returns 3. Fix it.",
        files: ["calc.py": "def total_up_to(n):\n    total = 0\n    for i in range(n):\n        total += i\n    return total\n"],
        check: { read in
            let py = (read("calc.py") ?? "").replacingOccurrences(of: " ", with: "")
            return firstFailure(
                expect(py.contains("range(n+1)") || py.contains("range(1,n+1)") || py.contains("n*(n+1)//2"), "it still stops before n"),
                expect(py.contains("deftotal_up_to(n)"), "the function signature changed"))
        })

    static let optionalParam = GoldenTask(
        id: "optional-param",
        goal: "Give greet in src/greet.ts a second, optional greeting parameter that defaults to \"Hello\" and is used instead of the fixed word",
        files: ["src/greet.ts": "export function greet(name: string): string {\n  return `Hello, ${name}!`;\n}\n"],
        check: { read in
            let ts = (read("src/greet.ts") ?? "").replacingOccurrences(of: " ", with: "")
            return firstFailure(
                expect(ts.contains("greeting=\"Hello\"") || ts.contains("greeting:string=\"Hello\"") || ts.contains("greeting='Hello'")
                       || ts.contains("greeting:string='Hello'"), "there's no greeting parameter defaulting to \"Hello\""),
                expect(ts.contains("${greeting}"), "the greeting isn't used in the message"),
                expect(ts.contains("${name}"), "the name was dropped"))
        })

    static let removeFunction = GoldenTask(
        id: "remove-function",
        goal: "Remove the unused function legacyFormat from src/format.ts",
        files: ["src/format.ts": "export function formatPrice(cents: number): string {\n  return `$${(cents / 100).toFixed(2)}`;\n}\n\nexport function legacyFormat(cents: number): string {\n  return cents + \" cents\";\n}\n"],
        check: { read in
            let ts = read("src/format.ts") ?? ""
            return firstFailure(
                expect(!ts.contains("legacyFormat") && !ts.contains("\" cents\""), "legacyFormat is still there"),
                expect(ts.contains("function formatPrice") && ts.contains("toFixed(2)"), "formatPrice was changed"))
        })

    static let moveConstant = GoldenTask(
        id: "move-constant",
        goal: "Move the TAX_RATE constant from src/checkout.ts into a new file src/config.ts, export it there, and import it in src/checkout.ts",
        files: ["src/checkout.ts": "const TAX_RATE = 0.2;\n\nexport function withTax(amount: number): number {\n  return amount * (1 + TAX_RATE);\n}\n"],
        check: { read in
            let config = (read("src/config.ts") ?? "").replacingOccurrences(of: " ", with: "")
            let checkout = read("src/checkout.ts") ?? ""
            return firstFailure(
                expect(config.contains("exportconstTAX_RATE=0.2"), "src/config.ts doesn't export TAX_RATE = 0.2"),
                expect(!checkout.contains("const TAX_RATE"), "src/checkout.ts still defines TAX_RATE"),
                expect(checkout.contains("import") && checkout.contains("TAX_RATE") && checkout.contains("config"), "src/checkout.ts doesn't import it"),
                expect(checkout.contains("amount * (1 + TAX_RATE)"), "withTax changed"))
        })

    static let swiftEnum = GoldenTask(
        id: "swift-enum",
        goal: "Add a purple case to the Tint enum in Sources/Tint.swift, with the hex value 8E5CF7",
        files: ["Sources/Tint.swift": "enum Tint: String {\n    case cyan = \"3DD6F5\"\n    case amber = \"F5B83D\"\n}\n"],
        check: { read in
            let swift = (read("Sources/Tint.swift") ?? "").uppercased().replacingOccurrences(of: " ", with: "")
            return firstFailure(
                expect(swift.contains("CASEPURPLE=\"8E5CF7\""), "there's no purple case with 8E5CF7"),
                expect(swift.contains("CASECYAN=\"3DD6F5\"") && swift.contains("CASEAMBER"), "the existing cases changed"))
        })

    static let ciNode = GoldenTask(
        id: "ci-node",
        goal: "In the CI workflow, change the Node version from 18 to 20",
        files: [".github/workflows/ci.yml": "name: CI\non: [push]\njobs:\n  test:\n    runs-on: ubuntu-latest\n    steps:\n      - uses: actions/checkout@v4\n      - uses: actions/setup-node@v4\n        with:\n          node-version: 18\n      - run: npm test\n"],
        check: { read in
            let yml = read(".github/workflows/ci.yml") ?? ""
            return firstFailure(
                expect(yml.contains("node-version: 20") || yml.contains("node-version: '20'") || yml.contains("node-version: \"20\""), "node-version isn't 20"),
                expect(!yml.contains("node-version: 18"), "18 is still there"),
                expect(yml.contains("- run: npm test"), "the steps changed"))
        })

    static let gitignore = GoldenTask(
        id: "gitignore",
        goal: "Make git ignore the dist folder",
        files: [".gitignore": "node_modules/\n.DS_Store\n", "src/index.ts": "console.log(1);\n"],
        check: { read in
            let lines = (read(".gitignore") ?? "").split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            return firstFailure(
                expect(lines.contains { ["dist", "dist/", "/dist", "/dist/"].contains($0) }, ".gitignore doesn't ignore dist"),
                expect(lines.contains("node_modules/") && lines.contains(".DS_Store"), "existing entries were removed"))
        })

    static let docComment = GoldenTask(
        id: "doc-comment",
        goal: "Add a doc comment above clamp in src/math.ts that explains what it does",
        files: ["src/math.ts": "export function clamp(value: number, min: number, max: number): number {\n  return Math.min(Math.max(value, min), max);\n}\n"],
        check: { read in
            let ts = read("src/math.ts") ?? ""
            guard let fn = ts.range(of: "export function clamp") else { return "clamp is gone" }
            let before = ts[..<fn.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
            return firstFailure(
                expect(before.hasSuffix("*/") || before.split(separator: "\n").last?.trimmingCharacters(in: .whitespaces).hasPrefix("//") == true,
                       "there's no comment right above clamp"),
                expect(ts.contains("Math.min(Math.max(value, min), max)"), "clamp's body changed"))
        })

    static let pythonFunction = GoldenTask(
        id: "python-function",
        goal: "Add an is_even function to utils.py that returns True for even numbers",
        files: ["utils.py": "def is_positive(n):\n    return n > 0\n"],
        check: { read in
            let py = (read("utils.py") ?? "").replacingOccurrences(of: " ", with: "")
            return firstFailure(
                expect(py.contains("defis_even("), "there's no is_even"),
                expect(py.contains("%2==0") || py.contains("%2!=1") || py.contains("&1==0"), "is_even doesn't test divisibility by 2"),
                expect(py.contains("defis_positive(n):") && py.contains("returnn>0"), "is_positive changed"))
        })

    static let cssRule = GoldenTask(
        id: "css-rule",
        goal: "Add a .hidden class to styles.css that hides an element",
        files: ["styles.css": ".card {\n  padding: 16px;\n}\n"],
        check: { read in
            let css = (read("styles.css") ?? "").replacingOccurrences(of: " ", with: "")
            return firstFailure(
                expect(css.contains(".hidden{") && (css.contains("display:none") || css.contains("visibility:hidden")), "there's no .hidden rule that hides"),
                expect(css.contains(".card{") && css.contains("padding:16px"), ".card changed"))
        })

    static let typos = GoldenTask(
        id: "typos",
        goal: "Fix the spelling mistakes in README.md",
        files: ["README.md": "# notes\n\nYou will recieve an email when teh build finishes.\n"],
        check: { read in
            let md = read("README.md") ?? ""
            return firstFailure(
                expect(md.contains("receive") && md.contains("the build"), "the typos aren't fixed"),
                expect(!md.contains("recieve") && !md.contains("teh "), "a typo is still there"),
                expect(md.contains("# notes"), "the heading changed"))
        })

    static let slugifyTest = """
        import { describe, it, expect } from "vitest";
        import { add, slugify } from "../src/util";

        describe("util", () => {
          it("adds", () => {
            expect(add(2, 3)).toBe(5);
          });
          it("slugifies", () => {
            expect(slugify("Hello World")).toBe("hello-world");
          });
          it("slugifies punctuation", () => {
            expect(slugify("Hi, there!")).toBe("hi-there");
          });
        });

        """

    static let failingTest = GoldenTask(
        id: "failing-test",
        goal: "A test is failing. Run the tests, then fix the code (not the test) so they all pass.",
        files: [
            "src/util.ts": "export function add(a: number, b: number): number {\n  return a + b;\n}\n\nexport function slugify(text: string): string {\n  return text.toLowerCase().replace(/ /g, \"-\");\n}\n",
            "tests/util.test.ts": slugifyTest,
        ],
        testsMustPass: true,
        check: { read in
            expect(read("tests/util.test.ts") == slugifyTest, "the test file was changed")
        })
}
