// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// A snippet body expanded into the text to insert and the tab stops to Tab through (PLAN.md §11.1).
/// It understands the useful part of VS Code's snippet syntax:
///
/// - `$1`, `${1}`, `${1:default}`, `${1|one,two|}` — a numbered stop, with a default or a first choice;
/// - `$0` — where the caret ends (the last stop when you Tab past the rest);
/// - `\$`, `\}` and `$$` — a literal `$`, `}` or `$`.
///
/// A stop's `range` is a UTF-16 range in `text`, so the editor can select it and move it with edits.
/// Mirrored stops (the same number twice) keep their text but only the first is a stop, which is all
/// the platform's caret set can show.
public struct SnippetExpansion: Sendable, Equatable {
    public struct Stop: Sendable, Equatable {
        public let index: Int
        public let range: NSRange
        public init(index: Int, range: NSRange) {
            self.index = index
            self.range = range
        }
    }

    public let text: String
    /// In tab order: 1, 2, … then `$0` last when the snippet has one.
    public let stops: [Stop]

    /// Where the caret lands when the last stop is Tabbed past: the end of `$0` if there is one, else
    /// the end of the snippet.
    public var trailingCaret: Int {
        if let zero = stops.first(where: { $0.index == 0 }) { return NSMaxRange(zero.range) }
        return (text as NSString).length
    }

    /// Expands `body`. `indent` (the line's leading whitespace) is added after every newline, as VS
    /// Code does, so an inserted block lines up where the caret is.
    public init(_ body: String, indent: String = "") {
        let characters = Array(body)
        var out = ""
        var found: [(index: Int, range: NSRange)] = []
        var i = 0

        /// Emits text, remembering a stop at the current position when `stop` is set.
        func emit(_ chunk: String, stop: Int?) {
            if let stop {
                let location = (out as NSString).length
                // An added indent lives inside the stop: typing a multi-line default replaces it too.
                out += chunk
                found.append((index: stop, range: NSRange(location: location, length: (chunk as NSString).length)))
            } else {
                for character in chunk {
                    out.append(character)
                    if character == "\n", !indent.isEmpty { out += indent }
                }
            }
        }

        while i < characters.count {
            let c = characters[i]
            if c == "\\", i + 1 < characters.count, "$}||,".contains(characters[i + 1]) {
                out.append(characters[i + 1])
                i += 2
                continue
            }
            if c == "$", i + 1 < characters.count, characters[i + 1] == "$" {
                out.append("$")
                i += 2
                continue
            }
            guard c == "$" else {
                out.append(c)
                if c == "\n", !indent.isEmpty { out += indent }
                i += 1
                continue
            }

            // "$" at the end, or one that starts nothing: a literal.
            if i + 1 < characters.count, characters[i + 1] == "{" {
                guard let close = Self.matchingBrace(characters, from: i + 1) else { out.append(c); i += 1; continue }
                let inner = String(characters[(i + 2)..<close])
                let (name, defaultValue) = Self.split(inner)
                if let index = Int(name) {
                    emit(defaultValue, stop: index)
                } else {
                    // A named variable has no stop we can move to; insert its default as plain text.
                    out += defaultValue
                }
                i = close + 1
                continue
            }
            if i + 1 < characters.count, characters[i + 1].isNumber {
                var j = i + 1
                while j < characters.count, characters[j].isNumber { j += 1 }
                let index = Int(String(characters[(i + 1)..<j])) ?? 0
                emit("", stop: index)
                i = j
                continue
            }
            out.append(c)
            i += 1
        }

        text = out
        // Tab order: 1, 2, … then $0; the first occurrence of a repeated number keeps the stop.
        var seen = Set<Int>()
        stops = found
            .sorted { a, b in a.index == b.index ? a.range.location < b.range.location : Self.tabOrder(a.index, b.index) }
            .filter { seen.insert($0.index).inserted }
            .map { Stop(index: $0.index, range: $0.range) }
    }

