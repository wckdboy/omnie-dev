// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Cached npm packages as browser modules: an import map for a project, file resolution the way
/// bundlers do it, and CommonJS wrapped as ES modules (with named exports found statically).
enum NpmModules {
    static let base = "omnie-run://local/__omnie/npm/"

    struct Chosen: Hashable { let name: String; let version: String }

    /// The packages a project gets: its own dependencies at the best cached versions, then theirs.
    /// One version per name (the first found), like a flat node_modules.
    static func resolve(project: URL, cache: URL) -> [Chosen] {
        var chosen: [String: Chosen] = [:]
        var order: [Chosen] = []
        var queue = NpmCache.projectDependencies(project)
        while !queue.isEmpty {
            let (name, range) = queue.removeFirst()
            guard chosen[name] == nil, let version = NpmCache.best(name, range: range, in: cache) else { continue }
            let pick = Chosen(name: name, version: version.description)
            chosen[name] = pick
            order.append(pick)
            let manifest = NpmCache.packageJSON(NpmCache.folder(cache, name, pick.version))
            queue += (manifest?["dependencies"] as? [String: String] ?? [:]).sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
        }
        return order
    }

    static func importMap(project: URL, cache: URL) -> [String: String] {
        var map: [String: String] = [:]
        for pick in resolve(project: project, cache: cache) {
            let folder = NpmCache.folder(cache, pick.name, pick.version)
            let manifest = NpmCache.packageJSON(folder) ?? [:]
            let prefix = base + pick.name + "/" + pick.version + "/"
            if let entry = entry(manifest, subpath: ".", folder: folder) { map[pick.name] = prefix + entry }
            map[pick.name + "/"] = prefix
            // Explicit subpath exports ("pkg/client"); wildcards fall back to the folder.
            if let exports = manifest["exports"] as? [String: Any] {
                for key in exports.keys where key.hasPrefix("./") && key != "./" && !key.contains("*") {
                    if let target = entry(manifest, subpath: key, folder: folder) { map[pick.name + "/" + key.dropFirst(2)] = prefix + target }
                }
            }
        }
        return map
    }

    /// The file a package's subpath ("." or "./x") points at, relative to its folder.
    static func entry(_ manifest: [String: Any], subpath: String, folder: URL) -> String? {
        if let exports = manifest["exports"] {
            var target: Any? = nil
            if let map = exports as? [String: Any], map.keys.contains(where: { $0.hasPrefix(".") }) { target = map[subpath] }
            else if subpath == "." { target = exports }
            if let target, let path = condition(target) { return clean(path, folder: folder) }
            if subpath != "." { return nil }
        }
        guard subpath == "." else { return clean(subpath, folder: folder) }
        for key in ["module", "main"] { if let path = manifest[key] as? String, let found = clean(path, folder: folder) { return found } }
        if let browser = manifest["browser"] as? String, let found = clean(browser, folder: folder) { return found }
        return clean("index.js", folder: folder)
    }

    /// Picks from conditional exports the way a browser bundler does.
    static func condition(_ value: Any) -> String? {
        if let path = value as? String { return path }
        if let list = value as? [Any] { return list.lazy.compactMap(condition).first }
        guard let map = value as? [String: Any] else { return nil }
        for key in ["browser", "import", "module", "default"] { if let v = map[key], let path = condition(v) { return path } }
        return nil
    }

    static func clean(_ path: String, folder: URL) -> String? {
        var p = path
        while p.hasPrefix("./") { p.removeFirst(2) }
        return file(p, in: folder)
    }

    /// Node's resolution for a path inside a package: as is, with an extension, or a folder's index
    /// (or its package.json main).
    static func file(_ path: String, in folder: URL) -> String? {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        func isFile(_ p: String) -> Bool { fm.fileExists(atPath: folder.appending(path: p).path, isDirectory: &isDirectory) && !isDirectory.boolValue }
        let p = path.hasSuffix("/") ? String(path.dropLast()) : path
        if !p.isEmpty, isFile(p) { return p }
        for ext in [".js", ".mjs", ".cjs", ".json"] where isFile(p + ext) { return p + ext }
        let prefix = p.isEmpty ? "" : p + "/"
        if let main = NpmCache.packageJSON(folder.appending(path: p))?["main"] as? String, let found = file(prefix + main, in: folder) { return found }
        for index in ["index.js", "index.mjs", "index.cjs", "index.json"] where isFile(prefix + index) { return prefix + index }
        return nil
    }

    // MARK: Serving

