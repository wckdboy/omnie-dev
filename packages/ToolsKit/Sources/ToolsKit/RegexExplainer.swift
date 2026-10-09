// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// The regex explainer in the Patterns lab (PLAN.md §11.1): each piece of a pattern and what it
/// matches, in plain words. Deterministic; covers the syntax JavaScript and Swift share.
public enum RegexExplainer {
    public struct Part: Sendable, Equatable {
        public let token: String
        public let meaning: String
        /// Nesting inside groups, for indentation.
        public let depth: Int
    }

    static let escapes: [Character: String] = [
        "d": "a digit", "D": "a character that isn't a digit", "w": "a word character (letter, digit or _)",
        "W": "a character that isn't a word character", "s": "whitespace", "S": "a character that isn't whitespace",
        "b": "a word boundary", "B": "not a word boundary", "n": "a newline", "t": "a tab", "r": "a carriage return",
    ]

    public static func explain(_ pattern: String) -> [Part] {
        let chars = Array(pattern)
        var parts: [Part] = []
        var i = 0, depth = 0, group = 0
        func quantifier() -> String {
            guard i < chars.count else { return "" }
            var q = ""
            switch chars[i] {
            case "*": q = "zero or more times"; i += 1
            case "+": q = "one or more times"; i += 1
            case "?": q = "optionally"; i += 1
            case "{":
                guard let close = chars[i...].firstIndex(of: "}") else { return "" }
                let inner = String(chars[(i + 1)..<close])
                let nums = inner.split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
                if nums.count == 1, let n = Int(nums[0]) { q = "exactly \(n) times" }
                else if nums.count == 2, let a = Int(nums[0]), nums[1].isEmpty { q = "\(a) or more times" }
                else if nums.count == 2, let a = Int(nums[0]), let b = Int(nums[1]) { q = "\(a) to \(b) times" }
                else { return "" }
                i = close + 1
            default: return ""
            }
            if i < chars.count, chars[i] == "?" { i += 1; q += ", as few as possible" }
            else if i < chars.count, chars[i] == "+" { i += 1; q += ", without backtracking" }
            return q
        }
        func add(_ token: String, _ meaning: String) {
            let start = i
            let q = quantifier()
            let qText = String(chars[start..<i])
            parts.append(Part(token: token + qText, meaning: q.isEmpty ? meaning : "\(meaning), \(q)", depth: depth))
        }
        while i < chars.count {
            let c = chars[i]
            switch c {
            case "\\":
                guard i + 1 < chars.count else { parts.append(Part(token: "\\", meaning: "a trailing backslash (an error)", depth: depth)); i += 1; continue }
                let e = chars[i + 1]
                i += 2
                if let meaning = escapes[e] { add("\\\(e)", meaning) }
                else if e.isNumber { add("\\\(e)", "the same text group \(e) matched") }
                else { add("\\\(e)", "the character \"\(e)\"") }
            case "[":
                var j = i + 1
                if j < chars.count, chars[j] == "^" { j += 1 }
                if j < chars.count, chars[j] == "]" { j += 1 }
                while j < chars.count, chars[j] != "]" { j += chars[j] == "\\" ? 2 : 1 }
                let token = String(chars[i...min(j, chars.count - 1)])
                i = min(j + 1, chars.count)
                let negated = token.hasPrefix("[^")
                let body = String(token.dropFirst(negated ? 2 : 1).dropLast())
                add(token, (negated ? "one character that isn't " : "one of ") + describeClass(body))
            case "(":
                var token = "(", meaning: String
                if pattern[pattern.index(pattern.startIndex, offsetBy: i)...].hasPrefix("(?:") { token = "(?:"; meaning = "start of a group (not captured)" }
                else if pattern[pattern.index(pattern.startIndex, offsetBy: i)...].hasPrefix("(?=") { token = "(?="; meaning = "followed by (lookahead)" }
                else if pattern[pattern.index(pattern.startIndex, offsetBy: i)...].hasPrefix("(?!") { token = "(?!"; meaning = "not followed by (negative lookahead)" }
                else if pattern[pattern.index(pattern.startIndex, offsetBy: i)...].hasPrefix("(?<=") { token = "(?<="; meaning = "preceded by (lookbehind)" }
                else if pattern[pattern.index(pattern.startIndex, offsetBy: i)...].hasPrefix("(?<!") { token = "(?<!"; meaning = "not preceded by (negative lookbehind)" }
                else if let named = pattern[pattern.index(pattern.startIndex, offsetBy: i)...].firstMatch(of: /^\(\?<([A-Za-z_]\w*)>/) {
                    group += 1; token = String(named.0); meaning = "start of group \(group), named \"\(named.1)\""
                } else { group += 1; meaning = "start of group \(group)" }
                parts.append(Part(token: token, meaning: meaning, depth: depth))
                i += token.count
                depth += 1
            case ")":
                depth = max(0, depth - 1)
                i += 1
                add(")", "end of the group")
            case "|": parts.append(Part(token: "|", meaning: "or", depth: depth)); i += 1
            case "^": parts.append(Part(token: "^", meaning: "the start of the text (or of a line with the m flag)", depth: depth)); i += 1
            case "$": parts.append(Part(token: "$", meaning: "the end of the text (or of a line with the m flag)", depth: depth)); i += 1
            case ".": i += 1; add(".", "any character except a newline")
            default:
                // A run of literal characters; a quantifier applies only to the last one.
                var j = i
                while j < chars.count, !"\\[]()|^$.*+?{".contains(chars[j]) { j += 1 }
                if j < chars.count, "*+?{".contains(chars[j]), j - i > 1 { j -= 1 }
                if j == i { j = i + 1 }
                let text = String(chars[i..<j])
                i = j
                add(text, text.count == 1 ? "the character \"\(text)\"" : "the text \"\(text)\"")
            }
        }
        return parts
    }

    static func describeClass(_ body: String) -> String {
        var items: [String] = []
        let c = Array(body)
        var i = 0
        while i < c.count {
            if c[i] == "\\", i + 1 < c.count {
                items.append(escapes[c[i + 1]] ?? "\"\(c[i + 1])\""); i += 2
            } else if i + 2 < c.count, c[i + 1] == "-" {
                items.append("\(c[i])–\(c[i + 2])"); i += 3
            } else {
                items.append("\"\(c[i])\""); i += 1
            }
        }
        return items.joined(separator: ", ")
    }
}
