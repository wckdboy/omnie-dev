// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing
@testable import RunKit

struct MiniYAMLTests {
    @Test func parsesTheCommonShapes() throws {
        let yaml = """
            # a comment
            name: demo   # trailing comment
            version: 3
            ratio: 1.5
            on: true
            empty: ~
            quoted: "a: b # not a comment"
            single: 'it''s'
            url: https://example.com/a#frag
            list:
              - one
              - 2
            flat:
            - x
            - y
            flow: [a, "b, c", {k: v}]
            people:
              - name: Ada
                langs: [en, fr]
              - name: Grace
            nested:
              - - 1
                - 2
            text: |
              line one
                indented
            folded: >-
              joined
              words
            """
        let value = try #require(MiniYAML.parse(yaml) as? [String: Any])
        #expect(value["name"] as? String == "demo")
        #expect(value["version"] as? Int == 3)
        #expect(value["ratio"] as? Double == 1.5)
        #expect(value["on"] as? Bool == true)
        #expect(value["empty"] is NSNull)
        #expect(value["quoted"] as? String == "a: b # not a comment")
        #expect(value["single"] as? String == "it's")
        #expect(value["url"] as? String == "https://example.com/a#frag")
        #expect((value["list"] as? [Any])?.count == 2)
        #expect((value["list"] as? [Any])?.last as? Int == 2)
        #expect(value["flat"] as? [String] == ["x", "y"])
        let flow = try #require(value["flow"] as? [Any])
        #expect(flow[0] as? String == "a" && flow[1] as? String == "b, c" && (flow[2] as? [String: Any])?["k"] as? String == "v")
        let people = try #require(value["people"] as? [[String: Any]])
        #expect(people.count == 2)
        #expect(people[0]["name"] as? String == "Ada" && people[0]["langs"] as? [String] == ["en", "fr"])
        #expect(people[1]["name"] as? String == "Grace")
        #expect(value["nested"] as? [[Int]] == [[1, 2]])
        #expect(value["text"] as? String == "line one\n  indented\n")
        #expect(value["folded"] as? String == "joined words")
    }

    @Test func openAPIFromYAML() {
        let yaml = """
            openapi: 3.0.3
            servers:
              - url: /api
            paths:
              /items/{id}:
                get:
                  responses:
                    '200':
                      content:
                        application/json:
                          schema:
                            $ref: '#/components/schemas/Item'
            components:
              schemas:
                Item:
                  type: object
                  properties:
                    id: { type: integer, example: 42 }
                    tags:
                      type: array
                      items: { type: string }
            """
        let routes = OpenAPIMocks.routes(yaml: yaml)
        #expect(routes.count == 1)
        #expect(routes.first?.path == "/api/items/:id")
        #expect(routes.first?.body.contains("\"id\" : 42") == true)
        #expect(routes.first?.body.contains("\"string\"") == true)
    }
}