    /// A cached file as the browser should get it. `path` is "<name>/<version>/<file>".
    static func body(path: String, cache: URL, project: URL) -> (Data, String)? {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        let nameLength = parts.first?.hasPrefix("@") == true ? 2 : 1
        guard parts.count > nameLength + 1 else { return nil }
        let name = parts[0..<nameLength].joined(separator: "/")
        let version = parts[nameLength]
        let folder = NpmCache.folder(cache, name, version)
        let inner = parts[(nameLength + 1)...].joined(separator: "/").removingPercentEncoding ?? ""
        guard Semver(version) != nil, !inner.split(separator: "/").contains(".."),
              let found = file(inner, in: folder), let data = try? Data(contentsOf: folder.appending(path: found)) else { return nil }
        let ext = (found as NSString).pathExtension.lowercased()
        if ext == "json" { return (Data("export default \(String(decoding: data, as: UTF8.self));".utf8), "text/javascript") }
        guard ["js", "mjs", "cjs"].contains(ext) else {
            return (data, SchemeHandler.mimeTypes[ext] ?? "application/octet-stream")
        }
        var source = String(decoding: data, as: UTF8.self).replacingOccurrences(of: "process.env.NODE_ENV", with: "\"production\"")
        if ext == "cjs" || (ext == "js" && isCommonJS(source)) {
            let available = Set(importMap(project: project, cache: cache).keys)
            source = wrapCommonJS(source, file: found, folder: folder, available: available, prefix: base + name + "/" + version + "/")
        }
        // Served at the requested URL: if resolution added an extension or index, re-export from
        // the real file so its own relative imports resolve from the right place.
        if found != inner {
            let url = base + name + "/" + version + "/" + found
            source = "export * from \(SchemeHandler.jsString(url));\nexport { default } from \(SchemeHandler.jsString(url));\n"
            if !(ext == "cjs" || (ext == "js" && isCommonJS(String(decoding: data, as: UTF8.self)))),
               !String(decoding: data, as: UTF8.self).contains("export default") {
                source = "export * from \(SchemeHandler.jsString(url));\n"
            }
        }
        return (Data(source.utf8), "text/javascript")
    }

