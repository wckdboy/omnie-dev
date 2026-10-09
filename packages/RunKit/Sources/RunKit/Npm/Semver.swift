// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// npm's version ranges, the parts package.json files use: exact, `^`, `~`, comparators,
/// hyphen ranges, `x`/`*` wildcards and `||`.
public struct Semver: Comparable, Hashable, Sendable, CustomStringConvertible {
    public let major: Int, minor: Int, patch: Int
    public let prerelease: [String]

    public init?(_ text: String) {
        var text = text.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("v") || text.hasPrefix("=") { text.removeFirst() }
        let core = text.split(separator: "+", maxSplits: 1).first.map(String.init) ?? text
        let parts = core.split(separator: "-", maxSplits: 1)
        let numbers = parts.first?.split(separator: ".").map { Int($0) } ?? []
        guard numbers.count == 3, let a = numbers[0], let b = numbers[1], let c = numbers[2] else { return nil }
        major = a; minor = b; patch = c
        prerelease = parts.count > 1 ? parts[1].split(separator: ".").map(String.init) : []
    }

    init(_ major: Int, _ minor: Int, _ patch: Int, _ prerelease: [String] = []) {
        self.major = major; self.minor = minor; self.patch = patch; self.prerelease = prerelease
    }

    public var description: String { "\(major).\(minor).\(patch)" + (prerelease.isEmpty ? "" : "-" + prerelease.joined(separator: ".")) }

    public static func < (a: Semver, b: Semver) -> Bool {
        if (a.major, a.minor, a.patch) != (b.major, b.minor, b.patch) { return (a.major, a.minor, a.patch) < (b.major, b.minor, b.patch) }
        if a.prerelease.isEmpty || b.prerelease.isEmpty { return !a.prerelease.isEmpty && b.prerelease.isEmpty }
        for (x, y) in zip(a.prerelease, b.prerelease) where x != y {
            switch (Int(x), Int(y)) {
            case let (i?, j?): return i < j
            case (.some, nil): return true
            case (nil, .some): return false
            default: return x < y
            }
        }
        return a.prerelease.count < b.prerelease.count
    }
}

public struct SemverRange: Sendable {
    struct Comparator: Sendable {
        enum Op: Sendable { case lt, le, gt, ge, eq }
        let op: Op
        let version: Semver
        func test(_ v: Semver) -> Bool {
            switch op {
            case .lt: v < version
            case .le: v <= version
            case .gt: v > version
            case .ge: v >= version
            case .eq: v == version
            }
        }
    }
    /// Any of these sets; every comparator in a set must hold.
    let sets: [[Comparator]]

    public init?(_ text: String) {
        var sets: [[Comparator]] = []
        for alternative in text.components(separatedBy: "||") {
            guard let set = Self.parseSet(alternative.trimmingCharacters(in: .whitespaces)) else { return nil }
            sets.append(set)
        }
        self.sets = sets
    }

    /// Prereleases match only a range that names a prerelease of the same version (npm's rule).
    public func contains(_ v: Semver) -> Bool {
        sets.contains { set in
            set.allSatisfy { $0.test(v) }
                && (v.prerelease.isEmpty || set.contains { c in !c.version.prerelease.isEmpty
                    && (c.version.major, c.version.minor, c.version.patch) == (v.major, v.minor, v.patch) })
        }
    }

    public func best(of versions: [Semver]) -> Semver? { versions.filter(contains).max() }

    /// A partial version: numbers present (nil for x, *, or missing) plus a prerelease.
    private static func partial(_ text: String) -> (Int?, Int?, Int?, [String])? {
        var text = text
        if text.hasPrefix("v") || text.hasPrefix("=") { text.removeFirst() }
        if text.isEmpty { return (nil, nil, nil, []) }
        let core = text.split(separator: "+", maxSplits: 1).first.map(String.init) ?? text
        let pieces = core.split(separator: "-", maxSplits: 1)
        let numbers = pieces[0].split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard numbers.count <= 3 else { return nil }
        var out: [Int?] = []
        for n in numbers {
            if ["x", "X", "*"].contains(n) { out.append(nil); continue }
            guard let value = Int(n) else { return nil }
            out.append(value)
        }
        // Once one part is a wildcard, the rest are too.
        if let first = out.firstIndex(where: { $0 == nil }) { for k in first..<out.count { out[k] = nil } }
        while out.count < 3 { out.append(nil) }
        return (out[0], out[1], out[2], pieces.count > 1 ? pieces[1].split(separator: ".").map(String.init) : [])
    }

