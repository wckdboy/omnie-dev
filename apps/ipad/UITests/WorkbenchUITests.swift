// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

import XCTest

/// The workbench as VS Code users expect it: every panel and dock closes and comes back, nothing
/// hides under the keyboard, the line commands work, and projects start and switch from anywhere.
@MainActor
final class WorkbenchUITests: XCTestCase {
    var app: XCUIApplication!

    func launch(_ extra: [String] = []) {
        app = XCUIApplication()
        app.launchArguments = ["-OmnieUIFixture", "-OmnieLayout", "standard", "-OmnieNoWelcome", "-OmnieNoPanelDrag"] + extra
        app.launch()
        XCTAssertTrue(editor.waitForExistence(timeout: 15))
    }

    var editor: XCUIElement { app.textViews.matching(NSPredicate(format: "label BEGINSWITH 'Code editor'")).firstMatch }

    func toggle(_ dock: String) -> XCUIElement { app.buttons["layout-toggle-\(dock)"] }

    func testPanelsAndDocksCloseAndComeBack() {
        launch(["-OmnieRunCommand", "view.bottom"])
        // The terminal (bottom) closes from its tab.
        let closeTerminal = app.buttons["Close Terminal"]
        XCTAssertTrue(closeTerminal.waitForExistence(timeout: 10))
        closeTerminal.tap()
        XCTAssertFalse(app.buttons["Close Terminal"].waitForExistence(timeout: 2))
        XCTAssertEqual(toggle("bottom").value as? String, "Hidden")
        // The empty bottom dock comes back with the terminal from the status strip.
        toggle("bottom").tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label == 'Close Terminal'")).firstMatch.waitForExistence(timeout: 5))
        // The right dock hides from its own button and comes back from the strip.
        XCTAssertEqual(toggle("right").value as? String, "Shown")
        app.buttons["Hide the right dock"].firstMatch.tap()
        XCTAssertEqual(toggle("right").value as? String, "Hidden")
        XCTAssertFalse(app.buttons["Close Agent"].exists)
        toggle("right").tap()
        XCTAssertTrue(app.buttons["Close Agent"].waitForExistence(timeout: 5))
    }

    func testNothingHidesUnderTheKeyboard() {
        launch(["-OmnieRunCommand", "view.bottom"])
        editor.tap()
        sleep(2)
        // With the on-screen keyboard up, the bottom dock and the status strip sit above it.
        XCTAssertTrue(app.buttons["Close Terminal"].isHittable, "the terminal's tab is above the keyboard")
        XCTAssertTrue(toggle("bottom").isHittable, "the status strip is above the keyboard")
    }

    func testLineCommands() {
        launch()
        editor.tap()
        sleep(1)
        warmUpKeyboard(app)
        app.typeKey(.upArrow, modifierFlags: .command)   // the first line
        app.typeKey("/", modifierFlags: .command)
        XCTAssertTrue(waitForValue("// let alpha = 1;"), "⌘/ comments the line out")
        app.typeKey("/", modifierFlags: .command)
        XCTAssertTrue(waitForValue("let alpha = 1;"))
        app.typeKey(.downArrow, modifierFlags: .option)
        XCTAssertTrue(waitForValue("Line 2, column", text: "let alpha = 1;"), "⌥↓ moves it down")
        app.typeKey(.downArrow, modifierFlags: [.option, .shift])
        XCTAssertTrue(waitForValue("Line 3, column", text: "let alpha = 1;"), "⇧⌥↓ copies it below")
        app.typeKey("k", modifierFlags: [.command, .shift])
        XCTAssertTrue(waitForValue("Line 3, column", text: "function gamma() { return beta; }"), "⇧⌘K deletes it")
    }

    /// The editor's value is "Line N, column M. <line>".
    func waitForValue(_ prefix: String, text: String? = nil) -> Bool {
        for _ in 0..<20 {
            let value = editor.value as? String ?? ""
            if let text {
                if value.hasPrefix(prefix) && value.hasSuffix(". " + text) { return true }
            } else if value.hasSuffix(". " + prefix) {
                return true
            }
            usleep(200_000)
        }
        return false
    }

    func openRecent() {
        app.buttons["project-switcher"].tap()
    }

    func testNewProjectAndSwitching() {
        launch(["-OmnieRunCommand", "file.newProject"])
        let name = app.textFields["new-project-name"]
        XCTAssertTrue(name.waitForExistence(timeout: 10))
        let project = "ui-\(Int.random(in: 1000...9999))"
        name.tap()
        name.typeText(project)
        app.buttons["template-typescript"].tap()
        app.buttons["new-project-create"].tap()
        XCTAssertTrue(app.textViews["Code editor, index.ts"].waitForExistence(timeout: 15), "the new project opens on its main file")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'main'")).firstMatch.waitForExistence(timeout: 10),
                      "it's a git repository on main")

        // The project switcher (⌃R on a hardware keyboard, or the project's name in the status strip): the
        // fixture is a recent project; switch back to it, then close it.
        openRecent()
        let recent = app.buttons["recent-uitest-fixture"]
        XCTAssertTrue(recent.waitForExistence(timeout: 10))
        recent.tap()
        XCTAssertTrue(app.textViews["Code editor, main.ts"].waitForExistence(timeout: 10) || app.staticTexts["Pick a file in the navigator"].waitForExistence(timeout: 5))
        openRecent()
        let close = app.buttons["projects-close"]
        XCTAssertTrue(close.waitForExistence(timeout: 10))
        close.tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'New project'")).firstMatch.waitForExistence(timeout: 10),
                      "no project: the start page offers a new one")
    }
}
