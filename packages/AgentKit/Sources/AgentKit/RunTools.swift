// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

import Foundation
import PolicyKit

/// `run_tests`: the project's tests, run in RunKit's sandbox (no network, a timeout). The app
/// supplies the runner; AgentKit doesn't depend on WebKit.
public struct RunTestsTool: AgentTool {
    let runner: @Sendable (_ file: String?) async -> String
    public init(runner: @escaping @Sendable (_ file: String?) async -> String) { self.runner = runner }
    public let name = "run_tests"
    public let description = "Run the project's tests (*.test.ts, *.spec.js, test_*.py and so on), or one test file. Returns each test's result and any errors. Use it to check your change."
    public var parameters: [String: JSONValue] { schema(["path": ("string", "One test file to run. Default: all of them.")], required: []) }
    public func action(for call: ToolCall) throws -> Action {
        .runSandboxed(command: "run_tests" + (call.arguments["path"]?.string.map { " \($0)" } ?? ""), network: false)
    }
    public func run(_ call: ToolCall) async throws -> String { await runner(call.arguments["path"]?.string) }
}

/// `run_script`: one JavaScript or TypeScript file, in the same sandbox. Returns what it printed.
public struct RunScriptTool: AgentTool {
    let runner: @Sendable (_ file: String) async -> String
    public init(runner: @escaping @Sendable (_ file: String) async -> String) { self.runner = runner }
    public let name = "run_script"
    public let description = "Run a JavaScript, TypeScript or Python file from the project (no network, time-limited) and return what it printed and any errors."
    public var parameters: [String: JSONValue] { schema(["path": ("string", "The file to run.")], required: ["path"]) }
    public func action(for call: ToolCall) throws -> Action { .runSandboxed(command: "run_script \(try call.string("path"))", network: false) }
    public func run(_ call: ToolCall) async throws -> String { await runner(try call.string("path")) }
}

/// `check_types`: the TypeScript compiler over the whole project, offline. Returns each error with
/// its file, line and column, or that there are none.
public struct CheckTypesTool: AgentTool {
    let runner: @Sendable () async -> String
    public init(runner: @escaping @Sendable () async -> String) { self.runner = runner }
    public let name = "check_types"
    public let description = "Type-check the project's TypeScript (uses tsconfig.json if there is one). Returns each type error with file:line:column. Use it after editing .ts files."
    public var parameters: [String: JSONValue] { schema([:], required: []) }
    public func action(for call: ToolCall) throws -> Action { .runSandboxed(command: "check_types", network: false) }
    public func run(_ call: ToolCall) async throws -> String { await runner() }
}

/// `docs_lookup`: the offline docs (MDN, Python, Node… whatever is installed). Returns the best
/// page as text and other matches.
public struct DocsLookupTool: AgentTool {
    let runner: @Sendable (_ query: String) async -> String
    public init(runner: @escaping @Sendable (_ query: String) async -> String) { self.runner = runner }
    public let name = "docs_lookup"
    public let description = "Look up an API in the offline documentation (e.g. \"Array.prototype.flatMap\", \"pathlib.Path.glob\"). Returns the reference page as text. Use it when unsure how an API behaves."
    public var parameters: [String: JSONValue] { schema(["query": ("string", "The API or topic to look up.")], required: ["query"]) }
    public func action(for call: ToolCall) throws -> Action { .readProject(path: "docs:" + (try call.string("query"))) }
    public func run(_ call: ToolCall) async throws -> String { await runner(try call.string("query")) }
}
