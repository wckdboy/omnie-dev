// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing
@testable import ToolsKit

final class HTTPStub: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var last: URLRequest?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.last = request
        let response = HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{\"id\":7,\"name\":\"Ada\"}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

struct HTTPClientTests {
    let file = """
        @host = https://api.example.com
        @version = v2

        ### List users
        GET {{host}}/{{version}}/users?page=1 HTTP/1.1
        Accept: application/json
        Authorization: Bearer {{secret api-token}}

        ### Create a user
        POST {{host}}/{{version}}/users
        Content-Type: application/json

        {
          "name": "Ada"
        }

        ###
        https://example.com/health
        """

    @Test func parsesRequestsVariablesAndBodies() {
        let requests = HTTPFile.parse(file)
        #expect(requests.map(\.name) == ["List users", "Create a user", "GET https://example.com/health"])
        #expect(requests.map(\.method) == ["GET", "POST", "GET"])
        #expect(requests[0].url == "https://api.example.com/v2/users?page=1")
        #expect(requests[0].headers.map(\.0) == ["Accept", "Authorization"])
        #expect(requests[1].body == "{\n  \"name\": \"Ada\"\n}")
        #expect(requests[0].body == nil)
        #expect(HTTPFile.secrets(in: requests[0]) == ["api-token"])
        #expect(requests[0].line == 5)
    }

    @Test func fillsSecretsOnlyWhenSending() throws {
        let spec = HTTPFile.parse(file)[0]
        #expect(spec.headers[1].1 == "Bearer {{secret api-token}}")
        #expect(throws: HTTPClientError.missingSecret("api-token")) { _ = try HTTPClient.request(spec) { _ in nil } }
        let request = try HTTPClient.request(spec) { $0 == "api-token" ? "s3cret" : nil }
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer s3cret")
        #expect(throws: HTTPClientError.self) { _ = try HTTPClient.request(HTTPFile.parse("GET file:///etc/passwd")[0]) { _ in nil } }
    }

    @Test func sendsAndPrettyPrintsJSON() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [HTTPStub.self]
        let spec = HTTPFile.parse(file)[1]
        let result = try await HTTPClient.send(try HTTPClient.request(spec) { _ in nil }, session: URLSession(configuration: config))
        #expect(result.status == 201)
        #expect(result.displayBody == "{\n  \"id\" : 7,\n  \"name\" : \"Ada\"\n}")
        #expect(HTTPStub.last?.httpMethod == "POST")
    }
}
