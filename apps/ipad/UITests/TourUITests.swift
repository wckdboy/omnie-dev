// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

import XCTest

/// A visual tour: the app's main flows on a landscape iPad, a screenshot each, written to
/// $OMNIE_TOUR_DIR (pass TEST_RUNNER_OMNIE_TOUR_DIR to xcodebuild). Skipped without it. The agent
/// and sketch steps use the online model configured on the simulator.
@MainActor
final class TourUITests: XCTestCase {
    var dir: URL!
    var app: XCUIApplication!

    override func setUp() async throws {
        guard let path = ProcessInfo.processInfo.environment["OMNIE_TOUR_DIR"] else { throw XCTSkip("set TEST_RUNNER_OMNIE_TOUR_DIR to take the tour") }
        dir = URL(filePath: path)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        XCUIDevice.shared.orientation = .landscapeLeft
        continueAfterFailure = true
    }

    func launch(_ args: [String]) {
        app?.terminate()
        app = XCUIApplication()
        app.launchArguments = args + ["-OmnieNoPanelDrag", "-OmnieTestApprove"]
        app.launch()
    }

    func shot(_ name: String, settle: UInt32 = 2) {
        sleep(settle)
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: dir.appending(path: "\(name).png"))
    }

    func wait(_ predicate: String, _ timeout: TimeInterval = 20) -> Bool {
        app.descendants(matching: .any).matching(NSPredicate(format: predicate)).firstMatch.waitForExistence(timeout: timeout)
    }

    func testTour() {
        // 1. First run, then the sample project.
        launch(["-onboarding.done", "NO", "-OmnieLayout", "standard"])
        XCTAssertTrue(wait("label BEGINSWITH 'Try the sample project'"))
        shot("01-welcome")
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Try the sample project'")).firstMatch.tap()
        XCTAssertTrue(app.textViews["Code editor, README.md"].waitForExistence(timeout: 20))
        shot("02-sample")

        // 2. The tests fail.
        launch(["-OmnieOpenFolder", "Projects/Sample", "-OmnieOpenFile", "src/orbit.ts", "-OmnieLayout", "terminalBelow", "-OmnieTerminal", "npm test"])
        XCTAssertTrue(wait("label CONTAINS '2 failed'", 40))
        shot("03-tests-fail")

        // 3. The agent fixes them on its own branch; review, accept.
        launch(["-OmnieOpenFolder", "Projects/Sample", "-OmnieOpenFile", "src/orbit.ts", "-OmnieLayout", "standard",
                "-OmnieAgentTask", "fix orbitPosition so the tests pass"])
        XCTAssertTrue(wait("label == 'Accept and commit'", 240), "the agent finished with a changeset")
        shot("04-agent-review")
        app.buttons["Accept and commit"].firstMatch.tap()
        sleep(3)

        // 4. Green, in the terminal; the planets on Stage beside the code.
        launch(["-OmnieOpenFolder", "Projects/Sample", "-OmnieOpenFile", "src/orbit.ts", "-OmnieLayout", "previewBeside", "-OmnieTerminal", "npm test",
                "-OmnieRunCommand", "utility.stage"])
        XCTAssertTrue(wait("label CONTAINS '2 passed'", 40))
        shot("05-tests-pass-stage", settle: 6)

        // 5. The scene in the preview.
        launch(["-OmnieOpenFolder", "Projects/Sample", "-OmnieOpenFile", "src/planets.stage.ts", "-OmnieLayout", "standard", "-OmniePreview"])
        shot("06-preview", settle: 8)

        // 6. A sketch becomes a React component.
        launch(["-OmnieOpenFolder", "sketch-demo", "-OmnieLayout", "standard", "-OmnieRunCommand", "utility.tools", "-OmnieToolsPick", "Sketch",
                "-OmnieSketchDemo", "Sign-in card: the title says Welcome back, then email and password fields, then a Sign in button. Show it in App."])
        XCTAssertTrue(wait("label == 'Accept and commit'", 180), "the sketch became a changeset")
        shot("07-sketch-review")
        app.buttons["Accept and commit"].firstMatch.tap()
        sleep(3)
        launch(["-OmnieOpenFolder", "sketch-demo", "-OmnieOpenFile", "src/components/SignInCard.tsx", "-OmnieLayout", "standard", "-OmniePreview"])
        shot("08-sketch-preview", settle: 8)

        // 7. Blame, breadcrumbs, sticky scroll and the minimap.
        launch(["-OmnieOpenFolder", "blamedemo", "-OmnieOpenFile", "app.ts:9", "-OmnieLayout", "standard", "-OmnieRunCommand", "git.blame"])
        shot("09-blame", settle: 4)

        // 8. Editing history.
        launch(["-OmnieUIHistoryFixture", "-OmnieLayout", "standard", "-OmnieRunCommand", "git.editHistory"])
        XCTAssertTrue(wait("label == 'WIP try a footer'"))
        shot("10-edit-history")

        // 9. Two editors and the panels arranged around them.
        launch(["-OmnieOpenFolder", "Projects/Sample", "-OmnieOpenFile", "src/scene.ts", "-OmnieLayout", "previewBeside", "-OmnieRunCommand", "view.split",
                "-OmnieTerminal", "rg -n orbit"])
        shot("11-panes", settle: 5)
    }
}
