// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

import XCTest

/// Screenshots of the docks around the editor in both orientations, written to $OMNIE_SHOTS_DIR
/// (pass TEST_RUNNER_OMNIE_SHOTS_DIR to xcodebuild). Skipped without it.
@MainActor
final class LayoutShotsUITests: XCTestCase {
    func testLayoutsInBothOrientations() throws {
        guard let path = ProcessInfo.processInfo.environment["OMNIE_SHOTS_DIR"] else { throw XCTSkip("set TEST_RUNNER_OMNIE_SHOTS_DIR") }
        let dir = URL(filePath: path)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for orientation in [UIDeviceOrientation.portrait, .landscapeLeft] {
            XCUIDevice.shared.orientation = orientation
            for preset in ["standard", "previewBeside"] {
                let app = XCUIApplication()
                app.launchArguments = ["-OmnieUIFixture", "-OmnieLayout", preset, "-OmnieNoWelcome", "-OmnieNoPanelDrag",
                                       "-OmnieRunCommand", "view.bottom"]
                app.launch()
                XCUIDevice.shared.orientation = orientation
                sleep(2)
                let editor = app.textViews.matching(NSPredicate(format: "label BEGINSWITH 'Code editor'")).firstMatch
                XCTAssertTrue(editor.waitForExistence(timeout: 15))
                editor.tap()
                sleep(1)
                app.typeKey(.downArrow, modifierFlags: .command)
                app.typeText("// " + String(repeating: "a long line that should wrap or scroll, never hide ", count: 4) + "END")
                sleep(1)
                let name = "\(orientation == .portrait ? "portrait" : "landscape")-\(preset)"
                try XCUIScreen.main.screenshot().pngRepresentation.write(to: dir.appending(path: "\(name).png"))
                app.terminate()
            }
        }
    }
}
