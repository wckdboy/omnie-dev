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

    func testPython() {
        app = XCUIApplication()
        // On `area` in `print(area(2, 3))`: its definition is in geometry.py.
        app.launchArguments = ["-OmnieUIPyFixture", "-OmnieOpenFile", "app.py:3:8", "-OmnieLayout", "standard",
                               "-OmnieNoWelcome", "-OmnieNoPanelDrag", "-OmnieRunCommand", "editor.goToDefinition"]
        app.launch()
        XCTAssertTrue(app.textViews["Code editor, geometry.py"].waitForExistence(timeout: 60), "Jedi found the definition")
        XCTAssertTrue(waitForEditor("Line 3, column 5."), "\(editor.value ?? "")")
        // Completions as you type, from Jedi.
        editor.tap()
        sleep(1)
        app.typeKey(.downArrow, modifierFlags: .command)
        app.typeText("\nimport os\nos.pa")
        XCTAssertTrue(app.buttons["path, module"].waitForExistence(timeout: 20) || app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'pathsep'")).firstMatch.exists)
        shot("python-completions")
    }

    func testFormatDocument() {
        // Prettier puts gamma's body on lines of its own: 4 lines become 6.
        launch(at: "main.ts:1:1", ["editor.format"])
        // Formatting changes the file: it's unsaved once Prettier has answered.
        XCTAssertTrue(app.staticTexts["Unsaved"].waitForExistence(timeout: 30))
        editor.tap()
        sleep(1)
        app.typeKey(.downArrow, modifierFlags: .command)
        XCTAssertTrue(waitForEditor("Line 6,"), "\(editor.value ?? "")")
        app.typeKey(.upArrow, modifierFlags: .command)
        XCTAssertTrue(waitForEditor("Line 1,"))
        for _ in 0..<3 {
            app.typeKey(.downArrow, modifierFlags: [])
            usleep(300_000)
        }
        XCTAssertTrue(waitForEditor("Line 4,"))
        XCTAssertTrue((editor.value as? String ?? "").hasSuffix(".   return beta;"), "\(editor.value ?? "")")
    }

    func lineText(_ line: Int) -> String {
        editor.tap()
        usleep(500_000)
        app.typeKey(.upArrow, modifierFlags: .command)
        usleep(300_000)
        for _ in 1..<line {
            app.typeKey(.downArrow, modifierFlags: [])
            usleep(300_000)
        }
        let value = editor.value as? String ?? ""
        return value.components(separatedBy: ". ").dropFirst().joined(separator: ". ")
    }

    func testMultipleCursors() {
        // Change all occurrences of `alpha`, then type its new name once.
        launch(at: "main.ts:1:1", [])
        editor.tap()
        sleep(1)
        warmUpKeyboard(app)
        app.typeKey(.upArrow, modifierFlags: .command)
        for _ in 0..<5 {
            app.typeKey(.rightArrow, modifierFlags: [])
            usleep(200_000)
        }
        app.typeKey("l", modifierFlags: [.command, .shift])
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH '2 cursors'")).firstMatch.waitForExistence(timeout: 10))
        app.typeText("first")
        sleep(1)
        XCTAssertEqual(lineText(1), "let first = 1;")
        XCTAssertEqual(lineText(2), "const beta = first + 2;")

        // Cursors on three lines' starts (⌥⌘↓ twice), then one comment marker typed at all three.
        app.typeKey(.upArrow, modifierFlags: .command)
        usleep(300_000)
        app.typeKey(.downArrow, modifierFlags: [.option, .command])
        usleep(300_000)
        app.typeKey(.downArrow, modifierFlags: [.option, .command])
        usleep(300_000)
        app.typeText("# ")
        sleep(1)
        XCTAssertEqual(lineText(1), "# let first = 1;")
        XCTAssertTrue(lineText(3).hasPrefix("# function gamma() { return beta; }"))   // then its diagnostics, read out
    }

    func testPythonProblemsFromRuff() {
        app = XCUIApplication()
        app.launchArguments = ["-OmnieUIPyFixture", "-OmnieOpenFile", "geometry.py", "-OmnieLayout", "standard",
                               "-OmnieNoWelcome", "-OmnieNoPanelDrag"]
        app.launch()
        XCTAssertTrue(editor.waitForExistence(timeout: 15))
        // The unused import is counted in the status strip and listed with its rule.
        let count = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'warning'")).firstMatch
        XCTAssertTrue(count.waitForExistence(timeout: 30), "the strip counts the warning")
        count.tap()
        XCTAssertTrue(app.staticTexts["`os` imported but unused"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Ruff F401'")).firstMatch.exists)
    }
}
