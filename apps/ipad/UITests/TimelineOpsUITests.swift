// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

import XCTest

/// Timeline operations: tag a commit, reset to it keeping the changes, undo, and the reflog.
@MainActor
final class TimelineOpsUITests: XCTestCase {
    func testTagResetUndoAndReflog() {
        let app = XCUIApplication()
        app.launchArguments = ["-OmnieUIHistoryFixture", "-OmnieLayout", "standard", "-OmnieNoPanelDrag",
                               "-OmnieRunCommand", "git.timeline"]
        app.launch()
        func row(_ summary: String) -> XCUIElement {
            app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", summary)).firstMatch
        }
        let header = row("Add the header")
        XCTAssertTrue(header.waitForExistence(timeout: 15))

        // Tag it.
        header.press(forDuration: 1.0)
        app.buttons["Tag…"].tap()
        app.textFields["v1.0"].typeText("v0.1")
        app.alerts.buttons["Tag"].tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'v0.1'")).firstMatch.waitForExistence(timeout: 5), "the tag shows on the row")

        // Reset to it: the three later commits leave the list, their changes stay uncommitted.
        row("Add the header").press(forDuration: 1.0)
        app.buttons["Reset to here (keep changes)"].tap()
        app.buttons["Reset, keep the changes"].tap()
        let gone = NSPredicate(format: "exists == false")
        expectation(for: gone, evaluatedWith: row("Add the sign-in form"))
        waitForExpectations(timeout: 10)

        // Undo brings them back.
        let undo = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Undo Reset to'")).firstMatch
        XCTAssertTrue(undo.waitForExistence(timeout: 5))
        undo.tap()
        XCTAssertTrue(row("Add the sign-in form").waitForExistence(timeout: 10))

        // The reflog has the reset in it.
        // The switch itself sits at the row's trailing edge.
        app.switches["Show everything (reflog)"].firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        let entry = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'reset to'")).firstMatch
        XCTAssertTrue(entry.waitForExistence(timeout: 5))
    }
}
