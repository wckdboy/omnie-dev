// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

import XCTest

/// Opens a pull request on a real Gitea (Forgejo's API) from the app: clone, commit on a branch,
/// Pull Requests…, push and open. Needs a Gitea the simulator reaches, so it runs only with
/// `TEST_RUNNER_OMNIE_GITEA=http://127.0.0.1:3999` and `TEST_RUNNER_OMNIE_GITEA_TOKEN` (an
/// admin's token) set for xcodebuild.
@MainActor
final class PullRequestUITests: XCTestCase {
    let base = ProcessInfo.processInfo.environment["OMNIE_GITEA"]
    let token = ProcessInfo.processInfo.environment["OMNIE_GITEA_TOKEN"]

    func call(_ method: String, _ path: String, _ body: [String: Any]? = nil) throws -> Any {
        var request = URLRequest(url: URL(string: "\(base!)/api/v1/\(path)")!)
        request.httpMethod = method
        request.setValue("token \(token!)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let body { request.httpBody = try JSONSerialization.data(withJSONObject: body) }
        let done = expectation(description: path)
        nonisolated(unsafe) var result: (Data?, Int) = (nil, 0)
        URLSession.shared.dataTask(with: request) { data, response, _ in
            result = (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
            done.fulfill()
        }.resume()
        wait(for: [done], timeout: 30)
        XCTAssertTrue((200..<300).contains(result.1), "\(method) \(path): \(result.1)")
        guard let data = result.0, !data.isEmpty else { return [:] as [String: Any] }
        return try JSONSerialization.jsonObject(with: data)
    }

    func testOpensAPullRequestOnGitea() throws {
        guard let base, let token, let host = URL(string: base)?.host() else {
            throw XCTSkip("Set TEST_RUNNER_OMNIE_GITEA and TEST_RUNNER_OMNIE_GITEA_TOKEN to run against a Gitea.")
        }
        let user = try XCTUnwrap((try call("GET", "user") as? [String: Any])?["login"] as? String)
        let name = "pr-ui-\(UUID().uuidString.prefix(8).lowercased())"
        _ = try call("POST", "user/repos", ["name": name, "auto_init": true, "default_branch": "main"])
        defer { _ = try? call("DELETE", "repos/\(user)/\(name)") }

        let app = XCUIApplication()
        app.launchArguments = [
            "-OmniePRFixture", "\(base)/\(user)/\(name).git", "-OmnieForgeToken", host, user, token,
            "-forge.kind.\(host)", "forgejo", "-OmnieTestApprove", "-OmnieNoWelcome", "-OmnieNoPanelDrag",
            "-OmnieLayout", "standard", "-OmnieRunCommand", "git.pullRequests",
        ]
        app.launch()

        // Prefilled from the branch's one commit.
        let title = app.textFields["pr-title"]
        XCTAssertTrue(title.waitForExistence(timeout: 30))
        XCTAssertEqual(title.value as? String, "Add orbit notes")
        let open = app.buttons["pr-open"]
        for _ in 0..<3 where !open.isHittable { app.swipeUp() }
        XCTAssertTrue(open.waitForExistence(timeout: 10) && open.isEnabled, "nothing is open yet for feature → main")
        open.tap()

        let opened = app.buttons["pr-opened"]
        XCTAssertTrue(opened.waitForExistence(timeout: 60), app.staticTexts["pr-problem"].exists ? app.staticTexts["pr-problem"].label : "no PR")
        XCTAssertTrue(app.buttons["pr-row-1"].waitForExistence(timeout: 10), "the open list has it, with its checks")

        let pulls = try XCTUnwrap(try call("GET", "repos/\(user)/\(name)/pulls?state=open") as? [[String: Any]])
        XCTAssertEqual(pulls.count, 1)
        XCTAssertEqual(pulls.first?["title"] as? String, "Add orbit notes")
        XCTAssertEqual(pulls.first?["body"] as? String, "Says which unit the angles use.")
        XCTAssertEqual((pulls.first?["head"] as? [String: Any])?["ref"] as? String, "feature")
    }
}
