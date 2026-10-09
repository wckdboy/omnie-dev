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
