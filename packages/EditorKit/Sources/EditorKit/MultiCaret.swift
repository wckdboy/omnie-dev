// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// VS Code's multi-cursor commands over the engine's carets (patch 0012), as pure functions of the
/// text: where Add Cursor Above/Below puts the next caret, and what Change All Occurrences removes.
public enum MultiCaret {
    /// A caret on the line above (or below) the topmost (bottommost) caret, at its column, clamped
    /// to that line's length; nil at the first (last) line.
    public static func adjacent(in text: String, carets: [Int], above: Bool) -> Int? {
        let ns = text as NSString
        guard let edge = above ? carets.min() : carets.max() else { return nil }
        let line = ns.lineRange(for: NSRange(location: min(edge, ns.length), length: 0))
        let column = edge - line.location
        if above {
            guard line.location > 0 else { return nil }
            let target = ns.lineRange(for: NSRange(location: line.location - 1, length: 0))
            return target.location + min(column, contentLength(ns, target))
        }
        // There's a line below only when this one ends with a newline.
        let next = NSMaxRange(line)
        guard line.length > 0, ns.character(at: next - 1) == 10 else { return nil }
        let target = ns.lineRange(for: NSRange(location: next, length: 0))
        return target.location + min(column, contentLength(ns, target))
    }

    /// A line's length without its newline.
    static func contentLength(_ ns: NSString, _ line: NSRange) -> Int {
        line.length > 0 && ns.character(at: NSMaxRange(line) - 1) == 10 ? line.length - 1 : line.length
    }

    /// The word at a location: letters, digits, `_` and `$`; nil when there's none.
    public static func word(in text: String, at location: Int) -> NSRange? {
        let ns = text as NSString
        func isWord(_ i: Int) -> Bool {
            guard i >= 0, i < ns.length, let scalar = UnicodeScalar(ns.character(at: i)) else { return false }
            return CharacterSet.alphanumerics.contains(scalar) || scalar == "_" || scalar == "$"
        }
        var start = min(location, ns.length), end = start
        while isWord(start - 1) { start -= 1 }
        while isWord(end) { end += 1 }
        return end > start ? NSRange(location: start, length: end - start) : nil
    }

    /// Every whole-word occurrence of `needle` (exact case), in order.
    public static func occurrences(of needle: String, in text: String) -> [NSRange] {
        let ns = text as NSString
        let length = (needle as NSString).length
        guard length > 0 else { return [] }
        var found: [NSRange] = []
        var search = NSRange(location: 0, length: ns.length)
        while true {
            let r = ns.range(of: needle, options: [.literal], range: search)
            guard r.location != NSNotFound else { break }
            // An identifier counts only as a whole word ("item" isn't in "items" or "$item").
            if !isIdentifier(needle) || word(in: text, at: r.location) == r { found.append(r) }
            search = NSRange(location: NSMaxRange(r), length: ns.length - NSMaxRange(r))
        }
        return found
    }

    static func isIdentifier(_ s: String) -> Bool {
        s.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || $0 == "_" || $0 == "$" }
    }

    /// Change All Occurrences: the text without them, and a caret where each was.
    public static func removing(_ ranges: [NSRange], from text: String) -> (text: String, carets: [Int]) {
        let out = NSMutableString(string: text)
        for r in ranges.reversed() { out.replaceCharacters(in: r, with: "") }
        var carets: [Int] = []
        var removed = 0
        for r in ranges {
            carets.append(r.location - removed)
            removed += r.length
        }
        return (out as String, carets)
    }
}
