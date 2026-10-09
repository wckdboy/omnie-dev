// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

import XCTest

/// Remotes: add one (labeled by host), then preview moving the repo to another forge.
@MainActor
final class RemotesUITests: XCTestCase {
    func testAddRemoteAndPreviewAMove() {
        let app = XCUIApplication()
        app.launchArguments = ["-OmnieUIHistoryFixture", "-OmnieLayout", "standard", "-OmnieNoPanelDrag", "-OmnieRunCommand", "git.remotes"]
        app.launch()
        let name = app.textFields["Name"]
        XCTAssertTrue(name.waitForExistence(timeout: 15))
        func type(_ field: XCUIElement, _ text: String) {
            for _ in 0..<5 where (field.value(forKey: "hasKeyboardFocus") as? Bool) != true { field.tap(); sleep(1) }
            app.typeText(text)
        }
        type(name, "origin")
        type(app.textFields["URL (https:// or git@host:path)"], "https://forgejo.example.net/me/app.git")
        app.buttons["Add remote"].tap()
        let label = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'origin · forgejo.example.net'")).firstMatch
        XCTAssertTrue(label.waitForExistence(timeout: 5), "the remote is listed with its host")

        type(app.textFields["New remote's name (e.g. forgejo)"], "codeberg")
        type(app.textFields["New forge URL"], "https://codeberg.org/me/app.git")
        let step = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'Push 1 branch and 0 tags to “codeberg”'")).firstMatch
        XCTAssertTrue(step.waitForExistence(timeout: 5), "the move is previewed step by step")
        // The button sits under the steps, below the fold.
        let move = app.buttons["Move"]
        for _ in 0..<3 where !move.isHittable { app.swipeUp() }
        XCTAssertTrue(move.isHittable)
    }
}
