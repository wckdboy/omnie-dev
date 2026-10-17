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
