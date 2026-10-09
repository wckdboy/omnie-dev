// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Finds credentials in text about to be committed or accepted from the agent (PLAN.md §12:
/// "Diffs are secret-scanned before accept and before commit").
///
/// Rules favor known token formats, which almost never misfire. One generic rule catches
/// `password = "…"`-style assignments, but only for values that look random. A line containing
/// `omnie:allow-secret` is skipped, for test fixtures.
public struct SecretScanner: Sendable {
    public struct Finding: Sendable, Hashable, Identifiable {
        public var id: String { "\(path):\(line):\(rule)" }
        public let path: String
        public let line: Int
        /// What was found, e.g. "GitHub token".
        public let rule: String
        /// The match with most of it hidden, safe to show and to log.
        public let redacted: String
        /// Known formats are certain; the generic assignment rule is a guess.
        public let isCertain: Bool
    }

    struct Rule: @unchecked Sendable {
        let name: String
        let regex: NSRegularExpression
        let certain: Bool
        /// Capture group holding the secret (0 = the whole match).
        let group: Int

        init(_ name: String, _ pattern: String, certain: Bool = true, group: Int = 0) {
            self.name = name
            // The patterns are constants; a typo should fail loudly in tests.
            regex = try! NSRegularExpression(pattern: pattern)
            self.certain = certain
            self.group = group
        }
    }

    static let rules: [Rule] = [
        Rule("Private key", #"-----BEGIN (?:RSA |EC |DSA |OPENSSH |PGP |ENCRYPTED )?PRIVATE KEY(?: BLOCK)?-----"#),
        Rule("AWS access key", #"\b(?:AKIA|ASIA)[0-9A-Z]{16}\b"#),
        Rule("GitHub token", #"\bgh[pousr]_[A-Za-z0-9]{36,}\b"#),
        Rule("GitHub token", #"\bgithub_pat_[A-Za-z0-9_]{22,}\b"#),
        Rule("GitLab token", #"\bglpat-[A-Za-z0-9_\-]{20,}"#),
        Rule("Anthropic API key", #"\bsk-ant-[A-Za-z0-9_\-]{20,}"#),
        Rule("OpenAI API key", #"\bsk-(?!ant-)(?:proj-)?[A-Za-z0-9_\-]{32,}"#),
        Rule("Slack token", #"\bxox[abprs]-[A-Za-z0-9\-]{10,}"#),
        Rule("Stripe live key", #"\b[rs]k_live_[A-Za-z0-9]{20,}"#),
        Rule("Google API key", #"\bAIza[0-9A-Za-z_\-]{35}\b"#),
        Rule("Hugging Face token", #"\bhf_[A-Za-z]{34,}\b"#),
        Rule("Possible secret",
             #"(?i)\b(?:api[_-]?key|secret|password|passwd|auth[_-]?token|access[_-]?token|private[_-]?key)\b["']?\s*[:=]\s*["']([^"'\s]{12,})["']"#,
             certain: false, group: 1),
    ]

    static let allowMarker = "omnie:allow-secret"
    /// Long lines (minified bundles) are only scanned this far.
    static let maxLineLength = 4_000

    public init() {}

    public func scan(path: String, line: Int, text: String) -> [Finding] {
        guard !text.contains(Self.allowMarker) else { return [] }
        let text = text.count > Self.maxLineLength ? String(text.prefix(Self.maxLineLength)) : text
        let ns = text as NSString
        var findings: [Finding] = []
        var covered: [NSRange] = []
        for rule in Self.rules {
            for match in rule.regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                let range = match.range(at: rule.group)
                guard range.location != NSNotFound,
                      !covered.contains(where: { NSIntersectionRange($0, range).length > 0 }) else { continue }
                let value = ns.substring(with: range)
                if !rule.certain && !Self.looksRandom(value) { continue }
                covered.append(range)
                findings.append(Finding(path: path, line: line, rule: rule.name,
                                        redacted: Self.redact(value), isCertain: rule.certain))
            }
        }
        return findings
    }

    /// Scans many lines; `lines` are (path, 1-based line, text).
    public func scan(_ lines: some Sequence<(path: String, line: Int, text: String)>) -> [Finding] {
        lines.flatMap { scan(path: $0.path, line: $0.line, text: $0.text) }
    }

    /// Keeps a few leading characters (the token prefix is what identifies it) and hides the rest.
    static func redact(_ value: String) -> String {
        let shown = value.hasPrefix("-----") ? value : String(value.prefix(min(6, value.count / 3))) + "…"
        return value.hasPrefix("-----") ? shown : "\(shown) (\(value.count) chars)"
    }

    /// Placeholders and references aren't secrets: "changeme", "${TOKEN}", "process.env.KEY",
    /// "xxxxxxxxxxxx". A real secret has varied characters (Shannon entropy ≥ 3.5 bits/char).
    static func looksRandom(_ value: String) -> Bool {
        let lower = value.lowercased()
        let placeholders = ["example", "changeme", "placeholder", "your", "xxxx", "****", "${", "{{", "<", "process.env", "env("]
        if placeholders.contains(where: lower.contains) { return false }
        var counts: [Character: Int] = [:]
        for c in value { counts[c, default: 0] += 1 }
        let n = Double(value.count)
        let entropy = counts.values.reduce(0.0) { sum, k in
            let p = Double(k) / n
            return sum - p * log2(p)
        }
        return entropy >= 3.5
    }
}
