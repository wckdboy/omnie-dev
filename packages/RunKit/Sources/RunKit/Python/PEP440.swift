// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Python package versions and requirements (PEP 440, 508), the parts requirements files use.
public struct PyVersion: Comparable, Hashable, Sendable, CustomStringConvertible {
    public let text: String
    let epoch: Int
    let release: [Int]
    /// ("a" | "b" | "rc", n), or nil for a final release.
    let pre: (String, Int)?
    let post: Int?
    let dev: Int?

    public var isPrerelease: Bool { pre != nil || dev != nil }
    public var description: String { text }

    public init?(_ raw: String) {
        var s = raw.trimmingCharacters(in: .whitespaces).lowercased()
        if s.hasPrefix("v") { s.removeFirst() }
        if let plus = s.firstIndex(of: "+") { s = String(s[..<plus]) }
        guard let m = s.wholeMatch(of: /(?:(\d+)!)?(\d+(?:\.\d+)*)(?:[-_.]?(a|b|c|rc|alpha|beta|pre|preview)[-_.]?(\d*))?(?:(?:-(\d+))|(?:[-_.]?(?:post|rev|r)[-_.]?(\d*)))?(?:[-_.]?dev[-_.]?(\d*))?/) else { return nil }
        text = raw.trimmingCharacters(in: .whitespaces)
        epoch = m.1.flatMap { Int($0) } ?? 0
        release = m.2.split(separator: ".").compactMap { Int($0) }
        if let kind = m.3 {
            let k = switch kind { case "alpha": "a"; case "beta": "b"; case "c", "pre", "preview": "rc"; default: String(kind) }
            pre = (k, Int(m.4 ?? "") ?? 0)
        } else { pre = nil }
        post = m.5.flatMap { Int($0) } ?? m.6.map { Int($0) ?? 0 }
        dev = m.7.map { Int($0) ?? 0 }
    }

    public static func == (a: Self, b: Self) -> Bool { a.key == b.key }
    public func hash(into h: inout Hasher) { h.combine(key.description) }

    /// Sort key: dev releases before pre-releases before finals before post releases.
    var key: [Int] {
        var r = release
        while r.count > 1, r.last == 0 { r.removeLast() }
        let preRank: [Int] = if let pre { [["a": 0, "b": 1, "rc": 2][pre.0] ?? 0, pre.1] } else if dev != nil, post == nil { [-1, 0] } else { [3, 0] }
        return [epoch, r.count] + r + preRank + [post.map { $0 + 1 } ?? 0, dev ?? Int.max]
    }

    public static func < (a: Self, b: Self) -> Bool {
        if a.epoch != b.epoch { return a.epoch < b.epoch }
        let n = max(a.release.count, b.release.count)
        let ra = a.release + Array(repeating: 0, count: n - a.release.count), rb = b.release + Array(repeating: 0, count: n - b.release.count)
        if ra != rb { return ra.lexicographicallyPrecedes(rb) }
        let pa = Array(a.key.suffix(4)), pb = Array(b.key.suffix(4))
        return pa.lexicographicallyPrecedes(pb)
    }
}

/// A comma-separated specifier set: ">=1.2,<2", "~=3.1", "==2.*", "!=1.5".
public struct PySpecifier: Sendable {
    let clauses: [(String, String)]

    public init?(_ text: String) {
        var clauses: [(String, String)] = []
        for part in text.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) where !part.isEmpty {
            guard let m = part.wholeMatch(of: /(~=|===|==|!=|<=|>=|<|>)\s*(.+)/) else { return nil }
            clauses.append((String(m.1), String(m.2).trimmingCharacters(in: .whitespaces)))
        }
        self.clauses = clauses
    }

    public func contains(_ v: PyVersion) -> Bool {
        // Pre-releases only if a clause names one.
        if v.isPrerelease, !clauses.contains(where: { PyVersion($0.1)?.isPrerelease == true }) { return false }
        return clauses.allSatisfy { op, target in
            if target.hasSuffix(".*") {
                guard let prefix = PyVersion(String(target.dropLast(2))) else { return false }
                let matches = Array(v.release.prefix(prefix.release.count)) + Array(repeating: 0, count: max(0, prefix.release.count - v.release.count)) == prefix.release
                return op == "==" ? matches : op == "!=" ? !matches : false
            }
            guard let t = PyVersion(target) else { return false }
            switch op {
            case "==", "===": return v == t
            case "!=": return v != t
            case "<=": return v <= t
            case ">=": return v >= t
            case "<": return v < t
            case ">": return v > t
            case "~=":
                guard t.release.count >= 2 else { return false }
                return v >= t && Array(v.release.prefix(t.release.count - 1)) == Array(t.release.prefix(t.release.count - 1))
            default: return false
            }
        }
    }

    public func best(of versions: [PyVersion]) -> PyVersion? { versions.filter(contains).max() }
}

