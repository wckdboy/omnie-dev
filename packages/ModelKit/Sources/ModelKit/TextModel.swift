// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// One message in a conversation.
public struct ChatTurn: Codable, Sendable, Hashable {
    public enum Role: String, Codable, Sendable {
        case system, user, assistant
        /// A tool's result, fed back to the model.
        case tool
    }

    public let role: Role
    public let content: String

    public init(_ role: Role, _ content: String) {
        self.role = role
        self.content = content
    }
}

public enum ModelPrompt: Sendable, Hashable {
    /// A chat turn, formatted with the model's own chat template.
    case chat(system: String?, user: String)
    /// A whole conversation (the agent loop), formatted with the model's chat template.
    case conversation([ChatTurn])
    /// Text passed to the model as-is (fill-in-the-middle, base-model completion).
    case raw(String)
}

/// A local or remote text model. Backends stream text; `complete` adds stop sequences on top.
public protocol TextModel: Sendable {
    func stream(_ prompt: ModelPrompt, maxTokens: Int, temperature: Float) async throws -> AsyncThrowingStream<String, Error>
}

extension TextModel {
    /// Collects the stream, stopping at the first stop sequence (which isn't included).
    public func complete(_ prompt: ModelPrompt, maxTokens: Int, temperature: Float = 0,
                         stop: [String] = []) async throws -> String {
        var text = ""
        for try await chunk in try await stream(prompt, maxTokens: maxTokens, temperature: temperature) {
            text += chunk
            if let cut = Self.firstStop(in: text, stop) {
                return String(text[..<cut])
            }
        }
        return text
    }

    static func firstStop(in text: String, _ stops: [String]) -> String.Index? {
        stops.compactMap { text.range(of: $0)?.lowerBound }.min()
    }
}

/// Whether a model fits in memory now (PLAN.md §16 rule 5: check before loading anything large).
public enum MemoryBudget {
    /// Weights plus a quarter for activations and KV cache, plus 512 MB for the rest of the app.
    public static func required(for pack: ModelPack) -> Int64 {
        let weights = pack.files.filter { $0.name.hasSuffix(".safetensors") }.reduce(0) { $0 + $1.size }
        return weights + weights / 4 + 512 << 20
    }

    public static func canLoad(_ pack: ModelPack, available: Int64) -> Bool {
        available >= required(for: pack)
    }
}
