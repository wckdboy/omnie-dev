// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing
@testable import RunKit

/// The Python debugger (PLAN.md §5.3): breakpoints (with conditions), stepping, locals, evaluation
/// and the call stack, over the project's own modules, on Pyodide's line tracer. The worker blocks
/// on the app's answer, so a test is just a closure returning answers.
extension WebKitSuites {
@MainActor
struct PythonDebuggerTests {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("pydebug-\(UUID().uuidString)")
        let files = [
            "geometry.py": "def area(width, height):\n    result = width * height\n    return result\n",
            "main.py": """
                from geometry import area

                side = 3
                total = area(side, 4)
                print(f"area {total}")
                """,
            "loop.py": """
                total = 0
                for i in range(1, 4):
                    total += i
                print(f"total {total}")
                """,
        ]
        for (path, text) in files {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    /// A debug run with a short timeout, retried once if the web view stalled (nothing happened at
    /// all), as the other WebKit suites do. `answer` gets the pause and how many have happened.
    func run(_ entry: String, _ breakpoints: Set<Debugger.Breakpoint>, timeout: Double = 60,
             answer: @escaping @MainActor @Sendable (Debugger.Pause, Int) async -> Debugger.Answer) async throws -> (result: RunResult, pauses: [Debugger.Pause]) {
        var last: (RunResult, [Debugger.Pause])?
        for _ in 0..<2 {
            let box = Box<Debugger.Pause>()
            let result = await (try JSRunner(root: root)).debugPython(entry, breakpoints: breakpoints, timeout: timeout) { pause in
                let index = box.values.count
                box.append(pause)
                return await answer(pause, index)
            }
            last = (result, box.values)
            let stalled = box.values.isEmpty && result.output.isEmpty && result.ending != .finished
            if !stalled { return last! }
        }
        return last!
    }

    @Test func stopsAtABreakpointAndShowsLocals() async throws {
        let (result, pauses) = try await run("main.py", [.init(file: "main.py", line: 4)]) { _, _ in .resume }
        #expect(pauses.count == 1, "\(result.report)")
        let pause = try #require(pauses.first)
        #expect(pause.file == "main.py")
        #expect(pause.line == 4)
        #expect(pause.reason == .breakpoint)
        // `side` is in scope; `total` is being assigned by this very statement, so it isn't yet.
        #expect(pause.locals.contains { $0.name == "side" && $0.value == "3" }, "\(pause.locals)")
        #expect(!pause.locals.contains { $0.name == "total" })
        #expect(pause.stack.contains { $0.file == "main.py" && $0.line == 4 }, "\(pause.stack)")
        #expect(result.output.contains { $0.text == "area 12" }, "\(result.report)")
        #expect(result.ending == .finished)
        #expect(result.passed)
    }

    @Test func stepsIntoAnImportedFunction() async throws {
        let (result, pauses) = try await run("main.py", [.init(file: "main.py", line: 4)]) { _, index in
            index == 0 ? .stepInto : .resume
        }
        try #require(pauses.count >= 2, "\(result.report)")
        #expect(pauses[0].file == "main.py")
        let inside = pauses[1]
        #expect(inside.file == "geometry.py", "step in lands in the callee \(inside.stack)")
        #expect(inside.line == 2)
        #expect(inside.reason == .step)
        #expect(inside.locals.contains { $0.name == "width" && $0.value == "3" }, "\(inside.locals)")
        #expect(inside.locals.contains { $0.name == "height" && $0.value == "4" })
        #expect(inside.stack.first?.file == "geometry.py")
        #expect(inside.stack.contains { $0.file == "main.py" }, "the caller is on the stack")
        #expect(result.output.contains { $0.text == "area 12" })
    }

    @Test func stepsOverToTheNextStatement() async throws {
        let (result, pauses) = try await run("main.py", [.init(file: "main.py", line: 3)]) { _, index in
            index == 0 ? .stepOver : .resume
        }
        try #require(pauses.count >= 2, "\(result.report)")
        #expect(pauses[0].line == 3)
        #expect(pauses[1].file == "main.py")
        #expect(pauses[1].line == 4, "step over stops on the next statement, not inside the call")
        #expect(result.output.contains { $0.text == "area 12" })
    }

    @Test func stepsOutOfAFunction() async throws {
        // A breakpoint inside the callee; Step Out returns to the next statement in the caller.
        let (result, pauses) = try await run("main.py", [.init(file: "geometry.py", line: 2)]) { _, index in
            index == 0 ? .stepOut : .resume
        }
        try #require(pauses.count >= 2, "\(result.report)")
        #expect(pauses[0].file == "geometry.py")
        let back = pauses[1]
        #expect(back.file == "main.py", "step out returns to the caller \(back.stack)")
        #expect(back.line == 5)
        #expect(back.reason == .step)
        #expect(back.locals.contains { $0.name == "total" && $0.value == "12" }, "\(back.locals)")
        #expect(result.output.contains { $0.text == "area 12" })
    }

    @Test func stepsThroughALoop() async throws {
        // A breakpoint inside the loop body; each iteration is a separate stop.
        let (result, pauses) = try await run("loop.py", [.init(file: "loop.py", line: 3)]) { _, _ in .resume }
        #expect(pauses.count == 3, "\(result.report)")
        #expect(pauses.map(\.line) == [3, 3, 3])
        #expect(pauses.last?.locals.contains { $0.name == "i" && $0.value == "3" } == true)
        #expect(result.output.contains { $0.text == "total 6" })
    }

    @Test func evaluatesAnExpressionInThePausedFrame() async throws {
        let (result, pauses) = try await run("main.py", [.init(file: "main.py", line: 4)]) { pause, _ in
            // The same stop is held open for the evaluation; its result arrives with the next one.
            pause.evaluated == nil ? .evaluate("side + 1") : .resume
        }
        try #require(pauses.count >= 2, "\(result.report)")
        #expect(pauses[0].evaluated == nil)
        let evaluated = try #require(pauses[1].evaluated)
        #expect(evaluated.expression == "side + 1")
        #expect(evaluated.result == "4")
        #expect(!evaluated.failed)
        #expect(pauses[1].line == 4, "it stays at the same stop")
        #expect(pauses[1].locals.contains { $0.name == "side" })
        #expect(result.output.contains { $0.text == "area 12" })
    }

    @Test func evaluationErrorsComeBackAsText() async throws {
        let (_, pauses) = try await run("main.py", [.init(file: "main.py", line: 4)]) { pause, _ in
            pause.evaluated == nil ? .evaluate("nope()") : .resume
        }
        try #require(pauses.count >= 2)
        let evaluated = try #require(pauses[1].evaluated)
        #expect(evaluated.failed)
        #expect(evaluated.result.contains("NameError"), "\(evaluated.result)")
    }

    @Test func aConditionalBreakpointStopsOnlyWhenTrue() async throws {
        // In the loop (`i` from 1 to 3), stop only when `i == 2`.
        let (result, pauses) = try await run("loop.py", [.init(file: "loop.py", line: 3, condition: "i == 2")]) { _, _ in .resume }
        #expect(pauses.count == 1, "only the second iteration should stop (\(pauses.count) stops)")
        #expect(pauses.first?.locals.contains { $0.name == "i" && $0.value == "2" } == true)
        #expect(result.output.contains { $0.text == "total 6" })
    }

    @Test func aConditionalBreakpointThatNeverHoldsRunsToTheEnd() async throws {
        let (result, pauses) = try await run("loop.py", [.init(file: "loop.py", line: 3, condition: "i > 99")]) { _, _ in .resume }
        #expect(pauses.isEmpty, "a false condition never stops")
        #expect(result.output.contains { $0.text == "total 6" })
    }

    @Test func stoppingEndsTheRun() async throws {
        let (result, pauses) = try await run("main.py", [.init(file: "main.py", line: 3)]) { _, _ in .stop }
        #expect(pauses.count == 1)
        #expect(!result.output.contains { $0.text == "area 12" }, "stopping shouldn't finish the program")
        #expect(result.ending == .finished)
    }
}
}
