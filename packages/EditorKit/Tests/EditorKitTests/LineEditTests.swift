// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing
@testable import EditorKit

struct LineEditTests {
    /// Applies an edit and returns the new text and selection.
    func run(_ edit: LineEdit, _ text: String, _ selection: NSRange, comment: LineEdit.CommentStyle = .line("//")) -> (String, NSRange)? {
        guard let result = edit.apply(to: text, selection: selection, comment: comment) else { return nil }
        let out = (text as NSString).replacingCharacters(in: result.range, with: result.replacement)
        return (out, result.selection)
    }

    @Test func togglesLineComments() throws {
        let text = "a()\n  b()\n\n  c()\n"
        // The whole text selected: marker at the shallowest indent, blank lines untouched.
        let (on, _) = try #require(run(.toggleComment, text, NSRange(location: 0, length: 16)))
        #expect(on == "// a()\n//   b()\n\n//   c()\n")
        let (off, _) = try #require(run(.toggleComment, on, NSRange(location: 0, length: (on as NSString).length)))
        #expect(off == text)
        // One line, caret mid-line: the caret moves with the text.
        let (one, caret) = try #require(run(.toggleComment, "  x = 1\n", NSRange(location: 4, length: 0), comment: .line("#")))
        #expect(one == "  # x = 1\n" && caret == NSRange(location: 6, length: 0))
        let (html, _) = try #require(run(.toggleComment, "<p>hi</p>", NSRange(location: 0, length: 0), comment: .block("<!--", "-->")))
        #expect(html == "<!-- <p>hi</p> -->")
        let (back, _) = try #require(run(.toggleComment, html, NSRange(location: 0, length: 0), comment: .block("<!--", "-->")))
        #expect(back == "<p>hi</p>")
    }

    @Test func movesAndCopiesLines() throws {
        let text = "one\ntwo\nthree"
        let (up, upSel) = try #require(run(.moveUp, text, NSRange(location: 5, length: 0)))
        #expect(up == "two\none\nthree" && upSel == NSRange(location: 1, length: 0))
        let (down, downSel) = try #require(run(.moveDown, text, NSRange(location: 5, length: 0)))
        #expect(down == "one\nthree\ntwo" && downSel == NSRange(location: 11, length: 0))
        #expect(run(.moveUp, text, NSRange(location: 1, length: 0)) == nil)
        #expect(run(.moveDown, text, NSRange(location: 10, length: 0)) == nil)
        // The last line (no newline after it) moves up too.
        let (lastUp, _) = try #require(run(.moveUp, text, NSRange(location: 9, length: 0)))
        #expect(lastUp == "one\nthree\ntwo")
        let (copied, copySel) = try #require(run(.copyDown, text, NSRange(location: 5, length: 0)))
        #expect(copied == "one\ntwo\ntwo\nthree" && copySel == NSRange(location: 9, length: 0))
        let (copiedLast, _) = try #require(run(.copyDown, text, NSRange(location: 9, length: 0)))
        #expect(copiedLast == "one\ntwo\nthree\nthree")
        let (copiedUp, upCopySel) = try #require(run(.copyUp, text, NSRange(location: 5, length: 0)))
        #expect(copiedUp == "one\ntwo\ntwo\nthree" && upCopySel == NSRange(location: 5, length: 0))
    }

    @Test func deletesIndentsAndOutdents() throws {
        let text = "one\ntwo\nthree"
        let (deleted, _) = try #require(run(.delete, text, NSRange(location: 5, length: 0)))
        #expect(deleted == "one\nthree")
        let (deletedLast, _) = try #require(run(.delete, text, NSRange(location: 9, length: 0)))
        #expect(deletedLast == "one\ntwo")
        // Two lines selected (ending at the next line's start, which stays out).
        let (indented, sel) = try #require(run(.indent, text, NSRange(location: 0, length: 8)))
        #expect(indented == "  one\n  two\nthree" && sel == NSRange(location: 0, length: 12))
        let (outdented, _) = try #require(run(.outdent, indented, NSRange(location: 0, length: 12)))
        #expect(outdented == text)
        let (single, _) = try #require(run(.outdent, " x", NSRange(location: 1, length: 0)))
        #expect(single == "x")
    }
}
