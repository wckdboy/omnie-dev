// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

import Foundation
import WebKit

/// A live preview of a web project (PLAN.md §8, Preview): its pages served from the project with
/// TypeScript transpiled on the fly, like a dev server without the build step. Same sandbox as
/// runs: read-only files, no network (connect-src 'none'), a throwaway data store.
@MainActor
public enum Preview {
    /// The page to open: index.html at the root, in public/ or in src/.
    public nonisolated static func entry(in root: URL) -> String? {
        ["index.html", "public/index.html", "src/index.html"].first {
            FileManager.default.fileExists(atPath: root.appendingPathComponent($0).path)
        }
    }

    /// The Markdown preview of a file in the project.
    public static func markdownURL(for file: String) -> URL {
        var components = URLComponents(string: "\(JSRunner.scheme)://local/__omnie/runtime/markdown.html")!
        components.queryItems = [URLQueryItem(name: "file", value: file)]
        return components.url!
    }

    public nonisolated static func isMarkdown(_ path: String) -> Bool {
        ["md", "markdown", "mdx"].contains((path as NSString).pathExtension.lowercased())
    }

    public static func url(for page: String) -> URL {
        URL(string: "\(JSRunner.scheme)://local/\(page)")!
    }

    /// A web view configuration serving `root`. `onConsole` gets (level, text) for everything the
    /// page logs, and uncaught errors as "error".
    public static func configuration(root: URL, onConsole: @escaping @MainActor (String, String) -> Void) throws -> WKWebViewConfiguration {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.setURLSchemeHandler(SchemeHandler(resolver: ModuleResolver(root: root), transpiler: try Transpiler()),
                                   forURLScheme: JSRunner.scheme)
        let relay = ConsoleRelay(onConsole)
        config.userContentController.add(relay, name: "omnieConsole")
        config.userContentController.addUserScript(WKUserScript(source: consoleScript, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        return config
    }

    static let consoleScript = """
        (() => {
          const send = (level, args) => {
            try { window.webkit.messageHandlers.omnieConsole.postMessage({ level, text: args.map((a) => {
              if (typeof a === "string") return a;
              if (a instanceof Error) return a.name + ": " + a.message;
              try { return JSON.stringify(a); } catch { return String(a); }
            }).join(" ") }); } catch {}
          };
          for (const level of ["log", "info", "warn", "error", "debug"]) {
            const original = console[level].bind(console);
            console[level] = (...args) => { send(level, args); original(...args); };
          }
          addEventListener("error", (e) => send("error", [`${e.message} (${(e.filename || "").replace("omnie-run://local/", "")}:${e.lineno || "?"})`]));
          addEventListener("unhandledrejection", (e) => send("error", ["Unhandled rejection:", e.reason]));
        })();
        """

    final class ConsoleRelay: NSObject, WKScriptMessageHandler {
        let handler: @MainActor (String, String) -> Void
        init(_ handler: @escaping @MainActor (String, String) -> Void) { self.handler = handler }
        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any] else { return }
            let level = body["level"] as? String ?? "log", text = body["text"] as? String ?? ""
            MainActor.assumeIsolated { handler(level, text) }
        }
    }
}
