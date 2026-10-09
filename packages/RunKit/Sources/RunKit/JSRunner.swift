// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

import Foundation
import WebKit

/// What a run printed and how it ended.
public struct RunResult: Sendable, Equatable {
    public struct Line: Sendable, Equatable {
        public enum Stream: String, Sendable { case out, err }
        public let stream: Stream
        public let text: String
    }

    public struct TestResult: Sendable, Equatable {
        public let file: String
        public let name: String
        public let passed: Bool
        public let error: String?
        public let ms: Int
    }

    public enum Ending: Sendable, Equatable {
        case finished
        case timedOut(seconds: Double)
    }

    public var output: [Line] = []
    public var tests: [TestResult] = []
    public var ending: Ending = .finished
    public var ms: Int = 0

    /// Uncaught errors count as failures, like a non-zero exit.
    public var passed: Bool {
        ending == .finished && !output.contains { $0.stream == .err && $0.text.hasPrefix("Uncaught") } && tests.allSatisfy(\.passed)
    }

    /// A plain-text report: what a terminal would show, and what the agent reads.
    public var report: String {
        var lines: [String] = []
        for line in output { lines.append(line.stream == .err ? "! \(line.text)" : line.text) }
        if !tests.isEmpty {
            for test in tests {
                lines.append("\(test.passed ? "✓" : "✗") \(test.file) › \(test.name)" + (test.error.map { "\n    \($0)" } ?? ""))
            }
            let failed = tests.filter { !$0.passed }.count
            lines.append(failed == 0 ? "\(tests.count) passed (\(ms) ms)" : "\(failed) failed, \(tests.count - failed) passed (\(ms) ms)")
        }
        if case .timedOut(let s) = ending { lines.append("Stopped: took longer than \(Int(s)) s.") }
        return lines.isEmpty ? "(no output)" : lines.joined(separator: "\n")
    }
}

/// Runs a project's JavaScript or TypeScript in a throwaway WKWebView (PLAN.md §8: JS/TS on the
/// device, JavaScriptCore's JIT out of process). Files are served read-only from the project
/// (TypeScript transpiled on the way), the page can't reach the network, and a run that doesn't
/// finish in time is stopped.
@MainActor
public final class JSRunner {
    public static let scheme = "omnie-run"
    let root: URL
    let transpiler: Transpiler

    public init(root: URL) throws {
        self.root = root
        transpiler = try Transpiler()
    }

    /// The project's test files: *.test.* and *.spec.* (TypeScript or JavaScript), outside node_modules.
    public nonisolated static func testFiles(in root: URL) -> [String] {
        let resolver = ModuleResolver(root: root)
        var files: [String] = []
        let enumerator = FileManager.default.enumerator(at: resolver.root, includingPropertiesForKeys: nil)
        while let url = enumerator?.nextObject() as? URL {
            if ["node_modules", ".git", "dist", "build"].contains(url.lastPathComponent) { enumerator?.skipDescendants(); continue }
            let name = url.lastPathComponent
            if name.range(of: #"\.(test|spec)\.(ts|tsx|js|mjs|jsx)$"#, options: .regularExpression) != nil {
                files.append(String(url.path.dropFirst(resolver.root.path.count + 1)))
            }
        }
        return files.sorted()
    }

    public func runTests(_ files: [String], timeout: Double = 30) async -> RunResult {
        var query = [URLQueryItem(name: "mode", value: "tests")]
        query += files.map { URLQueryItem(name: "file", value: $0) }
        return await run(query: query, timeout: timeout)
    }

    public func runScript(_ entry: String, timeout: Double = 30) async -> RunResult {
        await run(query: [URLQueryItem(name: "entry", value: entry)], timeout: timeout)
    }

    private func run(query: [URLQueryItem], timeout: Double) async -> RunResult {
        let session = Session(root: root, transpiler: transpiler)
        let start = Date()
        var result = await session.start(query: query, timeout: timeout)
        result.ms = Int(Date().timeIntervalSince(start) * 1000)
        return result
    }

    /// One run: its own web view, scheme handler and message handler, torn down at the end.
    final class Session: NSObject, WKScriptMessageHandler {
        let handler: SchemeHandler
        var webView: WKWebView?
        var result = RunResult()
        var continuation: CheckedContinuation<RunResult, Never>?

        init(root: URL, transpiler: Transpiler) {
            handler = SchemeHandler(resolver: ModuleResolver(root: root), transpiler: transpiler)
        }

