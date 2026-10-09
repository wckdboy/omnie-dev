// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

import Foundation
import JavaScriptCore

/// The Patterns lab (PLAN.md §11.1): JSON checked and formatted, and regular expressions tried
/// in the JavaScript flavor (JavaScriptCore, what a web project runs) or Swift's.
public enum Patterns {
    public struct JSONReport: Sendable, Equatable {
        public let formatted: String?
        /// "line 3, column 7: …" when the JSON doesn't parse.
        public let error: String?
    }

    /// Validates and pretty-prints JSON with 2-space indentation, keeping key order.
    public static func json(_ text: String) -> JSONReport {
        guard let context = JSContext() else { return JSONReport(formatted: nil, error: "No JavaScript engine") }
        context.setObject(text, forKeyedSubscript: "input" as NSString)
        let out = context.evaluateScript("""
            (() => { try { return { ok: JSON.stringify(JSON.parse(input), null, 2) }; }
                     catch (e) { return { error: String(e.message) }; } })()
            """)
        if let ok = out?.objectForKeyedSubscript("ok"), !ok.isUndefined { return JSONReport(formatted: ok.toString(), error: nil) }
        let message = out?.objectForKeyedSubscript("error")?.toString() ?? "invalid JSON"
        return JSONReport(formatted: nil, error: locate(message, in: text))
    }

    /// Adds a line and column to an error that names a character position.
    static func locate(_ message: String, in text: String) -> String {
        guard let match = message.firstMatch(of: /(?:position|offset|character) (\d+)/), let offset = Int(match.1) else { return message }
        let prefix = text.prefix(offset)
        let line = prefix.filter { $0 == "\n" }.count + 1
        let column = prefix.count - (prefix.lastIndex(of: "\n").map { prefix.distance(from: prefix.startIndex, to: $0) + 1 } ?? 0) + 1
        return "line \(line), column \(column): \(message)"
    }

    public enum Flavor: String, Sendable, CaseIterable { case javascript = "JavaScript", swift = "Swift" }

    public struct Match: Sendable, Equatable {
        public let range: Range<Int>
        public let text: String
        public let groups: [String?]
    }

    public struct RegexReport: Sendable, Equatable {
        public let matches: [Match]
        public let error: String?
    }

    /// All matches of `pattern` in `text`, with capture groups. Offsets are in characters.
    public static func regex(_ pattern: String, flags: String = "", in text: String, flavor: Flavor) -> RegexReport {
        switch flavor {
        case .javascript: return javascriptRegex(pattern, flags: flags, in: text)
        case .swift: return swiftRegex(pattern, flags: flags, in: text)
        }
    }

    static func javascriptRegex(_ pattern: String, flags: String, in text: String) -> RegexReport {
        guard let context = JSContext() else { return RegexReport(matches: [], error: "No JavaScript engine") }
        context.setObject(pattern, forKeyedSubscript: "pattern" as NSString)
        context.setObject(flags.replacingOccurrences(of: "g", with: "") + "g", forKeyedSubscript: "flags" as NSString)
        context.setObject(text, forKeyedSubscript: "input" as NSString)
        let out = context.evaluateScript("""
            (() => {
              let re; try { re = new RegExp(pattern, flags); } catch (e) { return { error: String(e.message) }; }
              // Offsets in visible characters (grapheme clusters), like Swift's String.
              const segmenter = new Intl.Segmenter();
              const toChars = (i) => [...segmenter.segment(input.slice(0, i))].length;
              const out = [];
              for (const m of input.matchAll(re)) {
                if (out.length >= 1000) break;
                const start = toChars(m.index);
                out.push({ start, end: start + [...segmenter.segment(m[0])].length, text: m[0], groups: m.slice(1).map((g) => g ?? null) });
              }
              return { matches: out };
            })()
            """)
        if let error = out?.objectForKeyedSubscript("error"), !error.isUndefined { return RegexReport(matches: [], error: error.toString()) }
        let list = out?.objectForKeyedSubscript("matches")?.toArray() as? [[String: Any]] ?? []
        return RegexReport(matches: list.map { m in
            let start = (m["start"] as? NSNumber)?.intValue ?? 0, end = (m["end"] as? NSNumber)?.intValue ?? 0
            return Match(range: start..<end, text: m["text"] as? String ?? "", groups: (m["groups"] as? [Any] ?? []).map { $0 as? String })
        }, error: nil)
    }

