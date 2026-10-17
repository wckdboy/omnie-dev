// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

import XCTest

/// The debugger end to end: a breakpoint on main.ts's second line, started at launch (F9 and F5 run
/// the same commands; XCUITest can't send function keys), and the Debug panel showing the stop, its
/// locals and the call stack — then continuing out of it.
@MainActor
final class DebuggerUITests: XCTestCase {
    func testStopsAtABreakpointAndShowsLocals() {
        let app = XCUIApplication()
        app.launchArguments = ["-OmnieUIFixture", "-OmnieLayout", "standard", "-OmnieNoWelcome", "-OmnieNoPanelDrag",
                               "-OmnieOpenFile", "main.ts:2",
                               "-OmnieRunCommand", "debug.toggleBreakpoint",
                               "-OmnieRunCommand", "debug.startOrContinue"]
        app.launch()

        // "Locals" only shows while stopped, so it is the pause's signal (the controls are always there).
        XCTAssertTrue(app.staticTexts["Locals"].waitForExistence(timeout: 60), "the debugger didn't stop")
        XCTAssertTrue(app.staticTexts["Call stack"].exists)
        // main.ts:2 is `const beta = alpha + 2;`, so `alpha` is in scope.
        XCTAssertTrue(app.staticTexts["alpha"].exists, "alpha should be in scope")
        XCTAssertTrue(app.staticTexts["main.ts:2"].exists, "the stop's frame should be listed")

        // Evaluate in the paused frame: `alpha + 1` is 3.
        let field = app.textFields["Evaluate"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText("alpha + 1\n")
        XCTAssertTrue(app.staticTexts["3"].waitForExistence(timeout: 10), "the expression's result didn't come back")

        app.buttons["Continue"].tap()
        XCTAssertTrue(app.staticTexts["Locals"].waitForNonExistence(timeout: 30), "continue didn't leave the stop")
    }
}
