// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

import XCTest

/// A workspace with more than one folder, as VS Code users expect it: a folder added to the project
/// shows its own tree in the navigator, is searched by quick open and find in project, and can be
/// taken back out. The fixture's project is `uitest-fixture`; `-OmnieAddFolder uitest-extra` adds a
/// sibling folder with one known file (`extra.ts`).
@MainActor
final class MultiRootUITests: XCTestCase {
    var app: XCUIApplication!

    func launch(_ extra: [String] = []) {
        app = XCUIApplication()
        app.launchArguments = ["-OmnieUIFixture", "-OmnieAddFolder", "uitest-extra", "-OmnieLayout", "focusRight",
                               "-OmnieNoWelcome", "-OmnieNoPanelDrag"] + extra
        app.launch()
        XCTAssertTrue(editor.waitForExistence(timeout: 15))
    }

    var editor: XCUIElement { app.textViews.matching(NSPredicate(format: "label BEGINSWITH 'Code editor'")).firstMatch }

    func element(_ label: String) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label == %@", label)).firstMatch
    }

    func testTheAddedFolderHasItsOwnTreeAndOpens() {
        launch()
        // Both folders are in the navigator: the project's own file, and the added folder's.
        XCTAssertTrue(element("main.ts, file").waitForExistence(timeout: 10), "the project's file is there")
        let header = element("uitest-extra, folder in the workspace")
        XCTAssertTrue(header.waitForExistence(timeout: 10), "the added folder's header names it")
        let file = element("extra.ts, file")
        XCTAssertTrue(file.waitForExistence(timeout: 10), "the added folder's file is listed under it")

        file.tap()
        XCTAssertTrue(app.textViews["Code editor, extra.ts"].waitForExistence(timeout: 10),
                      "tapping a file in an added folder opens it")
    }

    func testTheFolderCanBeTakenBackOut() {
        launch()
        XCTAssertTrue(element("uitest-extra, folder in the workspace").waitForExistence(timeout: 10))
        app.buttons["Remove uitest-extra from the workspace"].tap()
        XCTAssertFalse(element("uitest-extra, folder in the workspace").waitForExistence(timeout: 3),
                       "the folder leaves the workspace")
        XCTAssertTrue(element("main.ts, file").exists, "the project's own folder stays")
    }

    func testQuickOpenCoversAddedFolders() {
        launch(["-OmnieRunCommand", "file.quickOpen", "-OmnieQuickOpen", "extra"])
        // The result is named by the folder it came from.
        let row = app.staticTexts["uitest-extra/extra.ts"]
        XCTAssertTrue(row.waitForExistence(timeout: 10), "quick open finds the added folder's file")
        row.tap()
        XCTAssertTrue(app.textViews["Code editor, extra.ts"].waitForExistence(timeout: 10))
    }

    func testFindInProjectCoversAddedFolders() {
        launch(["-OmnieRunCommand", "search.project", "-OmnieFind", "delta"])
        let group = app.staticTexts["uitest-extra/extra.ts"]
        XCTAssertTrue(group.waitForExistence(timeout: 15), "find in project searches the added folder")
        let match = app.staticTexts["let delta = 4;"]
        XCTAssertTrue(match.waitForExistence(timeout: 10), "the match is listed")
        match.tap()
        XCTAssertTrue(app.textViews["Code editor, extra.ts"].waitForExistence(timeout: 10), "tapping it opens that file")
    }

    func testAnAddedFolderAndItsFileComeBackAfterRelaunch() {
        launch(["-OmnieRestoreSessions"])
        XCTAssertTrue(element("extra.ts, file").waitForExistence(timeout: 10))
        element("extra.ts, file").tap()
        XCTAssertTrue(app.textViews["Code editor, extra.ts"].waitForExistence(timeout: 10))
        XCUIDevice.shared.press(.home)
        sleep(1)
        app.terminate()

        // No fixture and no -OmnieAddFolder: the project reopens by itself, and the folder it had
        // added (remembered by bookmark) and the file open in it come back with it.
        app.launchArguments = ["-OmnieRestoreSessions", "-OmnieLayout", "focusRight", "-OmnieNoWelcome", "-OmnieNoPanelDrag"]
        app.launch()
        XCTAssertTrue(element("uitest-extra, folder in the workspace").waitForExistence(timeout: 15),
                      "the added folder is back in the workspace")
        XCTAssertTrue(app.textViews["Code editor, extra.ts"].waitForExistence(timeout: 15),
                      "the file open in it is back too")
    }

    func testGitFollowsAFileIntoAnAddedFolder() {
        launch()
        // The fixture's own project isn't a repository, so the strip says so while its file is open.
        XCTAssertTrue(app.staticTexts["not a git repo"].waitForExistence(timeout: 15))

        element("extra.ts, file").tap()
        XCTAssertTrue(app.textViews["Code editor, extra.ts"].waitForExistence(timeout: 10))
        // The added folder is its own repository: the strip (and the git panels) follow the file into it.
        let branch = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "main")).firstMatch
        XCTAssertTrue(branch.waitForExistence(timeout: 20), "the strip reports the added folder's branch")
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "uitest-extra"))
                        .firstMatch.exists, "and names the folder the repository belongs to")
        XCTAssertFalse(app.staticTexts["not a git repo"].exists, "and no longer the project's state")

        element("main.ts, file").tap()
        XCTAssertTrue(app.textViews["Code editor, main.ts"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["not a git repo"].waitForExistence(timeout: 20),
                      "back in the project's own folder, which isn't a repository")
    }
}