    /// Ascending, except `$0` sorts last.
    static func tabOrder(_ a: Int, _ b: Int) -> Bool {
        if a == 0 { return false }
        if b == 0 { return true }
        return a < b
    }

    /// The `}` that closes the `${` at `open`, skipping escaped ones. No nesting inside a default.
    static func matchingBrace(_ characters: [Character], from open: Int) -> Int? {
        var i = open + 1
        while i < characters.count {
            let c = characters[i]
            if c == "\\" { i += 2; continue }
            if c == "}" { return i }
            if c == "\n" { return nil }
            i += 1
        }
        return nil
    }

    /// `${1:default}` → ("1", "default"); `${1|a,b|}` → ("1", "a"); `${1}` → ("1", "").
    static func split(_ inner: String) -> (String, String) {
        if let colon = inner.firstIndex(of: ":") {
            return (String(inner[inner.startIndex..<colon]), String(inner[inner.index(after: colon)...]))
        }
        if let bar = inner.firstIndex(of: "|") {
            let name = String(inner[inner.startIndex..<bar])
            let rest = inner[inner.index(after: bar)...]
            let choices = rest.hasSuffix("|") ? rest.dropLast() : rest
            return (name, choices.split(separator: ",", omittingEmptySubsequences: false).first.map(String.init) ?? "")
        }
        return (inner, "")
    }
}

/// Where the caret is among a snippet's stops, moved with the text as you edit (PLAN.md §11.1).
public struct SnippetSession: Sendable, Equatable {
    public var stops: [SnippetExpansion.Stop]
    /// The stop currently selected; equal to `stops.count` once you've Tabbed past the last, at which
    /// point the session is finished and `isDone` is true.
    public var current: Int
    public var trailingCaret: Int

    public init(stops: [SnippetExpansion.Stop], trailingCaret: Int) {
        self.stops = stops
        self.current = 0
        self.trailingCaret = trailingCaret
    }

    public var isDone: Bool { current >= stops.count }

    /// Moves every stop with an edit, dropping none; a stop the edit lands on grows or shrinks with it.
    mutating func adjust(forEdit edit: NSRange, replacementLength: Int) {
        stops = stops.map { SnippetExpansion.Stop(index: $0.index, range: $0.range.adjusted(forEdit: edit, replacementLength: replacementLength)) }
        trailingCaret = trailingCaret.adjustedOffset(forEdit: edit, replacementLength: replacementLength)
    }

    /// Tab: the next stop, or the end. Returns the new selection.
    public mutating func next() -> NSRange? {
        guard !isDone else { return nil }
        current += 1
        return isDone ? NSRange(location: trailingCaret, length: 0) : stops[current].range
    }

    /// Shift-Tab: the previous stop. nil at the first.
    public mutating func previous() -> NSRange? {
        guard current > 0 else { return nil }
        current -= 1
        return stops[current].range
    }
}

extension NSRange {
    /// This range after `edit` is replaced by `replacementLength` UTF-16 units. Ranges strictly before
    /// stay, ranges strictly after shift, and a range the edit lands on — including a caret stop where
    /// text is typed — grows or shrinks to cover the new text.
    func adjusted(forEdit edit: NSRange, replacementLength: Int) -> NSRange {
        let stopStart = location, stopEnd = NSMaxRange(self)
        let editStart = edit.location, editEnd = NSMaxRange(edit)
        if stopEnd < editStart { return self }
        if stopStart > editEnd || (stopStart == editEnd && edit.length > 0) {
            return NSRange(location: location + replacementLength - edit.length, length: length)
        }
        let start = min(stopStart, editStart)
        let end = max(stopEnd, editEnd + replacementLength - edit.length)
        return NSRange(location: start, length: max(0, end - start))
    }
}

extension Int {
    /// This caret offset after `edit` is replaced by `replacementLength` units.
    func adjustedOffset(forEdit edit: NSRange, replacementLength: Int) -> Int {
        if self < edit.location { return self }
        if self > NSMaxRange(edit) { return self + replacementLength - edit.length }
        return edit.location + replacementLength
    }
}
