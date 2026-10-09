// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

import XCTest

/// A project comes back as you left it: its open file, with the caret where it was.
@MainActor
final class SessionRestoreUITests: XCTestCase {
    func testTheOpenFileAndCaretComeBack() {
        let app = XCUIApplication()
        app.launchArguments = ["-OmnieUIFixture", "-OmnieOpenFile", "main.ts:3", "-OmnieRestoreSessions",
                               "-OmnieLayout", "standard", "-OmnieNoWelcome", "-OmnieNoPanelDrag"]
        app.launch()
        let line3 = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Ln 3,'")).firstMatch
        XCTAssertTrue(line3.waitForExistence(timeout: 15), "the fixture opens main.ts on line 3")
        // Going to the background saves the session, caret included.
        XCUIDevice.shared.press(.home)
        sleep(1)
        app.terminate()

        // No fixture this time: the last project reopens by itself.
        app.launchArguments = ["-OmnieRestoreSessions", "-OmnieLayout", "standard", "-OmnieNoWelcome", "-OmnieNoPanelDrag"]
        app.launch()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Ln 3,'")).firstMatch.waitForExistence(timeout: 15),
                      "main.ts is open again with the caret on line 3")
        XCTAssertTrue(app.textViews["Code editor, main.ts"].exists || app.descendants(matching: .any)["Code editor, main.ts"].exists)
    }
}
