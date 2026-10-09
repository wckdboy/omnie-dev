// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// HTTPS credentials per host, e.g. a GitHub or Forgejo personal access token.
public struct HTTPSToken: Codable, Equatable, Sendable {
    public var username: String
    public var token: String

    public init(username: String, token: String) {
        self.username = username
        self.token = token
    }

    private static func account(_ host: String) -> String { "https.token.\(host.lowercased())" }

    public static func load(host: String) -> HTTPSToken? {
        Keychain.data(for: account(host)).flatMap { try? JSONDecoder().decode(HTTPSToken.self, from: $0) }
    }

    public static func save(_ token: HTTPSToken, host: String) throws {
        try Keychain.set(try JSONEncoder().encode(token), for: account(host))
    }

    public static func delete(host: String) { Keychain.delete(account(host)) }

    /// The username convention each forge expects with a token.
    public static func usernameHint(for host: String) -> String {
        switch host.lowercased() {
        case "github.com": "Any name works with a GitHub token, e.g. your username."
        case "gitlab.com": "Use oauth2 as the username with a GitLab token."
        default: "Your account name on this forge."
        }
    }
}
