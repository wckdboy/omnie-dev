// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

import Foundation
import WebKit

/// A place in a project file: UTF-16 offset and length (as the editor counts), 1-based line and
/// column, and that line's text for lists.
public struct SourceLocation: Sendable, Hashable, Identifiable {
    public var id: String { "\(path):\(start):\(length)" }
    public let path: String
    public let start: Int
    public let length: Int
    public let line: Int
    public let column: Int
    public let preview: String
    /// For references: whether this one declares the symbol, or writes it.
    public var isDefinition = false
    public var isWrite = false
}

/// What the language service knows about the symbol at a place.
public struct QuickInfo: Sendable, Hashable {
    public let kind: String
    public let signature: String
    public let documentation: String
    public let tags: [String]
}

public struct Completion: Sendable, Hashable, Identifiable {
    public var id: String { name + "|" + kind }
    public let name: String
    /// The language service's kind: "method", "property", "function", "const", "keyword", …
    public let kind: String
    public let insertText: String
    /// What the completion replaces: the word typed so far.
    public let start: Int
    public let length: Int
}

/// A rename: every place to change, or why it can't be.
public struct RenamePlan: Sendable, Hashable {
    public struct Edit: Sendable, Hashable {
        public let location: SourceLocation
        public let newText: String
    }
    public let displayName: String
    public let edits: [Edit]
    public var files: [String] { Array(Set(edits.map(\.location.path))).sorted() }
}

public enum LanguageServiceError: Error, LocalizedError, Equatable {
    case notReady(String)
    case failed(String)
    case cantRename(String)

    public var errorDescription: String? {
        switch self {
        case .notReady(let why): "The language service isn't running: \(why)"
        case .failed(let why): "The language service failed: \(why)"
        case .cantRename(let why): why
        }
    }
}

/// Code intelligence for a project, offline, in RunKit's sandbox and kept running: go to
/// definition, find references, rename, quick info and completions. TypeScript and JavaScript get
/// the TypeScript language service (what VS Code uses); Python gets Jedi in Pyodide. Feed it the
/// editor's text with `update` so answers follow unsaved edits; `reload` after files change on disk.
@MainActor
public final class LanguageService: NSObject, WKScriptMessageHandler {
    public enum Flavor: String, Sendable, CaseIterable {
        case typescript, python

        /// The flavor for a project file, or nil when neither answers for it.
        public static func of(_ path: String) -> Flavor? {
            if path.range(of: #"\.(ts|tsx|mts|cts|js|jsx|mjs|cjs)$"#, options: .regularExpression) != nil { return .typescript }
            if path.hasSuffix(".py") || path.hasSuffix(".pyi") { return .python }
            return nil
        }

        var mode: String { self == .typescript ? "language" : "pylanguage" }
    }

    public let root: URL
    public let flavor: Flavor
    private let handler: SchemeHandler
    private var webView: WKWebView?
    private var ready: CheckedContinuation<Void, Error>?
    private var isReady = false
    private var pending: [Int: CheckedContinuation<Any?, Error>] = [:]
    private var nextID = 1

    public init(root: URL, flavor: Flavor = .typescript) throws {
        self.root = root
        self.flavor = flavor
        handler = SchemeHandler(resolver: ModuleResolver(root: root), transpiler: try Transpiler())
    }

    /// Whether a project file is one some service answers for.
    public nonisolated static func handles(_ path: String) -> Bool { Flavor.of(path) != nil }

