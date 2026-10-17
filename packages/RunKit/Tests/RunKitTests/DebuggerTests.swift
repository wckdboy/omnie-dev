// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing
@testable import RunKit

/// The debugger (PLAN.md §5.3): breakpoints (with conditions), stepping, locals, evaluation and the
/// call stack, over the project's own modules. The worker blocks on the app's answer, so a test is
/// just a closure returning answers.
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
        ]
        for (path, text) in files {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    /// A debug run with a short timeout, retried once if the web view stalled (nothing happened at
    /// all), as the other WebKit suites do. `answer` gets the pause and how many have happened.
    func run(_ entry: String, _ breakpoints: Set<Debugger.Breakpoint>, timeout: Double = 40, project: URL? = nil,
             answer: @escaping @MainActor @Sendable (Debugger.Pause, Int) async -> Debugger.Answer) async throws -> (result: RunResult, pauses: [Debugger.Pause]) {
        var last: (RunResult, [Debugger.Pause])?
        for _ in 0..<2 {
            let box = Box<Debugger.Pause>()
            let result = await (try JSRunner(root: project ?? root)).debug(entry, breakpoints: breakpoints, timeout: timeout) { pause in
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
        let (result, pauses) = try await run("scripts/debug.ts", [.init(file: "scripts/debug.ts", line: 3)]) { _, _ in .resume }
        #expect(pauses.count == 1, "\(result.report)")
        let pause = try #require(pauses.first)
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
        let (result, pauses) = try await run("scripts/debug.ts", [.init(file: "scripts/debug.ts", line: 3)]) { _, index in
            index == 0 ? .stepInto : .resume
        }
        try #require(pauses.count >= 2, "\(result.report)")
        #expect(pauses[0].file == "scripts/debug.ts")
        let inside = pauses[1]
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
        let (result, pauses) = try await run("scripts/debug.ts", [.init(file: "scripts/debug.ts", line: 2)]) { _, index in
            index == 0 ? .stepOver : .resume
        }
        try #require(pauses.count >= 2, "\(result.report)")
        #expect(pauses[0].line == 2)
        #expect(pauses[1].file == "scripts/debug.ts")
        #expect(pauses[1].line == 3, "step over stops on the next statement, not inside the call")
        #expect(result.output.contains { $0.text == "sum 5" })
    }

    @Test func stepsOutOfAFunction() async throws {
        // A breakpoint inside the callee; Step Out returns to the next statement in the caller.
        let (result, pauses) = try await run("scripts/debug.ts", [.init(file: "scripts/math.ts", line: 2)]) { _, index in
            index == 0 ? .stepOut : .resume
        }
        try #require(pauses.count >= 2, "\(result.report)")
        #expect(pauses[0].file == "scripts/math.ts")
        let back = pauses[1]
        #expect(back.file == "scripts/debug.ts", "step out returns to the caller \(back.stack)")
        #expect(back.line == 4)
        #expect(back.reason == .step)
        #expect(back.locals.contains { $0.name == "b" && $0.value == "5" })
        #expect(result.output.contains { $0.text == "sum 5" })
    }

    @Test func stepsThroughALoop() async throws {
        // A breakpoint inside the loop body; each iteration is a separate stop.
        let (result, pauses) = try await run("scripts/loop.ts", [.init(file: "scripts/loop.ts", line: 3)]) { _, _ in .resume }
        #expect(pauses.count == 3, "\(result.report)")
        #expect(pauses.map(\.line) == [3, 3, 3])
        #expect(pauses.last?.locals.contains { $0.name == "i" && $0.value == "3" } == true)
        #expect(result.output.contains { $0.text == "total 6" })
    }

    @Test func evaluatesAnExpressionInThePausedFrame() async throws {
        let (result, pauses) = try await run("scripts/debug.ts", [.init(file: "scripts/debug.ts", line: 3)]) { pause, _ in
            // The same stop is held open for the evaluation; its result arrives with the next one.
            pause.evaluated == nil ? .evaluate("a + 1") : .resume
        }
        try #require(pauses.count >= 2, "\(result.report)")
        #expect(pauses[0].evaluated == nil)
        let evaluated = try #require(pauses[1].evaluated)
        #expect(evaluated.expression == "a + 1")
        #expect(evaluated.result == "3")
        #expect(!evaluated.failed)
        #expect(pauses[1].line == 3, "it stays at the same stop")
        #expect(pauses[1].locals.contains { $0.name == "a" })
        #expect(result.output.contains { $0.text == "sum 5" })
    }

    @Test func evaluationErrorsComeBackAsText() async throws {
        let (_, pauses) = try await run("scripts/debug.ts", [.init(file: "scripts/debug.ts", line: 3)]) { pause, _ in
            pause.evaluated == nil ? .evaluate("nope()") : .resume
        }
        try #require(pauses.count >= 2)
        let evaluated = try #require(pauses[1].evaluated)
        #expect(evaluated.failed)
        #expect(evaluated.result.contains("Error"), "\(evaluated.result)")
    }

    @Test func aConditionalBreakpointStopsOnlyWhenTrue() async throws {
        // In the loop (`i` from 1 to 3), stop only when `i === 2`.
        let (result, pauses) = try await run("scripts/loop.ts", [.init(file: "scripts/loop.ts", line: 3, condition: "i === 2")]) { _, _ in .resume }
        #expect(pauses.count == 1, "only the second iteration should stop (\(pauses.count) stops)")
        #expect(pauses.first?.locals.contains { $0.name == "i" && $0.value == "2" } == true)
        #expect(result.output.contains { $0.text == "total 6" })
    }

    @Test func aConditionalBreakpointThatNeverHoldsRunsToTheEnd() async throws {
        let (result, pauses) = try await run("scripts/loop.ts", [.init(file: "scripts/loop.ts", line: 3, condition: "i > 99")]) { _, _ in .resume }
        #expect(pauses.isEmpty, "a false condition never stops")
        #expect(result.output.contains { $0.text == "total 6" })
    }

    @Test func stoppingEndsTheRun() async throws {
        let (result, pauses) = try await run("scripts/debug.ts", [.init(file: "scripts/debug.ts", line: 2)]) { _, _ in .stop }
        #expect(pauses.count == 1)
        #expect(!result.output.contains { $0.text == "sum 5" }, "stopping shouldn't finish the program")
        #expect(result.ending == .finished)
    }

    /// A project whose entry imports a cached package: the package loads from the offline cache
    /// (uninstrumented), and the project's own code still stops at its breakpoints.
    @Test func debugsAProjectThatImportsAPackage() async throws {
        let project = FileManager.default.temporaryDirectory.appendingPathComponent("dbgnpm-\(UUID().uuidString)")
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent("dbgnpm-cache-\(UUID().uuidString)")
        for (path, text) in [
            "package.json": #"{ "dependencies": { "tiny": "^1.0.0" } }"#,
            "main.ts": """
                import { shout } from "tiny";
                const loud = shout("hi");
                console.log(loud);
                """,
        ] {
            let url = project.appending(path: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        for (path, text) in [
            "tiny/1.0.0/package.json": #"{ "name": "tiny", "version": "1.0.0", "exports": { ".": "./index.js" } }"#,
            "tiny/1.0.0/index.js": "export const shout = (s) => s.toUpperCase() + \"!\";\n",
            "tiny/1.0.0/.omnie-npm.json": #"{"integrity": "sha512-test", "name": "tiny", "version": "1.0.0"}"#,
        ] {
            let url = cache.appending(path: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        NpmCache.sharedRoot = cache
        defer { NpmCache.sharedRoot = nil }

        let pauses = Box<Debugger.Pause>()
        let result = await (try JSRunner(root: project)).debug("main.ts", breakpoints: [.init(file: "main.ts", line: 2)], timeout: 40) { pause in
            pauses.append(pause)
            return .resume
        }
        #expect(pauses.values.count == 1, "\(result.report)")
        #expect(pauses.values.first?.file == "main.ts")
        #expect(result.output.contains { $0.text == "HI!" }, "the package's code ran (\(result.report))")
    }

    @Test func anUnknownPackageSaysHowToGetIt() async throws {
        let project = FileManager.default.temporaryDirectory.appendingPathComponent("dbgnpm2-\(UUID().uuidString)")
        let url = project.appending(path: "main.ts")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try "import x from \"never-installed\";\nconsole.log(x);\n".write(to: url, atomically: true, encoding: .utf8)
        let (result, _) = try await run("main.ts", [], project: project) { _, _ in .resume }
        #expect(result.output.contains { $0.stream == .err && $0.text.contains("npm install") }, "\(result.report)")
    }
}

/// A tiny reference box, so a test can collect pauses from the (Sendable) pause closure.
@MainActor
final class Box<T> {
    var values: [T] = []
    func append(_ value: T) { values.append(value) }
}
}
