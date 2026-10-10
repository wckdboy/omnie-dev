// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing
@testable import EditorKit

struct MultiCaretTests {
    @Test func addsCaretsAboveAndBelowAtTheColumn() {
        let text = "alpha\nb\ngamma delta\n"
        // From column 3 of "alpha": "b" is shorter (clamped to its end), then column 3 of "gamma".
        #expect(MultiCaret.adjacent(in: text, carets: [3], above: false) == 7)
        #expect(MultiCaret.adjacent(in: text, carets: [3, 7], above: false) == 9)
        #expect(MultiCaret.adjacent(in: text, carets: [11], above: true) == 7)
        #expect(MultiCaret.adjacent(in: text, carets: [3], above: true) == nil)
        // The empty last line after the final newline counts; past it there's nothing.
        #expect(MultiCaret.adjacent(in: text, carets: [11], above: false) == 20)
        #expect(MultiCaret.adjacent(in: text, carets: [20], above: false) == nil)
    }

    @Test func changeAllOccurrencesFindsWholeWords() {
        let text = "let item = 1;\nitems.push(item);\nconsole.log(item, $item);\n"
        let ranges = MultiCaret.occurrences(of: "item", in: text)
        #expect(ranges.map(\.location) == [4, 25, 44])
        #expect(MultiCaret.word(in: text, at: 6) == NSRange(location: 4, length: 4))
        let (out, carets) = MultiCaret.removing(ranges, from: text)
        #expect(out == "let  = 1;\nitems.push();\nconsole.log(, $item);\n")
        #expect(carets == [4, 21, 36])
    }
}
