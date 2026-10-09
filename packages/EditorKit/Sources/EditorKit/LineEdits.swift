// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// VS Code's line commands as pure text edits: what to replace, with what, and where the selection
/// goes after. The controller applies them through the text view, so each is one undo step.
public enum LineEdit: Sendable, Equatable {
    case toggleComment
    case moveUp, moveDown
    case copyUp, copyDown
    case delete
    case indent, outdent

    /// How a language comments a line out: `//`, `#`, `--`, or a pair wrapped around it.
    public enum CommentStyle: Sendable, Equatable {
        case line(String)
        case block(String, String)
    }

    public struct Result: Sendable, Equatable {
        /// The range in the old text to replace.
        public var range: NSRange
        public var replacement: String
        /// The selection in the new text.
        public var selection: NSRange
    }

    /// nil when there's nothing to do (moving the first line up).
    public func apply(to text: String, selection: NSRange, comment: CommentStyle = .line("//"), indentUnit: String = "  ") -> Result? {
        let ns = text as NSString
        // The whole lines the selection touches; a selection ending at a line's start leaves that line out.
        var end = NSMaxRange(selection)
        if selection.length > 0, end > selection.location, end <= ns.length, end > 0, ns.character(at: end - 1) == 10 { end -= 1 }
        let lines = ns.lineRange(for: NSRange(location: selection.location, length: max(0, end - selection.location)))
        let block = ns.substring(with: lines)
        let endsWithNewline = block.hasSuffix("\n")
        let body = endsWithNewline ? String(block.dropLast()) : block
        let rows = body.components(separatedBy: "\n")

        switch self {
        case .toggleComment:
            let edited = Self.toggle(rows, comment)
            let replacement = edited.joined(separator: "\n") + (endsWithNewline ? "\n" : "")
            let delta = (replacement as NSString).length - lines.length
            return Result(range: lines, replacement: replacement, selection: Self.shift(selection, in: lines, by: delta, firstRow: rows[0], newFirstRow: edited[0]))

        case .indent, .outdent:
            var firstShift = 0
            var total = 0
            let edited = rows.enumerated().map { index, row -> String in
                let changed: String
                if self == .indent {
                    changed = row.isEmpty ? row : indentUnit + row
                } else {
                    changed = Self.outdent(row, unit: indentUnit)
                }
                let d = (changed as NSString).length - (row as NSString).length
                if index == 0 { firstShift = d }
                total += d
                return changed
            }
            let replacement = edited.joined(separator: "\n") + (endsWithNewline ? "\n" : "")
            // A selection from a line's start keeps that start and grows with every line, as in VS Code.
            let fromLineStart = selection.length > 0 && selection.location == lines.location
            let start = fromLineStart ? lines.location : max(lines.location, selection.location + firstShift)
            let length = selection.length == 0 ? 0 : max(0, selection.length + total - (fromLineStart ? 0 : firstShift))
            return Result(range: lines, replacement: replacement, selection: NSRange(location: start, length: length))

        case .delete:
            // The lines and their newline; the last line takes the newline before it instead.
            var range = lines
            if !endsWithNewline, range.location > 0 { range = NSRange(location: range.location - 1, length: range.length + 1) }
            return Result(range: range, replacement: "", selection: NSRange(location: min(range.location, ns.length - range.length), length: 0))

        case .copyUp, .copyDown:
            let copy = endsWithNewline ? block : "\n" + block
            if self == .copyDown {
                // The copy goes after the lines and is selected the same way.
                let insertAt = NSMaxRange(lines)
                let offset = (endsWithNewline ? block as NSString : copy as NSString).length
                return Result(range: NSRange(location: insertAt, length: 0),
                              replacement: endsWithNewline ? block : copy,
                              selection: NSRange(location: selection.location + offset, length: selection.length))
            }
            // Up: the copy goes before; the selection stays on the upper (new) lines.
            return Result(range: NSRange(location: lines.location, length: 0),
                          replacement: endsWithNewline ? block : body + "\n", selection: selection)

        case .moveUp:
            guard lines.location > 0 else { return nil }
            let above = ns.lineRange(for: NSRange(location: lines.location - 1, length: 0))
            let aboveText = ns.substring(with: above)
            let moved = endsWithNewline ? block + aboveText : body + "\n" + String(aboveText.dropLast())
            let shift = (aboveText as NSString).length
            return Result(range: NSRange(location: above.location, length: above.length + lines.length), replacement: moved,
                          selection: NSRange(location: selection.location - shift, length: selection.length))

        case .moveDown:
            guard NSMaxRange(lines) < ns.length else { return nil }
            let below = ns.lineRange(for: NSRange(location: NSMaxRange(lines), length: 0))
            let belowText = ns.substring(with: below)
            let belowEndsWithNewline = belowText.hasSuffix("\n")
            let moved = belowEndsWithNewline ? belowText + block : belowText + "\n" + body
            let shift = (belowEndsWithNewline ? belowText as NSString : (belowText + "\n") as NSString).length
            return Result(range: NSRange(location: lines.location, length: lines.length + below.length), replacement: moved,
                          selection: NSRange(location: selection.location + shift, length: selection.length))
        }
    }

