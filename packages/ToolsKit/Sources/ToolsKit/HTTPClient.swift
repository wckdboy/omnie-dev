// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// A request from a `.http` file (the REST Client / JetBrains format), PLAN.md §11.1:
///
///     @host = https://api.example.com
///     ### List users
///     GET {{host}}/users?page=1
///     Authorization: Bearer {{secret api-token}}
///
///     ### Create one
///     POST {{host}}/users
///     Content-Type: application/json
///
///     {"name": "Ada"}
///
/// `{{secret NAME}}` is filled in from the Keychain when the request is sent, so secrets never live
/// in the file (or the repo).
public struct HTTPRequestSpec: Sendable, Hashable, Identifiable {
    public var id: Int { line }
    /// The `###` title, or the request line.
    public let name: String
    public let method: String
    public let url: String
    public let headers: [(String, String)]
    public let body: String?
    /// Where the request starts in the file (1-based).
    public let line: Int

    public static func == (a: Self, b: Self) -> Bool {
        a.name == b.name && a.method == b.method && a.url == b.url && a.body == b.body && a.line == b.line
            && a.headers.map { $0.0 + ":" + $0.1 } == b.headers.map { $0.0 + ":" + $0.1 }
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(line)
        hasher.combine(url)
    }
}

public enum HTTPFile {
    public static let methods: Set<String> = ["GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS"]

    /// The requests in a `.http` file, with `@variables` substituted (secrets are left for later).
    public static func parse(_ text: String) -> [HTTPRequestSpec] {
        var variables: [String: String] = [:]
        var requests: [HTTPRequestSpec] = []
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map { String($0).replacingOccurrences(of: "\r", with: "") }
        var title: String?
        var i = 0
        func substitute(_ s: String) -> String {
            var out = s
            for (k, v) in variables { out = out.replacingOccurrences(of: "{{\(k)}}", with: v) }
            return out
        }
        while i < lines.count {
            let line = lines[i].trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("###") {
                let t = line.dropFirst(3).trimmingCharacters(in: .whitespaces)
                title = t.isEmpty ? nil : t
                i += 1; continue
            }
            if line.hasPrefix("@"), let eq = line.firstIndex(of: "=") {
                let name = line[line.index(after: line.startIndex)..<eq].trimmingCharacters(in: .whitespaces)
                variables[name] = substitute(line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces))
                i += 1; continue
            }
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix("//") { i += 1; continue }
            // A request line: METHOD URL [HTTP/x], or just a URL (GET).
            let parts = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            let method = methods.contains(parts[0].uppercased()) ? parts[0].uppercased() : "GET"
            let url = substitute(methods.contains(parts[0].uppercased()) ? (parts.count > 1 ? parts[1] : "") : parts[0])
            let start = i + 1
            i += 1
            var headers: [(String, String)] = []
            while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).isEmpty, !lines[i].hasPrefix("###") {
                if let colon = lines[i].firstIndex(of: ":") {
                    headers.append((lines[i][..<colon].trimmingCharacters(in: .whitespaces),
                                    substitute(lines[i][lines[i].index(after: colon)...].trimmingCharacters(in: .whitespaces))))
                }
                i += 1
            }
            var bodyLines: [String] = []
            if i < lines.count, !lines[i].hasPrefix("###") { i += 1 }
            while i < lines.count, !lines[i].hasPrefix("###") { bodyLines.append(lines[i]); i += 1 }
            while bodyLines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { bodyLines.removeLast() }
            let body = bodyLines.isEmpty ? nil : substitute(bodyLines.joined(separator: "\n"))
            requests.append(HTTPRequestSpec(name: title ?? "\(method) \(url)", method: method, url: url, headers: headers, body: body, line: start))
            title = nil
        }
        return requests
    }

    /// The names of `{{secret NAME}}` placeholders a request uses.
    public static func secrets(in spec: HTTPRequestSpec) -> [String] {
        let all = ([spec.url, spec.body ?? ""] + spec.headers.map(\.1)).joined(separator: "\n")
        return all.matches(of: /\{\{\s*secret\s+([\w.\-]+)\s*\}\}/).map { String($0.1) }
    }
}

public struct HTTPResult: Sendable, Equatable {
    public let status: Int
    public let headers: [String: String]
    public let body: String
    public let bytes: Int
    public let ms: Int

    /// The body pretty-printed when it's JSON.
    public var displayBody: String {
        guard let data = body.data(using: .utf8), let json = try? JSONSerialization.jsonObject(with: data),
              let pretty = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else { return body }
        return String(decoding: pretty, as: UTF8.self)
    }
}

public enum HTTPClientError: Error, Equatable, LocalizedError {
    case badURL(String)
    case missingSecret(String)
    public var errorDescription: String? {
        switch self {
        case .badURL(let u): "Not a URL: \(u)"
        case .missingSecret(let name): "The secret \"\(name)\" isn't set. Add it in the HTTP tool's Secrets."
        }
    }
}

public enum HTTPClient {
    /// Builds the URLRequest, filling `{{secret NAME}}` from `secret`.
    public static func request(_ spec: HTTPRequestSpec, secret: (String) -> String?) throws -> URLRequest {
        func fill(_ s: String) throws -> String {
            var out = s
            for match in s.matches(of: /\{\{\s*secret\s+([\w.\-]+)\s*\}\}/) {
                guard let value = secret(String(match.1)) else { throw HTTPClientError.missingSecret(String(match.1)) }
                out = out.replacingOccurrences(of: String(match.0), with: value)
            }
            return out
        }
        guard let url = URL(string: try fill(spec.url)), url.scheme == "http" || url.scheme == "https" else {
            throw HTTPClientError.badURL(spec.url)
        }
        var request = URLRequest(url: url)
        request.httpMethod = spec.method
        for (name, value) in spec.headers { request.setValue(try fill(value), forHTTPHeaderField: name) }
        if let body = spec.body { request.httpBody = Data(try fill(body).utf8) }
        request.timeoutInterval = 60
        return request
    }

    public static func send(_ request: URLRequest, session: URLSession = .shared) async throws -> HTTPResult {
        let start = Date()
        let (data, response) = try await session.data(for: request)
        let http = response as? HTTPURLResponse
        var headers: [String: String] = [:]
        for (k, v) in http?.allHeaderFields ?? [:] { headers["\(k)"] = "\(v)" }
        return HTTPResult(status: http?.statusCode ?? 0, headers: headers,
                          body: String(decoding: data.prefix(2_000_000), as: UTF8.self), bytes: data.count,
                          ms: Int(Date().timeIntervalSince(start) * 1000))
    }
}
