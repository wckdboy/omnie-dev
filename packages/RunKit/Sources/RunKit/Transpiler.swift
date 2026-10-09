// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

import Foundation
import JavaScriptCore

/// TypeScript and TSX to JavaScript, by Sucrase running in JavaScriptCore (PLAN.md §8: JS/TS on the
/// device). Strips types and keeps ES modules, so WebKit can load the result as a module graph.
/// In-process JavaScriptCore has no JIT here, which is fine: Sucrase is a single fast pass.
public final class Transpiler: @unchecked Sendable {
    public enum Error: Swift.Error, Equatable, LocalizedError {
        case missingBundle
        case syntax(String)
        public var errorDescription: String? {
            switch self {
            case .missingBundle: "RunKit's TypeScript transpiler isn't bundled (run scripts/vendor-runkit.sh)."
            case .syntax(let message): message
            }
        }
    }

    private let context: JSContext
    private let transform: JSValue
    private let lock = NSLock()

    public init() throws {
        guard let url = Bundle.module.url(forResource: "sucrase", withExtension: "js", subdirectory: "JS"),
              let source = try? String(contentsOf: url, encoding: .utf8),
              let context = JSContext() else { throw Error.missingBundle }
        context.evaluateScript(source)
        guard let transform = context.objectForKeyedSubscript("OmnieSucrase")?.objectForKeyedSubscript("transform"),
              !transform.isUndefined else { throw Error.missingBundle }
        self.context = context
        self.transform = transform
    }

    /// Whether a path is something this transpiles.
    public static func handles(_ path: String) -> Bool {
        [".ts", ".tsx", ".mts", ".jsx"].contains { path.hasSuffix($0) } && !path.hasSuffix(".d.ts")
    }

    public func transpile(_ source: String, path: String) throws -> String {
        lock.lock()
        defer { lock.unlock() }
        var transforms = ["typescript"]
        if path.hasSuffix(".tsx") || path.hasSuffix(".jsx") { transforms = path.hasSuffix(".jsx") ? ["jsx"] : ["typescript", "jsx"] }
        let options: [String: Any] = ["transforms": transforms, "disableESTransforms": true, "filePath": path,
                                      "production": true, "jsxRuntime": "automatic"]
        context.exception = nil
        let result = transform.call(withArguments: [source, options])
        if let exception = context.exception {
            throw Error.syntax("\(path): \(exception.toString() ?? "syntax error")")
        }
        guard let code = result?.objectForKeyedSubscript("code")?.toString() else { throw Error.syntax("\(path): no output") }
        return code
    }
}
