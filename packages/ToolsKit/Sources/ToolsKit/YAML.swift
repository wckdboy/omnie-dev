// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Enough YAML for API specs and config files: block mappings and sequences, plain and quoted
/// scalars, flow `[…]` and `{…}`, `|` and `>` block strings, comments. No anchors, tags or
/// multiple documents. Returns Foundation values, like JSONSerialization. Used by the Patterns lab
/// and by RunKit's OpenAPI mocks.
public enum YAML {
    struct Line { let indent: Int; let text: String }

    public static func parse(_ source: String) -> Any? {
        var lines: [Line] = []
        for raw in source.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false) {
            let text = String(raw)
            if text.hasPrefix("---") || text.hasPrefix("...") { continue }
            var indent = text.prefix { $0 == " " }.count
            var rest = String(text.dropFirst(indent))
            // "- key: value" and "- - a" become "-" plus the rest on its own line, one column in,
            // so the item is an ordinary nested block.
            while rest.hasPrefix("- ") {
                let after = rest.dropFirst(2)
                let inner = String(after.drop { $0 == " " })
                guard splitKey(inner) != nil || inner.hasPrefix("- ") else { break }
                lines.append(Line(indent: indent, text: "-"))
                indent += 2 + (after.count - inner.count)
                rest = inner
            }
            lines.append(Line(indent: indent, text: rest))
        }
        var i = 0
        return block(&i, lines, minIndent: 0)
    }

    private static func isBlank(_ line: Line) -> Bool { line.text.isEmpty || line.text.hasPrefix("#") }

    private static func skipBlank(_ i: inout Int, _ lines: [Line]) {
        while i < lines.count, isBlank(lines[i]) { i += 1 }
    }

    /// The node starting at the next non-blank line, if it's indented at least `minIndent`.
    private static func block(_ i: inout Int, _ lines: [Line], minIndent: Int) -> Any? {
        skipBlank(&i, lines)
        guard i < lines.count, lines[i].indent >= minIndent else { return nil }
        let indent = lines[i].indent
        if lines[i].text == "-" || lines[i].text.hasPrefix("- ") { return sequence(&i, lines, indent: indent) }
        if splitKey(lines[i].text) != nil { return mapping(&i, lines, indent: indent) }
        let value = scalar(stripComment(lines[i].text))
        i += 1
        return value
    }

    private static func sequence(_ i: inout Int, _ lines: [Line], indent: Int) -> [Any] {
        var items: [Any] = []
        while true {
            skipBlank(&i, lines)
            guard i < lines.count, lines[i].indent == indent, lines[i].text == "-" || lines[i].text.hasPrefix("- ") else { break }
            let rest = lines[i].text == "-" ? "" : String(lines[i].text.dropFirst(2))
            let trimmed = rest.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") {
                i += 1
                items.append(block(&i, lines, minIndent: indent + 1) ?? NSNull())
            } else {
                items.append(value(trimmed, &i, lines, parentIndent: indent))
            }
        }
        return items
    }

    private static func mapping(_ i: inout Int, _ lines: [Line], indent: Int) -> [String: Any] {
        var object: [String: Any] = [:]
        while true {
            skipBlank(&i, lines)
            guard i < lines.count, lines[i].indent == indent, let (key, rest) = splitKey(lines[i].text) else { break }
            let trimmed = stripComment(rest).trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                i += 1
                // A nested block, or a sequence at the same indent as the key ("key:\n- a").
                skipBlank(&i, lines)
                if i < lines.count, lines[i].indent == indent, lines[i].text == "-" || lines[i].text.hasPrefix("- ") {
                    object[key] = sequence(&i, lines, indent: indent)
                } else {
                    object[key] = block(&i, lines, minIndent: indent + 1) ?? NSNull()
                }
            } else {
                object[key] = value(trimmed, &i, lines, parentIndent: indent)
            }
        }
        return object
    }

    /// An inline value after "key:" or "- ", consuming its line (and a block string's lines).
    private static func value(_ text: String, _ i: inout Int, _ lines: [Line], parentIndent: Int) -> Any {
        i += 1
        if text.hasPrefix("|") || text.hasPrefix(">") {
            var body: [String] = []
            var blockIndent: Int?
            while i < lines.count {
                let line = lines[i]
                if line.text.isEmpty { body.append(""); i += 1; continue }
                guard line.indent > parentIndent else { break }
                let at = blockIndent ?? line.indent
                blockIndent = at
                body.append(String(repeating: " ", count: max(0, line.indent - at)) + line.text)
                i += 1
            }
            while body.last == "" { body.removeLast() }
            let joined = text.hasPrefix(">") ? body.joined(separator: " ") : body.joined(separator: "\n")
            return text.contains("-") ? joined : joined + "\n"
        }
        return scalar(text)
    }

    /// "key: rest" with the key unquoted, or nil if the line isn't a mapping entry.
    static func splitKey(_ text: String) -> (String, String)? {
        if let quote = text.first, quote == "\"" || quote == "'" {
            guard let end = text.dropFirst().firstIndex(of: quote) else { return nil }
            let after = text[text.index(after: end)...]
            guard after.hasPrefix(":"), after.count == 1 || after.dropFirst().first == " " else { return nil }
            return (String(text[text.index(after: text.startIndex)..<end]), String(after.dropFirst()))
        }
        guard !text.hasPrefix("[") && !text.hasPrefix("{") && !text.hasPrefix("#") else { return nil }
        var index = text.startIndex
        while let colon = text[index...].firstIndex(of: ":") {
            let next = text.index(after: colon)
            if next == text.endIndex || text[next] == " " {
                return (String(text[..<colon]).trimmingCharacters(in: .whitespaces), String(text[next...]))
            }
            index = next
        }
        return nil
    }

    static func stripComment(_ text: String) -> String {
        var quote: Character?
        var previous: Character = " "
        for (offset, c) in text.enumerated() {
            if let q = quote { if c == q { quote = nil } }
            else if c == "\"" || c == "'" { quote = c }
            else if c == "#", previous == " " { return String(text.prefix(offset)).trimmingCharacters(in: .whitespaces) }
            previous = c
        }
        return text
    }

    static func scalar(_ raw: String) -> Any {
        let text = stripComment(raw).trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("[") || text.hasPrefix("{") {
            var index = text.startIndex
            return flow(text, &index)
        }
        if text.count >= 2, text.hasPrefix("\""), text.hasSuffix("\"") {
            return (try? JSONSerialization.jsonObject(with: Data(text.utf8), options: .fragmentsAllowed)) as? String
                ?? String(text.dropFirst().dropLast())
        }
        if text.count >= 2, text.hasPrefix("'"), text.hasSuffix("'") {
            return String(text.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
        }
        switch text {
        case "", "~", "null", "Null", "NULL": return NSNull()
        case "true", "True", "TRUE": return true
        case "false", "False", "FALSE": return false
        default: break
        }
        if let int = Int(text) { return int }
        if text.contains(where: \.isNumber), let double = Double(text), !text.hasPrefix("+") { return double }
        return text
    }

    /// `[a, b]` and `{k: v}`, nested.
    private static func flow(_ text: String, _ index: inout String.Index) -> Any {
        func skipSpaces() { while index < text.endIndex, text[index] == " " { index = text.index(after: index) } }
        func token() -> String {
            skipSpaces()
            var out = ""
            var quote: Character?
            while index < text.endIndex {
                let c = text[index]
                if let q = quote { if c == q { quote = nil } }
                else if c == "\"" || c == "'" { quote = c }
                else if ",]}".contains(c) { break }
                out.append(c)
                index = text.index(after: index)
            }
            return out.trimmingCharacters(in: .whitespaces)
        }
        let open = text[index]
        index = text.index(after: index)
        if open == "[" {
            var items: [Any] = []
            while index < text.endIndex {
                skipSpaces()
                if text[index] == "]" { index = text.index(after: index); break }
                if text[index] == "[" || text[index] == "{" { items.append(flow(text, &index)) } else { items.append(scalar(token())) }
                skipSpaces()
                if index < text.endIndex, text[index] == "," { index = text.index(after: index) }
            }
            return items
        }
        var object: [String: Any] = [:]
        while index < text.endIndex {
            skipSpaces()
            if text[index] == "}" { index = text.index(after: index); break }
            var key = ""
            while index < text.endIndex, text[index] != ":" { key.append(text[index]); index = text.index(after: index) }
            if index < text.endIndex { index = text.index(after: index) }
            skipSpaces()
            let value: Any = index < text.endIndex && (text[index] == "[" || text[index] == "{") ? flow(text, &index) : scalar(token())
            object[(scalar(key) as? String) ?? key.trimmingCharacters(in: .whitespaces)] = value
            skipSpaces()
            if index < text.endIndex, text[index] == "," { index = text.index(after: index) }
        }
        return object
    }
}
