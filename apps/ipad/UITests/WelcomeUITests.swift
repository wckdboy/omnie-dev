// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

import XCTest

/// First run: the welcome shows, and "Try the sample project" opens a committed copy of it.
@MainActor
final class WelcomeUITests: XCTestCase {
    func testSampleProjectFromTheWelcome() {
        let app = XCUIApplication()
        // As on a first launch (the argument domain wins over what earlier runs stored).
        app.launchArguments = ["-onboarding.done", "NO", "-OmnieLayout", "standard", "-OmnieNoPanelDrag"]
        app.launch()
        let sample = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Try the sample project'")).firstMatch
        XCTAssertTrue(sample.waitForExistence(timeout: 15), "the welcome shows on first launch")
        sample.tap()
        // The sample opens with its README in the editor.
        let readme = app.textViews["Code editor, README.md"]
        XCTAssertTrue(readme.waitForExistence(timeout: 15), "the sample project opened")
        XCTAssertFalse(sample.exists, "the welcome closed")
    }
}