    private static func parseSet(_ text: String) -> [Comparator]? {
        if text.isEmpty || text == "*" || text == "latest" || text == "x" { return [Comparator(op: .ge, version: Semver(0, 0, 0))] }
        // Hyphen range: "1.2 - 2.3.4".
        let hyphen = text.components(separatedBy: " - ")
        if hyphen.count == 2, let low = partial(hyphen[0].trimmingCharacters(in: .whitespaces)),
           let high = partial(hyphen[1].trimmingCharacters(in: .whitespaces)) {
            let start = Comparator(op: .ge, version: Semver(low.0 ?? 0, low.1 ?? 0, low.2 ?? 0, low.3))
            let end: Comparator = switch (high.0, high.1, high.2) {
            case (let a?, let b?, let c?): Comparator(op: .le, version: Semver(a, b, c, high.3))
            case (let a?, let b?, nil): Comparator(op: .lt, version: Semver(a, b + 1, 0, ["0"]))
            case (let a?, nil, _): Comparator(op: .lt, version: Semver(a + 1, 0, 0, ["0"]))
            default: Comparator(op: .ge, version: Semver(0, 0, 0))
            }
            return [start, end]
        }
        // Join "< 2" into "<2", then split on spaces.
        var tokens: [String] = []
        for token in text.split(separator: " ").map(String.init) {
            if let last = tokens.last, ["<", "<=", ">", ">=", "=", "^", "~", "~>"].contains(last) { tokens[tokens.count - 1] = last + token }
            else { tokens.append(token) }
        }
        var set: [Comparator] = []
        for token in tokens {
            guard let comparators = parseOne(token) else { return nil }
            set += comparators
        }
        return set
    }

    private static func parseOne(_ token: String) -> [Comparator]? {
        var op = ""
        var rest = Substring(token)
        for prefix in ["<=", ">=", "~>", "<", ">", "=", "^", "~"] where rest.hasPrefix(prefix) {
            op = prefix; rest = rest.dropFirst(prefix.count); break
        }
        guard let (a, b, c, pre) = partial(String(rest)) else { return nil }
        let floor = Semver(a ?? 0, b ?? 0, c ?? 0, pre)
        func lt(_ v: Semver) -> Comparator { Comparator(op: .lt, version: v) }
        func ge(_ v: Semver) -> Comparator { Comparator(op: .ge, version: v) }
        switch op {
        case "^":
            guard let a else { return [ge(Semver(0, 0, 0))] }
            if a > 0 { return [ge(floor), lt(Semver(a + 1, 0, 0, ["0"]))] }
            guard let b else { return [ge(floor), lt(Semver(1, 0, 0, ["0"]))] }
            if b > 0 || c == nil { return [ge(floor), lt(Semver(0, b + 1, 0, ["0"]))] }
            return [ge(floor), lt(Semver(0, 0, (c ?? 0) + 1, ["0"]))]
        case "~", "~>":
            guard let a else { return [ge(Semver(0, 0, 0))] }
            guard let b else { return [ge(floor), lt(Semver(a + 1, 0, 0, ["0"]))] }
            return [ge(floor), lt(Semver(a, b + 1, 0, ["0"]))]
        case "", "=":
            switch (a, b, c) {
            case (nil, _, _): return [ge(Semver(0, 0, 0))]
            case (let a?, nil, _): return [ge(floor), lt(Semver(a + 1, 0, 0, ["0"]))]
            case (let a?, let b?, nil): return [ge(floor), lt(Semver(a, b + 1, 0, ["0"]))]
            default: return [Comparator(op: .eq, version: floor)]
            }
        case ">":
            switch (a, b, c) {
            case (nil, _, _): return [lt(Semver(0, 0, 0))]
            case (let a?, nil, _): return [ge(Semver(a + 1, 0, 0))]
            case (let a?, let b?, nil): return [ge(Semver(a, b + 1, 0))]
            default: return [Comparator(op: .gt, version: floor)]
            }
        case ">=": return [ge(floor)]
        case "<": return [lt(floor.prerelease.isEmpty && c == nil ? Semver(floor.major, floor.minor, 0, ["0"]) : floor)]
        case "<=":
            switch (a, b, c) {
            case (let a?, nil, _): return [lt(Semver(a + 1, 0, 0, ["0"]))]
            case (let a?, let b?, nil): return [lt(Semver(a, b + 1, 0, ["0"]))]
            default: return [Comparator(op: .le, version: floor)]
            }
        default: return nil
        }
    }
}