    /// Comments every line out, or (when they all are) back in. Blank lines are left alone, and
    /// the comment marker goes at the shallowest indent, as VS Code does.
    static func toggle(_ rows: [String], _ style: CommentStyle) -> [String] {
        let content = rows.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !content.isEmpty else { return rows }
        switch style {
        case .line(let marker):
            let allCommented = content.allSatisfy { $0.trimmingCharacters(in: .whitespaces).hasPrefix(marker) }
            if allCommented {
                return rows.map { row in
                    guard let r = row.range(of: marker) else { return row }
                    var out = row
                    let after = out.index(r.upperBound, offsetBy: 0)
                    let removeSpace = after < out.endIndex && out[after] == " "
                    out.removeSubrange(r.lowerBound..<(removeSpace ? out.index(after: after) : after))
                    return out
                }
            }
            let indent = content.map { $0.prefix { $0 == " " || $0 == "\t" }.count }.min() ?? 0
            return rows.map { row in
                guard !row.trimmingCharacters(in: .whitespaces).isEmpty else { return row }
                let i = row.index(row.startIndex, offsetBy: indent)
                return String(row[..<i]) + marker + " " + String(row[i...])
            }
        case .block(let open, let close):
            return rows.map { row in
                let trimmed = row.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { return row }
                let lead = String(row.prefix { $0 == " " || $0 == "\t" })
                if trimmed.hasPrefix(open), trimmed.hasSuffix(close), trimmed.count >= open.count + close.count {
                    let inner = trimmed.dropFirst(open.count).dropLast(close.count).trimmingCharacters(in: .whitespaces)
                    return lead + inner
                }
                return lead + open + " " + trimmed + " " + close
            }
        }
    }

    static func outdent(_ row: String, unit: String) -> String {
        if row.hasPrefix(unit) { return String(row.dropFirst(unit.count)) }
        if row.hasPrefix("\t") { return String(row.dropFirst()) }
        let spaces = row.prefix { $0 == " " }.count
        return String(row.dropFirst(min(spaces, unit.count)))
    }

    /// The selection after a toggle: moved by what changed before it on its first line, and
    /// stretched by the rest when it spans lines.
    static func shift(_ selection: NSRange, in lines: NSRange, by delta: Int, firstRow: String, newFirstRow: String) -> NSRange {
        let firstDelta = (newFirstRow as NSString).length - (firstRow as NSString).length
        let location = max(lines.location, selection.location + firstDelta)
        if selection.length == 0 { return NSRange(location: location, length: 0) }
        return NSRange(location: location, length: max(0, selection.length + delta - firstDelta))
    }
}
