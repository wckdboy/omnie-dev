// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing
@testable import RunKit

struct OpenAPIMocksTests {
    let openAPI3 = """
        {
          "openapi": "3.1.0",
          "servers": [{ "url": "https://api.example.com/v1/" }],
          "paths": {
            "/users": {
              "get": { "responses": { "200": { "content": { "application/json": {
                "schema": { "type": "array", "items": { "$ref": "#/components/schemas/User" } } } } } } },
              "post": { "responses": { "201": { "content": { "application/json": {
                "example": { "id": 7, "name": "Ada" } } } } } }
            },
            "/users/{userId}": {
              "get": { "responses": { "404": { "description": "gone" }, "200": { "$ref": "#/components/responses/OneUser" } } },
              "delete": { "responses": { "204": { "description": "deleted" } } }
            }
          },
          "components": {
            "schemas": {
              "User": { "type": "object", "properties": {
                "id": { "type": "integer" }, "email": { "type": "string", "format": "email" },
                "role": { "type": "string", "enum": ["admin", "member"] }, "tags": { "type": "array", "items": { "type": "string" } } } }
            },
            "responses": {
              "OneUser": { "content": { "application/json": { "examples": { "ada": { "value": { "id": 1, "name": "Ada" } } } } } }
            }
          }
        }
        """

    @Test func routesFromAnOpenAPI3Spec() throws {
        let routes = OpenAPIMocks.routes(from: Data(openAPI3.utf8))
        #expect(routes.map { "\($0.method) \($0.path) \($0.status)" } == [
            "GET /v1/users 200", "POST /v1/users 201", "GET /v1/users/:userId 200", "DELETE /v1/users/:userId 204",
        ])
        let list = try #require(routes.first)
        let users = try JSONSerialization.jsonObject(with: Data(list.body.utf8)) as? [[String: Any]]
        let user = try #require(users?.first)
        #expect(user["id"] as? Int == 1 && user["email"] as? String == "ada@example.com" && user["role"] as? String == "admin")
        #expect(user["tags"] as? [String] == ["string"])
        #expect(list.contentType == "application/json")
        #expect(routes[1].body.contains("\"name\" : \"Ada\""))
        #expect(routes[2].body.contains("\"id\" : 1"))
        #expect(routes[3].body.isEmpty)
        #expect(MockRoutes.match(method: "GET", path: "/v1/users/42", in: routes)?.status == 200)
    }

    @Test func routesFromASwagger2Spec() {
        let spec = """
            { "swagger": "2.0", "basePath": "/api", "paths": { "/ping": { "get": { "responses": {
              "200": { "schema": { "$ref": "#/definitions/Pong" } } } } } },
              "definitions": { "Pong": { "properties": { "ok": { "type": "boolean" } } } } }
            """
        let routes = OpenAPIMocks.routes(from: Data(spec.utf8))
        #expect(routes.count == 1)
        #expect(routes.first?.path == "/api/ping")
        #expect(routes.first?.body.contains("\"ok\" : true") == true)
    }

    @Test func recordedResponsesComeFirst() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("openapi-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appending(path: "api"), withIntermediateDirectories: true)
        try openAPI3.write(to: root.appending(path: "api/openapi.json"), atomically: true, encoding: .utf8)
        try MockRoutes.record(MockRoute(method: "GET", path: "/v1/users", status: 200, contentType: "application/json", body: "[]"), root: root)
        let all = MockRoutes.all(root: root)
        #expect(all.count == 5)
        #expect(MockRoutes.match(method: "GET", path: "/v1/users", in: all)?.body == "[]")
        #expect(MockRoutes.match(method: "DELETE", path: "/v1/users/3", in: all)?.status == 204)
    }
}
