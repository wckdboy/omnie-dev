// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

import XCTest

/// The docks: a panel moves to another dock from its tab's menu, and the layout is kept.
@MainActor
final class PaneLayoutUITests: XCTestCase {
    func testMovePanelToBottomDockAndBack() {
        let app = XCUIApplication()
        app.launchArguments = ["-OmnieUIFixture", "-OmnieLayout", "standard", "-OmnieNoPanelDrag"]
        app.launch()
        let terminal = app.buttons["Terminal"].firstMatch
        XCTAssertTrue(terminal.waitForExistence(timeout: 15))
        let rightX = terminal.frame.midX
        XCTAssertGreaterThan(rightX, app.frame.width / 2, "the terminal starts in the right dock")

        terminal.press(forDuration: 1.0)
        let toBottom = app.buttons["Bottom dock"]
        XCTAssertTrue(toBottom.waitForExistence(timeout: 5))
        toBottom.tap()
        // Now under the editor: lower half, and no longer in the right dock's tab bar.
        let moved = app.buttons["Terminal"].firstMatch
        XCTAssertTrue(moved.waitForExistence(timeout: 5))
        XCTAssertGreaterThan(moved.frame.midY, app.frame.height / 2)
        XCTAssertLessThan(moved.frame.midX, rightX)

        // It survives a relaunch (no preset this time).
        app.terminate()
        app.launchArguments = ["-OmnieUIFixture", "-OmnieNoPanelDrag"]
        app.launch()
        let again = app.buttons["Terminal"].firstMatch
        XCTAssertTrue(again.waitForExistence(timeout: 15))
        XCTAssertGreaterThan(again.frame.midY, app.frame.height / 2)

        // And back: into its own group on the right.
        again.press(forDuration: 1.0)
        let toRight = app.buttons["Right dock"]
        XCTAssertTrue(toRight.waitForExistence(timeout: 5))
        toRight.tap()
        XCTAssertGreaterThan(app.buttons["Terminal"].firstMatch.frame.midX, app.frame.width / 2)
    }

    func testDragPanelToAnotherGroup() {
        let app = XCUIApplication()
        app.launchArguments = ["-OmnieUIFixture", "-OmnieLayout", "terminalBelow"]
        app.launch()
        let preview = app.buttons["Preview"].firstMatch
        let terminal = app.buttons["Terminal"].firstMatch
        XCTAssertTrue(preview.waitForExistence(timeout: 15) && terminal.exists)
        XCTAssertGreaterThan(terminal.frame.midY, app.frame.height / 2, "the terminal starts in the bottom dock")
        XCTAssertLessThan(preview.frame.midY, app.frame.height / 2, "the preview starts in the right dock")
        // Drag the preview's tab onto the terminal's: it joins the bottom group.
        preview.press(forDuration: 0.6, thenDragTo: terminal)
        let moved = app.buttons["Preview"].firstMatch
        XCTAssertTrue(moved.waitForExistence(timeout: 5))
        XCTAssertLessThan(abs(moved.frame.midY - app.buttons["Terminal"].firstMatch.frame.midY), 4, "the preview joined the terminal's tab bar")
    }

    func testOpenPanelInNewWindow() {
        let app = XCUIApplication()
        app.launchArguments = ["-OmnieUIFixture", "-OmnieLayout", "standard", "-OmnieNoPanelDrag"]
        app.launch()
        let preview = app.buttons["Preview"].firstMatch
        XCTAssertTrue(preview.waitForExistence(timeout: 15))
        let windows = app.windows.count
        preview.press(forDuration: 1.0)
        let open = app.buttons["Open in new window"]
        XCTAssertTrue(open.waitForExistence(timeout: 5))
        open.tap()
        // A second window, and the preview's tab left the dock.
        let deadline = Date().addingTimeInterval(10)
        while app.windows.count <= windows && Date() < deadline { usleep(200_000) }
        XCTAssertGreaterThan(app.windows.count, windows, "a window opened for the panel")
        XCTAssertFalse(app.buttons.matching(identifier: "Preview").allElementsBoundByIndex.contains { $0.isHittable && $0.frame.height < 80 },
                       "no Preview tab is left in the docks")
    }
}
