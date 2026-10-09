// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

import DesignKit
import Foundation
import Testing
import UIKit
@testable import EditorKit

@MainActor
struct ReloadTests {
    func load(_ editor: CodeEditorController, _ text: String) async {
        var loaded = false
        editor.onLoaded = { loaded = true }
        editor.load(text, language: nil)
        for _ in 0..<200 where !loaded { try? await Task.sleep(for: .milliseconds(10)) }
    }

    /// The file shrank under the caret (an agent rewrote it): the caret ends inside the new text, and
    /// asking the tokenizer about it (what the keyboard does next) doesn't trap.
    @Test func aShorterFileKeepsTheCaretInside() async {
        let editor = CodeEditorController(theme: EditorTheme(palette: .dark, density: .regular))
        editor.textView.frame = CGRect(x: 0, y: 0, width: 800, height: 600)
        await load(editor, "one\ntwo\nthree\nfour\n")
        editor.selectedRange = NSRange(location: 14, length: 4)
        await load(editor, "1\n")
        #expect(editor.selectedRange == NSRange(location: 2, length: 0))
        let textView = editor.textView
        if let caret = textView.selectedTextRange?.start {
            _ = textView.tokenizer.position(from: caret, toBoundary: .line, inDirection: .storage(.forward))
        }
        await load(editor, "one\ntwo\n")
        editor.selectedRange = NSRange(location: 5, length: 0)
        await load(editor, "one\ntwo\nthree\n")
        #expect(editor.selectedRange == NSRange(location: 5, length: 0))
    }
}
