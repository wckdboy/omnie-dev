// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

import XCTest

/// TypeScript intelligence in the editor, against the fixture's main.ts:
///   1 let alpha = 1;
///   2 const beta = alpha + 2;
///   3 function gamma() { return beta; }
@MainActor
final class CodeIntelUITests: XCTestCase {
    var app: XCUIApplication!

    func launch(at place: String, _ commands: [String]) {
        app = XCUIApplication()
        app.launchArguments = ["-OmnieUIFixture", "-OmnieOpenFile", place, "-OmnieLayout", "standard", "-OmnieNoWelcome", "-OmnieNoPanelDrag"]
            + commands.flatMap { ["-OmnieRunCommand", $0] }
        app.launch()
        XCTAssertTrue(editor.waitForExistence(timeout: 15))
    }

    var editor: XCUIElement { app.textViews.matching(NSPredicate(format: "label BEGINSWITH 'Code editor'")).firstMatch }

    func waitForEditor(_ prefix: String, timeout: TimeInterval = 20) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if (editor.value as? String ?? "").hasPrefix(prefix) { return true }
            usleep(250_000)
        }
        return false
    }

    /// A screenshot to $OMNIE_SHOTS_DIR when it's set (TEST_RUNNER_OMNIE_SHOTS_DIR).
    func shot(_ name: String) {
        guard let dir = ProcessInfo.processInfo.environment["OMNIE_SHOTS_DIR"] else { return }
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: URL(filePath: dir).appending(path: "\(name).png"))
    }

    func testGoToDefinition() {
        // On `beta` in line 3: its declaration is line 2, column 7.
        launch(at: "main.ts:3:28", ["editor.goToDefinition"])
        XCTAssertTrue(waitForEditor("Line 2, column 7."), "\(editor.value ?? "")")
    }

    func testEditMenuGoesToDefinition() {
        launch(at: "main.ts:1:1", [])
        // A long press on `beta` in line 3 ("function gamma() { return beta; }") selects it and
        // shows the edit menu, whose code items follow the system's.
        let origin = app.coordinate(withNormalizedOffset: .zero)
        origin.withOffset(CGVector(dx: 237, dy: 105)).press(forDuration: 1.2)
        sleep(1)
        shot("edit-menu")
        var item = app.menuItems["Go to Definition"]
        for _ in 0..<3 where !item.exists {
            // Later pages of the menu.
            let more = app.buttons.matching(NSPredicate(format: "label == 'Forward' OR identifier == 'Forward'")).firstMatch
            guard more.exists else { break }
            more.tap()
            item = app.menuItems["Go to Definition"]
        }
        XCTAssertTrue(item.waitForExistence(timeout: 5))
        item.tap()
        XCTAssertTrue(waitForEditor("Line 2, column 7."), "\(editor.value ?? "")")
    }

    func testFindReferencesAndRename() {
        launch(at: "main.ts:1:6", ["editor.findReferences"])
        XCTAssertTrue(app.navigationBars["2 references"].waitForExistence(timeout: 20))
        shot("references")
        XCTAssertTrue(app.staticTexts["main.ts"].exists || app.staticTexts["MAIN.TS"].exists)
        app.buttons["Done"].tap()

        app.terminate()
        launch(at: "main.ts:1:6", ["editor.rename"])
        let field = app.textFields["rename-field"]
        XCTAssertTrue(field.waitForExistence(timeout: 20))
        field.tap()
        field.press(forDuration: 0.1)
        if let value = field.value as? String {
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: value.count))
        }
        field.typeText("first")
        app.buttons["rename-go"].tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Renamed alpha to first: 2 places'")).firstMatch.waitForExistence(timeout: 20))
        XCTAssertTrue(waitForEditor("Line 1,"))
        XCTAssertTrue((editor.value as? String ?? "").hasSuffix(". let first = 1;"), "\(editor.value ?? "")")
    }

    func testQuickInfo() {
        launch(at: "main.ts:3:11", ["editor.quickInfo"])
        let card = app.descendants(matching: .any)["info-card"]
        XCTAssertTrue(card.waitForExistence(timeout: 20))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'function gamma(): number'")).firstMatch.exists)
        shot("quick-info")
    }

    func testCompletionsAsYouType() {
        launch(at: "main.ts:4:1", [])
        editor.tap()
        app.typeKey(.downArrow, modifierFlags: .command)
        app.typeText("be")
        let item = app.buttons["beta, const"]
        XCTAssertTrue(item.waitForExistence(timeout: 20), "the list offers beta")
        sleep(1)
        shot("completions")
        item.tap()
        XCTAssertTrue(waitForEditor("Line 4, column 5. beta"), "\(editor.value ?? "")")
    }
}
