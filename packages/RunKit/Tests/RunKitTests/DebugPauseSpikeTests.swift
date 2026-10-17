// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing
import WebKit

/// Spike (PLAN.md §5.3, the JS/TS debugger): a worker can *block* on a custom-scheme request that the
/// app holds open and answers later, which is what turns "pause at a breakpoint" into something a
/// single-threaded JavaScript engine can actually do. If this works, the debugger is a matter of
/// instrumenting hooks around it; if it doesn't, stepping needs a different primitive.
extension WebKitSuites {
@MainActor
struct DebugPauseSpikeTests {
    /// Serves three URLs and parks `/pause` until the test answers it.
    final class Handler: NSObject, WKURLSchemeHandler {
        var parked: (any WKURLSchemeTask)?
        var answered = false

        func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
            guard let url = task.request.url else { return }
            let respond: (String, String) -> Void = { body, mime in
                let data = Data(body.utf8)
                task.didReceive(HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                                headerFields: ["Content-Type": mime, "Content-Length": String(data.count)])!)
                task.didReceive(data)
                task.didFinish()
            }
            switch url.path {
            case "/page.html":
                respond(#"""
                    <!doctype html><meta charset="utf-8"><body><script>
                    const worker = new Worker("spike://local/worker.js");
                    worker.onmessage = (e) => window.webkit.messageHandlers.run.postMessage({ type: "done", text: e.data.text });
                    worker.onerror = (e) => window.webkit.messageHandlers.run.postMessage({ type: "done", text: "worker error: " + e.message });
                    </script>
                    """#, "text/html")
            case "/worker.js":
                respond(#"""
                    // A synchronous XHR blocks this worker until the app answers the parked request.
                    const xhr = new XMLHttpRequest();
                    xhr.open("GET", "spike://local/pause?line=3", false);
                    xhr.send();
                    postMessage({ text: xhr.responseText });
                    """#, "text/javascript")
            case "/pause":
                parked = task   // held: the test answers it below
            default:
                respond("missing", "text/plain")
            }
        }

        func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}

        /// Answers the parked pause with the action the app chose.
        func resume(_ action: String) {
            guard let task = parked, !answered, let url = task.request.url else { return }
            answered = true
            parked = nil
            let data = Data(action.utf8)
            task.didReceive(HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                            headerFields: ["Content-Type": "text/plain", "Content-Length": String(data.count)])!)
            task.didReceive(data)
            task.didFinish()
        }
    }

    @Test func aWorkerBlocksOnAHeldPauseUntilTheAppAnswers() async throws {
        let handler = Handler()
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(handler, forURLScheme: "spike")
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 320, height: 240), configuration: config)

        let spinner = MessageSpy()
        config.userContentController.add(spinner, name: "run")
        webView.load(URLRequest(url: URL(string: "spike://local/page.html")!))

        // The pause arrives once the worker blocks on it.
        var parked = false
        for _ in 0..<300 where !parked {
            try? await Task.sleep(for: .milliseconds(20))
            parked = handler.parked != nil
        }
        #expect(parked, "the worker never blocked on the pause")
        #expect(spinner.value == nil, "the worker should still be blocked")

        // Answer it, a beat later: the worker must come back with the response.
        try? await Task.sleep(for: .milliseconds(150))
        handler.resume("stepOver")

        var done: String?
        for _ in 0..<300 where done == nil {
            try? await Task.sleep(for: .milliseconds(20))
            done = spinner.value
        }
        #expect(done == "stepOver", "the worker didn't resume with the action (got \(done ?? "nil"))")
    }

    /// The harness's message channel: the page's `run` messages.
    @MainActor
    final class MessageSpy: NSObject, WKScriptMessageHandler {
        var value: String?
        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            value = (message.body as? [String: Any])?["text"] as? String ?? ""
        }
    }
}
}
