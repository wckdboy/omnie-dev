// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

import CryptoKit
import Foundation

/// Offline documentation (PLAN.md §11.1 and §8): DevDocs bundles (MDN, Python, Node, three.js…)
/// downloaded while online and searched with no connection. A bundle is an index of entries and
/// a page per path; pages are stored one file each under `<root>/<slug>/pages/`.
public struct DocsBundle: Codable, Hashable, Sendable, Identifiable {
    public var id: String { slug }
    public let name: String
    public let slug: String
    public let release: String?
    public let size: Int
    public let mtime: Int
    /// The bundle's licence and credits, as HTML (shown with its pages).
    public let attribution: String

    public var title: String { release.map { "\(name) \($0)" } ?? name }

    enum CodingKeys: String, CodingKey { case name, slug, release, size = "db_size", mtime, attribution }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        slug = try c.decode(String.self, forKey: .slug)
        release = try c.decodeIfPresent(String.self, forKey: .release).flatMap { $0.isEmpty ? nil : $0 }
        size = try c.decodeIfPresent(Int.self, forKey: .size) ?? 0
        mtime = try c.decodeIfPresent(Int.self, forKey: .mtime) ?? 0
        attribution = try c.decodeIfPresent(String.self, forKey: .attribution) ?? ""
    }
}

public struct DocsEntry: Codable, Hashable, Sendable {
    public let name: String
    public let path: String
    public let type: String
    /// Set when searching across bundles.
    public var slug: String = ""

    enum CodingKeys: String, CodingKey { case name, path, type }
}