        func start(query: [URLQueryItem], timeout: Double) async -> RunResult {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                let config = WKWebViewConfiguration()
                config.websiteDataStore = .nonPersistent()
                config.setURLSchemeHandler(handler, forURLScheme: JSRunner.scheme)
                config.userContentController.add(self, name: "run")
                let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 320, height: 240), configuration: config)
                self.webView = webView
                // One origin for the harness and the project, so module loads aren't cross-origin.
                var components = URLComponents(string: "\(JSRunner.scheme)://local/runtime/harness.html")!
                components.queryItems = query
                webView.load(URLRequest(url: components.url!))
                DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
                    self?.finish(.timedOut(seconds: timeout))
                }
            }
        }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
            switch type {
            case "console":
                let level = body["level"] as? String ?? "log"
                result.output.append(.init(stream: level == "error" || level == "warn" ? .err : .out, text: body["text"] as? String ?? ""))
            case "error":
                result.output.append(.init(stream: .err, text: "Uncaught " + (body["text"] as? String ?? "error")))
            case "test":
                result.tests.append(.init(file: body["file"] as? String ?? "", name: body["name"] as? String ?? "",
                                          passed: body["ok"] as? Bool ?? false, error: body["error"] as? String,
                                          ms: (body["ms"] as? NSNumber)?.intValue ?? 0))
            case "done":
                finish(.finished)
            default:
                break
            }
        }

        private func finish(_ ending: RunResult.Ending) {
            guard let continuation else { return }
            self.continuation = nil
            result.ending = ending
            // WebKit's own message for a failed import doesn't name the file.
            for path in handler.missing { result.output.append(.init(stream: .err, text: "Uncaught Error: Can't find module \(path) in the project.")) }
            webView?.stopLoading()
            webView?.configuration.userContentController.removeScriptMessageHandler(forName: "run")
            webView = nil
            continuation.resume(returning: result)
        }
    }
}

/// Serves `omnie-run://local/runtime/…` from RunKit's bundle and `omnie-run://local/project/…` from the
/// project: resolved like a bundler would, TypeScript transpiled, JSON as a module, and a
/// Content-Security-Policy that keeps the page off the network.
final class SchemeHandler: NSObject, WKURLSchemeHandler {
    let resolver: ModuleResolver
    let transpiler: Transpiler
    /// Project modules that were asked for but don't exist.
    private(set) var missing: [String] = []

    init(resolver: ModuleResolver, transpiler: Transpiler) {
        self.resolver = resolver
        self.transpiler = transpiler
    }

    static let csp = "default-src omnie-run:; script-src omnie-run: 'unsafe-inline'; connect-src 'none'; img-src omnie-run: data:; style-src omnie-run: 'unsafe-inline'"

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url else { return }
        // omnie-run://local/<runtime|project>/<path>
        let parts = url.path.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: true)
        let area = parts.first.map(String.init) ?? ""
        let path = parts.count > 1 ? String(parts[1]) : ""
        do {
            let (data, mime) = try body(area: area, path: path)
            let headers = ["Content-Type": mime, "Content-Length": String(data.count), "Content-Security-Policy": Self.csp,
                           "Cache-Control": "no-store"]
            task.didReceive(HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)!)
            task.didReceive(data)
            task.didFinish()
        } catch let error as NotFound where area == "project" {
            missing.append(error.path)
            task.didReceive(HTTPURLResponse(url: url, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: ["Content-Security-Policy": Self.csp])!)
            task.didFinish()
        } catch {
            // A module that can't load surfaces as a console error with this text.
            let message = Data("throw new Error(\(Self.jsString((error as? LocalizedError)?.errorDescription ?? "\(error)")));".utf8)
            task.didReceive(HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                            headerFields: ["Content-Type": "text/javascript", "Content-Security-Policy": Self.csp])!)
            task.didReceive(message)
            task.didFinish()
        }
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}

    struct NotFound: LocalizedError {
        let path: String
        var errorDescription: String? { "Can't find module \(path) in the project." }
    }

    func body(area: String, path: String) throws -> (Data, String) {
        if area == "runtime" {
            guard let url = Bundle.module.url(forResource: (path as NSString).deletingPathExtension,
                                              withExtension: (path as NSString).pathExtension, subdirectory: "JS/runtime"),
                  let data = try? Data(contentsOf: url) else { throw NotFound(path: path) }
            return (data, path.hasSuffix(".html") ? "text/html" : "text/javascript")
        }
        guard let file = resolver.resolve(path), let data = try? Data(contentsOf: file) else { throw NotFound(path: path) }
        let name = file.lastPathComponent
        if name.hasSuffix(".json") {
            return (Data("export default \(String(decoding: data, as: UTF8.self));".utf8), "text/javascript")
        }
        if Transpiler.handles(name) {
            let js = try transpiler.transpile(String(decoding: data, as: UTF8.self), path: path)
            return (Data(js.utf8), "text/javascript")
        }
        return (data, "text/javascript")
    }

    static func jsString(_ text: String) -> String {
        let data = try? JSONSerialization.data(withJSONObject: [text])
        return data.map { String(decoding: $0, as: UTF8.self).dropFirst().dropLast() }.map(String.init) ?? "\"error\""
    }
}
