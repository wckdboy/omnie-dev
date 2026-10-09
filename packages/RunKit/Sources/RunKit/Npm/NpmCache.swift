// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

import CryptoKit
import Foundation

/// The offline package cache's npm tier (PLAN.md §8): packages you prefetch while online, checked
/// against the registry's integrity hash, unpacked under `<root>/<name>/<version>/`, and served to
/// previews, runs and tests through an import map. Shared by every project; re-downloadable, so
/// it lives in Application Support out of backups.
public actor NpmCache {
    public struct Installed: Codable, Hashable, Sendable {
        public let name: String
        public let version: String
    }

    public enum Failure: Error, LocalizedError, Equatable {
        case notFound(String)
        case noMatchingVersion(String, String)
        case integrity(String)
        case badMetadata(String)

        public var errorDescription: String? {
            switch self {
            case .notFound(let name): "There's no package \"\(name)\" on the registry."
            case .noMatchingVersion(let name, let range): "No version of \(name) matches \"\(range)\"."
            case .integrity(let name): "\(name) doesn't match the registry's checksum, so it wasn't installed."
            case .badMetadata(let name): "The registry's answer for \(name) couldn't be read."
            }
        }
    }

    /// Fetches a URL's bytes; the app passes URLSession, tests a local fake. Throwing URLError
    /// `.fileDoesNotExist` (or returning a 404 body) means "no such package".
    public typealias Fetch = @Sendable (URL) async throws -> Data

    public nonisolated let root: URL
    let fetch: Fetch
    let registry: URL
    static let marker = ".omnie-npm.json"

    public init(root: URL, registry: URL = URL(string: "https://registry.npmjs.org")!, fetch: @escaping Fetch) {
        self.root = root
        self.registry = registry
        self.fetch = fetch
    }

    /// Where previews look, set once by the app at launch.
    public nonisolated(unsafe) static var sharedRoot: URL?

    // MARK: Installing

    /// Installs `name` at the best version for `range`, then its dependencies, skipping what's
    /// already cached. Returns what was newly installed.
    @discardableResult
    public func install(_ name: String, range: String = "latest", progress: @Sendable (String) -> Void = { _ in }) async throws -> [Installed] {
        var installed: [Installed] = []
        var queue: [(String, String)] = [(name, range)]
        var seen: Set<String> = []
        while !queue.isEmpty {
            let (next, wanted) = queue.removeFirst()
            guard seen.insert("\(next)@\(wanted)").inserted else { continue }
            let version: String
            if let cached = Self.best(next, range: wanted, in: root) {
                version = cached.description
            } else {
                progress("Fetching \(next)@\(wanted)")
                version = try await download(next, range: wanted)
                installed.append(Installed(name: next, version: version))
            }
            let manifest = Self.packageJSON(Self.folder(root, next, version))
            for (dependency, dependencyRange) in (manifest?["dependencies"] as? [String: String] ?? [:]).sorted(by: { $0.key < $1.key })
            where SemverRange(dependencyRange) != nil {
                queue.append((dependency, dependencyRange))
            }
        }
        return installed
    }

    /// Everything a project's package.json asks for (dependencies and devDependencies).
    @discardableResult
    public func installProject(_ project: URL, progress: @Sendable (String) -> Void = { _ in }) async throws -> [Installed] {
        var installed: [Installed] = []
        for (name, range) in Self.projectDependencies(project) where SemverRange(range) != nil {
            installed += try await install(name, range: range, progress: progress)
        }
        return installed
    }

    private func download(_ name: String, range: String) async throws -> String {
        let encoded = name.replacingOccurrences(of: "/", with: "%2f")
        guard let metaURL = URL(string: registry.absoluteString + "/" + encoded) else { throw Failure.notFound(name) }
        let data: Data
        do { data = try await fetch(metaURL) } catch let error as URLError where error.code == .fileDoesNotExist { throw Failure.notFound(name) }
        guard let meta = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw Failure.badMetadata(name) }
        if meta["error"] as? String == "Not found" { throw Failure.notFound(name) }
        guard let versions = meta["versions"] as? [String: Any] else { throw Failure.badMetadata(name) }
        // "latest" means the dist-tag; any other tag name too.
        let tags = meta["dist-tags"] as? [String: String] ?? [:]
        let chosen: String
        if let tagged = tags[range] {
            chosen = tagged
        } else if let r = SemverRange(range), let best = r.best(of: versions.keys.compactMap(Semver.init)) {
            // npm prefers `latest` when it satisfies the range.
            if let latest = tags["latest"].flatMap(Semver.init), r.contains(latest), best > latest { chosen = latest.description } else { chosen = best.description }
        } else {
            throw Failure.noMatchingVersion(name, range)
        }
        guard let info = versions[chosen] as? [String: Any], let dist = info["dist"] as? [String: Any],
              let tarballText = dist["tarball"] as? String, let tarballURL = URL(string: tarballText) else { throw Failure.badMetadata(name) }
        let tarball = try await fetch(tarballURL)
        guard Self.verify(tarball, integrity: dist["integrity"] as? String, shasum: dist["shasum"] as? String) else { throw Failure.integrity("\(name)@\(chosen)") }

        let files = try Tarball.files(try Tarball.gunzip(tarball))
        let target = Self.folder(root, name, chosen)
        let staging = target.deletingLastPathComponent().appending(path: ".\(chosen).partial-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        for file in files {
            let url = staging.appending(path: file.path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try file.data.write(to: url)
        }
        let record = ["name": name, "version": chosen, "integrity": dist["integrity"] as? String ?? "sha1-" + (dist["shasum"] as? String ?? "")]
        try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]).write(to: staging.appending(path: Self.marker))
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.moveItem(at: staging, to: target)
        try excludeFromBackup()
        return chosen
    }

    static func verify(_ data: Data, integrity: String?, shasum: String?) -> Bool {
        if let integrity {
            // Space-separated; the strongest one we know decides.
            for item in integrity.split(separator: " ") where item.hasPrefix("sha512-") {
                return Data(SHA512.hash(data: data)).base64EncodedString() == item.dropFirst(7)
            }
        }
        if let shasum { return Insecure.SHA1.hash(data: data).map { String(format: "%02x", $0) }.joined() == shasum.lowercased() }
        return false
    }

    private func excludeFromBackup() throws {
        var url = root
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
    }

    // MARK: Reading the cache (no actor hop: plain file reads)

    static func folder(_ root: URL, _ name: String, _ version: String) -> URL { root.appending(path: name).appending(path: version) }

    /// Cached versions of a package (complete installs only).
    public nonisolated static func versions(of name: String, in root: URL) -> [Semver] {
        let dir = root.appending(path: name)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.compactMap { v in
            FileManager.default.fileExists(atPath: dir.appending(path: v).appending(path: marker).path) ? Semver(v) : nil
        }
    }

    public nonisolated static func best(_ name: String, range: String, in root: URL) -> Semver? {
        let cached = versions(of: name, in: root)
        guard let r = SemverRange(range) else { return nil }
        return r.best(of: cached)
    }

    /// Every cached package, name → versions, for the UI.
    public nonisolated static func all(in root: URL) -> [String: [Semver]] {
        var out: [String: [Semver]] = [:]
        let top = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        for entry in top where !entry.hasPrefix(".") {
            let names = entry.hasPrefix("@") ? ((try? FileManager.default.contentsOfDirectory(atPath: root.appending(path: entry).path)) ?? []).map { "\(entry)/\($0)" } : [entry]
            for name in names {
                let versions = versions(of: name, in: root)
                if !versions.isEmpty { out[name] = versions.sorted() }
            }
        }
        return out
    }

    static func packageJSON(_ folder: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: folder.appending(path: "package.json")) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    /// name → range from a project's package.json; dependencies win over devDependencies.
    public nonisolated static func projectDependencies(_ project: URL) -> [(String, String)] {
        guard let manifest = packageJSON(project) else { return [] }
        var all: [String: String] = manifest["devDependencies"] as? [String: String] ?? [:]
        all.merge(manifest["dependencies"] as? [String: String] ?? [:]) { _, prod in prod }
        return all.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
    }
}
