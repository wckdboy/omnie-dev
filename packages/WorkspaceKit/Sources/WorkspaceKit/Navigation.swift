// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Fuzzy file matching for quick open (⌘P): the query's characters in order, scored so that
/// consecutive runs, word and path starts, and matches in the file name rank first.
public enum FuzzyMatch {
    /// nil when `query` isn't a subsequence of `candidate` (case-insensitive). A match within the
    /// file name always beats one spread over the path.
    public static func score(_ query: String, _ candidate: String) -> Int? {
        let name = (candidate as NSString).lastPathComponent
        if name != candidate, let inName = pathScore(query, name) { return 10_000 + inName - candidate.count / 8 }
        return pathScore(query, candidate)
    }

    static func pathScore(_ query: String, _ candidate: String) -> Int? {
        let q = Array(query.lowercased().filter { !$0.isWhitespace })
        guard !q.isEmpty else { return 0 }
        let c = Array(candidate)
        let lower = Array(candidate.lowercased())
        let nameStart = (candidate.lastIndex(of: "/").map { candidate.distance(from: candidate.startIndex, to: $0) + 1 }) ?? 0
        var score = 0, qi = 0, previous = -2
        for (i, ch) in lower.enumerated() where qi < q.count && ch == q[qi] {
            var points = 1
            if i == previous + 1 { points += 5 }                                    // consecutive
            if i == 0 || "/_-. ".contains(c[i - 1]) { points += 8 }                 // start of a word or path part
            else if c[i].isUppercase && c[i - 1].isLowercase { points += 6 }        // camelCase hump
            if i >= nameStart { points += 3 }                                       // in the file name
            score += points
            previous = i
            qi += 1
        }
        guard qi == q.count else { return nil }
        return score * 100 / max(c.count, 1) + score - (c.count - nameStart) / 4    // shorter, shallower wins ties
    }

    /// The best `limit` candidates for `query`, best first.
    public static func rank(_ query: String, _ candidates: [String], limit: Int = 50) -> [String] {
        candidates.compactMap { c in score(query, c).map { (c, $0) } }
            .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0 < $1.0 }
            .prefix(limit).map(\.0)
    }
}

/// Text search across a project (find in project, ⇧⌘F).
public enum ProjectSearch {
    public struct Hit: Sendable, Hashable, Identifiable {
        public var id: String { "\(path):\(line):\(column)" }
        public let path: String
        /// 1-based.
        public let line: Int
        /// 1-based, in characters.
        public let column: Int
        public let text: String
        /// The match's UTF-16 range in the file, for selecting it in the editor.
        public let range: NSRange
    }

    public static let skipped: Set<String> = [".git", "node_modules", ".build", "DerivedData", "dist", "build", ".venv", "__pycache__"]

    /// The project's files, relative paths, for quick open. Capped so a huge repo can't stall.
    public static func files(in root: URL, limit: Int = 50_000) -> [String] {
        let base = root.standardizedFileURL.resolvingSymlinksInPath()
        var out: [String] = []
        let e = FileManager.default.enumerator(at: base, includingPropertiesForKeys: [.isRegularFileKey])
        while let url = e?.nextObject() as? URL, out.count < limit {
            if skipped.contains(url.lastPathComponent) { e?.skipDescendants(); continue }
            if url.lastPathComponent == ".DS_Store" { continue }
            if (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                out.append(String(url.standardizedFileURL.resolvingSymlinksInPath().path.dropFirst(base.path.count + 1)))
            }
        }
        return out.sorted()
    }

    /// Every occurrence of `query` (case-insensitive unless `caseSensitive`), at most `limit`.
    public static func search(_ query: String, in root: URL, caseSensitive: Bool = false, limit: Int = 1_000) -> [Hit] {
        guard !query.isEmpty else { return [] }
        let base = root.standardizedFileURL.resolvingSymlinksInPath()
        let options: String.CompareOptions = caseSensitive ? [] : .caseInsensitive
        var hits: [Hit] = []
        for path in files(in: base) {
            let url = base.appending(path: path)
            guard let data = try? Data(contentsOf: url), data.count < 4_000_000, !data.prefix(8192).contains(0) else { continue }
            let text = String(decoding: data, as: UTF8.self)
            let ns = text as NSString
            var lineStart = 0, line = 1
            var searchRange = NSRange(location: 0, length: ns.length)
            while hits.count < limit {
                let found = ns.range(of: query, options: options, range: searchRange)
                guard found.location != NSNotFound else { break }
                // Advance the line counter to the match.
                while true {
                    let next = ns.range(of: "\n", options: [], range: NSRange(location: lineStart, length: ns.length - lineStart))
                    guard next.location != NSNotFound, next.location < found.location else { break }
                    lineStart = next.location + 1
                    line += 1
                }
                let lineRange = ns.lineRange(for: NSRange(location: found.location, length: 0))
                let lineText = ns.substring(with: lineRange).trimmingCharacters(in: .newlines)
                let column = (ns.substring(with: NSRange(location: lineStart, length: found.location - lineStart))).count + 1
                hits.append(Hit(path: path, line: line, column: column, text: String(lineText.prefix(240)), range: found))
                searchRange = NSRange(location: NSMaxRange(found), length: ns.length - NSMaxRange(found))
            }
            if hits.count >= limit { break }
        }
        return hits
    }
}
