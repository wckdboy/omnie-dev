// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

import XCTest

/// The editor with a hardware keyboard (docs/spikes/editor-p0.md, test 7), through real key events.
/// The editor's accessibility value is "Line N, column M. <that line's text>", which is what the
/// tests read back.
@MainActor
final class EditorKeyboardTests: XCTestCase {
    var app: XCUIApplication!
    var editor: XCUIElement!

    override func setUp() async throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-OmnieUIFixture"]
        app.launch()
        editor = app.textViews.matching(NSPredicate(format: "label BEGINSWITH 'Code editor'")).firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 15), "the editor didn't appear")
        // The first line, then its start: tapping the middle of a short file lands on the last line.
        editor.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.012)).tap()
        // UIKit places the caret only once a double tap is ruled out (~300 ms), as UITextView does.
        sleep(1)
        warmUpKeyboard(app)
        key(.leftArrow, .command)
    }

    func key(_ key: XCUIKeyboardKey, _ modifiers: XCUIElement.KeyModifierFlags = []) {
        app.typeKey(key, modifierFlags: modifiers)
        settle()
    }

    func type(_ text: String) {
        app.typeText(text)
        settle()
    }

    /// Lets the editor's accessibility value catch up with the last key.
    func settle() { usleep(250_000) }

    /// "Line N, column M" and the line's text.
    func position() -> (line: Int, column: Int, text: String) {
        let value = editor.value as? String ?? ""
        let m = value.firstMatch(of: /Line (\d+), column (\d+)\. ?(.*)/)
        return (Int(m?.1 ?? "") ?? -1, Int(m?.2 ?? "") ?? -1, String(m?.3 ?? ""))
    }

    func testArrowsAndJumps() {
        XCTAssertEqual(position().line, 1)
        XCTAssertEqual(position().column, 1)
        key(.downArrow)
        XCTAssertEqual(position().line, 2)
        key(.rightArrow, .command)
        XCTAssertEqual(position().column, 24, "⌘→ goes to the end of the line")
        key(.leftArrow, .option)
        XCTAssertEqual(position().column, 22, "⌥← goes to the start of the word (\"2\" in \"alpha + 2;\")")
        key(.leftArrow, .command)
        XCTAssertEqual(position().column, 1, "⌘← goes to the start of the line")
        key(.downArrow, .command)
        XCTAssertEqual(position().line, 4, "⌘↓ goes to the end of the document")
        key(.upArrow, .command)
        XCTAssertEqual(position().line, 1, "⌘↑ goes back to the first line")
    }

    func testWordSelectionThenShiftArrowsThenTyping() {
        key(.rightArrow, .command)              // end of "let alpha = 1;"
        key(.leftArrow, [.option, .shift])      // select "1;" back to the word start
        key(.leftArrow, [.option, .shift])      // "= " is skipped like UIKit does: back to "alpha"
        key(.rightArrow, .shift)                // shrink by one character
        type("X")
        XCTAssertEqual(position().line, 1)
        XCTAssertEqual(position().text, "let aX")
    }

    func testUndoRedo() {
        key(.rightArrow, .command)
        type(" // note")
        XCTAssertEqual(position().text, "let alpha = 1; // note")
        app.typeKey("z", modifierFlags: .command); settle()
        XCTAssertEqual(position().text, "let alpha = 1;", "⌘Z undoes the typing")
        app.typeKey("z", modifierFlags: [.command, .shift]); settle()
        XCTAssertEqual(position().text, "let alpha = 1; // note", "⇧⌘Z redoes it")
    }

    func testSelectAllCopyPaste() {
        // Copy the first line, paste it at the end of the document.
        key(.rightArrow, [.command, .shift])
        app.typeKey("c", modifierFlags: .command); settle()
        key(.downArrow, .command)
        app.typeKey("v", modifierFlags: .command); settle()
        XCTAssertEqual(position().line, 4)
        XCTAssertEqual(position().text, "let alpha = 1;")
        // Select all and replace.
        app.typeKey("a", modifierFlags: .command); settle()
        type("done")
        XCTAssertEqual(position().line, 1)
        XCTAssertEqual(position().text, "done")
    }
}

/// Under XCUITest the first ⌘ shortcut after a tap is dropped, in a plain UITextView as much as in
/// the editor (checked: ⌘A then typing), so a harmless one goes first.
@MainActor
func warmUpKeyboard(_ app: XCUIApplication) {
    app.typeKey(.rightArrow, modifierFlags: .command)
    usleep(300_000)
}

/// VoiceOver (test 8), the parts a machine can check: Apple's accessibility audit of the main
/// screen, and the editor speaking its name and position.
@MainActor
final class AccessibilityAuditTests: XCTestCase {
    func testEditorSpeaksItsNameAndPosition() {
        let app = XCUIApplication()
        app.launchArguments = ["-OmnieUIFixture"]
        app.launch()
        let editor = app.textViews.matching(NSPredicate(format: "label BEGINSWITH 'Code editor'")).firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 15))
        XCTAssertEqual(editor.label, "Code editor, main.ts")
        editor.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.012)).tap()
        sleep(1)
        // Plain arrows to the start of the line: this test is about what VoiceOver hears.
        for _ in 0..<16 { app.typeKey(.leftArrow, modifierFlags: []) }
        usleep(300_000)
        XCTAssertEqual(editor.value as? String, "Line 1, column 1. let alpha = 1;")
    }

    func testAuditMainScreen() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-OmnieUIFixture"]
        app.launch()
        XCTAssertTrue(app.textViews.matching(NSPredicate(format: "label BEGINSWITH 'Code editor'")).firstMatch.waitForExistence(timeout: 15))
        var issues: [String] = []
        try app.performAccessibilityAudit { issue in
            let label = issue.element?.label ?? ""
            let line = "\(issue.compactDescription) — \(issue.element?.debugDescription.prefix(120) ?? "no element")"
            // The editor's gutter numbers follow the code size, which is separate from Dynamic Type
            // (PLAN.md §883); the one-line status strip truncates at the largest sizes.
            if issue.auditType == .dynamicType, label.allSatisfy(\.isNumber) || issue.compactDescription.contains("partially") {
                print("[a11y] (accepted) \(line)")
            } else {
                issues.append(line)
            }
            return true
        }
        for issue in issues { print("[a11y] \(issue)") }
        XCTAssertTrue(issues.isEmpty, "\(issues.count) accessibility issue(s); see [a11y] lines")
    }
}
