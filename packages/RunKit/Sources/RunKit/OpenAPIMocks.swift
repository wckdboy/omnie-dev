// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

import Foundation
import ToolsKit

/// Mock routes from an OpenAPI 3 or Swagger 2 document in the project (PLAN.md §11.1), so a
/// frontend runs against an API that only exists as a spec. Each operation answers with its first
/// success response: the example if the spec has one, else a sample built from the schema.
/// JSON or YAML.
public enum OpenAPIMocks {
    /// Where specs are looked for: the project root and `api/`, `docs/`, `spec/`.
    static let folders = ["", "api", "docs", "spec"]

    public static func specFiles(in root: URL) -> [URL] {
        folders.flatMap { folder -> [URL] in
            let dir = folder.isEmpty ? root : root.appending(path: folder)
            let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
            return names.filter { name in
                let lower = name.lowercased()
                return ["openapi", "swagger"].contains((lower as NSString).deletingPathExtension) && ["json", "yaml", "yml"].contains((lower as NSString).pathExtension)
                    || [".openapi.json", ".openapi.yaml", ".openapi.yml"].contains { lower.hasSuffix($0) }
            }.sorted().map { dir.appending(path: $0) }
        }
    }

    public static func load(root: URL) -> [MockRoute] {
        specFiles(in: root).flatMap { url -> [MockRoute] in
            guard let data = try? Data(contentsOf: url) else { return [] }
            return url.pathExtension.lowercased() == "json" ? routes(from: data) : routes(yaml: String(decoding: data, as: UTF8.self))
        }
    }

    public static func routes(from data: Data) -> [MockRoute] {
        routes(spec: try? JSONSerialization.jsonObject(with: data))
    }

    public static func routes(yaml: String) -> [MockRoute] {
        routes(spec: YAML.parse(yaml))
    }

    static func routes(spec: Any?) -> [MockRoute] {
        guard let spec = spec as? [String: Any], let paths = spec["paths"] as? [String: Any] else { return [] }
        let base = basePath(spec)
        var routes: [MockRoute] = []
        for (path, item) in paths.sorted(by: { $0.key < $1.key }) {
            guard let item = item as? [String: Any] else { continue }
            let mockPath = base + path.replacing(/\{([^}\/]+)\}/) { ":" + $0.1 }
            for method in ["get", "post", "put", "patch", "delete"] {
                guard let operation = item[method] as? [String: Any],
                      let responses = operation["responses"] as? [String: Any] else { continue }
                let code = responses.keys.filter { $0.hasPrefix("2") }.sorted().first ?? (responses["default"] != nil ? "default" : nil)
                guard let code, let response = resolve(responses[code], in: spec) as? [String: Any] else { continue }
                let status = Int(code) ?? 200
                let (contentType, body) = sample(response, spec: spec)
                routes.append(MockRoute(method: method, path: mockPath, status: status, contentType: contentType, body: body))
            }
        }
        return routes
    }

    /// "/v1" from `servers[0].url` (OpenAPI 3) or `basePath` (Swagger 2); "" when it's the root.
    static func basePath(_ spec: [String: Any]) -> String {
        var path = spec["basePath"] as? String ?? ""
        if let server = (spec["servers"] as? [[String: Any]])?.first?["url"] as? String {
            path = URL(string: server)?.path() ?? (server.hasPrefix("/") ? server : "")
        }
        while path.hasSuffix("/") { path.removeLast() }
        return path
    }

    static func sample(_ response: [String: Any], spec: [String: Any]) -> (String, String) {
        // OpenAPI 3: content by media type.
        if let content = response["content"] as? [String: Any] {
            let type = content.keys.first { $0.contains("json") } ?? content.keys.sorted().first
            guard let type, let media = content[type] as? [String: Any] else { return ("text/plain", "") }
            if let example = media["example"] { return (type, json(example)) }
            if let examples = media["examples"] as? [String: Any], let first = examples.keys.sorted().first,
               let value = (resolve(examples[first], in: spec) as? [String: Any])?["value"] {
                return (type, json(value))
            }
            if let schema = media["schema"] { return (type, json(value(for: schema, spec: spec, depth: 0))) }
            return (type, "")
        }
        // Swagger 2: schema and examples on the response.
        if let example = (response["examples"] as? [String: Any])?["application/json"] { return ("application/json", json(example)) }
        if let schema = response["schema"] { return ("application/json", json(value(for: schema, spec: spec, depth: 0))) }
        return ("text/plain", "")
    }

    /// A plausible value for a schema: its example, default or first enum value, else by type.
    static func value(for raw: Any?, spec: [String: Any], depth: Int) -> Any {
        guard depth < 8, let schema = resolve(raw, in: spec) as? [String: Any] else { return NSNull() }
        if let example = schema["example"] { return example }
        if let examples = schema["examples"] as? [Any], let first = examples.first { return first }
        if let value = schema["default"] { return value }
        if let options = schema["enum"] as? [Any], let first = options.first { return first }
        if let all = schema["allOf"] as? [Any] {
            var merged: [String: Any] = [:]
            for part in all { if let object = value(for: part, spec: spec, depth: depth + 1) as? [String: Any] { merged.merge(object) { a, _ in a } } }
            return merged
        }
        for key in ["oneOf", "anyOf"] { if let first = (schema[key] as? [Any])?.first { return value(for: first, spec: spec, depth: depth + 1) } }
        var type = schema["type"] as? String
        if type == nil, let types = schema["type"] as? [String] { type = types.first { $0 != "null" } }
        if type == nil { type = schema["properties"] != nil ? "object" : schema["items"] != nil ? "array" : nil }
        switch type {
        case "object":
            var object: [String: Any] = [:]
            for (name, property) in (schema["properties"] as? [String: Any]) ?? [:] {
                object[name] = value(for: property, spec: spec, depth: depth + 1)
            }
            return object
        case "array": return [value(for: schema["items"], spec: spec, depth: depth + 1)]
        case "integer": return (schema["minimum"] as? Int) ?? 1
        case "number": return (schema["minimum"] as? Double) ?? 1.5
        case "boolean": return true
        case "string":
            switch schema["format"] as? String {
            case "date-time": return "2026-01-01T12:00:00Z"
            case "date": return "2026-01-01"
            case "email": return "ada@example.com"
            case "uuid": return "3f2b8c1e-5d6a-4e7f-9a0b-1c2d3e4f5a6b"
            case "uri", "url": return "https://example.com"
            default: return "string"
            }
        default: return NSNull()
        }
    }

    /// Follows a local `$ref` ("#/components/schemas/User").
    static func resolve(_ raw: Any?, in spec: [String: Any], hops: Int = 0) -> Any? {
        guard let object = raw as? [String: Any], let ref = object["$ref"] as? String else { return raw }
        guard hops < 16, ref.hasPrefix("#/") else { return nil }
        var node: Any? = spec
        for part in ref.dropFirst(2).split(separator: "/") {
            let key = part.replacingOccurrences(of: "~1", with: "/").replacingOccurrences(of: "~0", with: "~")
            node = (node as? [String: Any])?[key]
        }
        return resolve(node, in: spec, hops: hops + 1)
    }

    static func json(_ value: Any) -> String {
        if let string = value as? String, !JSONSerialization.isValidJSONObject([string]) { return string }
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed]) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }
}
