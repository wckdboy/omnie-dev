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
    /// A WASI program's exit status.
    public var exitCode: Int32?
    /// Project files a WASI program wrote or deleted.
    public var changedFiles: [String] = []
    /// A WASI program's fuel spent (calls and loop iterations) and its largest memory, in bytes.
    public var fuelUsed: Int64?
    public var memoryPeak: Int?

    /// "fuel 1,234,567 · memory 18 MB" for a WASI run, else nil.
    public var resourceSummary: String? {
        var parts: [String] = []
        if let fuelUsed { parts.append("fuel \(fuelUsed.formatted())") }
        if let memoryPeak { parts.append("memory \(ByteCountFormatter.string(fromByteCount: Int64(memoryPeak), countStyle: .memory))") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Uncaught errors count as failures, like a non-zero exit.
    public var passed: Bool {
        ending == .finished && !output.contains { $0.stream == .err && $0.text.hasPrefix("Uncaught") } && tests.allSatisfy(\.passed)
            && (exitCode ?? 0) == 0
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
        if let exitCode, exitCode != 0 { lines.append("Exited with \(exitCode).") }
        if !changedFiles.isEmpty { lines.append("Changed: " + changedFiles.joined(separator: ", ")) }
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

    /// Python's test files: test_*.py and *_test.py.
    public nonisolated static func pythonTestFiles(in root: URL) -> [String] {
        SchemeHandler.projectFiles(ModuleResolver(root: root).root).filter {
            let name = ($0 as NSString).lastPathComponent
            return name.hasSuffix(".py") && (name.hasPrefix("test_") || name.hasSuffix("_test.py"))
        }
    }

    /// Runs a Python file with Pyodide (CPython in WebAssembly). The first run in a web view
    /// starts Python, which takes a few seconds.
    public func runPython(_ entry: String, timeout: Double = 60) async -> RunResult {
        await run(query: [URLQueryItem(name: "mode", value: "python"), URLQueryItem(name: "entry", value: entry)], timeout: timeout)
    }

    public func runPythonTests(_ files: [String], timeout: Double = 60) async -> RunResult {
        await run(query: [URLQueryItem(name: "mode", value: "pytest")] + files.map { URLQueryItem(name: "file", value: $0) }, timeout: timeout)
    }

    /// Every test in the project: JS/TS files with the vitest subset, Python files with the pytest
    /// subset, in one result. `only` limits it to one file.
    public func runAllTests(only file: String? = nil) async -> RunResult {
        let js = file.map { $0.hasSuffix(".py") ? [] : [$0] } ?? Self.testFiles(in: root)
        let py = file.map { $0.hasSuffix(".py") ? [$0] : [] } ?? Self.pythonTestFiles(in: root)
        var result = RunResult()
        let start = Date()
        for part in [js.isEmpty ? nil : await runTests(js), py.isEmpty ? nil : await runPythonTests(py)].compactMap({ $0 }) {
            result.output += part.output
            result.tests += part.tests
            if part.ending != .finished { result.ending = part.ending }
        }
        result.ms = Int(Date().timeIntervalSince(start) * 1000)
        return result
    }

    /// Runs a file by its kind: Python, a WASI program, or JavaScript/TypeScript.
    public func runFile(_ path: String) async -> RunResult {
        if path.hasSuffix(".py") { return await runPython(path) }
        if path.hasSuffix(".wasm") { return await runWasm(path) }
        return await runScript(path)
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
        /// Messages the session doesn't handle itself (the type checker's diagnostics).
        var onMessage: (([String: Any]) -> Void)?

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
                var components = URLComponents(string: "\(JSRunner.scheme)://local/__omnie/runtime/harness.html")!
                components.setQueryForJS(query)
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
                onMessage?(body)
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

/// Serves `omnie-run://local/__omnie/runtime/…` from RunKit's bundle and everything else from the
/// project: resolved like a bundler would, TypeScript transpiled, JSON as a module, and a
/// Content-Security-Policy that keeps the page off the network.
final class SchemeHandler: NSObject, WKURLSchemeHandler {
    let resolver: ModuleResolver
    let transpiler: Transpiler
    /// Project modules that were asked for but don't exist.
    private(set) var missing: [String] = []
    /// Every request served (for the preview's network log); RunKit's own runtime files aren't reported.
    var onRequest: (@MainActor (Preview.NetworkEntry) -> Void)?

    private func report(_ url: URL, method: String?, status: Int, bytes: Int, started: Date, mock: Bool = false) {
        guard let onRequest, !url.path.hasPrefix("/__omnie/runtime/"), url.path != "/__omnie/manifest.json" else { return }
        let entry = Preview.NetworkEntry(kind: Preview.NetworkEntry.kind(for: url.path), method: method ?? "GET",
                                         url: url.path + (url.query().map { "?" + $0 } ?? ""), status: status,
                                         ms: Int(Date().timeIntervalSince(started) * 1000), mock: mock ? true : nil, bytes: bytes)
        MainActor.assumeIsolated { onRequest(entry) }
    }

    init(resolver: ModuleResolver, transpiler: Transpiler) {
        self.resolver = resolver
        self.transpiler = transpiler
    }

    /// Only this scheme, never the network: fetch can read the project and RunKit's files (Pyodide
    /// loads its runtime that way), and WebAssembly may compile.
    static let csp = "default-src omnie-run:; script-src omnie-run: blob: 'unsafe-inline' 'wasm-unsafe-eval'; connect-src omnie-run: data: blob:; img-src omnie-run: data: blob:; style-src omnie-run: 'unsafe-inline'; worker-src omnie-run: blob:"

    /// The project's files for Pyodide's file system: under 2 MB each, at most 3,000, skipping
    /// version control, dependencies and build output.
    /// The project's directories (empty ones too), skipping what projectFiles skips.
    nonisolated static func projectDirectories(_ root: URL) -> [String] {
        var dirs: [String] = []
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey])
        while let url = enumerator?.nextObject() as? URL, dirs.count < 3_000 {
            if [".git", "node_modules", ".venv", "venv", "__pycache__", "dist", "build", ".build"].contains(url.lastPathComponent) {
                enumerator?.skipDescendants(); continue
            }
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
            if url.path.hasPrefix(root.path + "/") { dirs.append(String(url.path.dropFirst(root.path.count + 1))) }
        }
        return dirs.sorted()
    }

    nonisolated static func projectFiles(_ root: URL) -> [String] {
        var files: [String] = []
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey])
        while let url = enumerator?.nextObject() as? URL, files.count < 3_000 {
            if [".git", "node_modules", ".venv", "venv", "__pycache__", "dist", "build", ".build"].contains(url.lastPathComponent) {
                enumerator?.skipDescendants(); continue
            }
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values?.isRegularFile == true, (values?.fileSize ?? 0) < 2_000_000,
                  ModuleResolver.realPath(url.path).hasPrefix(root.path + "/") else { continue }
            files.append(String(url.path.dropFirst(root.path.count + 1)))
        }
        return files.sorted()
    }

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url else { return }
        // omnie-run://local/__omnie/runtime/<file> is RunKit's; everything else is the project, at the
        // origin root so a page's "/src/main.ts" works.
        let full = String(url.path.dropFirst())
        var area = "project", path = full
        for bundled in ["runtime", "pyodide", "packages", "npm"] where full.hasPrefix("__omnie/\(bundled)/") {
            area = bundled
            path = String(full.dropFirst("__omnie/\(bundled)/".count))
        }
        if full == "__omnie/manifest.json" { area = "manifest" }
        if full == "__omnie/dirs.json" { area = "dirs" }
        if full == "__omnie/npm-types.json" { area = "npm-types" }
        if full == "__omnie/python-packages.json" { area = "python-packages" }
        if full.hasPrefix("__omnie/pypi/") { area = "pypi"; path = String(full.dropFirst("__omnie/pypi/".count)) }
        if full.hasPrefix("__omnie/npm-raw/") { area = "npm-raw"; path = String(full.dropFirst("__omnie/npm-raw/".count)) }
        if full.hasPrefix("__omnie/source/") { area = "source"; path = String(full.dropFirst("__omnie/source/".count)) }
        let started = Date()
        do {
            let (data, mime) = try body(area: area, path: path, query: url.query() ?? "")
            report(url, method: task.request.httpMethod, status: 200, bytes: data.count, started: started)
            let headers = ["Content-Type": mime, "Content-Length": String(data.count), "Content-Security-Policy": Self.csp,
                           "Cache-Control": "no-store"]
            task.didReceive(HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)!)
            task.didReceive(data)
            task.didFinish()
        } catch let error as NotFound where area == "project" {
            // Not a file: a recorded API response, if the project has one for this request.
            let routes = MockRoutes.all(root: resolver.root)
            if let route = MockRoutes.match(method: task.request.httpMethod ?? "GET", path: "/" + path, in: routes) {
                let body = Data(route.body.utf8)
                task.didReceive(HTTPURLResponse(url: url, statusCode: route.status, httpVersion: "HTTP/1.1",
                                                headerFields: ["Content-Type": route.contentType, "Content-Length": String(body.count),
                                                               "X-Omnie-Mock": "1"])!)
                task.didReceive(body)
                task.didFinish()
                report(url, method: task.request.httpMethod, status: route.status, bytes: body.count, started: started, mock: true)
                return
            }
            missing.append(error.path)
            report(url, method: task.request.httpMethod, status: 404, bytes: 0, started: started)
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

    /// The project's packages from the npm cache, by bare specifier.
    var npmImports: [String: String] {
        NpmCache.sharedRoot.map { NpmModules.importMap(project: resolver.root, cache: $0) } ?? [:]
    }

    func body(area: String, path: String, query: String = "") throws -> (Data, String) {
        if area == "python-packages" {
            let (lock, wheels) = PyCache.sharedRoot.map { PyCache.resolve(project: resolver.root, cache: $0) } ?? ([], [])
            let urls = wheels.map { "omnie-run://local/__omnie/pypi/" + $0 }
            return (try JSONSerialization.data(withJSONObject: ["lock": lock, "wheels": urls]), "application/json")
        }
        if area == "pypi" {
            guard let cache = PyCache.sharedRoot, !path.split(separator: "/").contains(".."),
                  let data = try? Data(contentsOf: cache.appending(path: "wheels").appending(path: path)) else { throw NotFound(path: path) }
            return (data, "application/octet-stream")
        }
        if area == "npm-types" {
            let list = NpmCache.sharedRoot.map { NpmModules.typeFiles(project: resolver.root, cache: $0) } ?? []
            return (try JSONSerialization.data(withJSONObject: list), "application/json")
        }
        if area == "npm-raw" {
            guard let cache = NpmCache.sharedRoot, let data = NpmModules.raw(path: path, cache: cache) else { throw NotFound(path: path) }
            return (data, "text/plain; charset=utf-8")
        }
        if area == "npm" {
            guard let cache = NpmCache.sharedRoot, let found = NpmModules.body(path: path, cache: cache, project: resolver.root) else { throw NotFound(path: path) }
            return found
        }
        if area == "runtime" || area == "pyodide" || area == "packages" {
            let directory = ("JS/\(area)/" + path as NSString).deletingLastPathComponent
            // Pyodide packages fetched into the Python cache are served beside its bundled files, so
            // its own loader (dependencies, shared libraries, checksums) works on them.
            let isPackage = area == "pyodide" && !path.contains("/") && (path.hasSuffix(".whl") || path.hasSuffix(".zip"))
            let cached = isPackage ? PyCache.sharedRoot.map { $0.appending(path: "pyodide").appending(path: path) } : nil
            guard let url = Bundle.module.url(forResource: ((path as NSString).lastPathComponent as NSString).deletingPathExtension,
                                              withExtension: (path as NSString).pathExtension, subdirectory: directory)
                    ?? cached.flatMap({ FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }),
                  var data = try? Data(contentsOf: url) else { throw NotFound(path: path) }
            let ext = (path as NSString).pathExtension.lowercased()
            if area == "runtime", ext == "html" {
                data = Data(String(decoding: data, as: UTF8.self)
                    .replacingOccurrences(of: "<!--omnie:importmap-->",
                                          with: PackageCache.importMapTag(adding: npmImports.merging(["vitest": "omnie-run://local/__omnie/runtime/vitest.js"]) { _, v in v })).utf8)
            }
            return (data, Self.mimeTypes[ext] ?? (ext == "py" ? "text/plain" : "application/octet-stream"))
        }
        if area == "dirs" {
            return (try JSONSerialization.data(withJSONObject: Self.projectDirectories(resolver.root)), "application/json")
        }
        if area == "manifest" {
            return (try JSONSerialization.data(withJSONObject: Self.projectFiles(resolver.root)), "application/json")
        }
        guard let file = resolver.resolve(path), let data = try? Data(contentsOf: file) else { throw NotFound(path: path) }
        // A project file as it is on disk, not transpiled (the type checker reads sources).
        if area == "source" { return (data, "text/plain; charset=utf-8") }
        let name = file.lastPathComponent
        if name.hasSuffix(".html") || name.hasSuffix(".htm") {
            return (Data(PackageCache.inject(into: String(decoding: data, as: UTF8.self), adding: npmImports).utf8), "text/html")
        }
        // Shaders, and `?raw` imports (Vite's convention), are strings. Shaders register their text
        // so the Stage can map compile errors back to the file.
        let shader = Self.shaderExtensions.contains((name as NSString).pathExtension.lowercased())
        if shader || query.split(separator: "&").contains("raw") {
            let text = Self.jsString(String(decoding: data, as: UTF8.self))
            let register = shader ? "(globalThis.__omnieShaders ??= new Map()).set(text, \(Self.jsString(path)));\n" : ""
            return (Data("const text = \(text);\n\(register)export default text;\n".utf8), "text/javascript")
        }
        if name.hasSuffix(".json") {
            return (Data("export default \(String(decoding: data, as: UTF8.self));".utf8), "text/javascript")
        }
        if Transpiler.handles(name) {
            let js = try transpiler.transpile(String(decoding: data, as: UTF8.self), path: path)
            return (Data(js.utf8), "text/javascript")
        }
        return (data, Self.mimeTypes[(name as NSString).pathExtension.lowercased()] ?? "application/octet-stream")
    }

    nonisolated static let shaderExtensions: Set<String> = ["glsl", "vert", "frag", "vs", "fs", "wgsl"]

    nonisolated static let mimeTypes: [String: String] = [
        "js": "text/javascript", "mjs": "text/javascript", "cjs": "text/javascript",
        "html": "text/html", "htm": "text/html", "css": "text/css", "svg": "image/svg+xml",
        "png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg", "gif": "image/gif", "webp": "image/webp",
        "ico": "image/x-icon", "woff": "font/woff", "woff2": "font/woff2", "ttf": "font/ttf", "otf": "font/otf",
        "txt": "text/plain", "md": "text/plain", "wasm": "application/wasm", "glb": "model/gltf-binary",
        "gltf": "model/gltf+json", "map": "application/json",
    ]

    nonisolated static func jsString(_ text: String) -> String {
        let data = try? JSONSerialization.data(withJSONObject: [text])
        return data.map { String(decoding: $0, as: UTF8.self).dropFirst().dropLast() }.map(String.init) ?? "\"error\""
    }
}

extension URLComponents {
    /// Sets the query so the page's URLSearchParams reads it back exactly: Foundation leaves `+`
    /// as is, which form decoding turns into a space (`rg '[a-z]+'` arrived as `[a-z] `).
    mutating func setQueryForJS(_ items: [URLQueryItem]) {
        queryItems = items
        percentEncodedQuery = percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
    }
}
