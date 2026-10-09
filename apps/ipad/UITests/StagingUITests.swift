// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

import XCTest

/// The Stage view: choose one added line, stage it with S's button, commit only that.
@MainActor
final class StagingUITests: XCTestCase {
    func testStageOneLineAndCommitIt() {
        let app = XCUIApplication()
        app.launchArguments = ["-OmnieUIHistoryFixture", "-OmnieUIStagingFixture", "-OmnieLayout", "standard",
                               "-OmnieNoPanelDrag", "-OmnieRunCommand", "git.commit"]
        app.launch()
        let chosen = app.buttons["Chosen changes"]
        XCTAssertTrue(chosen.waitForExistence(timeout: 15))
        chosen.tap()

        let four = app.descendants(matching: .any)["Added: four"].firstMatch
        XCTAssertTrue(four.waitForExistence(timeout: 5), "a.txt's added line is listed")
        four.tap()
        app.buttons["Stage selected lines"].tap()
        XCTAssertTrue(app.staticTexts["Staged"].waitForExistence(timeout: 5), "the line moved to Staged")

        let message = app.descendants(matching: .any)["commit-message"].firstMatch
        XCTAssertTrue(message.waitForExistence(timeout: 5))
        // Typing through the element focuses it first (app-level keys go wherever focus is).
        message.tap()
        let drafted = (message.value as? String) ?? ""
        message.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: drafted.count + 2))
        message.typeText("Add four")
        app.buttons["Commit"].tap()

        // The commit is in the timeline; notes.txt and the rest of a.txt stay uncommitted.
        app.buttons["Timeline"].firstMatch.tap()
        let row = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Add four'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
    }
}
