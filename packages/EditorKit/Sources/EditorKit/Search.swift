// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Runestone

/// Find & replace inside the open file (VS Code's ⌘F): matches are highlighted, the current one
/// more strongly, and replace goes through the text view so it is undoable like any other edit.
extension CodeEditorController {
    /// The most matches highlighted at once: past this the answer stops being useful and the cost
    /// stops being worth it.
    public static let searchMatchLimit = 20_000

    /// All matches of `query` in the text, as UTF-16 ranges, left to right.
    public func searchRanges(_ query: String, caseSensitive: Bool) -> [NSRange] {
        guard !query.isEmpty else { return [] }
        let text = textView.text as NSString
        let options: NSString.CompareOptions = caseSensitive ? [] : [.caseInsensitive]
        var ranges: [NSRange] = []
        var location = 0
        while location <= text.length, ranges.count < Self.searchMatchLimit {
            let found = text.range(of: query, options: options, range: NSRange(location: location, length: text.length - location))
            guard found.location != NSNotFound else { break }
            ranges.append(found)
            location = found.location + max(1, found.length)
        }
        return ranges
    }

    /// Draws the matches; `current` is drawn stronger and scrolled to. Other decorations (marks,
    /// fold chevrons) are kept.
    public func setSearchHighlights(_ ranges: [NSRange], current: Int?) {
        searchDecorations = ranges.enumerated().map { index, range in
            let color = index == current ? theme.palette.accent.ion.uiColor.withAlphaComponent(0.45)
                                         : theme.palette.surface.selection.uiColor
            return Decoration(id: "find-\(index)", range: range, style: .background(color))
        }
        textView.decorations = textView.decorations.filter { !$0.id.hasPrefix("find-") } + searchDecorations
        if let current, ranges.indices.contains(current) { textView.scrollRangeToVisible(ranges[current]) }
    }

    public func clearSearchHighlights() {
        guard !searchDecorations.isEmpty else { return }
        searchDecorations = []
        textView.decorations = textView.decorations.filter { !$0.id.hasPrefix("find-") }
    }

    /// Replaces every range (given in ascending order) with `replacement`. Returns how many changed.
    @discardableResult
    public func replaceAll(_ ranges: [NSRange], with replacement: String) -> Int {
        guard !ranges.isEmpty else { return 0 }
        let undo = textView.undoManager
        undo?.beginUndoGrouping()
        var count = 0
        // Back to front so the earlier ranges keep their offsets while we edit.
        for range in ranges.reversed() where replace(range, with: replacement) { count += 1 }
        undo?.endUndoGrouping()
        return count
    }
}
