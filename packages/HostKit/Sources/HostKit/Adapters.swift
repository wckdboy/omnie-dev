// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Forgejo and Gitea: `/api/v1`, GitHub-shaped pull requests.
struct GiteaForge: Forge {
    let client: ForgeClient
    var repo: ForgeRepo { client.repo }
    var base: String { "repos/\(repo.owner)/\(repo.name)" }

    func currentUser() async throws -> String {
        guard let login = try object(await client.get("user"), "user").string("login") else { throw ForgeError.badResponse("user") }
        return login
    }

    func defaultBranch() async throws -> String {
        try object(await client.get(base), "repository").string("default_branch") ?? "main"
    }

    func pullRequests(state: PullRequest.State?) async throws -> [PullRequest] {
        // Gitea has open/closed/all; merged ones are closed with `merged` set.
        let query = ["state": state == nil ? "all" : state == .open ? "open" : "closed", "limit": "50"]
        let list = try objects(await client.get("\(base)/pulls", query: query), "pulls").map(Self.pullRequest)
        return state.map { wanted in list.filter { $0.state == wanted } } ?? list
    }

    func create(_ draft: PullRequestDraft) async throws -> PullRequest {
        // Gitea marks drafts by title prefix (WIP:), configurable per server; the common one.
        let title = draft.isDraft && !draft.title.hasPrefix("WIP:") ? "WIP: \(draft.title)" : draft.title
        let json = try await client.post("\(base)/pulls", ["title": title, "body": draft.body, "head": draft.head, "base": draft.base])
        return Self.pullRequest(try object(json, "pull"))
    }

    func checks(sha: String) async throws -> CheckState {
        let combined = try object(await client.get("\(base)/commits/\(sha)/status"), "status")
        // An empty state with no statuses means no CI reported.
        guard ((combined["statuses"] as? [Any])?.count ?? 0) > 0 else { return .none }
        return Self.state(combined.string("state"))
    }

    static func state(_ value: String?) -> CheckState {
        switch value {
        case "success": .success
        case "pending", "running", "waiting", "blocked": .pending
        case "failure", "error", "cancelled": .failure
        default: .none
        }
    }

    static func pullRequest(_ json: [String: Any]) -> PullRequest {
        let state: PullRequest.State = json.bool("merged") ? .merged : json.string("state") == "open" ? .open : .closed
        return PullRequest(
            number: json.int("number") ?? 0, title: json.string("title") ?? "", body: json.string("body") ?? "",
            state: state, head: json.path("head", "ref") as? String ?? "", base: json.path("base", "ref") as? String ?? "",
            headSHA: json.path("head", "sha") as? String ?? "", author: json.path("user", "login") as? String ?? "",
            url: json.string("html_url").flatMap(URL.init(string:)), isDraft: json.bool("draft"))
    }
}

/// GitHub: the REST API, statuses and check runs both.
struct GitHubForge: Forge {
    let client: ForgeClient
    var repo: ForgeRepo { client.repo }
    var base: String { "repos/\(repo.owner)/\(repo.name)" }

    func currentUser() async throws -> String {
        guard let login = try object(await client.get("user"), "user").string("login") else { throw ForgeError.badResponse("user") }
        return login
    }

    func defaultBranch() async throws -> String {
        try object(await client.get(base), "repository").string("default_branch") ?? "main"
    }

    func pullRequests(state: PullRequest.State?) async throws -> [PullRequest] {
        let query = ["state": state == nil ? "all" : state == .open ? "open" : "closed", "per_page": "50"]
        let list = try objects(await client.get("\(base)/pulls", query: query), "pulls").map(Self.pullRequest)
        return state.map { wanted in list.filter { $0.state == wanted } } ?? list
    }

    func create(_ draft: PullRequestDraft) async throws -> PullRequest {
        var body: [String: Any] = ["title": draft.title, "body": draft.body, "head": draft.head, "base": draft.base]
        if draft.isDraft { body["draft"] = true }
        return Self.pullRequest(try object(await client.post("\(base)/pulls", body), "pull"))
    }

