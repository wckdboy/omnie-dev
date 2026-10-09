// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

import CryptoKit
import Foundation

/// The offline package cache's Python tier (PLAN.md §8). Two sources, both checked by sha256:
/// packages Pyodide builds (numpy, pandas…: its lock file pins each wheel) come from Pyodide's CDN
/// into `<root>/pyodide/`, where Pyodide's own loader finds them; pure-Python wheels from PyPI go
/// into `<root>/wheels/<name>/<version>/`.
public actor PyCache {
    public struct Installed: Hashable, Sendable {
        public let name: String
        public let version: String
    }

    public enum Failure: Error, LocalizedError, Equatable {
        case notFound(String)
        case noWheel(String, String)
        case integrity(String)
        case badMetadata(String)

        public var errorDescription: String? {
            switch self {
            case .notFound(let name): "There's no package \"\(name)\" on PyPI."
            case .noWheel(let name, let spec): "No pure-Python wheel of \(name)\(spec.isEmpty ? "" : " " + spec) (packages with compiled code work only if Pyodide builds them)."
            case .integrity(let name): "\(name) doesn't match its published checksum, so it wasn't installed."
            case .badMetadata(let name): "PyPI's answer for \(name) couldn't be read."
            }
        }
    }

    public typealias Fetch = @Sendable (URL) async throws -> Data

    public nonisolated let root: URL
    let fetch: Fetch
    let pypi: URL
    let pyodideCDN: URL
    static let marker = ".omnie-pypi.json"

    public init(root: URL, pypi: URL = URL(string: "https://pypi.org/pypi")!,
                pyodideCDN: URL = URL(string: "https://cdn.jsdelivr.net/pyodide/v314.0.7/full")!, fetch: @escaping Fetch) {
        self.root = root
        self.pypi = pypi
        self.pyodideCDN = pyodideCDN
        self.fetch = fetch
    }

    public nonisolated(unsafe) static var sharedRoot: URL?

    // MARK: Pyodide's lock

    struct LockPackage: Sendable { let name: String; let version: String; let file: String; let sha256: String; let depends: [String] }

    /// Pyodide's own packages, by normalized name.
    static let lock: [String: LockPackage] = {
        guard let url = Bundle.module.url(forResource: "pyodide-lock", withExtension: "json", subdirectory: "JS/pyodide"),
              let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let packages = json["packages"] as? [String: [String: Any]] else { return [:] }
        var out: [String: LockPackage] = [:]
        for (key, p) in packages {
            guard let file = p["file_name"] as? String, let sha = p["sha256"] as? String else { continue }
            let name = PyRequirement.normalize(p["name"] as? String ?? key)
            out[name] = LockPackage(name: name, version: p["version"] as? String ?? "", file: file, sha256: sha,
                                    depends: (p["depends"] as? [String] ?? []).map(PyRequirement.normalize))
        }
        return out
    }()

    // MARK: Installing

    @discardableResult
    public func install(_ requirement: PyRequirement, progress: @Sendable (String) -> Void = { _ in }) async throws -> [Installed] {
        var installed: [Installed] = []
        var queue = [requirement]
        var seen: Set<String> = []
        while !queue.isEmpty {
            let req = queue.removeFirst()
            guard req.appliesHere, seen.insert(req.name + req.specifier).inserted else { continue }
            if let pkg = Self.lock[req.name] {
                // Pyodide's build: one version, and its own dependency list.
                let target = root.appending(path: "pyodide").appending(path: pkg.file)
                if !FileManager.default.fileExists(atPath: target.path) {
                    progress("Fetching \(pkg.name) \(pkg.version) (Pyodide build)")
                    let data = try await fetch(pyodideCDN.appending(path: pkg.file))
                    guard Self.sha256(data) == pkg.sha256 else { throw Failure.integrity("\(pkg.name) \(pkg.version)") }
                    try write(data, to: target)
                    installed.append(Installed(name: pkg.name, version: pkg.version))
                }
                queue += pkg.depends.compactMap { PyRequirement($0) }
                continue
            }
            let version: String
            if let cached = Self.best(req.name, specifier: req.specifier, in: root) {
                version = cached.text
            } else {
                progress("Fetching \(req.name)\(req.specifier)")
                version = try await download(req)
                installed.append(Installed(name: req.name, version: version))
            }
            queue += Self.requires(req.name, version, in: root).compactMap(PyRequirement.init)
        }
        return installed
    }

    @discardableResult
    public func installProject(_ project: URL, progress: @Sendable (String) -> Void = { _ in }) async throws -> [Installed] {
        var installed: [Installed] = []
        for req in Self.projectRequirements(project) { installed += try await install(req, progress: progress) }
        return installed
    }

    private func download(_ req: PyRequirement) async throws -> String {
        guard let spec = PySpecifier(req.specifier) else { throw Failure.noWheel(req.name, req.specifier) }
        let meta = try await json(pypi.appending(path: req.name).appending(path: "json"), name: req.name)
        guard let releases = meta["releases"] as? [String: [[String: Any]]] else { throw Failure.badMetadata(req.name) }
        // Newest matching version that has a pure wheel and isn't yanked.
        let candidates = releases.compactMap { key, files -> (PyVersion, [String: Any])? in
            guard let v = PyVersion(key), spec.contains(v), let wheel = Self.pureWheel(files) else { return nil }
            return (v, wheel)
        }.sorted { $0.0 > $1.0 }
        guard let (version, wheel) = candidates.first, let urlText = wheel["url"] as? String, let url = URL(string: urlText),
              let filename = wheel["filename"] as? String, let sha = (wheel["digests"] as? [String: String])?["sha256"] else {
            throw Failure.noWheel(req.name, req.specifier)
        }
        // The version's own metadata has its dependencies.
        let info = try await json(pypi.appending(path: req.name).appending(path: version.text).appending(path: "json"), name: req.name)
        let requires = ((info["info"] as? [String: Any])?["requires_dist"] as? [String]) ?? []
        let data = try await fetch(url)
        guard Self.sha256(data) == sha.lowercased() else { throw Failure.integrity("\(req.name) \(version.text)") }
        let folder = root.appending(path: "wheels").appending(path: req.name).appending(path: version.text)
        try write(data, to: folder.appending(path: filename))
        let record: [String: Any] = ["name": req.name, "version": version.text, "wheel": filename, "sha256": sha, "requires": requires]
        try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]).write(to: folder.appending(path: Self.marker))
        return version.text
    }

    private func json(_ url: URL, name: String) async throws -> [String: Any] {
        let data: Data
        do { data = try await fetch(url) } catch let error as URLError where error.code == .fileDoesNotExist { throw Failure.notFound(name) }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw Failure.badMetadata(name) }
        if object["message"] as? String == "Not Found" { throw Failure.notFound(name) }
        return object
    }

    static func pureWheel(_ files: [[String: Any]]) -> [String: Any]? {
        files.first { f in
            guard f["packagetype"] as? String == "bdist_wheel", f["yanked"] as? Bool != true,
                  let name = f["filename"] as? String, name.hasSuffix(".whl") else { return false }
            let tags = name.dropLast(4).split(separator: "-")
            guard tags.count >= 5 else { return false }
            let python = tags[tags.count - 3], abi = tags[tags.count - 2], platform = tags[tags.count - 1]
            return platform == "any" && abi == "none" && python.split(separator: ".").contains { $0.hasPrefix("py3") || $0 == "py2.py3" || $0.hasPrefix("py3") }
        }
    }

    private func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        var r = root
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? r.setResourceValues(values)
    }

    static func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    // MARK: Reading the cache

    nonisolated static func record(_ name: String, _ version: String, in root: URL) -> [String: Any]? {
        let url = root.appending(path: "wheels").appending(path: name).appending(path: version).appending(path: marker)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    public nonisolated static func versions(of name: String, in root: URL) -> [PyVersion] {
        let dir = root.appending(path: "wheels").appending(path: name)
        return ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).compactMap { v in
            record(name, v, in: root) != nil ? PyVersion(v) : nil
        }
    }

    public nonisolated static func best(_ name: String, specifier: String, in root: URL) -> PyVersion? {
        PySpecifier(specifier)?.best(of: versions(of: name, in: root))
    }

    static func requires(_ name: String, _ version: String, in root: URL) -> [String] {
        record(name, version, in: root)?["requires"] as? [String] ?? []
    }

    public nonisolated static func isCached(lockPackage name: String, in root: URL) -> Bool {
        guard let pkg = lock[name] else { return false }
        return FileManager.default.fileExists(atPath: root.appending(path: "pyodide").appending(path: pkg.file).path)
    }

    /// From requirements.txt, else pyproject.toml's [project] dependencies.
    public nonisolated static func projectRequirements(_ project: URL) -> [PyRequirement] {
        if let text = try? String(contentsOf: project.appending(path: "requirements.txt"), encoding: .utf8) {
            return text.split(separator: "\n").compactMap { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty, !trimmed.hasPrefix("#"), !trimmed.hasPrefix("-"), !trimmed.contains("://") else { return nil }
                return PyRequirement(trimmed)
            }
        }
        guard let toml = try? String(contentsOf: project.appending(path: "pyproject.toml"), encoding: .utf8),
              let section = toml.firstMatch(of: /(?s)\[project\](.*?)(?:\n\[|\z)/),
              let deps = String(section.1).firstMatch(of: /(?s)\bdependencies\s*=\s*\[(.*?)\]/) else { return [] }
        return String(deps.1).matches(of: /"([^"]+)"|'([^']+)'/).compactMap { PyRequirement(String($0.1 ?? $0.2 ?? "")) }
    }

    /// What a project's Python gets: Pyodide packages to load by name, and wheel paths (relative
    /// to the cache) to load by URL. Only what's cached.
    nonisolated static func resolve(project: URL, cache root: URL) -> (lock: [String], wheels: [String]) {
        var lockNames: [String] = [], wheels: [String] = []
        var seen: Set<String> = []
        var queue = projectRequirements(project)
        while !queue.isEmpty {
            let req = queue.removeFirst()
            guard req.appliesHere, seen.insert(req.name).inserted else { continue }
            if lock[req.name] != nil {
                if isCached(lockPackage: req.name, in: root) { lockNames.append(req.name) }
                // Pyodide loads a lock package's dependencies itself.
                continue
            }
            guard let version = best(req.name, specifier: req.specifier, in: root),
                  let wheel = record(req.name, version.text, in: root)?["wheel"] as? String else { continue }
            wheels.append("\(req.name)/\(version.text)/\(wheel)")
            queue += requires(req.name, version.text, in: root).compactMap(PyRequirement.init)
        }
        return (lockNames, wheels)
    }
}
