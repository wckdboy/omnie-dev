// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// A model behind an HTTP API (PLAN.md §7, router policy 2: online + auto). The key is passed in
/// for each request by the caller (SecretsKit's broker); it's never part of a prompt.
public struct RemoteModelConfig: Codable, Sendable, Hashable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        /// Anthropic's Messages API.
        case anthropic
        /// The OpenAI chat-completions shape: OpenAI, DeepSeek, OpenRouter, local servers.
        case openAICompatible
    }

    public var kind: Kind
    /// Shown in the UI and the audit log, and the provider name for consent ("anthropic").
    public var provider: String
    public var baseURL: URL
    public var model: String

    public init(kind: Kind, provider: String, baseURL: URL, model: String) {
        self.kind = kind
        self.provider = provider
        self.baseURL = baseURL
        self.model = model
    }

    public static let anthropic = RemoteModelConfig(kind: .anthropic, provider: "anthropic",
                                                    baseURL: URL(string: "https://api.anthropic.com")!, model: "claude-sonnet-5-5")
    public static let openAI = RemoteModelConfig(kind: .openAICompatible, provider: "openai",
                                                 baseURL: URL(string: "https://api.openai.com/v1")!, model: "gpt-5")
    public static let deepSeek = RemoteModelConfig(kind: .openAICompatible, provider: "deepseek",
                                                   baseURL: URL(string: "https://api.deepseek.com/v1")!, model: "deepseek-chat")
    public static let openRouter = RemoteModelConfig(kind: .openAICompatible, provider: "openrouter",
                                                     baseURL: URL(string: "https://openrouter.ai/api/v1")!, model: "anthropic/claude-sonnet-5.5")

    public var host: String { baseURL.host() ?? provider }
}

public enum RemoteModelError: Error, Equatable, LocalizedError {
    case http(status: Int, message: String)
    case badResponse

    public var errorDescription: String? {
        switch self {
        case .http(401, _), .http(403, _): "The provider refused the API key. Check it in Settings › Models."
        case .http(429, _): "The provider is rate-limiting requests. Try again in a moment."
        case .http(let status, let message): "The provider returned \(status): \(message)"
        case .badResponse: "The provider's response couldn't be read."
        }
    }
}

/// Streams text from a remote model. `session` is injectable for tests.
public struct RemoteModel: TextModel {
    public let config: RemoteModelConfig
    let apiKey: String
    let session: URLSession

    public init(config: RemoteModelConfig, apiKey: String, session: URLSession = .shared) {
        self.config = config
        self.apiKey = apiKey
        self.session = session
    }

