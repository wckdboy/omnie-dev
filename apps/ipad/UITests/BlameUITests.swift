// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

import XCTest

/// Blame: the column names who changed each run of lines; tapping one opens the timeline.
@MainActor
final class BlameUITests: XCTestCase {
    func testBlameRunsOpenTheTimeline() {
        let app = XCUIApplication()
        app.launchArguments = ["-OmnieUIHistoryFixture", "-OmnieLayout", "standard", "-OmnieNoPanelDrag",
                               "-OmnieOpenFile", "a.txt", "-OmnieRunCommand", "git.blame"]
        app.launch()
        let run = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Lines 1 to 1: UI Test'")).firstMatch
        XCTAssertTrue(run.waitForExistence(timeout: 15), "the blame column describes line 1")
        run.tap()
        let timeline = app.buttons["Timeline"].firstMatch
        XCTAssertTrue(timeline.waitForExistence(timeout: 5))
        XCTAssertTrue(timeline.isSelected, "tapping a run shows the timeline")
    }
}
