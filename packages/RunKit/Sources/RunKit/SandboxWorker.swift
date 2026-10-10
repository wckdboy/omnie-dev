// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

import Foundation
import WebKit

/// A worker in RunKit's sandbox that stays up and answers requests: the harness in a `mode`
/// that sends "ready", then takes `omnieLanguage({ id, op, ... })` and replies
/// `{ type: "reply", id, result | error }`. The language services and the formatter run on it.
@MainActor
final class SandboxWorker: NSObject, WKScriptMessageHandler {
    let mode: String
    private let handler: SchemeHandler
    private var webView: WKWebView?
    private var ready: CheckedContinuation<Void, Error>?
    private var isReady = false
    private var pending: [Int: CheckedContinuation<Any?, Error>] = [:]
    private var nextID = 1

    init(root: URL, mode: String) throws {
        self.mode = mode
        handler = SchemeHandler(resolver: ModuleResolver(root: root), transpiler: try Transpiler())
    }

    /// Starts the sandbox (once).
    func start(timeout: Double = 30) async throws {
        if isReady { return }
        if webView == nil {
            let config = WKWebViewConfiguration()
            config.websiteDataStore = .nonPersistent()
            config.setURLSchemeHandler(handler, forURLScheme: JSRunner.scheme)
            config.userContentController.add(WeakHandler(self), name: "run")
            let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 10, height: 10), configuration: config)
            self.webView = webView
            var components = URLComponents(string: "\(JSRunner.scheme)://local/__omnie/runtime/harness.html")!
            components.setQueryForJS([URLQueryItem(name: "mode", value: mode)])
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

    func stop() {
        webView?.stopLoading()
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "run")
        webView = nil
        isReady = false
        for (_, continuation) in pending { continuation.resume(throwing: LanguageServiceError.notReady("stopped")) }
        pending = [:]
    }

    func request(_ op: String, _ args: [String: Any], timeout: Double = 60) async throws -> Any? {
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

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
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
}

/// WebKit keeps its script message handlers strongly; this breaks the cycle.
final class WeakHandler: NSObject, WKScriptMessageHandler {
    weak var target: (any WKScriptMessageHandler)?
    init(_ target: any WKScriptMessageHandler) { self.target = target }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(controller, didReceive: message)
    }
}
