// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// WASI programs (wasm32-wasip1) on the device (PLAN.md §8, L1 in §25): run in RunKit's sandboxed
/// web view against the project. They read the project's files; what they write, create or
/// delete is applied inside the project when they exit. No sockets, a memory cap and a timeout.
extension JSRunner {
    /// Which directories a WASI program starts with.
    public enum Preopens: String, Sendable {
        /// "." (the working directory) and, without one, "/" (the project).
        case standard
        /// Just "/" for the project (how wasi-testsuite runs).
        case root
        case none
    }

    /// Curated tools RunKit carries, by command name (built by scripts/vendor-runkit.sh).
    public nonisolated static func bundledTools() -> [String] {
        guard let dir = Bundle.module.url(forResource: "wasi", withExtension: nil, subdirectory: "JS/packages"),
              let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return [] }
        return names.filter { $0.hasSuffix(".wasm") }.map { String($0.dropLast(5)) }.sorted()
    }

    /// The project's own tools: `.wasm` files in tools/ or .omnie/tools/, by name → path.
    public nonisolated static func projectTools(in root: URL) -> [String: String] {
        var tools: [String: String] = [:]
        for folder in [".omnie/tools", "tools"] {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: root.appending(path: folder).path)) ?? []
            for name in names where name.hasSuffix(".wasm") { tools[String(name.dropLast(5))] = "\(folder)/\(name)" }
        }
        return tools
    }

    /// The fuel budget per run: one unit per function call or loop iteration, about half a minute
    /// of busy work on an M-series chip. 0 means none (the timeout still applies).
    public nonisolated static let defaultFuel: Int64 = 20_000_000_000

    /// Runs `program`: a `.wasm` path in the project, or the name of a bundled tool.
    public func runWasm(_ program: String, args: [String] = [], stdin: String = "", env: [String: String] = [:],
                        cwd: String = "", timeout: Double = 60, memoryLimitMB: Int = 1024, preopens: Preopens = .standard,
                        fuel: Int64 = defaultFuel) async -> RunResult {
        let isProjectFile = program.hasSuffix(".wasm")
        let moduleURL = isProjectFile
            ? "omnie-run://local/" + program.split(separator: "/").map { $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0) }.joined(separator: "/")
            : "omnie-run://local/__omnie/packages/wasi/\(program).wasm"
        let name = isProjectFile ? ((program as NSString).lastPathComponent as NSString).deletingPathExtension : program
        let spec: [String: Any] = ["module": moduleURL, "args": [name] + args, "env": env, "stdin": stdin, "cwd": cwd, "memoryLimitMB": memoryLimitMB, "preopens": preopens.rawValue, "fuel": fuel]
        let specJSON = String(decoding: try! JSONSerialization.data(withJSONObject: spec), as: UTF8.self)

        let session = Session(root: root, transpiler: transpiler)
        var exit: [String: Any]?
        session.onMessage = { body in if body["type"] as? String == "wasiExit" { exit = body } }
        let start = Date()
        var result = await session.start(query: [URLQueryItem(name: "mode", value: "wasi"), URLQueryItem(name: "spec", value: specJSON)], timeout: timeout)
        result.ms = Int(Date().timeIntervalSince(start) * 1000)
        if let exit {
            result.exitCode = (exit["code"] as? NSNumber)?.int32Value
            result.fuelUsed = (exit["fuelUsed"] as? NSNumber)?.int64Value
            result.memoryPeak = (exit["memoryPeak"] as? NSNumber)?.intValue
            do { result.changedFiles = try Self.apply(exit, to: root) }
            catch { result.output.append(.init(stream: .err, text: "Couldn't save the program's changes: \(error.localizedDescription)")) }
        }
        return result
    }

    /// Writes, creates and deletes what the program changed, refusing anything outside the project.
    nonisolated static func apply(_ exit: [String: Any], to root: URL) throws -> [String] {
        let resolver = ModuleResolver(root: root)
        let fm = FileManager.default
        func inside(_ path: String) -> URL? {
            guard !path.isEmpty, !path.hasPrefix("/"), !path.split(separator: "/").contains(".."),
                  !path.split(separator: "/").contains(".git") else { return nil }
            let url = resolver.root.appending(path: path)
            // The deepest existing ancestor must resolve inside the project (no symlinked escapes).
            var probe = url.deletingLastPathComponent()
            while !fm.fileExists(atPath: probe.path), probe.path.count > resolver.root.path.count { probe = probe.deletingLastPathComponent() }
            let real = ModuleResolver.realPath(probe.path)
            return real == resolver.root.path || real.hasPrefix(resolver.root.path + "/") ? url : nil
        }
        var changed: [String] = []
        for dir in (exit["dirs"] as? [String] ?? []).sorted() {
            guard let url = inside(dir) else { continue }
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
        }
        for (path, base64) in (exit["writes"] as? [String: String] ?? [:]).sorted(by: { $0.key < $1.key }) {
            guard let url = inside(path), let data = Data(base64Encoded: base64) else { continue }
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if (try? Data(contentsOf: url)) != data {
                try data.write(to: url, options: .atomic)
                changed.append(path)
            }
        }
        for path in exit["deletes"] as? [String] ?? [] {
            guard let url = inside(path), fm.fileExists(atPath: url.path) else { continue }
            try fm.removeItem(at: url)
            changed.append(path)
        }
        for dir in (exit["removedDirs"] as? [String] ?? []).sorted(by: >) {
            guard let url = inside(dir), (try? fm.contentsOfDirectory(atPath: url.path))?.isEmpty == true else { continue }
            try fm.removeItem(at: url)
        }
        return changed.sorted()
    }
}