public actor DocsStore {
    public typealias Fetch = @Sendable (URL) async throws -> Data

    public nonisolated let root: URL
    let fetch: Fetch
    let catalogURL: URL
    let documents: URL

    /// Bundles worth having on a plane for this app's projects.
    public static let suggested = ["javascript", "dom", "css", "html", "typescript", "node", "threejs", "react",
                                   "python~3.14", "numpy~2.4", "pandas~3", "git"]

    public init(root: URL, catalog: URL = URL(string: "https://devdocs.io/docs.json")!,
                documents: URL = URL(string: "https://documents.devdocs.io")!, fetch: @escaping Fetch) {
        self.root = root
        self.catalogURL = catalog
        self.documents = documents
        self.fetch = fetch
    }

    /// Every bundle DevDocs offers (fetched, then kept for offline browsing of what's installed).
    public func catalog() async throws -> [DocsBundle] {
        let data = try await fetch(catalogURL)
        let bundles = try JSONDecoder().decode([DocsBundle].self, from: data)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try data.write(to: root.appending(path: "catalog.json"), options: .atomic)
        return bundles
    }

    public nonisolated func cachedCatalog() -> [DocsBundle] {
        guard let data = try? Data(contentsOf: root.appending(path: "catalog.json")) else { return [] }
        return (try? JSONDecoder().decode([DocsBundle].self, from: data)) ?? []
    }

    /// Downloads a bundle and splits it into pages. `progress` gets a fraction.
    public func install(_ bundle: DocsBundle, progress: @Sendable (Double) -> Void = { _ in }) async throws {
        let base = documents.appending(path: bundle.slug)
        progress(0)
        let indexData = try await fetch(URL(string: base.appending(path: "index.json").absoluteString + "?\(bundle.mtime)")!)
        let index = try JSONDecoder().decode(Index.self, from: indexData)
        progress(0.1)
        let dbData = try await fetch(URL(string: base.appending(path: "db.json").absoluteString + "?\(bundle.mtime)")!)
        guard let pages = try JSONSerialization.jsonObject(with: dbData) as? [String: String] else { throw CocoaError(.fileReadCorruptFile) }
        progress(0.6)
        let staging = root.appending(path: ".\(bundle.slug).partial-\(UUID().uuidString)")
        let pagesDir = staging.appending(path: "pages")
        try FileManager.default.createDirectory(at: pagesDir, withIntermediateDirectories: true)
        var done = 0
        for (path, html) in pages {
            guard let safe = Self.safePath(path) else { continue }
            let url = pagesDir.appending(path: safe + ".html")
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(html.utf8).write(to: url)
            done += 1
            if done % 500 == 0 { progress(0.6 + 0.4 * Double(done) / Double(max(pages.count, 1))) }
        }
        try JSONEncoder().encode(index.entries).write(to: staging.appending(path: "index.json"))
        // No published checksums for DevDocs: record what we got, so a later check can tell if it changed.
        var record = try JSONSerialization.jsonObject(with: JSONEncoder().encode(bundle)) as? [String: Any] ?? [:]
        record["sha256"] = SHA256.hash(data: dbData).map { String(format: "%02x", $0) }.joined()
        record["pages"] = pages.count
        try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]).write(to: staging.appending(path: "bundle.json"))
        let target = root.appending(path: bundle.slug)
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.moveItem(at: staging, to: target)
        var rootURL = root
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? rootURL.setResourceValues(values)
        cache[bundle.slug] = nil
        progress(1)
    }

    public func remove(_ slug: String) throws {
        cache[slug] = nil
        try FileManager.default.removeItem(at: root.appending(path: slug))
    }

    struct Index: Codable { let entries: [DocsEntry] }

    static func safePath(_ path: String) -> String? {
        let clean = path.split(separator: "#").first.map(String.init) ?? path
        let parts = clean.split(separator: "/").filter { !$0.isEmpty && $0 != "." }
        guard !parts.isEmpty, !parts.contains("..") else { return nil }
        return parts.joined(separator: "/")
    }

    // MARK: Reading (offline)

    public nonisolated func installed() -> [DocsBundle] {
        let slugs = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        return slugs.filter { !$0.hasPrefix(".") }.compactMap { slug in
            guard let data = try? Data(contentsOf: root.appending(path: slug).appending(path: "bundle.json")) else { return nil }
            return try? JSONDecoder().decode(DocsBundle.self, from: data)
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private var cache: [String: [DocsEntry]] = [:]

    func entries(_ slug: String) -> [DocsEntry] {
        if let hit = cache[slug] { return hit }
        let data = (try? Data(contentsOf: root.appending(path: slug).appending(path: "index.json"))) ?? Data()
        var list = (try? JSONDecoder().decode([DocsEntry].self, from: data)) ?? []
        for i in list.indices { list[i].slug = slug }
        cache[slug] = list
        return list
    }

    /// Entries matching `query` across installed bundles (or `slugs`), best first.
    public func search(_ query: String, in slugs: [String]? = nil, limit: Int = 50) -> [DocsEntry] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return [] }
        let words = q.split(separator: " ").map(String.init)
        var scored: [(Int, DocsEntry)] = []
        for slug in slugs ?? installed().map(\.slug) {
            for entry in entries(slug) {
                let name = entry.name.lowercased()
                guard let score = Self.score(name, q, words) else { continue }
                scored.append((score - min(entry.name.count, 60), entry))
            }
        }
        return scored.sorted { $0.0 > $1.0 }.prefix(limit).map(\.1)
    }

    static func score(_ name: String, _ q: String, _ words: [String]) -> Int? {
        if name == q { return 1_000 }
        // "Array.prototype.map()" should answer "map" and "array map".
        let bare = name.replacingOccurrences(of: "()", with: "")
        if bare == q || bare.hasSuffix("." + q) { return 900 }
        if name.hasPrefix(q) { return 700 }
        let tokens = bare.split { !$0.isLetter && !$0.isNumber && $0 != "_" }.map(String.init)
        if tokens.contains(q) { return 600 }
        if words.allSatisfy({ w in tokens.contains { $0.hasPrefix(w) } }) { return 400 }
        if name.contains(q) { return 200 }
        return nil
    }

    /// A page's HTML, by its path (an optional "#fragment" is ignored).
    public nonisolated func page(_ slug: String, _ path: String) -> String? {
        guard let safe = Self.safePath(path) else { return nil }
        return try? String(contentsOf: root.appending(path: slug).appending(path: "pages").appending(path: safe + ".html"), encoding: .utf8)
    }

    /// For the agent: the best matches and the top page as text, kept short.
    public func lookup(_ query: String, maxCharacters: Int = 2_500) -> String {
        let results = search(query, limit: 6)
        guard let top = results.first else {
            let names = installed().map(\.title).joined(separator: ", ")
            return names.isEmpty ? "No docs are installed (Settings › Docs)." : "Nothing in the installed docs (\(names)) matches \"\(query)\"."
        }
        var text = Self.plainText(page(top.slug, top.path) ?? "")
        if text.count > maxCharacters { text = String(text.prefix(maxCharacters)) + "…" }
        let others = results.dropFirst().map { "\($0.name) (\($0.slug))" }.joined(separator: ", ")
        return "\(top.name) — \(top.slug)\n\n\(text)" + (others.isEmpty ? "" : "\n\nAlso: \(others)")
    }

    /// HTML to readable text: block elements become line breaks, entities are decoded.
    public static func plainText(_ html: String) -> String {
        var s = html.replacing(/(?is)<(script|style)[^>]*>.*?<\/\1>/, with: "")
        s = s.replacing(/(?i)<\s*(br|\/p|\/div|\/h[1-6]|\/li|\/pre|\/tr|\/dt|\/dd|\/table)\s*\/?>/, with: "\n")
        s = s.replacing(/(?i)<li[^>]*>/, with: "\n• ")
        s = s.replacing(/<[^>]+>/, with: "")
        for (entity, char) in [("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&#x27;", "'"), ("&nbsp;", " "), ("&amp;", "&")] {
            s = s.replacingOccurrences(of: entity, with: char)
        }
        s = s.replacing(/[ \t]+\n/, with: "\n").replacing(/\n{3,}/, with: "\n\n")
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
