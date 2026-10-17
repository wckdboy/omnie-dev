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
}
