// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// The forges with an adapter. Forgejo and Gitea share one API (Forgejo is a Gitea fork).
public enum ForgeKind: String, Codable, Sendable, CaseIterable, Identifiable {
    case forgejo, gitlab, github

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .forgejo: "Forgejo / Gitea"
        case .gitlab: "GitLab"
        case .github: "GitHub"
        }
    }

    /// What the forge calls the thing ("merge request" on GitLab).
    public var requestName: String { self == .gitlab ? "merge request" : "pull request" }

    /// The kind a host is known to be, from its name; nil means "set it by hand".
    public static func guess(host: String) -> ForgeKind? {
        let host = host.lowercased()
        if host == "github.com" || host.hasPrefix("github.") { return .github }
        if host == "gitlab.com" || host.contains("gitlab") { return .gitlab }
        if ["gitea.com", "codeberg.org", "next.forgejo.org"].contains(host)
            || host.contains("forgejo") || host.contains("gitea") || host.contains("codeberg") { return .forgejo }
        return nil
    }
}

/// A repository on a forge, found from a git remote's URL: `https://host/owner/name(.git)`,
/// `ssh://git@host:port/owner/name.git` or `git@host:owner/name.git`. GitLab's nested groups
/// make `owner` a path (`group/subgroup`).
public struct ForgeRepo: Sendable, Hashable, Codable {
    public var kind: ForgeKind
    /// Scheme, host and port of the web UI (an SSH remote's forge is assumed to serve HTTPS).
    public var web: URL
    public var owner: String
    public var name: String

    public init(kind: ForgeKind, web: URL, owner: String, name: String) {
        self.kind = kind
        self.web = web
        self.owner = owner
        self.name = name
    }

    /// `kind` overrides the guess from the host (a self-hosted forge with a plain name).
    public init?(remoteURL: String, kind: ForgeKind? = nil) {
        guard let (scheme, host, port, path) = Self.split(remoteURL),
              let kind = kind ?? ForgeKind.guess(host: host) else { return nil }
        var parts = path.split(separator: "/").map(String.init)
        if let last = parts.last, last.hasSuffix(".git") { parts[parts.count - 1] = String(last.dropLast(4)) }
        guard parts.count >= 2, !parts.last!.isEmpty else { return nil }
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.port = port
        guard let web = components.url else { return nil }
        self.init(kind: kind, web: web, owner: parts.dropLast().joined(separator: "/"), name: parts.last!)
    }

    public var host: String { web.host() ?? "" }
    public var fullName: String { "\(owner)/\(name)" }

    /// Where the REST API lives: `/api/v1` (Forgejo, Gitea), `/api/v4` (GitLab), and GitHub's
    /// own host (or `/api/v3` on GitHub Enterprise Server).
    public var api: URL {
        switch kind {
        case .forgejo: web.appending(path: "api/v1")
        case .gitlab: web.appending(path: "api/v4")
        case .github: host == "github.com" ? URL(string: "https://api.github.com")! : web.appending(path: "api/v3")
        }
    }

    /// Scheme, host, port and path of any remote form. HTTP stays HTTP (a forge on the LAN);
    /// everything else is reached over HTTPS, without the SSH port.
    static func split(_ url: String) -> (scheme: String, host: String, port: Int?, path: String)? {
        if let parsed = URLComponents(string: url), let host = parsed.host, !host.isEmpty {
            switch parsed.scheme?.lowercased() {
            case "http", "https": return (parsed.scheme!.lowercased(), host, parsed.port, parsed.path)
            case "ssh", "git", "git+ssh", "ssh+git": return ("https", host, nil, parsed.path)
            default: return nil
            }
        }
        // scp-like: [user@]host:path
        guard !url.contains("://"), let colon = url.firstIndex(of: ":") else { return nil }
        let userHost = url[..<colon]
        let host = userHost.split(separator: "@").last.map(String.init) ?? ""
        guard !host.isEmpty else { return nil }
        return ("https", host, nil, String(url[url.index(after: colon)...]))
    }
}
