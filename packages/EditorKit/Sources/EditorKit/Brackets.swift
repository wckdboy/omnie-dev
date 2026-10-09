// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// The bracket pair at the caret (PLAN.md §5.1): the bracket just before the caret, else the one
/// just after it, and its partner, counting nesting of the same kind. Text in quotes on the way is
/// skipped as long as the quotes stay on one line, which covers ordinary string literals.
public enum Brackets {
    static let pairs: [UInt16: (UInt16, Bool)] = [
        0x28: (0x29, true), 0x5B: (0x5D, true), 0x7B: (0x7D, true),   // ( [ {  open forwards
        0x29: (0x28, false), 0x5D: (0x5B, false), 0x7D: (0x7B, false), // ) ] }  close backwards
    ]

    /// UTF-16 offsets of the two brackets, or nil. `text` may be a window of the document; offsets
    /// are within it.
    public static func match(in text: NSString, caret: Int) -> (Int, Int)? {
        for at in [caret - 1, caret] where at >= 0 && at < text.length {
            let c = text.character(at: at)
            guard let (partner, forwards) = pairs[c], !inString(text, at) else { continue }
            var depth = 0
            var i = at
            while true {
                i += forwards ? 1 : -1
                guard i >= 0, i < text.length else { return nil }
                let u = text.character(at: i)
                if u == 0x22 || u == 0x27 || u == 0x60 {
                    // Jump over a quoted run on this line.
                    if let end = closingQuote(text, from: i, quote: u, forwards: forwards) { i = end; continue }
                }
                if u == c { depth += 1 } else if u == partner {
                    if depth == 0 { return (min(at, i), max(at, i)) }
                    depth -= 1
                }
            }
        }
        return nil
    }

    /// The other quote of a run starting at `from`, on the same line.
    static func closingQuote(_ text: NSString, from: Int, quote: UInt16, forwards: Bool) -> Int? {
        var i = from
        while true {
            i += forwards ? 1 : -1
            guard i >= 0, i < text.length else { return nil }
            let u = text.character(at: i)
            if u == 0x0A { return nil }
            if u == quote {
                if !(i > 0 && text.character(at: i - 1) == 0x5C) { return i }
            }
        }
    }

    /// Whether `at` sits inside a quoted run on its line (counting unescaped quotes before it).
    static func inString(_ text: NSString, _ at: Int) -> Bool {
        let line = text.lineRange(for: NSRange(location: at, length: 0))
        var open: UInt16?
        var i = line.location
        while i < at {
            let u = text.character(at: i)
            if u == 0x5C { i += 2; continue }
            if let q = open { if u == q { open = nil } } else if u == 0x22 || u == 0x27 || u == 0x60 { open = u }
            i += 1
        }
        return open != nil
    }
}
