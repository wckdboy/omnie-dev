// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Offline type checking for TypeScript projects (PLAN.md §5: diagnostics), with the TypeScript 5
/// compiler running in RunKit's sandbox. Reads `tsconfig.json` when there is one.
public struct TypeDiagnostic: Sendable, Hashable, Identifiable {
    public enum Category: String, Sendable { case error, warning, info }
    public var id: String { "\(path ?? ""):\(start ?? -1):\(code)" }
    public let code: Int
    public let category: Category
    public let message: String
    /// nil for project-wide problems (a bad tsconfig).
    public let path: String?
    public let line: Int?
    public let column: Int?
    /// UTF-16 offset and length in the file, for marking it in the editor.
    public let start: Int?
    public let length: Int?

    /// "src/a.ts:3:7 error TS2322: …"
    public var summary: String {
        let place = path.map { "\($0):\(line ?? 0):\(column ?? 0) " } ?? ""
        return "\(place)\(category.rawValue) TS\(code): \(message)"
    }
}

public struct TypeCheckResult: Sendable {
    public var diagnostics: [TypeDiagnostic] = []
    public var files = 0
    public var ms = 0
    public var failure: String?

    public var errors: Int { diagnostics.filter { $0.category == .error }.count }

    public var report: String {
        if let failure { return "Type check failed: \(failure)" }
        if diagnostics.isEmpty { return "No type errors in \(files) \(files == 1 ? "file" : "files") (\(ms) ms)." }
        return diagnostics.map(\.summary).joined(separator: "\n") + "\n\(errors) \(errors == 1 ? "error" : "errors") in \(files) files (\(ms) ms)."
    }
}

extension JSRunner {
    /// Whether a project has TypeScript to check.
    public nonisolated static func hasTypeScript(_ root: URL) -> Bool {
        SchemeHandler.projectFiles(ModuleResolver(root: root).root).contains { $0.hasSuffix(".ts") || $0.hasSuffix(".tsx") }
    }

    public func typeCheck(timeout: Double = 90) async -> TypeCheckResult {
        let session = Session(root: root, transpiler: transpiler)
        var collected = TypeCheckResult()
        session.onMessage = { body in
            guard let type = body["type"] as? String else { return }
            if type == "diagnostics" {
                collected.files = (body["files"] as? NSNumber)?.intValue ?? 0
                collected.ms = (body["ms"] as? NSNumber)?.intValue ?? 0
                collected.diagnostics = (body["diagnostics"] as? [[String: Any]] ?? []).map { d in
                    func int(_ k: String) -> Int? { (d[k] as? NSNumber)?.intValue }
                    return TypeDiagnostic(code: int("code") ?? 0, category: TypeDiagnostic.Category(rawValue: d["category"] as? String ?? "") ?? .error,
                                          message: d["message"] as? String ?? "", path: d["path"] as? String,
                                          line: int("line"), column: int("column"), start: int("start"), length: int("length"))
                }
            }
        }
        let result = await session.start(query: [URLQueryItem(name: "mode", value: "typecheck")], timeout: timeout)
        if case .timedOut(let s) = result.ending { collected.failure = "took longer than \(Int(s)) s" }
        if let error = result.output.first(where: { $0.stream == .err }) { collected.failure = collected.failure ?? error.text }
        return collected
    }
}
