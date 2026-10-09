// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing
@testable import HostKit

struct ForgeRepoTests {
    @Test func readsEveryRemoteForm() throws {
        let https = try #require(ForgeRepo(remoteURL: "https://codeberg.org/wckdboy/omnie-dev.git"))
        #expect(https.kind == .forgejo)
        #expect(https.web.absoluteString == "https://codeberg.org")
        #expect(https.fullName == "wckdboy/omnie-dev")
        #expect(https.api.absoluteString == "https://codeberg.org/api/v1")

        let scp = try #require(ForgeRepo(remoteURL: "git@github.com:wckdboy/omnie-dev.git"))
        #expect(scp.kind == .github)
        #expect(scp.api.absoluteString == "https://api.github.com")
        #expect(scp.name == "omnie-dev")

        // GitLab's nested groups; an SSH port isn't the web port.
        let ssh = try #require(ForgeRepo(remoteURL: "ssh://git@gitlab.example.com:2222/team/apps/ios.git"))
        #expect(ssh.kind == .gitlab)
        #expect(ssh.owner == "team/apps")
        #expect(ssh.web.absoluteString == "https://gitlab.example.com")
        #expect(ssh.api.absoluteString == "https://gitlab.example.com/api/v4")

        // A forge on the LAN keeps its scheme and port; its kind is set by hand.
        #expect(ForgeRepo(remoteURL: "http://192.168.1.20:3000/me/app") == nil)
        let lan = try #require(ForgeRepo(remoteURL: "http://192.168.1.20:3000/me/app", kind: .forgejo))
        #expect(lan.api.absoluteString == "http://192.168.1.20:3000/api/v1")

        let enterprise = try #require(ForgeRepo(remoteURL: "https://github.corp.example/me/app.git"))
        #expect(enterprise.api.absoluteString == "https://github.corp.example/api/v3")

        #expect(ForgeRepo(remoteURL: "https://github.com/onlyowner") == nil)
        #expect(ForgeRepo(remoteURL: "/local/path/repo.git", kind: .forgejo) == nil)
    }

    @Test func checksFoldLikeABadge() {
        #expect(CheckState.combine([.success, .pending, .failure]) == .failure)
        #expect(CheckState.combine([.success, .pending]) == .pending)
        #expect(CheckState.combine([.success, .none]) == .success)
        #expect(CheckState.combine([]) == .none)
    }
}

/// Answers requests from a table and keeps what was asked, so each adapter's paths, headers and
/// bodies are checked without a network.
final class StubProtocol: URLProtocol, @unchecked Sendable {
    struct Reply { var status: Int; var json: String }
    nonisolated(unsafe) static var replies: [String: Reply] = [:]
    nonisolated(unsafe) static var requests: [URLRequest] = []
    static let lock = NSLock()

