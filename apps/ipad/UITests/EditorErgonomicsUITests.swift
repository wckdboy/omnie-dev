// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

import XCTest

/// The editor's bracket and snippet ergonomics through real key events (PLAN.md §5.1, §11.1). The
/// editor's accessibility value is "Line N, column M. <that line's text>", which the tests read back.
@MainActor
final class EditorErgonomicsUITests: XCTestCase {
    var app: XCUIApplication!
    var editor: XCUIElement!

    override func setUp() async throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-OmnieUIFixture", "-OmnieLayout", "standard", "-OmnieNoWelcome", "-OmnieNoPanelDrag"]
        app.launch()
        editor = app.textViews.matching(NSPredicate(format: "label BEGINSWITH 'Code editor'")).firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 15), "the editor didn't appear")
        editor.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.012)).tap()
        sleep(1)
        warmUpKeyboard(app)
    }

    func settle() { usleep(250_000) }

    func position() -> (line: Int, column: Int, text: String) {
        let value = editor.value as? String ?? ""
        let m = value.firstMatch(of: /Line (\d+), column (\d+)\. ?(.*)/)
        return (Int(m?.1 ?? "") ?? -1, Int(m?.2 ?? "") ?? -1, String(m?.3 ?? ""))
    }

    func testGoToMatchingBracket() {
        app.typeKey("a", modifierFlags: .command); settle()
        app.typeText("(abc)"); settle()
        XCTAssertEqual(position().column, 6, "the caret is after the closing bracket")

        app.typeKey(.leftArrow, modifierFlags: .command); settle()  // start of the line
        app.typeKey(.rightArrow, modifierFlags: []); settle()       // just after "("
        XCTAssertEqual(position().column, 2)

        app.typeKey("\\", modifierFlags: [.command, .shift]); settle()
        XCTAssertEqual(position().column, 5, "⇧⌘\\ lands just before the partner")

        app.typeKey("\\", modifierFlags: [.command, .shift]); settle()
        XCTAssertEqual(position().column, 2, "and back again")
    }

    /// Smart indent: a line break inside a block indents by the file's unit (two spaces here), and
    /// Enter between `{}` opens the block up.
    func testLineBreakIndentsInsideABlock() {
        app.typeKey("a", modifierFlags: .command); settle()
        app.typeText("function f() {"); settle()
        app.typeText("\n"); settle()
        XCTAssertEqual(position().line, 2)
        XCTAssertEqual(position().column, 3, "the new line is indented by two spaces")
        // Enter between the braces opens the block: an indented line, and the closer below it.
        app.typeKey("a", modifierFlags: .command); settle()
        app.typeText("if (x) {}"); settle()
        app.typeKey(.leftArrow, modifierFlags: []); settle()          // between { and }
        app.typeText("\n"); settle()
        XCTAssertEqual(position().line, 2)
        XCTAssertEqual(position().column, 3)
        app.typeKey(.downArrow, modifierFlags: []); settle()
        XCTAssertEqual(position().line, 3)
        XCTAssertEqual(position().text, "}", "the closing brace is on its own line, not indented")
    }

    /// ⌘D selects the word, then adds the next occurrence as a real selection; typing replaces every
    /// one in a single undo step (engine 0.7.0's multi-selection).
    func testSelectNextOccurrenceThenTypingReplacesEveryOne() {
        // The fixture's line 1 is "let alpha = 1;" and line 2 has another "alpha".
        app.typeKey(.leftArrow, modifierFlags: .command); settle()   // start of line 1
        app.typeKey(.rightArrow, modifierFlags: .option); settle()   // end of "let"
        app.typeKey(.rightArrow, modifierFlags: []); settle()        // start of "alpha"
        XCTAssertEqual(position().column, 5)
        app.typeKey("d", modifierFlags: .command); settle()          // select "alpha"
        XCTAssertEqual(position().text, "let alpha = 1;")
        app.typeKey("d", modifierFlags: .command); settle()          // add "alpha" on line 2
        app.typeText("x"); settle()                                  // replace both
        XCTAssertEqual(position().line, 1)
        XCTAssertEqual(position().text, "let x = 1;")
        app.typeKey(.downArrow, modifierFlags: []); settle()
        XCTAssertEqual(position().line, 2)
        XCTAssertEqual(position().text, "const beta = x + 2;", "line 2's occurrence was replaced too")
        // One undo puts both back.
        app.typeKey("z", modifierFlags: .command); settle()
        app.typeKey(.upArrow, modifierFlags: []); settle()
        XCTAssertEqual(position().text, "let alpha = 1;")
    }
}