    static func isCommonJS(_ source: String) -> Bool {
        let esm = source.contains(/(^|\n|;)\s*(import\s*[{*"']|import\s+[\w$]|export\s*[{*]|export\s+[\w$])/)
        return !esm && (source.contains("require(") || source.contains("module.exports") || source.contains("exports."))
    }

    static let builtins: Set<String> = ["fs", "path", "os", "crypto", "util", "events", "stream", "buffer", "url", "assert",
                                        "http", "https", "zlib", "child_process", "tty", "net", "worker_threads", "module", "vm"]

    /// CommonJS as an ES module: each `require("x")` with a literal becomes a hoisted import, the
    /// body runs with `module`, `exports` and `require` in scope, and the exports it can see
    /// statically become named exports.
    static func wrapCommonJS(_ source: String, file: String, folder: URL, available: Set<String>, prefix: String) -> String {
        var imports: [String] = []
        var table: [String] = []
        var seen: Set<String> = []
        for match in source.matches(of: /require\(\s*["']([^"'\n]+)["']\s*\)/) {
            let specifier = String(match.1)
            guard seen.insert(specifier).inserted else { continue }
            var target: String?
            if specifier.hasPrefix(".") {
                let joined = ((file as NSString).deletingLastPathComponent as NSString).appendingPathComponent(specifier)
                if let found = self.file((joined as NSString).standardizingPath, in: folder) { target = prefix + found }
            } else if !builtins.contains(specifier), !specifier.hasPrefix("node:") {
                let packageName = specifier.hasPrefix("@") ? specifier.split(separator: "/").prefix(2).joined(separator: "/") : String(specifier.split(separator: "/")[0])
                if available.contains(specifier) || available.contains(packageName + "/") { target = specifier }
            }
            guard let target else { continue }
            let alias = "__r\(table.count)"
            imports.append("import * as \(alias) from \(SchemeHandler.jsString(target));")
            table.append("\(SchemeHandler.jsString(specifier)): \(alias)")
        }
        let names = exportNames(source, file: file, folder: folder, depth: 0)
            .filter { $0.range(of: #"^[A-Za-z_$][\w$]*$"#, options: .regularExpression) != nil && !reserved.contains($0) }
            .sorted()
        var out = imports.joined(separator: "\n") + "\n"
        out += """
            const __mods = { \(table.joined(separator: ", ")) };
            const __process = globalThis.process ?? { env: { NODE_ENV: "production" }, browser: true, version: "", versions: {}, platform: "browser", cwd: () => "/", nextTick: (f, ...a) => queueMicrotask(() => f(...a)) };
            function __require(s) {
              if (s in __mods) { const m = __mods[s]; return m && "__cjs" in m ? m.__cjs : m; }
              if (s.startsWith("node:") || \(SchemeHandler.jsString(builtins.sorted().joined(separator: ","))).split(",").includes(s)) return {};
              throw new Error("Cannot find module '" + s + "' (not in the offline package cache)");
            }
            const module = { exports: {} };
            (function (module, exports, require, process, global) {
            \(source)
            }).call(module.exports, module, module.exports, __require, __process, globalThis);
            const __exports = module.exports;
            export const __cjs = __exports;
            export default (__exports && __exports.__esModule && "default" in __exports) ? __exports.default : __exports;

            """
        if !names.isEmpty {
            out += "const { " + names.enumerated().map { "\($1): __e\($0)" }.joined(separator: ", ") + " } = __exports ?? {};\n"
            out += "export { " + names.enumerated().map { "__e\($0) as \($1)" }.joined(separator: ", ") + " };\n"
        }
        return out
    }

    static let reserved: Set<String> = ["default", "__cjs", "__esModule", "break", "case", "catch", "class", "const", "continue", "debugger",
                                        "delete", "do", "else", "enum", "export", "extends", "false", "finally", "for", "function", "if",
                                        "import", "in", "instanceof", "new", "null", "return", "super", "switch", "this", "throw", "true",
                                        "try", "typeof", "var", "void", "while", "with", "yield", "let", "static", "await", "implements",
                                        "interface", "package", "private", "protected", "public", "arguments", "eval"]

    /// The names a CommonJS module exports, as far as a static read can tell.
    static func exportNames(_ source: String, file: String, folder: URL, depth: Int) -> Set<String> {
        var names: Set<String> = []
        for m in source.matches(of: /(?:module\.)?exports\.([A-Za-z_$][\w$]*)\s*=[^=]/) { names.insert(String(m.1)) }
        for m in source.matches(of: /exports\[\s*["']([^"']+)["']\s*\]\s*=[^=]/) { names.insert(String(m.1)) }
        for m in source.matches(of: /Object\.defineProperty\(\s*(?:module\.)?exports\s*,\s*["']([^"']+)["']/) { names.insert(String(m.1)) }
        // esbuild's CJS output: __export(target, { name: () => name, ... }).
        for m in source.matches(of: /__export\(\s*\w+\s*,\s*\{([^}]*)\}/) {
            for n in String(m.1).matches(of: /([A-Za-z_$][\w$]*)\s*:\s*\(\)\s*=>/) { names.insert(String(n.1)) }
        }
        // module.exports = { a, b: c, d() {} }
        if let m = source.firstMatch(of: /module\.exports\s*=\s*\{/) {
            var depthCount = 0, token = "", atKey = true
            for c in source[m.range.upperBound...] {
                let identifier = c.isLetter || c.isNumber || c == "_" || c == "$"
                if depthCount == 0, atKey, !identifier, !token.isEmpty { names.insert(token); atKey = false }
                if c == "{" || c == "(" || c == "[" { depthCount += 1; atKey = false; continue }
                if c == "}" || c == ")" || c == "]" { if depthCount == 0 { break }; depthCount -= 1; continue }
                guard depthCount == 0 else { continue }
                if c == "," { atKey = true; token = ""; continue }
                if atKey, identifier { token.append(c) }
            }
            if atKey, !token.isEmpty { names.insert(token) }
        }
        // Re-exports: module.exports = require("./x"), __exportStar(require("./x"), exports).
        guard depth < 4 else { return names }
        var targets: [String] = []
        for m in source.matches(of: /module\.exports\s*=\s*require\(\s*["']([^"']+)["']\s*\)/) { targets.append(String(m.1)) }
        for m in source.matches(of: /__exportStar\(\s*require\(\s*["']([^"']+)["']\s*\)/) { targets.append(String(m.1)) }
        for m in source.matches(of: /__reExport\(\s*\w+\s*,\s*require\(\s*["']([^"']+)["']\s*\)/) { targets.append(String(m.1)) }
        for target in targets where target.hasPrefix(".") {
            let joined = (((file as NSString).deletingLastPathComponent as NSString).appendingPathComponent(target) as NSString).standardizingPath
            if let found = self.file(joined, in: folder), let text = try? String(contentsOf: folder.appending(path: found), encoding: .utf8) {
                names.formUnion(exportNames(text, file: found, folder: folder, depth: depth + 1))
            }
        }
        return names
    }
}
