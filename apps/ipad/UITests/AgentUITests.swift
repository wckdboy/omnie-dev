// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

import XCTest

/// The agent's changeset safety net: the app snapshots the project just before a changeset lands, and
/// the panel offers a one-tap Undo. The task is scripted (`-OmnieAgentDemo`) so it runs in the
/// simulator, and `-OmnieAgentDemoAccept` lands it.
@MainActor
final class AgentUITests: XCTestCase {
    func testUndoesALandedChangeset() {
        let app = XCUIApplication()
        app.launchArguments = ["-OmnieUIAgentFixture", "-OmnieLayout", "standard", "-OmnieNoWelcome", "-OmnieNoPanelDrag",
                               "-OmnieAgentDemo", "-OmnieAgentDemoAccept"]
        app.launch()

        // The demo lands the changeset; the panel then offers Undo (the snapshot taken on apply).
        let undo = app.buttons["Undo"]
        XCTAssertTrue(undo.waitForExistence(timeout: 90), "a landed changeset should offer Undo")
        undo.tap()
        XCTAssertTrue(undo.waitForNonExistence(timeout: 20), "undo should clear the affordance once the project is back")
    }
}
