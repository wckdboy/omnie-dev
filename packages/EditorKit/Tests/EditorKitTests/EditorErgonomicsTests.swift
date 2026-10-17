// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

import DesignKit
import Foundation
import Testing
import UIKit
@testable import EditorKit

@MainActor
struct EditorErgonomicsTests {
    private func loadedEditor(_ text: String) async -> CodeEditorController {
        let editor = CodeEditorController(theme: EditorTheme(palette: .dark, density: .regular))
        editor.textView.frame = CGRect(x: 0, y: 0, width: 600, height: 400)
        var loaded = false
        editor.onLoaded = { loaded = true }
        editor.load(text, language: nil)
        for _ in 0..<200 where !loaded { try? await Task.sleep(for: .milliseconds(10)) }
        return editor
    }

    // MARK: Snippets

    @Test func insertsASnippetAndWalksItsStops() async {
        let editor = await loadedEditor("    \n")
        editor.selectedRange = NSRange(location: 4, length: 0)
        editor.insertSnippet("if ($1) {\n  $2\n}")
        // The line's indent is added after each newline.
        #expect(editor.text == "    if () {\n      \n    }\n")
        // The first stop is selected (empty, inside the parens), then Tab takes the second.
        #expect(editor.selectedRange == NSRange(location: 8, length: 0))
        editor.snippetNext()
        #expect(editor.selectedRange == NSRange(location: 18, length: 0))
        // Tab past the last stop ends the session at the end of the snippet.
        editor.snippetNext()
        #expect(editor.snippet == nil)
        #expect(editor.selectedRange == NSRange(location: 24, length: 0))
    }

    @Test func typingFillsAStopAndKeepsTheRestInPlace() async {
        let editor = await loadedEditor("")
        editor.insertSnippet("${1:name} = ${2:value};")
        #expect(editor.text == "name = value;")
        #expect(editor.selectedRange == NSRange(location: 0, length: 4))
        // Typing over the first default replaces it and pulls the second stop along.
        editor.textView.insertText("count")
        #expect(editor.text == "count = value;")
        editor.snippetNext()
        #expect(editor.selectedRange == NSRange(location: 8, length: 5))
        editor.textView.insertText("1")
        #expect(editor.text == "count = 1;")
    }

    @Test func escapeLeavesTheTextInPlace() async {
        let editor = await loadedEditor("")
        editor.insertSnippet("$1$0")
        #expect(editor.snippet != nil)
        editor.endSnippet()
        #expect(editor.snippet == nil)
        #expect(editor.text == "")
    }

    @Test func loadingAFileDropsTheSession() async {
        let editor = await loadedEditor("")
        editor.insertSnippet("$1")
        #expect(editor.snippet != nil)
        editor.load("other\n", language: nil)
        #expect(editor.snippet == nil)
    }

    // MARK: Text transforms

    @Test func transformsTheSelectionOrTheWordAtTheCaret() async {
        let editor = await loadedEditor("let alpha = 1;\n")
        // Nothing selected: the word at the caret, left selected after the change.
        editor.selectedRange = NSRange(location: 6, length: 0)
        #expect(editor.transformCase(.upper))
        #expect(editor.text == "let ALPHA = 1;\n")
        #expect(editor.selectedRange == NSRange(location: 4, length: 5))
        // A selection is transformed in place.
        editor.selectedRange = NSRange(location: 0, length: 3)
        #expect(editor.transformCase(.title))
        #expect(editor.text == "Let ALPHA = 1;\n")
        #expect(editor.selectedRange == NSRange(location: 0, length: 3))
        // Nothing to do on punctuation.
        editor.selectedRange = NSRange(location: 10, length: 0)
        #expect(!editor.transformCase(.lower))
    }

    @Test func convertsTheWholeFileIndentation() async {
        let editor = await loadedEditor("\tfoo\n\t\tbar\n")
        editor.selectedRange = NSRange(location: 2, length: 0)   // after the tab
        editor.convertIndentation(toSpaces: true, unit: "  ")
        #expect(editor.text == "  foo\n    bar\n")
        #expect(editor.selectedRange == NSRange(location: 3, length: 0), "the caret stays put")
        editor.convertIndentation(toSpaces: false, unit: "  ")
        #expect(editor.text == "\tfoo\n\t\tbar\n")
        #expect(editor.selectedRange == NSRange(location: 2, length: 0))
    }

    // MARK: Selection

    @Test func expandsAndShrinksSelection() async {
        let editor = await loadedEditor("a = f(b, g(c))\n")
        // A caret inside "b" walks out: word, the outer brackets' contents, the brackets, the line.
        editor.selectedRange = NSRange(location: 6, length: 0)
        editor.expandSelection()
        #expect(editor.selectedRange == NSRange(location: 6, length: 1), "the word")
        editor.expandSelection()
        #expect(editor.selectedRange == NSRange(location: 6, length: 7), "b, g(c")
        editor.expandSelection()
        #expect(editor.selectedRange == NSRange(location: 5, length: 9), "f(b, g(c))")
        editor.expandSelection()
        #expect(editor.selectedRange == NSRange(location: 0, length: 15), "the line")
        editor.expandSelection()
        #expect(editor.selectedRange == NSRange(location: 0, length: 15), "nothing larger")
        editor.shrinkSelection()
        #expect(editor.selectedRange == NSRange(location: 5, length: 9))
        editor.shrinkSelection()
        #expect(editor.selectedRange == NSRange(location: 6, length: 7))
    }

    // MARK: Brackets

    @Test func jumpsToTheMatchingBracketBothWays() async {
        let editor = await loadedEditor("(abc)\n")
        editor.selectedRange = NSRange(location: 1, length: 0)
        editor.goToMatchingBracket()
        #expect(editor.selectedRange == NSRange(location: 4, length: 0))
        editor.goToMatchingBracket()
        #expect(editor.selectedRange == NSRange(location: 1, length: 0))
    }

    @Test func jumpsWithinNestedBrackets() async {
        let editor = await loadedEditor("f(a, (b))\n")
        editor.selectedRange = NSRange(location: 6, length: 0)
        editor.goToMatchingBracket()
        #expect(editor.selectedRange == NSRange(location: 7, length: 0))
        editor.goToMatchingBracket()
        #expect(editor.selectedRange == NSRange(location: 6, length: 0))
    }

    @Test func selectsToTheMatchingBracket() async {
        let editor = await loadedEditor("(abc)\n")
        editor.selectedRange = NSRange(location: 1, length: 0)
        editor.selectToMatchingBracket()
        #expect(editor.selectedRange == NSRange(location: 1, length: 4))
        #expect((editor.text as NSString).substring(with: editor.selectedRange) == "abc)")
    }

    @Test func doesNothingWithoutABracket() async {
        let editor = await loadedEditor("plain text\n")
        editor.selectedRange = NSRange(location: 3, length: 0)
        editor.goToMatchingBracket()
        #expect(editor.selectedRange == NSRange(location: 3, length: 0))
        editor.selectToMatchingBracket()
        #expect(editor.selectedRange == NSRange(location: 3, length: 0))
    }
}
