// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

import DesignKit
import Foundation
import Testing
import UIKit
@testable import EditorKit

@MainActor
struct GhostTextTests {
    func loadedEditor(_ text: String) async -> CodeEditorController {
        let editor = CodeEditorController(theme: EditorTheme(palette: .dark, density: .regular))
        editor.textView.frame = CGRect(x: 0, y: 0, width: 800, height: 600)
        var loaded = false
        editor.onLoaded = { loaded = true }
        editor.load(text, language: nil)
        for _ in 0..<200 where !loaded { try? await Task.sleep(for: .milliseconds(10)) }
        return editor
    }

    @Test func onlyAtTheEndOfALine() async {
        let editor = await loadedEditor("let x = \nfoo(bar)\n")
        editor.selectedRange = NSRange(location: 8, length: 0)
        editor.showGhostText("42", at: 8)
        #expect(editor.ghostText == "42")
        editor.clearGhostText()

        // Mid-line (before "bar)") isn't offered.
        editor.selectedRange = NSRange(location: 13, length: 0)
        editor.showGhostText("baz, ", at: 13)
        #expect(editor.ghostText == nil)
        // Multi-line suggestions aren't shown.
        editor.selectedRange = NSRange(location: 8, length: 0)
        editor.showGhostText("1\n2", at: 8)
        #expect(editor.ghostText == nil)
        // A stale location (the caret moved since the request) isn't shown.
        editor.showGhostText("42", at: 7)
        #expect(editor.ghostText == nil)
    }

    @Test func tabAcceptsAndTypingClears() async {
        let editor = await loadedEditor("let x = \n")
        editor.selectedRange = NSRange(location: 8, length: 0)
        var accepted: String?
        editor.onGhostAccepted = { accepted = $0 }
        editor.showGhostText("42", at: 8)
        editor.textView.insertText("\t")
        for _ in 0..<100 where accepted == nil { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(accepted == "42")
        #expect(editor.text == "let x = 42\n")
        #expect(editor.ghostText == nil)

        editor.showGhostText(" + 1", at: 10)
        editor.textView.insertText(";")
        #expect(editor.ghostText == nil)
        #expect(editor.text == "let x = 42;\n")
        // Tab with no suggestion is a normal tab.
        editor.textView.insertText("\t")
        #expect(editor.text.hasPrefix("let x = 42;"))
        #expect(editor.text.count > "let x = 42;\n".count)
    }
}
