// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// A pull request (a merge request on GitLab), the same on every forge.
public struct PullRequest: Sendable, Hashable, Identifiable, Codable {
    public enum State: String, Sendable, Codable { case open, closed, merged }

    /// The number people use: GitHub's and Gitea's `number`, GitLab's `iid`.
    public var number: Int
    public var title: String
    public var body: String
    public var state: State
    /// Branch names.
    public var head: String
    public var base: String
    /// The head commit, for checks.
    public var headSHA: String
    public var author: String
    public var url: URL?
    public var isDraft: Bool

    public var id: Int { number }

    public init(number: Int, title: String, body: String = "", state: State = .open, head: String, base: String,
                headSHA: String = "", author: String = "", url: URL? = nil, isDraft: Bool = false) {
        self.number = number
        self.title = title
        self.body = body
        self.state = state
        self.head = head
        self.base = base
        self.headSHA = headSHA
        self.author = author
        self.url = url
        self.isDraft = isDraft
    }
}

/// What a new pull request says.
public struct PullRequestDraft: Sendable, Hashable {
    public var title: String
    public var body: String
    public var head: String
    public var base: String
    public var isDraft: Bool

    public init(title: String, body: String = "", head: String, base: String, isDraft: Bool = false) {
        self.title = title
        self.body = body
        self.head = head
        self.base = base
        self.isDraft = isDraft
    }
}

/// CI on a commit, folded to one state: any failure fails, then anything running is pending.
public enum CheckState: String, Sendable, Codable {
    case none, pending, success, failure

    /// Folds several (statuses and check runs) the way a forge's badge does.
    public static func combine(_ states: [CheckState]) -> CheckState {
        if states.contains(.failure) { return .failure }
        if states.contains(.pending) { return .pending }
        if states.contains(.success) { return .success }
        return .none
    }
}

public enum ForgeError: Error, Equatable, LocalizedError {
    case noToken(host: String)
    case unauthorized(host: String)
    case notFound(String)
    case rejected(String)
    case http(status: Int, message: String)
    case badResponse(String)

    public var errorDescription: String? {
        switch self {
        case .noToken(let host): "Add an access token for \(host) (Settings › Accounts) to work with its pull requests."
        case .unauthorized(let host): "\(host) didn't accept the token. It may have expired or lack the repository scope."
        case .notFound(let what): "\(what) wasn't found, or the token can't see it."
        case .rejected(let message): message
        case .http(let status, let message): "The forge answered \(status)\(message.isEmpty ? "" : ": \(message)")."
        case .badResponse(let what): "The forge's answer wasn't what was expected (\(what))."
        }
    }
}

/// One forge's REST API for one repository.
public protocol Forge: Sendable {
    var repo: ForgeRepo { get }
    /// The token's user, which also proves the token works.
    func currentUser() async throws -> String
    func defaultBranch() async throws -> String
    func pullRequests(state: PullRequest.State?) async throws -> [PullRequest]
    func create(_ draft: PullRequestDraft) async throws -> PullRequest
    func checks(sha: String) async throws -> CheckState
}

extension ForgeRepo {
    /// The adapter for this repository's forge.
    public func forge(token: String, session: URLSession = .shared) -> any Forge {
        let client = ForgeClient(repo: self, token: token, session: session)
        switch kind {
        case .forgejo: return GiteaForge(client: client)
        case .gitlab: return GitLabForge(client: client)
        case .github: return GitHubForge(client: client)
        }
    }
}

/// JSON over HTTPS with the forge's way of sending a token.
struct ForgeClient: Sendable {
    let repo: ForgeRepo
    let token: String
    let session: URLSession

    func get(_ path: String, query: [String: String] = [:]) async throws -> Any {
        try await send("GET", path, query: query, body: nil)
    }

    func post(_ path: String, _ body: [String: Any]) async throws -> Any {
        try await send("POST", path, query: [:], body: body)
    }

    func send(_ method: String, _ path: String, query: [String: String], body: [String: Any]?) async throws -> Any {
        var components = URLComponents(url: repo.api.appending(path: path, directoryHint: .notDirectory), resolvingAgainstBaseURL: false)!
        // GitLab's project ids are URL-encoded paths (`group%2Fname`); keep the encoding.
        components.percentEncodedPath = repo.api.path(percentEncoded: true) + "/" + path
        if !query.isEmpty { components.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) } }
        guard let url = components.url else { throw ForgeError.badResponse("URL for \(path)") }
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Omnie-Dev", forHTTPHeaderField: "User-Agent")
        switch repo.kind {
        case .forgejo: request.setValue("token \(token)", forHTTPHeaderField: "Authorization")
        case .gitlab: request.setValue(token, forHTTPHeaderField: "PRIVATE-TOKEN")
        case .github:
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        }
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = data.isEmpty ? nil : try? JSONSerialization.jsonObject(with: data)
        guard (200..<300).contains(status) else {
            let message = Self.message(in: json) ?? String(decoding: data.prefix(200), as: UTF8.self)
            switch status {
            case 401: throw ForgeError.unauthorized(host: repo.host)
            case 404: throw ForgeError.notFound(repo.fullName)
            case 409, 422: throw ForgeError.rejected(message)
            default: throw ForgeError.http(status: status, message: message)
            }
        }
        guard let json else { throw ForgeError.badResponse("empty body from \(path)") }
        return json
    }

    /// The human part of an error body: `message` (GitHub, Gitea, GitLab), GitHub's `errors[].message`,
    /// or GitLab's `message` array.
    static func message(in json: Any?) -> String? {
        guard let object = json as? [String: Any] else { return nil }
        var parts: [String] = []
        if let message = object["message"] as? String { parts.append(message) }
        if let messages = object["message"] as? [String] { parts += messages }
        if let errors = object["errors"] as? [[String: Any]] { parts += errors.compactMap { $0["message"] as? String } }
        if let error = object["error"] as? String { parts.append(error) }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }
}

/// Reading JSON objects without a Codable type per forge.
extension Dictionary where Key == String, Value == Any {
    func string(_ key: String) -> String? { self[key] as? String }
    func int(_ key: String) -> Int? { (self[key] as? NSNumber)?.intValue }
    func bool(_ key: String) -> Bool { (self[key] as? Bool) ?? false }
    func object(_ key: String) -> [String: Any]? { self[key] as? [String: Any] }
    func path(_ keys: String...) -> Any? {
        var value: Any? = self
        for key in keys { value = (value as? [String: Any])?[key] }
        return value
    }
}

func objects(_ json: Any, _ what: String) throws -> [[String: Any]] {
    guard let list = json as? [[String: Any]] else { throw ForgeError.badResponse(what) }
    return list
}

func object(_ json: Any, _ what: String) throws -> [String: Any] {
    guard let object = json as? [String: Any] else { throw ForgeError.badResponse(what) }
    return object
}