    public func stream(_ prompt: ModelPrompt, maxTokens: Int, temperature: Float) async throws -> AsyncThrowingStream<String, Error> {
        let request = try makeRequest(prompt, maxTokens: maxTokens, temperature: temperature)
        var attempt = 0
        var bytes: URLSession.AsyncBytes
        while true {
            attempt += 1
            do {
                let (b, response) = try await session.bytes(for: request)
                guard let http = response as? HTTPURLResponse else { throw RemoteModelError.badResponse }
                guard (200..<300).contains(http.statusCode) else {
                    var body = ""
                    for try await line in b.lines { body += line; if body.count > 2_000 { break } }
                    throw RemoteModelError.http(status: http.statusCode, message: Self.errorMessage(body))
                }
                bytes = b
                break
            } catch where attempt < Self.attempts && Self.isTransient(error) {
                // Dropped connections, rate limits and overloads usually pass: wait and retry.
                try await Task.sleep(for: .milliseconds(500 * (1 << attempt)))
            }
        }
        let kind = config.kind
        let received = bytes
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await line in received.lines {
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        if payload == "[DONE]" { break }
                        if let text = Self.text(from: Data(payload.utf8), kind: kind) { continuation.yield(text) }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: Wire formats

    struct Message: Encodable, Equatable {
        let role: String
        let content: String
    }

    /// The prompt as (system, alternating messages). Tool results are user turns; consecutive
    /// turns of the same role are merged, since the APIs expect alternation.
    static func messages(_ prompt: ModelPrompt) -> (system: String?, messages: [Message]) {
        let turns: [ChatTurn]
        switch prompt {
        case .chat(let system, let user): turns = (system.map { [ChatTurn(.system, $0)] } ?? []) + [ChatTurn(.user, user)]
        case .conversation(let t, _, _): turns = t
        case .raw(let text): turns = [ChatTurn(.user, text)]
        }
        let system = turns.filter { $0.role == .system }.map(\.content).joined(separator: "\n\n")
        var messages: [Message] = []
        for turn in turns where turn.role != .system {
            let role = turn.role == .assistant ? "assistant" : "user"
            if let last = messages.last, last.role == role {
                messages[messages.count - 1] = Message(role: role, content: last.content + "\n\n" + turn.content)
            } else {
                messages.append(Message(role: role, content: turn.content))
            }
        }
        return (system.isEmpty ? nil : system, messages)
    }

    func makeRequest(_ prompt: ModelPrompt, maxTokens: Int, temperature: Float) throws -> URLRequest {
        var (system, messages) = Self.messages(prompt)
        // A pre-started reply (the agent's constrained retry) is the last assistant message.
        var prefill: String?
        if case .conversation(_, _, let prefix) = prompt, let prefix { prefill = prefix }
        var request: URLRequest
        var body: [String: Any]
        switch config.kind {
        case .anthropic:
            request = URLRequest(url: config.baseURL.appending(path: "v1/messages"))
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            // Current Claude models don't take a prefilled reply; ask for the same shape instead.
            if prefill != nil {
                let nudge = "Reply with exactly one tool call and nothing else: <tool_call>{\"name\": …, \"arguments\": {…}}</tool_call>"
                if let last = messages.last, last.role == "user" {
                    messages[messages.count - 1] = Message(role: "user", content: last.content + "\n\n" + nudge)
                } else {
                    messages.append(Message(role: "user", content: nudge))
                }
            }
            // No temperature: current Claude models reject it ("deprecated for this model").
            body = ["model": config.model, "max_tokens": maxTokens, "stream": true,
                    "messages": messages.map { ["role": $0.role, "content": $0.content] }]
            if let system { body["system"] = system }
        case .openAICompatible:
            request = URLRequest(url: config.baseURL.appending(path: "chat/completions"))
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            var all = (system.map { [Message(role: "system", content: $0)] } ?? []) + messages
            if let prefill { all.append(Message(role: "assistant", content: prefill)) }
            body = ["model": config.model, "max_tokens": maxTokens, "stream": true, "temperature": Double(temperature),
                    "messages": all.map { ["role": $0.role, "content": $0.content] }]
            system = nil
        }
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        request.timeoutInterval = 120
        return request
    }

    /// The text in one streamed event, or nil for events without text.
    static func text(from data: Data, kind: RemoteModelConfig.Kind) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        switch kind {
        case .anthropic:
            guard json["type"] as? String == "content_block_delta", let delta = json["delta"] as? [String: Any],
                  delta["type"] as? String == "text_delta" else { return nil }
            return delta["text"] as? String
        case .openAICompatible:
            let choice = (json["choices"] as? [[String: Any]])?.first
            return (choice?["delta"] as? [String: Any])?["content"] as? String
        }
    }

    static let attempts = 3

    /// Worth retrying: network drops and timeouts, 408, 429, and server errors (529 is "overloaded").
    static func isTransient(_ error: Error) -> Bool {
        if let error = error as? RemoteModelError, case .http(let status, _) = error {
            return status == 408 || status == 429 || status >= 500
        }
        if let error = error as? URLError {
            return [.networkConnectionLost, .timedOut, .notConnectedToInternet, .cannotConnectToHost, .dnsLookupFailed].contains(error.code)
        }
        return false
    }

    static func errorMessage(_ body: String) -> String {
        if let data = body.data(using: .utf8), let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let error = json["error"] as? [String: Any], let message = error["message"] as? String {
            return message
        }
        return String(body.prefix(200))
    }
}
