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
        var input: LMInput
        var tools: [[String: any Sendable]]?
        switch prompt {
        case .chat(let system, let user):
            var messages: [Chat.Message] = []
            if let system { messages.append(.system(system)) }
            messages.append(.user(user))
            input = try await container.prepare(input: UserInput(chat: messages))
        case .conversation(let turns, let toolsJSON, let prefix):
            // Given to the generator only, so it recognizes the calls; the agent's system prompt
            // already describes the tools, so the chat template doesn't render them again.
            if let data = toolsJSON?.data(using: .utf8),
               let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                tools = array.map { Self.sendable($0) }
            }
            let messages: [Chat.Message] = turns.map { turn in
                switch turn.role {
                case .system: .system(turn.content)
                case .user: .user(turn.content)
                case .assistant: .assistant(turn.content)
                case .tool: .tool(turn.content)
                }
            }
            input = try await container.prepare(input: UserInput(chat: messages))
            if let prefix, !prefix.isEmpty {
                // Append the pre-started reply to the rendered prompt. MLX's tool parser then sees only
                // the continuation, so it streams as text.
                let tokens = input.text.tokens.asArray(Int.self) + (await container.encode(prefix))
                input = LMInput(tokens: MLXArray(tokens))
                tools = nil
            }
        case .raw(let text):
            input = LMInput(tokens: MLXArray(await container.encode(text)))
        }
        #if DEBUG
        let trace = ProcessInfo.processInfo.arguments.contains("-OmnieModelTrace")
        if trace {
            let tokens = input.text.tokens.asArray(Int.self)
            let rendered = await container.decode(tokenIds: tokens)
            print("[trace] prompt \(tokens.count) tokens, ends with:\n\(rendered.suffix(700))\n[trace] ---")
        }
        #else
        let trace = false
        #endif
        let generation = try await container.generate(
            input: input, parameters: GenerateParameters(maxTokens: maxTokens, temperature: temperature), tools: tools)
        return AsyncThrowingStream { continuation in
            let task = Task {
                for await event in generation {
                    if Task.isCancelled { break }
                    if trace { print("[trace] event \(String(describing: event).prefix(300))") }
                    switch event {
                    case .chunk(let text): continuation.yield(text)
                    case .toolCall(let call): continuation.yield(Self.text(for: call))
                    // Tool-call-shaped output MLX couldn't parse: pass it on so the agent can say what went wrong.
                    case .rejectedToolCall(let rejected): continuation.yield(rejected.rawTextPreview)
                    case .info: break
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

extension MLXTextModel {
    /// A parsed call, back in Qwen's text form.
    static func text(for call: MLXLMCommon.ToolCall) -> String {
        // Name first, as Qwen's template writes calls (and as the model was trained to read them).
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let name = (try? encoder.encode(call.function.name)).map { String(decoding: $0, as: UTF8.self) } ?? "\"\""
        let arguments = (try? encoder.encode(call.function.arguments)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        return "<tool_call>\n{\"name\": \(name), \"arguments\": \(arguments)}\n</tool_call>"
    }

    /// JSONSerialization output as the Sendable dictionaries MLX's tool API takes.
    static func sendable(_ value: [String: Any]) -> [String: any Sendable] {
        value.mapValues(convert)
    }

    private static func convert(_ value: Any) -> any Sendable {
        switch value {
        case let dict as [String: Any]: return sendable(dict)
        case let array as [Any]: return array.map(convert)
        case let string as String: return string
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return number.boolValue }
            return number.doubleValue == number.doubleValue.rounded() ? number.intValue as any Sendable : number.doubleValue
        default: return String(describing: value)
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
