// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

import DesignKit
import Foundation
import Testing
import UIKit
@testable import EditorKit

@MainActor
struct FoldingTests {
    @Test func indentationRegionsKeepTheClosingLine() {
        let ts = """
        function f() {
          if (x) {
            a();

            b();
          }
          return 1;
        }
        const y = 2;
        """
        let regions = FoldRegions.compute(ts)
        // f's body (rows 1–6) folds with its closing brace (row 7) left visible; the if's body too.
        #expect(regions == [FoldRegion(header: 0, last: 6), FoldRegion(header: 1, last: 4)])
        let py = "def area(w, h):\n    \"\"\"Doc.\"\"\"\n    return w * h\n\n\nx = 1\n"
        #expect(FoldRegions.compute(py) == [FoldRegion(header: 0, last: 2)], "trailing blank lines stay out")
        #expect(FoldRegions.compute("a\nb\nc\n").isEmpty)
    }

    @Test func markdownFoldsByHeadings() {
        let md = "# Title\nintro\n## One\ntext\n```\n# not a heading\n```\n## Two\nmore\n# Next\n"
        #expect(FoldRegions.compute(md, markdown: true) == [
            FoldRegion(header: 0, last: 8), FoldRegion(header: 2, last: 6), FoldRegion(header: 7, last: 8),
        ])
    }

    @Test func rangesAndRows() {
        let text = "a\nb\nc\nd"
        let starts = FoldRegions.lineStarts(text)
        #expect(starts == [0, 2, 4, 6])
        #expect(FoldRegions.range(of: FoldRegion(header: 0, last: 2), lineStarts: starts, length: 7) == NSRange(location: 2, length: 4))
        #expect(FoldRegions.range(of: FoldRegion(header: 1, last: 3), lineStarts: starts, length: 7) == NSRange(location: 4, length: 3))
        #expect(FoldRegions.row(of: 5, lineStarts: starts) == 2)
    }

    @Test func foldAndUnfoldInTheEditor() async throws {
        let editor = CodeEditorController(theme: EditorTheme(palette: .dark, density: .regular))
        editor.textView.frame = CGRect(x: 0, y: 0, width: 600, height: 400)
        var loaded = false
        editor.onLoaded = { loaded = true }
        editor.load("function f() {\n  return 1;\n}\nconst x = 2;\n", language: nil)
        for _ in 0..<200 where !loaded || editor.foldRegions.isEmpty { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(editor.foldRegions == [FoldRegion(header: 0, last: 1)])
        #expect(editor.toggleFold(atRow: 0))
        #expect(editor.textView.foldedRanges == [NSRange(location: 15, length: 12)])
        #expect(editor.foldedHeaders == [0])
        #expect(editor.textView.decorations.contains { $0.id == "fold-0" })
        // The caret going into the fold opens it.
        editor.selectedRange = NSRange(location: 18, length: 0)
        #expect(editor.textView.foldedRanges.isEmpty)
        editor.foldAll()
        #expect(editor.textView.foldedRanges.count == 1)
        editor.unfoldAll()
        #expect(editor.textView.foldedRanges.isEmpty)
        #expect(!editor.toggleFold(atRow: 3), "nothing folds at a plain line")

        // Arrows step over a fold: from the header down lands on the line after it, and back up on the header.
        editor.textView.foldedRanges = [NSRange(location: 15, length: 12)]
        editor.folding.lastCaret = 3
        editor.textView.selectedRange = NSRange(location: 18, length: 0)   // where ↓ would put it, inside
        #expect(editor.skipOverFold())
        #expect(editor.textView.selectedRange.location == 28, "the line after it (\"}\"), clamped to its end")
        editor.folding.lastCaret = 28
        editor.textView.selectedRange = NSRange(location: 20, length: 0)
        #expect(editor.skipOverFold())
        #expect(editor.textView.selectedRange.location == 1, "back on the header, column 1")
        #expect(editor.textView.foldedRanges.count == 1, "still folded")
        editor.unfoldAll()

        // A tap on the header's chevron (the gutter's trailing edge) folds, and on "⋯" unfolds.
        editor.textView.layoutIfNeeded()
        let headerY = editor.textView.caretRect(for: editor.textView.beginningOfDocument).midY
        let chevron = CGPoint(x: editor.textView.gutterWidth - 9, y: headerY)
        #expect(editor.handleGutterTap(at: chevron), "gutter \(editor.textView.gutterWidth), y \(headerY)")
        #expect(editor.textView.foldedRanges.count == 1)
        let dots = try #require(editor.placeholderRect(for: editor.textView.foldedRanges[0]))
        #expect(editor.handleGutterTap(at: CGPoint(x: dots.midX, y: dots.midY)))
        #expect(editor.textView.foldedRanges.isEmpty)
    }
}
