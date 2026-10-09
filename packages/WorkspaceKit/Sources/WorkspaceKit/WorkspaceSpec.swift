// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// The workspace spec (PLAN.md §8.2): one file declares the project's environment for both
/// worlds, a `devcontainer.json` subset plus a small `run` section:
///
///     // .devcontainer/devcontainer.json
///     {
///       "image": "mcr.microsoft.com/devcontainers/typescript-node:22",
///       "forwardPorts": [5173],
///       "run": {
///         "tasks": { "dev": "vite", "test": "vitest run", "build": "tsc && vite build" },
///         "network": { "allow": ["api.example.com"] },
///         "deploy": "podman build -t app . && podman run -d app"
///       }
///     }
///
/// Without one, tasks come from package.json's scripts. Each task says where it can run.
public struct WorkspaceSpec: Equatable, Sendable {
    public var image: String?
    /// Task name → command line, in declaration order.
    public var tasks: [(name: String, command: String)]
    public var ports: [Int]
    /// Domains the project may reach without asking (still nothing in plane mode).
    public var allowedDomains: [String]
    public var deploy: String?
    /// The file it came from, relative to the project ("package.json" when derived).
    public var source: String?

    public init(image: String? = nil, tasks: [(name: String, command: String)] = [], ports: [Int] = [],
                allowedDomains: [String] = [], deploy: String? = nil, source: String? = nil) {
        self.image = image; self.tasks = tasks; self.ports = ports
        self.allowedDomains = allowedDomains; self.deploy = deploy; self.source = source
    }

    public static func == (a: Self, b: Self) -> Bool {
        a.image == b.image && a.ports == b.ports && a.allowedDomains == b.allowedDomains && a.deploy == b.deploy
            && a.source == b.source && a.tasks.map { $0.name + "\u{0}" + $0.command } == b.tasks.map { $0.name + "\u{0}" + $0.command }
    }

    public func command(for task: String) -> String? { tasks.first { $0.name == task }?.command }

    public static let specPaths = [".devcontainer/devcontainer.json", ".devcontainer.json"]

    /// The project's spec, or one derived from package.json scripts, or nil.
    public static func load(root: URL) -> WorkspaceSpec? {
        for path in specPaths {
            guard let data = try? Data(contentsOf: root.appending(path: path)),
                  let object = try? JSONSerialization.jsonObject(with: Data(stripJSONC(String(decoding: data, as: UTF8.self)).utf8)) as? [String: Any]
            else { continue }
            var spec = parse(object)
            spec.source = path
            // Tasks the spec doesn't name still come from package.json.
            for (name, command) in packageScripts(root: root) where spec.command(for: name) == nil { spec.tasks.append((name, command)) }
            return spec
        }
        let scripts = packageScripts(root: root)
        return scripts.isEmpty ? nil : WorkspaceSpec(tasks: scripts, source: "package.json")
    }

    static func parse(_ object: [String: Any]) -> WorkspaceSpec {
        var spec = WorkspaceSpec()
        spec.image = object["image"] as? String
        spec.ports = (object["forwardPorts"] as? [Any] ?? []).compactMap { ($0 as? Int) ?? ($0 as? String).flatMap { Int($0.split(separator: ":").last ?? "") } }
        if let run = object["run"] as? [String: Any] {
            if let tasks = run["tasks"] as? [String: Any] {
                // JSONSerialization loses key order; dev, test, build first, then the rest by name.
                let order = ["dev", "start", "test", "build"]
                let names = tasks.keys.sorted { (order.firstIndex(of: $0) ?? 99, $0) < (order.firstIndex(of: $1) ?? 99, $1) }
                spec.tasks = names.compactMap { name in (tasks[name] as? String).map { (name, $0) } }
            }
            spec.allowedDomains = ((run["network"] as? [String: Any])?["allow"] as? [String] ?? []).map { $0.lowercased() }
            spec.deploy = run["deploy"] as? String
        }
        return spec
    }

    static func packageScripts(root: URL) -> [(name: String, command: String)] {
        guard let data = try? Data(contentsOf: root.appending(path: "package.json")),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let scripts = object["scripts"] as? [String: String] else { return [] }
        let order = ["dev", "start", "test", "build"]
        return scripts.keys.sorted { (order.firstIndex(of: $0) ?? 99, $0) < (order.firstIndex(of: $1) ?? 99, $1) }.map { ($0, scripts[$0]!) }
    }

    /// devcontainer.json is JSON with comments and trailing commas.
    static func stripJSONC(_ text: String) -> String {
        var out = ""
        var i = text.startIndex
        var inString = false
        while i < text.endIndex {
            let c = text[i]
            let next = text.index(after: i) < text.endIndex ? text[text.index(after: i)] : "\0"
            if inString {
                out.append(c)
                if c == "\\", next != "\0" { out.append(next); i = text.index(i, offsetBy: 2); continue }
                if c == "\"" { inString = false }
            } else if c == "\"" {
                inString = true; out.append(c)
            } else if c == "/", next == "/" {
                while i < text.endIndex, text[i] != "\n" { i = text.index(after: i) }
                continue
            } else if c == "/", next == "*" {
                i = text.index(i, offsetBy: 2)
                while i < text.endIndex, !(text[i] == "*" && text.index(after: i) < text.endIndex && text[text.index(after: i)] == "/") { i = text.index(after: i) }
                i = text.index(i, offsetBy: 2, limitedBy: text.endIndex) ?? text.endIndex
                continue
            } else {
                out.append(c)
            }
            i = text.index(after: i)
        }
        return out.replacing(/,(\s*[}\]])/) { String($0.1) }
    }

    // MARK: Where a task runs

    public enum Backend: Equatable, Sendable {
        /// On the iPad: RunKit (JS/TS, Python, WASI) or a built-in.
        case device
        /// Needs a real container or a native toolchain: the remote host (P4), or "Queue for when online".
        case remote(reason: String)
    }

    /// Commands that run on the device, by their first word.
    static let deviceCommands: Set<String> = [
        "node", "tsx", "ts-node", "deno", "bun", "vite", "vitest", "jest", "python", "python3", "pytest", "jq",
        "echo", "ls", "cat", "grep", "test", "run", "tsc", "npm", "npx", "pnpm", "yarn", "pip", "pip3",
    ]

    /// Where a task's command can run. Every part of `a && b` must run here for it to.
    public static func backend(for command: String) -> Backend {
        for part in command.components(separatedBy: "&&").map({ $0.trimmingCharacters(in: .whitespaces) }) where !part.isEmpty {
            var words = part.split(separator: " ").map(String.init)
            while let first = words.first, first.contains("="), !first.hasPrefix("-") { words.removeFirst() }  // FOO=bar cmd
            guard let first = words.first else { continue }
            if first == "npx", words.count > 1 { words.removeFirst() }  // npx vitest → vitest
            let tool = words.first ?? first
            if tool.hasSuffix(".wasm") || tool.hasPrefix("./") { continue }
            if !deviceCommands.contains(tool) {
                return .remote(reason: "\(tool) needs a real toolchain or container")
            }
            if ["build"].contains(words.dropFirst().first ?? "") && tool == "vite" {
                return .remote(reason: "vite build bundles with Rollup and esbuild's native binary")
            }
        }
        return .device
    }
}
