// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing
@testable import RunKit

/// The debugger (PLAN.md §5.3): breakpoints, stepping, locals and the call stack, over the project's
/// own modules. The worker blocks on the app's answer, so a test is just a closure returning actions.
extension WebKitSuites {
@MainActor
struct DebuggerTests {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("debug-\(UUID().uuidString)")
        let files = [
            "scripts/math.ts": "export function add(x: number, y: number): number {\n  return x + y;\n}\n",
            "scripts/debug.ts": """
                import { add } from "./math";
                const a = 2;
                const b = add(a, 3);
                console.log(`sum ${b}`);
                """,
            "scripts/loop.ts": """
                let total = 0;
                for (let i = 1; i <= 3; i++) {
                  total += i;
                }
                console.log(`total ${total}`);
                """,
            "scripts/uses-package.ts": "import chalk from \"chalk\";\nconsole.log(chalk);\n",
        ]
        for (path, text) in files {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    @Test func stopsAtABreakpointAndShowsLocals() async throws {
        let pauses = Box<Debugger.Pause>()
        let result = await (try JSRunner(root: root)).debug("scripts/debug.ts",
                                                            breakpoints: [.init(file: "scripts/debug.ts", line: 3)]) { pause in
            pauses.append(pause)
            return .resume
        }
        #expect(pauses.values.count == 1, "REPORT: \(result.report)")
        let pause = try #require(pauses.values.first)
        #expect(pause.file == "scripts/debug.ts")
        #expect(pause.line == 3)
        #expect(pause.reason == .breakpoint)
        // `a` is in scope; `b` is being declared by this very statement, so it isn't yet.
        #expect(pause.locals.contains { $0.name == "a" && $0.value == "2" })
        #expect(!pause.locals.contains { $0.name == "b" })
        #expect(pause.stack.contains { $0.file == "scripts/debug.ts" && $0.line == 3 }, "\(pause.stack)")
        #expect(result.output.contains { $0.text == "sum 5" }, "\(result.report)")
        #expect(result.ending == .finished)
        #expect(result.passed)
    }

    @Test func stepsIntoAnImportedFunction() async throws {
        let pauses = Box<Debugger.Pause>()
        let result = await (try JSRunner(root: root)).debug("scripts/debug.ts",
                                                            breakpoints: [.init(file: "scripts/debug.ts", line: 3)]) { pause in
            pauses.append(pause)
            return pauses.values.count == 1 ? .stepInto : .resume
        }
        try #require(pauses.values.count >= 2, "\(result.report)")
        #expect(pauses.values[0].file == "scripts/debug.ts")
        let inside = pauses.values[1]
        #expect(inside.file == "scripts/math.ts", "step in lands in the callee \(inside.stack)")
        #expect(inside.line == 2)
        #expect(inside.reason == .step)
        #expect(inside.locals.contains { $0.name == "x" && $0.value == "2" })
        #expect(inside.locals.contains { $0.name == "y" && $0.value == "3" })
        #expect(inside.stack.first?.file == "scripts/math.ts")
        #expect(inside.stack.contains { $0.file == "scripts/debug.ts" }, "the caller is on the stack")
        #expect(result.output.contains { $0.text == "sum 5" })
    }

    @Test func stepsOverToTheNextStatement() async throws {
        let pauses = Box<Debugger.Pause>()
        let result = await (try JSRunner(root: root)).debug("scripts/debug.ts",
                                                            breakpoints: [.init(file: "scripts/debug.ts", line: 2)]) { pause in
            pauses.append(pause)
            return pauses.values.count == 1 ? .stepOver : .resume
        }
        try #require(pauses.values.count >= 2, "\(result.report)")
        #expect(pauses.values[0].line == 2)
        #expect(pauses.values[1].file == "scripts/debug.ts")
        #expect(pauses.values[1].line == 3, "step over stops on the next statement, not inside the call")
        #expect(result.output.contains { $0.text == "sum 5" })
    }

    @Test func stepsThroughALoop() async throws {
        // A breakpoint inside the loop body; each iteration is a separate stop.
        let pauses = Box<Debugger.Pause>()
        let result = await (try JSRunner(root: root)).debug("scripts/loop.ts",
                                                            breakpoints: [.init(file: "scripts/loop.ts", line: 3)]) { pause in
            pauses.append(pause)
            return .resume
        }
        // The loop runs three times, and the body is one statement.
        #expect(pauses.values.count == 3, "\(result.report)")
        #expect(pauses.values.map(\.line) == [3, 3, 3])
        #expect(pauses.values.last?.locals.contains { $0.name == "i" && $0.value == "3" } == true)
        #expect(result.output.contains { $0.text == "total 6" })
    }

    @Test func stepsOutOfAFunction() async throws {
        // A breakpoint inside the callee; Step Out returns to the next statement in the caller.
        let pauses = Box<Debugger.Pause>()
        let result = await (try JSRunner(root: root)).debug("scripts/debug.ts",
                                                            breakpoints: [.init(file: "scripts/math.ts", line: 2)]) { pause in
            pauses.append(pause)
            return pauses.values.count == 1 ? .stepOut : .resume
        }
        try #require(pauses.values.count >= 2, "\(result.report)")
        #expect(pauses.values[0].file == "scripts/math.ts")
        let back = pauses.values[1]
        #expect(back.file == "scripts/debug.ts", "step out returns to the caller \(back.stack)")
        #expect(back.line == 4)
        #expect(back.reason == .step)
        #expect(back.locals.contains { $0.name == "b" && $0.value == "5" })
        #expect(result.output.contains { $0.text == "sum 5" })
    }

    @Test func stoppingEndsTheRun() async throws {
        let pauses = Box<Debugger.Pause>()
        let result = await (try JSRunner(root: root)).debug("scripts/debug.ts",
                                                            breakpoints: [.init(file: "scripts/debug.ts", line: 2)]) { pause in
            pauses.append(pause)
            return .stop
        }
        #expect(pauses.values.count == 1)
        #expect(!result.output.contains { $0.text == "sum 5" }, "stopping shouldn't finish the program")
        #expect(result.ending == .finished)
    }

    @Test func aPackageImportSaysSo() async throws {
        let result = await (try JSRunner(root: root)).debug("scripts/uses-package.ts", breakpoints: []) { _ in .resume }
        #expect(result.output.contains { $0.stream == .err && $0.text.contains("npm packages") }, "\(result.report)")
    }
}

/// A tiny reference box, so a test can collect pauses from the (Sendable) pause closure.
@MainActor
final class Box<T> {
    var values: [T] = []
    func append(_ value: T) { values.append(value) }
}
}
