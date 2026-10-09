// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing
@testable import ModelKit

/// Plays back a canned HTTP response and keeps the request.
final class StubProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var status = 200
    nonisolated(unsafe) static var body = ""
    nonisolated(unsafe) static var requests: [URLRequest] = []
    nonisolated(unsafe) static var bodies: [Data] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests.append(request)
        if let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable { let n = stream.read(&buffer, maxLength: 4096); if n <= 0 { break }; data.append(buffer, count: n) }
            Self.bodies.append(data)
        } else {
            Self.bodies.append(request.httpBody ?? Data())
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/event-stream"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(Self.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}

    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        return URLSession(configuration: config)
    }
}

@Suite(.serialized)
struct RemoteModelTests {
    let conversation = ModelPrompt.conversation([
        ChatTurn(.system, "You are a coding agent."),
        ChatTurn(.user, "Fix add."),
        ChatTurn(.assistant, "<tool_call>{\"name\": \"read\"}</tool_call>"),
        ChatTurn(.user, "<tool_response>a.ts</tool_response>"),
        ChatTurn(.tool, "more data"),
    ], toolsJSON: nil, assistantPrefix: nil)

    @Test func anthropicStreamsTextAndSendsTheRightRequest() async throws {
        StubProtocol.status = 200
        StubProtocol.requests = []; StubProtocol.bodies = []
        StubProtocol.body = """
            event: message_start
            data: {"type":"message_start","message":{"id":"m"}}

            event: content_block_delta
            data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hello"}}

            event: content_block_delta
            data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":", world"}}

            event: message_stop
            data: {"type":"message_stop"}

            """
        let model = RemoteModel(config: .anthropic, apiKey: "sk-test", session: StubProtocol.session())
        #expect(try await model.complete(conversation, maxTokens: 100) == "Hello, world")
        let request = try #require(StubProtocol.requests.first)
        #expect(request.url?.absoluteString == "https://api.anthropic.com/v1/messages")
        #expect(request.value(forHTTPHeaderField: "x-api-key") == "sk-test")
        #expect(request.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
        let body = try JSONSerialization.jsonObject(with: StubProtocol.bodies[0]) as! [String: Any]
        #expect(body["model"] as? String == "claude-sonnet-5-5")
        #expect(body["system"] as? String == "You are a coding agent.")
        let messages = body["messages"] as! [[String: String]]
        // Alternating roles; the tool turn merged into the user turn before it.
        #expect(messages.map { $0["role"]! } == ["user", "assistant", "user"])
        #expect(messages[2]["content"] == "<tool_response>a.ts</tool_response>\n\nmore data")
    }

    @Test func openAICompatibleStreamsAndPrefills() async throws {
        StubProtocol.status = 200
        StubProtocol.requests = []; StubProtocol.bodies = []
        StubProtocol.body = """
            data: {"choices":[{"delta":{"role":"assistant"}}]}

            data: {"choices":[{"delta":{"content":"read\\", "}}]}

            data: {"choices":[{"delta":{"content":"\\"arguments\\": {}}"}}]}

            data: [DONE]

            """
        let model = RemoteModel(config: .deepSeek, apiKey: "k", session: StubProtocol.session())
        let prompt = ModelPrompt.conversation([ChatTurn(.system, "s"), ChatTurn(.user, "u")], toolsJSON: nil, assistantPrefix: "{\"name\": \"")
        #expect(try await model.complete(prompt, maxTokens: 10) == "read\", \"arguments\": {}}")
        let request = try #require(StubProtocol.requests.first)
        #expect(request.url?.absoluteString == "https://api.deepseek.com/v1/chat/completions")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer k")
        let body = try JSONSerialization.jsonObject(with: StubProtocol.bodies[0]) as! [String: Any]
        let messages = body["messages"] as! [[String: String]]
        #expect(messages.map { $0["role"]! } == ["system", "user", "assistant"])
        #expect(messages.last?["content"] == "{\"name\": \"")
    }

    @Test func errorsSayWhatToDo() async throws {
        StubProtocol.status = 401
        StubProtocol.body = "{\"type\":\"error\",\"error\":{\"type\":\"authentication_error\",\"message\":\"invalid x-api-key\"}}"
        let model = RemoteModel(config: .anthropic, apiKey: "bad", session: StubProtocol.session())
        await #expect(throws: RemoteModelError.http(status: 401, message: "invalid x-api-key")) {
            _ = try await model.complete(.chat(system: nil, user: "hi"), maxTokens: 5)
        }
        #expect(RemoteModelError.http(status: 401, message: "x").localizedDescription.contains("Settings › Models"))
        StubProtocol.status = 200
    }
}
