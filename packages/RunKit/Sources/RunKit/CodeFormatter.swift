// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Format Document (VS Code's ⇧⌥F), offline, in RunKit's sandbox: Prettier for JavaScript,
/// TypeScript, JSON, CSS, HTML, Markdown and YAML (with the project's Prettier options) and Ruff for
/// Python (with its line-length). Kept running per project once used.
@MainActor
public final class CodeFormatter {
    public let root: URL
    private let worker: SandboxWorker

    public init(root: URL) throws {
        self.root = root
        worker = try SandboxWorker(root: root, mode: "format")
    }

    /// Whether Prettier knows the file's language, by its name.
    public nonisolated static func handles(_ path: String) -> Bool {
        path.range(of: #"\.(js|jsx|mjs|cjs|ts|tsx|mts|cts|json|jsonc|json5|css|scss|less|html|htm|vue|md|markdown|mdx|yaml|yml|py|pyi)$"#,
                   options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// The text formatted, and where `cursor` (a UTF-16 offset) ends up in it. Syntax errors throw
    /// with Prettier's message.
    public func format(_ text: String, path: String, cursor: Int = 0) async throws -> (text: String, cursor: Int) {
        let result = try await worker.request("format", ["path": path, "text": text, "cursor": cursor], timeout: 30) as? [String: Any] ?? [:]
        guard let formatted = result["text"] as? String else { throw LanguageServiceError.failed("Prettier returned nothing") }
        return (formatted, (result["cursor"] as? NSNumber)?.intValue ?? cursor)
    }

    /// Ruff's lint for a Python file: unused imports, undefined names, syntax errors and the rest of
    /// its default rules. Syntax errors and undefined names are errors; the others warnings.
    public func lint(_ text: String, path: String) async throws -> [TypeDiagnostic] {
        let found = try await worker.request("lint", ["path": path, "text": text], timeout: 30) as? [[String: Any]] ?? []
        return found.map { d in
            func int(_ k: String) -> Int? { (d[k] as? NSNumber)?.intValue }
            let rule = d["rule"] as? String ?? ""
            let serious = rule == "invalid-syntax" || rule.hasPrefix("E9") || ["F821", "F822", "F823"].contains(rule)
            var diagnostic = TypeDiagnostic(code: 0, category: serious ? .error : .warning, message: d["message"] as? String ?? "",
                                            path: path, line: int("line"), column: int("column"), start: int("start"), length: int("length"))
            diagnostic.rule = rule
            return diagnostic
        }
    }

    public func stop() { worker.stop() }
}
