// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

import XCTest

/// Editor 2: the open file in a second editor; what's typed there reaches the main editor after
/// its autosave.
@MainActor
final class SplitEditorUITests: XCTestCase {
    func testEditsInTheSplitReachTheMainEditor() {
        let app = XCUIApplication()
        app.launchArguments = ["-OmnieUIFixture", "-OmnieLayout", "standard", "-OmnieNoPanelDrag", "-OmnieRunCommand", "view.split"]
        app.launch()
        let second = app.textViews["Second editor, main.ts"]
        XCTAssertTrue(second.waitForExistence(timeout: 15), "Editor 2 shows the open file")
        second.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.02)).tap()
        sleep(1)
        warmUpKeyboard(app)
        app.typeKey(.upArrow, modifierFlags: .command)
        app.typeKey(.leftArrow, modifierFlags: .command)
        app.typeText("// split\n")
        // Autosave after 3 s, then the main editor reloads the file.
        let main = app.textViews.matching(NSPredicate(format: "label BEGINSWITH 'Code editor'")).firstMatch
        sleep(5)
        // The main editor reads out its caret's line: put the caret on line 1 there.
        main.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.02)).tap()
        sleep(1)
        warmUpKeyboard(app)
        app.typeKey(.upArrow, modifierFlags: .command)
        usleep(300_000)
        XCTAssertEqual(main.value as? String, "Line 1, column 1. // split")
    }
}
