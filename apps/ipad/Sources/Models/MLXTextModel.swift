// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import ModelKit
import Tokenizers

/// ModelKit's TextModel on MLX Swift (PLAN.md §7). Loads a model folder (safetensors + tokenizer)
/// and streams text. Chat prompts go through the model's chat template; raw prompts are tokenized
/// as-is, special tokens included, for fill-in-the-middle.
final class MLXTextModel: TextModel, @unchecked Sendable {
    let container: ModelContainer

    private init(container: ModelContainer) { self.container = container }

    static func load(from folder: URL) async throws -> MLXTextModel {
        MLXTextModel(container: try await loadModelContainer(from: folder, using: TransformersTokenizerLoader()))
    }

    func stream(_ prompt: ModelPrompt, maxTokens: Int, temperature: Float) async throws -> AsyncThrowingStream<String, Error> {
        let input: LMInput
        switch prompt {
        case .chat(let system, let user):
            var messages: [Chat.Message] = []
            if let system { messages.append(.system(system)) }
            messages.append(.user(user))
            input = try await container.prepare(input: UserInput(chat: messages))
        case .raw(let text):
            input = LMInput(tokens: MLXArray(await container.encode(text)))
        }
        let generation = try await container.generate(
            input: input, parameters: GenerateParameters(maxTokens: maxTokens, temperature: temperature))
        return AsyncThrowingStream { continuation in
            let task = Task {
                for await event in generation {
                    if Task.isCancelled { break }
                    if case .chunk(let text) = event { continuation.yield(text) }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// Loads tokenizers with swift-transformers (the mlx-swift-lm 3 loader is pluggable).
struct TransformersTokenizerLoader: MLXLMCommon.TokenizerLoader {
    func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        TokenizerBridge(try await Tokenizers.AutoTokenizer.from(modelFolder: directory))
    }
}

private struct TokenizerBridge: MLXLMCommon.Tokenizer {
    let upstream: any Tokenizers.Tokenizer
    init(_ upstream: any Tokenizers.Tokenizer) { self.upstream = upstream }
    func encode(text: String, addSpecialTokens: Bool) -> [Int] { upstream.encode(text: text, addSpecialTokens: addSpecialTokens) }
    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String { upstream.decode(tokens: tokenIds, skipSpecialTokens: skipSpecialTokens) }
    func convertTokenToId(_ token: String) -> Int? { upstream.convertTokenToId(token) }
    func convertIdToToken(_ id: Int) -> String? { upstream.convertIdToToken(id) }
    var bosToken: String? { upstream.bosToken }
    var eosToken: String? { upstream.eosToken }
    var unknownToken: String? { upstream.unknownToken }
    func applyChatTemplate(messages: [[String: any Sendable]], tools: [[String: any Sendable]]?,
                           additionalContext: [String: any Sendable]?) throws -> [Int] {
        do {
            return try upstream.applyChatTemplate(messages: messages, tools: tools, additionalContext: additionalContext)
        } catch Tokenizers.TokenizerError.missingChatTemplate {
            throw MLXLMCommon.TokenizerError.missingChatTemplate
        }
    }
}
