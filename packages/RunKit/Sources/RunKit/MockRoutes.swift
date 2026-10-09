// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// The API mock server (PLAN.md §11.1): recorded responses in the project's `.omnie/mocks.json`,
/// served to previews for same-origin paths that aren't files (`fetch("/api/users")`). Lets a
/// frontend run against its API with no connection.
public struct MockRoute: Codable, Sendable, Hashable {
    public var method: String
    /// The path without the query, e.g. "/api/users".
    public var path: String
    public var status: Int
    public var contentType: String
    public var body: String

    public init(method: String, path: String, status: Int, contentType: String, body: String) {
        self.method = method.uppercased()
        self.path = path
        self.status = status
        self.contentType = contentType
        self.body = body
    }
}

public enum MockRoutes {
    public static let relativePath = ".omnie/mocks.json"

    public static func load(root: URL) -> [MockRoute] {
        guard let data = try? Data(contentsOf: root.appending(path: relativePath)) else { return [] }
        return (try? JSONDecoder().decode([MockRoute].self, from: data)) ?? []
    }

    /// Adds or replaces the route for the same method and path.
    public static func record(_ route: MockRoute, root: URL) throws {
        var routes = load(root: root).filter { !($0.method == route.method && $0.path == route.path) }
        routes.append(route)
        routes.sort { ($0.path, $0.method) < ($1.path, $1.method) }
        let url = root.appending(path: relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(routes).write(to: url, options: .atomic)
    }

    /// The route for a request: exact path, or a `:param` segment (`/api/users/:id`).
    public static func match(method: String, path: String, in routes: [MockRoute]) -> MockRoute? {
        let wanted = path.split(separator: "/")
        return routes.first { $0.method == method.uppercased() && $0.path == path }
            ?? routes.first { route in
                let parts = route.path.split(separator: "/")
                return route.method == method.uppercased() && parts.count == wanted.count
                    && zip(parts, wanted).allSatisfy { $0.hasPrefix(":") || $0 == $1 }
            }
    }
}
