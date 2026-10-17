// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

import DesignKit
import Foundation
import Testing
import UIKit
@testable import EditorKit

@MainActor
struct SearchTests {
    private func loadedEditor(_ text: String) async -> CodeEditorController {
        let editor = CodeEditorController(theme: EditorTheme(palette: .dark, density: .regular))
        editor.textView.frame = CGRect(x: 0, y: 0, width: 600, height: 400)
        var loaded = false
        editor.onLoaded = { loaded = true }
        editor.load(text, language: nil)
        for _ in 0..<200 where !loaded { try? await Task.sleep(for: .milliseconds(10)) }
        return editor
    }

    @Test func findsMatchesByCase() async {
        let editor = await loadedEditor("foo bar foo\nFoo foo\n")
        #expect(editor.searchRanges("foo", caseSensitive: true).count == 3)
        #expect(editor.searchRanges("foo", caseSensitive: false).count == 4)
        #expect(editor.searchRanges("", caseSensitive: true).isEmpty)
        #expect(editor.searchRanges("missing", caseSensitive: false).isEmpty)
    }

    @Test func wholeWordAndRegex() async {
        let editor = await loadedEditor("foo foobar\nfoo Foo\n")
        #expect(editor.searchRanges("foo", caseSensitive: true).count == 3)
        #expect(editor.searchRanges("foo", caseSensitive: true, wholeWord: true).count == 2, "not the one inside foobar")
        #expect(editor.searchRanges("foo", caseSensitive: false).count == 4)

        let words = await loadedEditor("foo fxo foobar\n")
        #expect(words.searchRanges("f.o", caseSensitive: true, regex: true).count == 3, "regex: foo, fxo, foo")
        #expect(words.searchRanges("\\bfoo\\b", caseSensitive: true, regex: true).count == 1, "whole-word via the pattern")
        #expect(words.searchRanges("(", caseSensitive: true, regex: true).isEmpty, "an invalid pattern finds nothing")
    }

    @Test func highlightsAndClears() async {
        let editor = await loadedEditor("one two one\n")
        editor.setSearchHighlights(editor.searchRanges("one", caseSensitive: true), current: 0)
        #expect(editor.textView.decorations.contains { $0.id == "find-0" })
        #expect(editor.textView.decorations.contains { $0.id == "find-1" })
        editor.clearSearchHighlights()
        #expect(!editor.textView.decorations.contains { $0.id.hasPrefix("find-") })
    }

    @Test func replacesEveryMatch() async {
        let editor = await loadedEditor("foo bar foo\nFoo foo\n")
        let ranges = editor.searchRanges("foo", caseSensitive: true)
        #expect(editor.replaceAll(ranges, with: "baz") == 3)
        #expect(editor.text == "baz bar baz\nFoo baz\n")
    }

    @Test func scopeLimitsMatchesToASelection() async {
        let editor = await loadedEditor("foo bar foo\nfoo\n")
        #expect(editor.searchRanges("foo", caseSensitive: true).count == 3)
        // Find in Selection: only matches inside the scope count.
        #expect(editor.searchRanges("foo", caseSensitive: true, scope: NSRange(location: 0, length: 3)).count == 1)
        #expect(editor.searchRanges("foo", caseSensitive: true, scope: NSRange(location: 0, length: 9)).count == 2)
        #expect(editor.searchRanges("foo", caseSensitive: true, scope: NSRange(location: 12, length: 3)).count == 1)
        // Replace All then only touches the scoped matches.
        let scoped = editor.searchRanges("foo", caseSensitive: true, scope: NSRange(location: 0, length: 3))
        #expect(editor.replaceAll(scoped, with: "bar") == 1)
        #expect(editor.text == "bar bar foo\nfoo\n")
    }
}
