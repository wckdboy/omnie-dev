// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing
@testable import RunKit

extension WebKitSuites {
@MainActor
struct JSRunnerTests {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("runkit-\(UUID().uuidString)")
        let files = [
            "src/math.ts": "export function add(a: number, b: number): number { return a + b; }\nexport const half = (n: number): number => n / 2;\n",
            "src/data.json": "{ \"answer\": 42 }",
            "tests/math.test.ts": """
                import { describe, it, expect } from "vitest";
                import { add, half } from "../src/math";
                import data from "../src/data.json";
                describe("math", () => {
                  it("adds", () => { expect(add(2, 3)).toBe(5); });
                  it("halves", async () => { expect(half(3)).toBeCloseTo(1.5); });
                  it("reads json", () => { expect(data).toEqual({ answer: 42 }); });
                  it("is wrong on purpose", () => { expect(add(1, 1)).not.toBe(2); });
                });
                """,
            "scripts/hello.ts": "const who: string = \"device\";\nconsole.log(`hello ${who}`);\nconsole.error(\"careful\");\n",
            "scripts/loop.js": "while (true) {}\n",
            "scripts/net.js": "await fetch(\"https://example.com\");\nconsole.log(\"reached the network\");\n",
            "scripts/broken.ts": "import { nope } from \"./missing\";\nconsole.log(nope);\n",
            "node_modules/x/a.test.ts": "",
        ]
        for (path, text) in files {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    @Test func findsTestFiles() {
        #expect(JSRunner.testFiles(in: root) == ["tests/math.test.ts"])
    }

    @Test func runsTypeScriptTests() async throws {
        let result = await (try JSRunner(root: root)).runTests(["tests/math.test.ts"])
        #expect(result.tests.map(\.name) == ["math > adds", "math > halves", "math > reads json", "math > is wrong on purpose"])
        #expect(result.tests.map(\.passed) == [true, true, true, false])
        #expect(result.tests[3].error?.contains("Expected not") == true)
        #expect(!result.passed)
        #expect(result.report.contains("1 failed, 3 passed"))
    }

    @Test func runsAScriptAndCapturesOutput() async throws {
        let result = await (try JSRunner(root: root)).runScript("scripts/hello.ts")
        #expect(result.output == [.init(stream: .out, text: "hello device"), .init(stream: .err, text: "careful")])
        #expect(result.passed)
    }

    @Test func stopsARunawayScript() async throws {
        let result = await (try JSRunner(root: root)).runScript("scripts/loop.js", timeout: 2)
        #expect(result.ending == .timedOut(seconds: 2))
        #expect(!result.passed)
    }

    @Test func hasNoNetwork() async throws {
        let result = await (try JSRunner(root: root)).runScript("scripts/net.js", timeout: 10)
        #expect(!result.output.contains { $0.text == "reached the network" })
        #expect(result.output.contains { $0.stream == .err })
    }

    @Test func missingModulesAreErrors() async throws {
        let result = await (try JSRunner(root: root)).runScript("scripts/broken.ts", timeout: 10)
        #expect(result.output.contains { $0.stream == .err && $0.text.contains("missing") })
    }
}
}

extension WebKitSuites {
@MainActor
struct PythonRunnerTests {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("py-\(UUID().uuidString)")
        let files = [
            "calc.py": "def total_up_to(n):\n    return sum(range(n + 1))\n\ndef divide(a, b):\n    return a / b\n",
            "main.py": "from calc import total_up_to\nimport sys\nprint('total', total_up_to(3))\nprint('oops', file=sys.stderr)\n",
            "loop.py": "while True:\n    pass\n",
            "boom.py": "def f():\n    raise ValueError('bad input')\nf()\n",
            "tests/test_calc.py": """
                import pytest
                from calc import total_up_to, divide

                def test_total():
                    assert total_up_to(3) == 6

                def test_wrong():
                    assert total_up_to(3) == 7

                def test_raises():
                    with pytest.raises(ZeroDivisionError):
                        divide(1, 0)

                @pytest.mark.parametrize("n,expected", [(1, 1), (2, 3)])
                def test_cases(n, expected):
                    assert total_up_to(n) == expected

                class TestApprox:
                    def test_float(self):
                        assert divide(1, 3) == pytest.approx(0.3333333)
                """,
        ]
        for (path, text) in files {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    @Test func runsAScript() async throws {
        let result = await (try JSRunner(root: root)).runPython("main.py")
        #expect(result.output.contains(.init(stream: .out, text: "total 6")))
        #expect(result.output.contains(.init(stream: .err, text: "oops")))
    }

    @Test func runsPytestStyleTests() async throws {
        #expect(JSRunner.pythonTestFiles(in: root) == ["tests/test_calc.py"])
        let result = await (try JSRunner(root: root)).runPythonTests(["tests/test_calc.py"])
        #expect(result.tests.map(\.name) == ["test_total", "test_wrong", "test_raises", "test_cases[1, 1]", "test_cases[2, 3]", "TestApprox.test_float"])
        #expect(result.tests.map(\.passed) == [true, false, true, true, true, true])
        #expect(result.tests[1].error == "assert failed: assert total_up_to(3) == 7\n    assert 6 == 7\n    total_up_to(3) = 6")
    }

    @Test func reportsExceptionsAndStopsLoops() async throws {
        let boom = await (try JSRunner(root: root)).runPython("boom.py")
        #expect(boom.output.contains { $0.stream == .err && $0.text.contains("ValueError: bad input") })
        let loop = await (try JSRunner(root: root)).runPython("loop.py", timeout: 8)
        #expect(loop.ending == .timedOut(seconds: 8))
    }
}
}