    /// Starts the sandbox (once); the project loads on the first request.
    public func start(timeout: Double = 30) async throws {
        if isReady { return }
        if webView == nil {
            let config = WKWebViewConfiguration()
            config.websiteDataStore = .nonPersistent()
            config.setURLSchemeHandler(handler, forURLScheme: JSRunner.scheme)
            config.userContentController.add(WeakHandler(self), name: "run")
            let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 10, height: 10), configuration: config)
            self.webView = webView
            var components = URLComponents(string: "\(JSRunner.scheme)://local/__omnie/runtime/harness.html")!
            components.setQueryForJS([URLQueryItem(name: "mode", value: flavor.mode)])
            webView.load(URLRequest(url: components.url!))
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            if isReady { continuation.resume(); return }
            ready = continuation
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
                guard let self, let ready = self.ready else { return }
                self.ready = nil
                ready.resume(throwing: LanguageServiceError.notReady("it didn't start in \(Int(timeout)) s"))
            }
        }
    }

    public func stop() {
        webView?.stopLoading()
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "run")
        webView = nil
        isReady = false
        for (_, continuation) in pending { continuation.resume(throwing: LanguageServiceError.notReady("stopped")) }
        pending = [:]
    }

    // MARK: Requests

    /// The editor's text for a file, saved or not.
    public func update(_ path: String, text: String) async throws {
        _ = try await request("update", ["path": path, "text": text])
    }

    /// Re-reads the project from disk (files added, removed or saved elsewhere).
    public func reload() async throws {
        _ = try await request("reload", [:], timeout: 120)
    }

    public func definition(_ path: String, offset: Int) async throws -> [SourceLocation] {
        Self.locations(try await request("definition", ["path": path, "offset": offset]))
    }

    public func references(_ path: String, offset: Int) async throws -> [SourceLocation] {
        Self.locations(try await request("references", ["path": path, "offset": offset]))
    }

    /// The symbol's name, to start a rename with; throws when it can't be renamed.
    public func renameTarget(_ path: String, offset: Int) async throws -> String {
        let info = try await request("renameInfo", ["path": path, "offset": offset]) as? [String: Any] ?? [:]
        if let error = info["error"] as? String { throw LanguageServiceError.cantRename(error) }
        return info["displayName"] as? String ?? ""
    }

    public func rename(_ path: String, offset: Int, to newName: String) async throws -> RenamePlan {
        let result = try await request("rename", ["path": path, "offset": offset, "newName": newName]) as? [String: Any] ?? [:]
        if let error = result["error"] as? String { throw LanguageServiceError.cantRename(error) }
        let edits = (result["edits"] as? [[String: Any]] ?? []).compactMap { e -> RenamePlan.Edit? in
            guard let location = Self.location(e) else { return nil }
            return .init(location: location, newText: e["newText"] as? String ?? newName)
        }
        return RenamePlan(displayName: result["displayName"] as? String ?? "", edits: edits)
    }

    public func quickInfo(_ path: String, offset: Int) async throws -> QuickInfo? {
        guard let info = try await request("quickInfo", ["path": path, "offset": offset]) as? [String: Any] else { return nil }
        return QuickInfo(kind: info["kind"] as? String ?? "", signature: info["signature"] as? String ?? "",
                         documentation: info["documentation"] as? String ?? "", tags: info["tags"] as? [String] ?? [])
    }

    public func completions(_ path: String, offset: Int, limit: Int = 60) async throws -> [Completion] {
        let result = try await request("completions", ["path": path, "offset": offset, "limit": limit]) as? [String: Any] ?? [:]
        return (result["entries"] as? [[String: Any]] ?? []).map { e in
            Completion(name: e["name"] as? String ?? "", kind: e["kind"] as? String ?? "", insertText: e["insertText"] as? String ?? "",
                       start: (e["start"] as? NSNumber)?.intValue ?? offset, length: (e["length"] as? NSNumber)?.intValue ?? 0)
        }
    }

    public func completionDetails(_ path: String, offset: Int, name: String) async throws -> QuickInfo? {
        guard let d = try await request("completionDetails", ["path": path, "offset": offset, "name": name]) as? [String: Any] else { return nil }
        return QuickInfo(kind: "", signature: d["signature"] as? String ?? "", documentation: d["documentation"] as? String ?? "", tags: [])
    }

    private func request(_ op: String, _ args: [String: Any], timeout: Double = 60) async throws -> Any? {
        try await start()
        guard let webView else { throw LanguageServiceError.notReady("no sandbox") }
        let id = nextID
        nextID += 1
        var message = args
        message["id"] = id
        message["op"] = op
        let json = String(decoding: try JSONSerialization.data(withJSONObject: message), as: UTF8.self)
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            webView.evaluateJavaScript("omnieLanguage(\(json))") { [weak self] _, error in
                guard let error, let self, let continuation = self.pending.removeValue(forKey: id) else { return }
                continuation.resume(throwing: LanguageServiceError.failed(error.localizedDescription))
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
                guard let continuation = self?.pending.removeValue(forKey: id) else { return }
                continuation.resume(throwing: LanguageServiceError.failed("\(op) took longer than \(Int(timeout)) s"))
            }
        }
    }

    public func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        switch type {
        case "ready":
            isReady = true
            ready?.resume()
            ready = nil
        case "reply":
            guard let id = (body["id"] as? NSNumber)?.intValue, let continuation = pending.removeValue(forKey: id) else { return }
            if let error = body["error"] as? String {
                continuation.resume(throwing: LanguageServiceError.failed(error))
            } else {
                continuation.resume(returning: body["result"] is NSNull ? nil : body["result"])
            }
        case "error":
            let text = body["text"] as? String ?? "error"
            if let ready { self.ready = nil; ready.resume(throwing: LanguageServiceError.notReady(text)) }
        default:
            break
        }
    }

    // MARK: Decoding

    static func locations(_ json: Any?) -> [SourceLocation] {
        (json as? [[String: Any]] ?? []).compactMap(location)
    }

    static func location(_ e: [String: Any]) -> SourceLocation? {
        guard let path = e["path"] as? String else { return nil }
        func int(_ k: String) -> Int { (e[k] as? NSNumber)?.intValue ?? 0 }
        var location = SourceLocation(path: path, start: int("start"), length: int("length"), line: int("line"), column: int("column"),
                                      preview: e["preview"] as? String ?? "")
        location.isDefinition = e["isDefinition"] as? Bool ?? false
        location.isWrite = e["isWrite"] as? Bool ?? false
        return location
    }
}

/// WebKit keeps its script message handlers strongly; this breaks the cycle.
private final class WeakHandler: NSObject, WKScriptMessageHandler {
    weak var target: (any WKScriptMessageHandler)?
    init(_ target: any WKScriptMessageHandler) { self.target = target }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(controller, didReceive: message)
    }
}