    static func swiftRegex(_ pattern: String, flags: String, in text: String) -> RegexReport {
        do {
            var regex = try Regex(pattern)
            if flags.contains("i") { regex = regex.ignoresCase() }
            if flags.contains("m") { regex = regex.anchorsMatchLineEndings() }
            if flags.contains("s") { regex = regex.dotMatchesNewlines() }
            var matches: [Match] = []
            for m in text.matches(of: regex).prefix(1000) {
                let start = text.distance(from: text.startIndex, to: m.range.lowerBound)
                let groups = (1..<m.output.count).map { i in m.output[i].substring.map(String.init) }
                matches.append(Match(range: start..<(start + m.output[0].substring!.count), text: String(text[m.range]), groups: groups))
            }
            return RegexReport(matches: matches, error: nil)
        } catch {
            return RegexReport(matches: [], error: "\(error)")
        }
    }
}

extension Patterns {
    public struct YAMLReport: Sendable, Equatable {
        /// The YAML as formatted JSON (keys sorted: YAML maps have no order to keep).
        public let json: String?
        public let error: String?
    }

    /// Parses YAML (the subset in YAML.swift) and shows it as JSON.
    public static func yaml(_ text: String) -> YAMLReport {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return YAMLReport(json: nil, error: "Empty") }
        guard let value = YAML.parse(text) else { return YAMLReport(json: nil, error: "Not YAML this parser reads (anchors and tags aren't supported).") }
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed])
        else { return YAMLReport(json: nil, error: "Can't show it as JSON.") }
        return YAMLReport(json: String(decoding: data, as: UTF8.self), error: nil)
    }

    /// JSON as YAML (block style, two-space indents, strings quoted only when needed).
    public static func yamlFromJSON(_ text: String) -> String? {
        guard let value = try? JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed]) else { return nil }
        var lines: [String] = []
        func scalar(_ v: Any) -> String {
            if v is NSNull { return "null" }
            if let n = v as? NSNumber {
                if CFGetTypeID(n) == CFBooleanGetTypeID() { return n.boolValue ? "true" : "false" }
                return n.stringValue
            }
            let s = "\(v)"
            let plain = !s.isEmpty && s.range(of: #"^[A-Za-z_][\w .\-/]*$"#, options: .regularExpression) != nil
                && !["true", "false", "null", "yes", "no", "on", "off", "~"].contains(s.lowercased()) && !s.hasSuffix(" ")
            if plain { return s }
            let data = try? JSONSerialization.data(withJSONObject: [s], options: [.withoutEscapingSlashes])
            return data.map { String(decoding: $0, as: UTF8.self).dropFirst().dropLast() }.map(String.init) ?? "\"\(s)\""
        }
        func emit(_ v: Any, _ indent: String) {
            if let d = v as? [String: Any] {
                if d.isEmpty { lines.append(indent + "{}"); return }
                for k in d.keys.sorted() {
                    let child = d[k]!
                    if let c = child as? [String: Any], !c.isEmpty { lines.append("\(indent)\(scalar(k)):"); emit(c, indent + "  ") }
                    else if let a = child as? [Any], !a.isEmpty { lines.append("\(indent)\(scalar(k)):"); emit(a, indent) }
                    else { lines.append("\(indent)\(scalar(k)): \(inline(child))") }
                }
            } else if let a = v as? [Any] {
                if a.isEmpty { lines.append(indent + "[]"); return }
                for item in a {
                    if let d = item as? [String: Any], !d.isEmpty {
                        var first = true
                        for k in d.keys.sorted() {
                            let child = d[k]!
                            let prefix = first ? "\(indent)- " : "\(indent)  "
                            first = false
                            if let c = child as? [String: Any], !c.isEmpty { lines.append("\(prefix)\(scalar(k)):"); emit(c, indent + "    ") }
                            else if let ca = child as? [Any], !ca.isEmpty { lines.append("\(prefix)\(scalar(k)):"); emit(ca, indent + "  ") }
                            else { lines.append("\(prefix)\(scalar(k)): \(inline(child))") }
                        }
                    } else if let inner = item as? [Any], !inner.isEmpty {
                        lines.append("\(indent)-"); emit(inner, indent + "  ")
                    } else {
                        lines.append("\(indent)- \(inline(item))")
                    }
                }
            } else {
                lines.append(indent + scalar(v))
            }
        }
        func inline(_ v: Any) -> String {
            if let d = v as? [String: Any], d.isEmpty { return "{}" }
            if let a = v as? [Any], a.isEmpty { return "[]" }
            return scalar(v)
        }
        emit(value, "")
        return lines.joined(separator: "\n") + "\n"
    }
}
