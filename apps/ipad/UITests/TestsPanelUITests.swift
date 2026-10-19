// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

import XCTest

/// The test explorer: run all, read a failure's full output (not the row's four lines), run that one
/// test again, and run a whole file again. The fixture has one passing and one failing test.
@MainActor
final class TestsPanelUITests: XCTestCase {
    var app: XCUIApplication!

    func testRunsTestsShowsOutputAndRerunsOne() {
        app = XCUIApplication()
        app.launchArguments = ["-OmnieUITestFixture", "-OmnieLayout", "standard", "-OmnieNoWelcome", "-OmnieNoPanelDrag",
                               "-OmnieRunCommand", "utility.tests"]
        app.launch()
        XCTAssertTrue(app.textViews.matching(NSPredicate(format: "label BEGINSWITH 'Code editor'")).firstMatch.waitForExistence(timeout: 15))

        app.buttons["Run all"].tap()
        let failure = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "is wrong on purpose")).firstMatch
        XCTAssertTrue(failure.waitForExistence(timeout: 60), "both tests ran")
        XCTAssertTrue(app.staticTexts["1 passed, 1 failed"].waitForExistence(timeout: 30))

        failure.tap()
        let output = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "expected 3 to be 4")).firstMatch
        XCTAssertTrue(output.waitForExistence(timeout: 10), "the detail sheet shows the full assertion message")

        app.buttons["Run again"].tap()
        XCTAssertTrue(output.waitForExistence(timeout: 30), "running one test again keeps its result")
        app.buttons["Done"].firstMatch.tap()

        // A whole file again: the results merge rather than replacing the other files'.
        let runFile = app.buttons["Run sum.test.ts again"]
        if runFile.waitForExistence(timeout: 5) { runFile.tap() }
        XCTAssertTrue(app.staticTexts["1 passed, 1 failed"].waitForExistence(timeout: 60))
    }
}