    func checks(sha: String) async throws -> CheckState {
        // Actions report check runs; older integrations report commit statuses. Both count.
        let runs = try object(await client.get("\(base)/commits/\(sha)/check-runs", query: ["per_page": "100"]), "check runs")
        let fromRuns = ((runs["check_runs"] as? [[String: Any]]) ?? []).map { run -> CheckState in
            guard run.string("status") == "completed" else { return .pending }
            switch run.string("conclusion") {
            case "success", "neutral", "skipped": return .success
            default: return .failure
            }
        }
        let combined = try object(await client.get("\(base)/commits/\(sha)/status"), "status")
        let statuses = (combined["statuses"] as? [Any])?.isEmpty == false ? [GiteaForge.state(combined.string("state"))] : []
        return CheckState.combine(fromRuns + statuses)
    }

    static func pullRequest(_ json: [String: Any]) -> PullRequest {
        let state: PullRequest.State = json["merged_at"] is String ? .merged : json.string("state") == "open" ? .open : .closed
        return PullRequest(
            number: json.int("number") ?? 0, title: json.string("title") ?? "", body: json.string("body") ?? "",
            state: state, head: json.path("head", "ref") as? String ?? "", base: json.path("base", "ref") as? String ?? "",
            headSHA: json.path("head", "sha") as? String ?? "", author: json.path("user", "login") as? String ?? "",
            url: json.string("html_url").flatMap(URL.init(string:)), isDraft: json.bool("draft"))
    }
}

/// GitLab: merge requests on `/api/v4/projects/<url-encoded path>`, pipelines for checks.
struct GitLabForge: Forge {
    let client: ForgeClient
    var repo: ForgeRepo { client.repo }
    var project: String {
        "projects/" + repo.fullName.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._~")))!
    }

    func currentUser() async throws -> String {
        guard let name = try object(await client.get("user"), "user").string("username") else { throw ForgeError.badResponse("user") }
        return name
    }

    func defaultBranch() async throws -> String {
        try object(await client.get(project), "project").string("default_branch") ?? "main"
    }

    func pullRequests(state: PullRequest.State?) async throws -> [PullRequest] {
        let states: [PullRequest.State: String] = [.open: "opened", .closed: "closed", .merged: "merged"]
        let query = ["state": state.map { states[$0]! } ?? "all", "per_page": "50"]
        return try objects(await client.get("\(project)/merge_requests", query: query), "merge requests").map(Self.mergeRequest)
    }

    func create(_ draft: PullRequestDraft) async throws -> PullRequest {
        let title = draft.isDraft && !draft.title.hasPrefix("Draft:") ? "Draft: \(draft.title)" : draft.title
        let json = try await client.post("\(project)/merge_requests", [
            "title": title, "description": draft.body, "source_branch": draft.head, "target_branch": draft.base,
        ])
        return Self.mergeRequest(try object(json, "merge request"))
    }

    func checks(sha: String) async throws -> CheckState {
        let pipelines = try objects(await client.get("\(project)/pipelines", query: ["sha": sha, "per_page": "1"]), "pipelines")
        return Self.state(pipelines.first?.string("status"))
    }

    static func state(_ value: String?) -> CheckState {
        switch value {
        case "success": .success
        case "created", "waiting_for_resource", "preparing", "pending", "running", "scheduled", "manual": .pending
        case "failed", "canceled": .failure
        default: .none
        }
    }

    static func mergeRequest(_ json: [String: Any]) -> PullRequest {
        let state: PullRequest.State = switch json.string("state") {
        case "opened": .open
        case "merged": .merged
        default: .closed
        }
        return PullRequest(
            number: json.int("iid") ?? 0, title: json.string("title") ?? "", body: json.string("description") ?? "",
            state: state, head: json.string("source_branch") ?? "", base: json.string("target_branch") ?? "",
            headSHA: json.string("sha") ?? "", author: json.path("author", "username") as? String ?? "",
            url: json.string("web_url").flatMap(URL.init(string:)), isDraft: json.bool("draft") || json.bool("work_in_progress"))
    }
}
