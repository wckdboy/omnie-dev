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
        components.setQueryForJS([URLQueryItem(name: "file", value: file)])
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
        let handler = SchemeHandler(resolver: ModuleResolver(root: root), transpiler: try Transpiler())
        // Every request the page makes, for DevTools-lite's network log (as "network" JSON).
        handler.onRequest = { entry in
            if let data = try? JSONEncoder().encode(entry) { onConsole("network", String(decoding: data, as: UTF8.self)) }
        }
        config.setURLSchemeHandler(handler, forURLScheme: JSRunner.scheme)
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

          // DevTools-lite, network: the scheme handler reports every request it serves; what never
          // reaches it (anything on the internet) is reported here, blocked.
          const net = (entry) => { try { window.webkit.messageHandlers.omnieConsole.postMessage({ level: "network", text: JSON.stringify(entry) }); } catch {} };
          const originalFetch = window.fetch.bind(window);
          window.fetch = async (input, init) => {
            try { return await originalFetch(input, init); } catch (e) {
              const url = String(typeof input === "string" ? input : input.url);
              if (!url.startsWith("omnie-run:") && !url.startsWith("/")) {
                net({ kind: "fetch", method: (init?.method || input?.method || "GET").toUpperCase(), url, status: 0, ms: 0, error: "blocked: the preview has no network" });
              }
              throw e;
            }
          };

          // The profiler: the page's own performance.measure()s.
          try {
            new PerformanceObserver((list) => {
              for (const e of list.getEntries()) {
                try { window.webkit.messageHandlers.omnieConsole.postMessage({ level: "perf", text: JSON.stringify({ name: e.name, ms: Math.round(e.duration * 10) / 10, start: Math.round(e.startTime) }) }); } catch {}
              }
            }).observe({ type: "measure", buffered: true });
          } catch {}

          // DevTools-lite, elements: an outline of the DOM, and an inspector that outlines one node.
          window.__omnieDOM = () => {
            let count = 0;
            const walk = (el, path) => {
              if (count++ > 800) return null;
              const children = [...el.children].filter((c) => c.id !== "__omnie-highlight");
              return { tag: el.tagName.toLowerCase(), id: el.id || "", cls: [...el.classList].slice(0, 4).join(" "),
                       text: children.length ? "" : (el.textContent || "").trim().replace(/\\s+/g, " ").slice(0, 40),
                       path, children: children.map((c, i) => walk(c, path.concat(i))).filter(Boolean) };
            };
            return JSON.stringify(walk(document.documentElement, []));
          };
          window.__omnieInspect = (path) => {
            let el = document.documentElement;
            for (const i of path || []) { const kids = [...el.children].filter((c) => c.id !== "__omnie-highlight"); el = kids[i]; if (!el) return null; }
            let box = document.getElementById("__omnie-highlight");
            if (!box) {
              box = document.createElement("div");
              box.id = "__omnie-highlight";
              box.style.cssText = "position:fixed;pointer-events:none;z-index:2147483647;outline:2px solid #5ad1e6;background:rgba(90,209,230,0.15);transition:all 80ms";
              document.documentElement.appendChild(box);
            }
            const r = el.getBoundingClientRect();
            Object.assign(box.style, { left: r.left + "px", top: r.top + "px", width: r.width + "px", height: r.height + "px", display: "block" });
            el.scrollIntoView?.({ block: "nearest" });
            const cs = getComputedStyle(el);
            return JSON.stringify({ tag: el.tagName.toLowerCase(), width: Math.round(r.width), height: Math.round(r.height),
              display: cs.display, position: cs.position, font: cs.fontSize + " " + cs.fontFamily.split(",")[0], color: cs.color,
              background: cs.backgroundColor, margin: cs.margin, padding: cs.padding,
              attributes: Object.fromEntries([...el.attributes].slice(0, 12).map((a) => [a.name, a.value.slice(0, 80)])) });
          };
          window.__omnieInspectClear = () => { const box = document.getElementById("__omnie-highlight"); if (box) box.style.display = "none"; };
        })();
        """

    // MARK: DevTools-lite

    /// One request the page made.
    public struct NetworkEntry: Codable, Sendable, Equatable, Identifiable {
        public var id: String { "\(kind) \(method) \(url) \(ms)" }
        public let kind: String
        public let method: String
        public let url: String
        public let status: Int
        public let ms: Int
        public var mock: Bool?
        public var bytes: Int?
        public var error: String?

        public init(kind: String, method: String, url: String, status: Int, ms: Int, mock: Bool? = nil, bytes: Int? = nil, error: String? = nil) {
            self.kind = kind; self.method = method; self.url = url; self.status = status; self.ms = ms
            self.mock = mock; self.bytes = bytes; self.error = error
        }

        /// What kind of load a path is, from its extension.
        static func kind(for path: String) -> String {
            switch (path.split(separator: "?").first.map(String.init) ?? path).split(separator: ".").last.map({ $0.lowercased() }) ?? "" {
            case "js", "mjs", "ts", "tsx", "jsx": "script"
            case "css": "style"
            case "html", "htm": "document"
            case "png", "jpg", "jpeg", "gif", "webp", "svg", "ico": "image"
            case "woff", "woff2", "ttf", "otf": "font"
            case "glb", "gltf", "obj", "stl", "wasm": "binary"
            default: "fetch"
            }
        }
    }

    /// A node of the DOM outline; `path` is child indices from <html>.
    public struct DOMNode: Decodable, Sendable, Equatable {
        public let tag: String
        public let id: String
        public let cls: String
        public let text: String
        public let path: [Int]
        public let children: [DOMNode]

        /// Depth-first, with depth.
        public func flattened(depth: Int = 0) -> [(node: DOMNode, depth: Int)] {
            [(self, depth)] + children.flatMap { $0.flattened(depth: depth + 1) }
        }

        public var summary: String {
            "<\(tag)" + (id.isEmpty ? "" : "#\(id)") + (cls.isEmpty ? "" : "." + cls.replacingOccurrences(of: " ", with: ".")) + ">"
                + (text.isEmpty ? "" : " \(text)")
        }
    }

    public struct ElementInfo: Decodable, Sendable, Equatable {
        public let tag: String
        public let width: Int
        public let height: Int
        public let display: String
        public let position: String
        public let font: String
        public let color: String
        public let background: String
        public let margin: String
        public let padding: String
        public let attributes: [String: String]
    }

    public static let domScript = "window.__omnieDOM?.()"
    public static func inspectScript(_ path: [Int]) -> String { "window.__omnieInspect?.(\(path))" }
    public static let clearInspectScript = "window.__omnieInspectClear?.()"

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
