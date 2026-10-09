// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

import XCTest

/// Edit history (interactive rebase): drop one commit, move another under the one it fixes and
/// fold it in, apply, and see the timeline; then Undo brings the old history back.
@MainActor
final class HistoryUITests: XCTestCase {
    func testDropFixupApplyAndUndo() {
        let app = XCUIApplication()
        app.launchArguments = ["-OmnieUIHistoryFixture", "-OmnieLayout", "standard", "-OmnieNoPanelDrag",
                               "-OmnieRunCommand", "git.editHistory"]
        app.launch()
        let footer = app.staticTexts["WIP try a footer"].firstMatch
        XCTAssertTrue(footer.waitForExistence(timeout: 15), "the sheet lists the commits")

        // Drop the footer experiment.
        app.buttons.matching(identifier: "Keep, change").element(boundBy: 1).tap()
        app.buttons["Drop"].tap()

        // Move "Fix header typo" (third) up under "Add the header", then fix it up into it.
        let handles = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Reorder'"))
        handles.element(boundBy: 2).press(forDuration: 0.8, thenDragTo: handles.element(boundBy: 1),
                                          withVelocity: .slow, thenHoldForDuration: 0.5)
        let rows = app.buttons.matching(NSPredicate(format: "label ENDSWITH ', change'"))
        // After the move the typo fix is second: its menu.
        rows.element(boundBy: 1).tap()
        app.buttons["Fix up the one above (drop this message)"].tap()

        // The preview: two commits.
        XCTAssertTrue(app.staticTexts["2 commits. Undo puts the old history back."].waitForExistence(timeout: 5))
        app.buttons["Apply"].tap()

        // The timeline shows the new history.
        app.buttons["Timeline"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Add the sign-in form"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["WIP try a footer"].exists)
        XCTAssertFalse(app.staticTexts["Fix header typo"].exists)

        // Undo.
        let undo = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Undo Edit history'")).firstMatch
        XCTAssertTrue(undo.waitForExistence(timeout: 5))
        undo.tap()
        XCTAssertTrue(app.staticTexts["WIP try a footer"].waitForExistence(timeout: 10))
    }
}
