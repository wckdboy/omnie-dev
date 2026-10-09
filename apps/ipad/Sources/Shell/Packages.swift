// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

import Foundation
import RunKit

/// The npm tier of the offline package cache, for the terminal and Prepare for offline. Fetching
/// is a package install from the network, so it asks first (and plane mode refuses it).
@MainActor
enum Packages {
    static var root: URL { AppPaths.support.appendingPathComponent("packages/npm", isDirectory: true) }

    static let cache = NpmCache(root: root) { url in
        let (data, response) = try await URLSession.shared.data(from: url)
        if (response as? HTTPURLResponse)?.statusCode == 404 { throw URLError(.fileDoesNotExist) }
        return data
    }

    /// Previews, runs and tests read the cache from here.
    static func activate() { NpmCache.sharedRoot = root }

    /// "react", "zod@^3", "@scope/pkg@1.2" → (name, range).
    static func parse(_ spec: String) -> (String, String) {
        let scoped = spec.hasPrefix("@")
        let body = scoped ? String(spec.dropFirst()) : spec
        guard let at = body.lastIndex(of: "@") else { return (spec, "latest") }
        let name = (scoped ? "@" : "") + body[..<at]
        let range = String(body[body.index(after: at)...])
        return (name, range.isEmpty ? "latest" : range)
    }

    /// The terminal's `npm install|ls`.
    static func command(_ args: [String], root project: URL, workspace: WorkspaceModel) async -> String {
        if args.first == "ls" { return list(project) }
        let specs = Array(args.dropFirst())
        let wanted = specs.isEmpty ? NpmCache.projectDependencies(project).map { "\($0.0)@\($0.1)" } : specs
        if wanted.isEmpty { return "package.json lists no dependencies. Try npm install <name>." }
        // Already cached: no network, no question.
        // git:, file:, workspace: and URL dependencies aren't on the registry.
        let fromRegistry = wanted.map(parse).filter { !$0.1.contains(":") && !$0.1.contains("/") }
        let missing = fromRegistry.filter { NpmCache.best($0.0, range: $0.1, in: root) == nil }
        var lines: [String] = []
        if !missing.isEmpty {
            let names = missing.map(\.0).joined(separator: ", ")
            guard await workspace.policy.authorize(.installPackage(name: names, fromNetwork: true)) else {
                return "Not installed: fetching packages needs the network and your OK" + (workspace.policy.planeMode ? " (plane mode is on)." : ".")
            }
            do {
                for (name, range) in missing {
                    let added = try await cache.install(name, range: range)
                    lines += added.map { "+ \($0.name)@\($0.version)" }
                }
            } catch {
                return (lines + [error.localizedDescription]).joined(separator: "\n")
            }
        }
        if !specs.isEmpty {
            workspace.saveCurrent()
            for (name, range) in specs.map(parse) {
                guard let version = NpmCache.best(name, range: range == "latest" ? "*" : range, in: root) else { continue }
                let saved = range == "latest" ? "^\(version)" : range
                do { if try addDependency(name, range: saved, to: project) { lines.append("package.json: \(name) \(saved)") } }
                catch { lines.append("Couldn't add \(name) to package.json: \(error.localizedDescription)") }
            }
            workspace.reloadFromDisk()
        }
        lines.append(lines.isEmpty ? "Everything is already in the offline cache." : "Previews, runs and tests import these from the offline cache, with no connection.")
        return lines.joined(separator: "\n")
    }

    static func list(_ project: URL) -> String {
        let wanted = NpmCache.projectDependencies(project)
        guard !wanted.isEmpty else { return "package.json lists no dependencies." }
        return wanted.map { name, range in
            if let v = NpmCache.best(name, range: range, in: root) { return "\(name)@\(v)  (\(range))" }
            return "\(name)  (\(range))  not cached: npm install fetches it"
        }.joined(separator: "\n")
    }

    /// Adds `"name": "range"` to package.json's dependencies as a text edit, so the file's own
    /// order and formatting stay.
    /// Returns false when it was already listed.
    @discardableResult
    static func addDependency(_ name: String, range: String, to project: URL) throws -> Bool {
        let url = project.appending(path: "package.json")
        let quotedName = String(data: try JSONEncoder().encode(name), encoding: .utf8)!
        let entry = "\(quotedName): \(String(data: try JSONEncoder().encode(range), encoding: .utf8)!)"
        guard var text = try? String(contentsOf: url, encoding: .utf8) else {
            try "{\n  \"dependencies\": {\n    \(entry)\n  }\n}\n".write(to: url, atomically: true, encoding: .utf8)
            return true
        }
        let manifest = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] ?? [:]
        if let deps = manifest["dependencies"] as? [String: Any], deps[name] != nil {
            // Already listed: leave the user's range alone.
            return false
        }
        if let match = text.firstMatch(of: /"dependencies"\s*:\s*\{/) {
            let after = text[match.range.upperBound...]
            let isEmpty = after.drop { $0.isWhitespace }.first == "}"
            let indent = after.split(separator: "\n", omittingEmptySubsequences: true).first.map { String($0.prefix { $0 == " " || $0 == "\t" }) } ?? "    "
            text.insert(contentsOf: isEmpty ? "\n    \(entry)\n  " : "\n\(indent.isEmpty ? "    " : indent)\(entry),", at: match.range.upperBound)
        } else if let brace = text.firstIndex(of: "{") {
            let isEmpty = text[text.index(after: brace)...].drop { $0.isWhitespace }.first == "}"
            text.insert(contentsOf: "\n  \"dependencies\": {\n    \(entry)\n  }" + (isEmpty ? "\n" : ","), at: text.index(after: brace))
        }
        guard (try? JSONSerialization.jsonObject(with: Data(text.utf8))) != nil else { throw CocoaError(.fileWriteUnknown) }
        try text.write(to: url, atomically: true, encoding: .utf8)
        return true
    }
}