/// One line of requirements: `name[extra] >=1,<2 ; python_version >= "3.8"`.
public struct PyRequirement: Sendable, Hashable {
    public let name: String
    public let specifier: String
    public let marker: String?

    /// PEP 503: lowercase, runs of -_. become one -.
    public static func normalize(_ name: String) -> String {
        name.lowercased().replacing(/[-_.]+/, with: "-")
    }

    public init?(_ line: String) {
        var text = line
        if let hash = text.range(of: " #") ?? (text.hasPrefix("#") ? text.range(of: "#") : nil) { text = String(text[..<hash.lowerBound]) }
        let parts = text.split(separator: ";", maxSplits: 1)
        guard let head = parts.first?.trimmingCharacters(in: .whitespaces),
              let m = head.wholeMatch(of: /([A-Za-z0-9][A-Za-z0-9._-]*)\s*(?:\[[^\]]*\])?\s*\(?\s*([^)]*?)\s*\)?/) else { return nil }
        name = Self.normalize(String(m.1))
        specifier = String(m.2)
        marker = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : nil
        guard specifier.isEmpty || PySpecifier(specifier) != nil else { return nil }
    }

    /// Whether this requirement applies in Pyodide (no extras requested).
    public var appliesHere: Bool { marker.map { PyMarker.evaluate($0) } ?? true }
}

/// PEP 508 environment markers, evaluated for Pyodide.
enum PyMarker {
    static let environment: [String: String] = [
        "python_version": "3.14", "python_full_version": "3.14.2", "sys_platform": "emscripten", "platform_system": "Emscripten",
        "os_name": "posix", "implementation_name": "cpython", "platform_python_implementation": "CPython",
        "platform_machine": "wasm32", "extra": "",
    ]

    static func evaluate(_ text: String) -> Bool {
        var tokens = tokenize(text)[...]
        return (try? or(&tokens)) ?? false
    }

    private static func tokenize(_ text: String) -> [String] {
        text.matches(of: /"[^"]*"|'[^']*'|\(|\)|===|==|!=|<=|>=|~=|<|>|not\s+in\b|\bin\b|[A-Za-z_][A-Za-z0-9_.]*|[0-9][^\s()]*/).map { String($0.0) }
    }

    struct Bad: Error {}

    private static func or(_ t: inout ArraySlice<String>) throws -> Bool {
        var value = try and(&t)
        while t.first == "or" { t.removeFirst(); let rhs = try and(&t); value = value || rhs }
        return value
    }

    private static func and(_ t: inout ArraySlice<String>) throws -> Bool {
        var value = try atom(&t)
        while t.first == "and" { t.removeFirst(); let rhs = try atom(&t); value = value && rhs }
        return value
    }

    private static func atom(_ t: inout ArraySlice<String>) throws -> Bool {
        if t.first == "(" {
            t.removeFirst()
            let value = try or(&t)
            guard t.first == ")" else { throw Bad() }
            t.removeFirst()
            return value
        }
        guard t.count >= 3 else { throw Bad() }
        let lhs = value(t.removeFirst()), op = t.removeFirst(), rhs = value(t.removeFirst())
        if op.hasPrefix("not") { return !rhs.contains(lhs) }
        if op == "in" { return rhs.contains(lhs) }
        if let a = PyVersion(lhs), let b = PyVersion(rhs), lhs.first?.isNumber == true, rhs.first?.isNumber == true {
            return PySpecifier("\(op)\(b.text)")?.contains(a) ?? false
        }
        switch op {
        case "==", "===": return lhs == rhs
        case "!=": return lhs != rhs
        default: return false
        }
    }

    private static func value(_ token: String) -> String {
        if token.hasPrefix("\"") || token.hasPrefix("'") { return String(token.dropFirst().dropLast()) }
        return environment[token] ?? token
    }
}