    static func session(_ replies: [String: Reply]) -> URLSession {
        lock.withLock {
            self.replies = replies
            requests = []
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var request = request
        if request.httpBody == nil, let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
            while stream.hasBytesAvailable {
                let n = stream.read(buffer, maxLength: 4096)
                if n <= 0 { break }
                data.append(buffer, count: n)
            }
            buffer.deallocate()
            stream.close()
            request.httpBody = data
        }
        let key = "\(request.httpMethod ?? "GET") \(request.url!.path(percentEncoded: true))"
        let reply = Self.lock.withLock {
            Self.requests.append(request)
            return Self.replies[key] ?? Reply(status: 404, json: #"{"message":"no stub for \#(key)"}"#)
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(reply.json.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func body(_ request: URLRequest) -> [String: Any] {
        (request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]) ?? [:]
    }
}

@Suite(.serialized)
struct AdapterTests {
    @Test func giteaOpensAndListsPullRequests() async throws {
        let pull = #"{"number":7,"title":"Fix orbit","body":"b","state":"open","merged":false,"head":{"ref":"fix","sha":"abc"},"base":{"ref":"main"},"user":{"login":"me"},"html_url":"https://codeberg.org/me/app/pulls/7"}"#
        let session = StubProtocol.session([
            "POST /api/v1/repos/me/app/pulls": .init(status: 201, json: pull),
            "GET /api/v1/repos/me/app/pulls": .init(status: 200, json: "[\(pull)]"),
            "GET /api/v1/repos/me/app/commits/abc/status": .init(status: 200, json: #"{"state":"pending","statuses":[{"state":"pending"}]}"#),
        ])
        let forge = try #require(ForgeRepo(remoteURL: "https://codeberg.org/me/app.git")).forge(token: "t0k", session: session)
        let created = try await forge.create(PullRequestDraft(title: "Fix orbit", body: "b", head: "fix", base: "main"))
        #expect(created == PullRequest(number: 7, title: "Fix orbit", body: "b", head: "fix", base: "main", headSHA: "abc",
                                       author: "me", url: URL(string: "https://codeberg.org/me/app/pulls/7")))
        #expect(try await forge.pullRequests(state: .open).map(\.number) == [7])
        #expect(try await forge.pullRequests(state: .merged).isEmpty)
        #expect(try await forge.checks(sha: "abc") == .pending)

        let post = StubProtocol.requests[0]
        #expect(post.value(forHTTPHeaderField: "Authorization") == "token t0k")
        #expect(StubProtocol.body(post)["head"] as? String == "fix")
        #expect(StubProtocol.requests[1].url?.query()?.contains("state=open") == true)
    }

    @Test func gitlabSpeaksMergeRequests() async throws {
        let mr = #"{"iid":3,"title":"Draft: Sketch","description":"d","state":"opened","source_branch":"sketch","target_branch":"main","sha":"def","author":{"username":"me"},"web_url":"https://gitlab.com/team/apps/ios/-/merge_requests/3","draft":true}"#
        let session = StubProtocol.session([
            "POST /api/v4/projects/team%2Fapps%2Fios/merge_requests": .init(status: 201, json: mr),
            "GET /api/v4/projects/team%2Fapps%2Fios/pipelines": .init(status: 200, json: #"[{"status":"failed"}]"#),
            "GET /api/v4/projects/team%2Fapps%2Fios": .init(status: 200, json: #"{"default_branch":"trunk"}"#),
        ])
        let forge = try #require(ForgeRepo(remoteURL: "git@gitlab.com:team/apps/ios.git")).forge(token: "glpat", session: session)
        let created = try await forge.create(PullRequestDraft(title: "Sketch", body: "d", head: "sketch", base: "main", isDraft: true))
        #expect(created.number == 3 && created.isDraft && created.state == .open && created.headSHA == "def")
        #expect(try await forge.checks(sha: "def") == .failure)
        #expect(try await forge.defaultBranch() == "trunk")

        let post = StubProtocol.requests[0]
        #expect(post.value(forHTTPHeaderField: "PRIVATE-TOKEN") == "glpat")
        #expect(StubProtocol.body(post)["title"] as? String == "Draft: Sketch")
        #expect(StubProtocol.body(post)["source_branch"] as? String == "sketch")
    }

    @Test func githubCountsCheckRunsAndStatuses() async throws {
        let session = StubProtocol.session([
            "GET /repos/me/app/commits/abc/check-runs": .init(status: 200, json: #"{"check_runs":[{"status":"completed","conclusion":"success"},{"status":"completed","conclusion":"skipped"}]}"#),
            "GET /repos/me/app/commits/abc/status": .init(status: 200, json: #"{"state":"pending","statuses":[]}"#),
            "POST /repos/me/app/pulls": .init(status: 422, json: #"{"message":"Validation Failed","errors":[{"message":"A pull request already exists for me:fix."}]}"#),
        ])
        let forge = try #require(ForgeRepo(remoteURL: "https://github.com/me/app")).forge(token: "ghp", session: session)
        // No statuses means only the check runs count (GitHub says "pending" for none).
        #expect(try await forge.checks(sha: "abc") == .success)
        await #expect(throws: ForgeError.rejected("Validation Failed A pull request already exists for me:fix.")) {
            try await forge.create(PullRequestDraft(title: "x", head: "fix", base: "main"))
        }
        #expect(StubProtocol.requests[0].value(forHTTPHeaderField: "Authorization") == "Bearer ghp")
    }

    @Test func aBadTokenSaysSo() async throws {
        let session = StubProtocol.session(["GET /api/v1/user": .init(status: 401, json: #"{"message":"token is required"}"#)])
        let forge = try #require(ForgeRepo(remoteURL: "https://codeberg.org/me/app")).forge(token: "bad", session: session)
        await #expect(throws: ForgeError.unauthorized(host: "codeberg.org")) { try await forge.currentUser() }
    }
}

/// Against a real Gitea (Forgejo's API): `OMNIE_LIVE_GITEA=http://127.0.0.1:3999` and
/// `OMNIE_GITEA_TOKEN` (an admin's token with every scope). Makes a repository with a branch,
/// opens a pull request from it, reads it back, and sees a commit status arrive.
struct LiveGiteaTests {
    static let base = ProcessInfo.processInfo.environment["OMNIE_LIVE_GITEA"]
    static let token = ProcessInfo.processInfo.environment["OMNIE_GITEA_TOKEN"]

    func call(_ method: String, _ path: String, _ body: [String: Any]? = nil) async throws -> Any {
        var request = URLRequest(url: URL(string: "\(Self.base!)/api/v1/\(path)")!)
        request.httpMethod = method
        request.setValue("token \(Self.token!)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let body { request.httpBody = try JSONSerialization.data(withJSONObject: body) }
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        try #require((200..<300).contains(status), "\(method) \(path): \(status) \(String(decoding: data, as: UTF8.self))")
        return data.isEmpty ? [:] as [String: Any] : try JSONSerialization.jsonObject(with: data)
    }

    @Test(.enabled(if: base != nil && token != nil))
    func opensAPullRequestOnGitea() async throws {
        let name = "hostkit-\(UUID().uuidString.prefix(8).lowercased())"
        let user = try #require((try await call("GET", "user") as? [String: Any])?["login"] as? String)
        _ = try await call("POST", "user/repos", ["name": name, "auto_init": true, "default_branch": "main"])
        _ = try await call("POST", "repos/\(user)/\(name)/branches", ["new_branch_name": "feature", "old_branch_name": "main"])
        let content = Data("orbit\n".utf8).base64EncodedString()
        _ = try await call("POST", "repos/\(user)/\(name)/contents/orbit.txt", ["content": content, "branch": "feature", "message": "Add orbit"])

        let repo = try #require(ForgeRepo(remoteURL: "\(Self.base!)/\(user)/\(name).git", kind: .forgejo))
        let forge = repo.forge(token: Self.token!)
        #expect(try await forge.currentUser() == user)
        #expect(try await forge.defaultBranch() == "main")
        let pull = try await forge.create(PullRequestDraft(title: "Add orbit", body: "From HostKit.", head: "feature", base: "main"))
        #expect(pull.state == .open && pull.head == "feature" && pull.base == "main" && pull.author == user)
        #expect(pull.url?.absoluteString.hasSuffix("/\(user)/\(name)/pulls/\(pull.number)") == true)
        #expect(try await forge.pullRequests(state: .open).map(\.number) == [pull.number])

        // A second one for the same branches is the forge's to refuse, and says why.
        await #expect(throws: ForgeError.self) {
            try await forge.create(PullRequestDraft(title: "Again", head: "feature", base: "main"))
        }

        #expect(try await forge.checks(sha: pull.headSHA) == .none)
        _ = try await call("POST", "repos/\(user)/\(name)/statuses/\(pull.headSHA)", ["state": "pending", "context": "ci/test"])
        #expect(try await forge.checks(sha: pull.headSHA) == .pending)
        _ = try await call("POST", "repos/\(user)/\(name)/statuses/\(pull.headSHA)", ["state": "success", "context": "ci/test"])
        #expect(try await forge.checks(sha: pull.headSHA) == .success)
        _ = try await call("DELETE", "repos/\(user)/\(name)")
    }
}
