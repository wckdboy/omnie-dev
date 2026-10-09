// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import Tokenizers
import os

/// P0 spike 2 (PLAN §25): a 4-bit 7B coder through MLX Swift on the iPad. Measures load time,
/// time to first token and prefill speed at 1k and 4k prompt tokens, decode speed, and memory
/// against the jetsam limit. The model folder goes in Documents/models/<name> (copied over USB).
@MainActor
final class ModelSpike {
    struct Result: Codable { var test: String; var metrics: [String: Double]; var note: String? }
    struct Report: Codable { var device: String; var system: String; var build: String; var model: String; var date: Date; var results: [Result] }

    var log: (String) -> Void = { print("[model]", $0) }
    private var results: [Result] = []

    static var modelsFolder: URL { URL.documentsDirectory.appendingPathComponent("models", isDirectory: true) }

    func run(modelName: String = "Qwen2.5-Coder-7B-Instruct-4bit") async {
        let folder = Self.modelsFolder.appendingPathComponent(modelName, isDirectory: true)
        guard FileManager.default.fileExists(atPath: folder.appendingPathComponent("config.json").path) else {
            log("No model at \(folder.path). Copy the model folder into Documents/models first.")
            return
        }
        let physicalGB = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824
        log("model: \(modelName); device RAM \(String(format: "%.1f", physicalGB)) GB; available to app before load: \(Int(Self.availableMB())) MB")
        record("device", ["physicalMemoryGB": physicalGB, "availableBeforeLoadMB": Self.availableMB()])

        let footprintBefore = Self.footprintMB()
        let t0 = CFAbsoluteTimeGetCurrent()
        let container: ModelContainer
        do {
            container = try await loadModelContainer(from: folder, using: TransformersTokenizerLoader())
        } catch {
            log("load failed: \(error)")
            return
        }
        let loadSeconds = CFAbsoluteTimeGetCurrent() - t0
        record("load", ["seconds": loadSeconds, "footprintMB": Self.footprintMB() - footprintBefore,
                        "availableAfterMB": Self.availableMB(), "mlxActiveMB": Double(Memory.activeMemory) / 1_048_576])

        // Warm-up: the first generation compiles GPU kernels; don't count it.
        _ = await container.perform { model, tokenizer in
            try? generate(promptTokens: tokenizer.encode(text: "let x = 1\n", addSpecialTokens: false),
                          parameters: GenerateParameters(maxTokens: 8, temperature: 0), model: model, tokenizer: tokenizer) { _ in .more }
                .tokensPerSecond
        }
        for promptTokens in [1_000, 4_000, 8_000] {
            Memory.peakMemory = 0
            let measured = await container.perform { model, tokenizer in
                // A realistic code prompt, repeated to the target length.
                let unit = "export function total(order: Order): number {\n  return order.items.reduce((sum, item) => sum + item.qty * item.price, 0);\n}\n\n"
                var tokens: [Int] = []
                while tokens.count < promptTokens { tokens += tokenizer.encode(text: unit, addSpecialTokens: false) }
                tokens = Array(tokens.prefix(promptTokens))
                let parameters = GenerateParameters(maxTokens: 128, temperature: 0)
                let result = try? generate(promptTokens: tokens, parameters: parameters, model: model, tokenizer: tokenizer) { _ in .more }
                return result.map { ($0.promptTime, $0.promptTokensPerSecond, $0.tokensPerSecond, Double($0.generationTokenCount)) }
            }
            guard let (ttft, prefill, decode, generated) = measured else {
                record("prompt \(promptTokens)", [:], note: "generation failed")
                continue
            }
            record("prompt \(promptTokens) tokens",
                   ["ttftSeconds": ttft, "prefillTokPerS": prefill, "decodeTokPerS": decode, "generatedTokens": generated,
                    "mlxPeakMB": Double(Memory.peakMemory) / 1_048_576, "footprintMB": Self.footprintMB(),
                    "availableMB": Self.availableMB()])
        }
        save(Report(device: "iPad " + EditorSpike.machine(), system: ProcessInfo.processInfo.operatingSystemVersionString,
                    build: EditorSpike.buildKind, model: modelName, date: .now, results: results))
    }

    private func record(_ test: String, _ metrics: [String: Double], note: String? = nil) {
        results.append(Result(test: test, metrics: metrics, note: note))
        let numbers = metrics.sorted { $0.key < $1.key }.map { "\($0.key)=\(String(format: "%.2f", $0.value))" }.joined(separator: " ")
        log("\(test): \(numbers)\(note.map { " — \($0)" } ?? "")")
    }

    private func save(_ report: Report) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let url = URL.documentsDirectory.appendingPathComponent("model-spike-\(EditorSpike.buildKind)-\(Int(Date().timeIntervalSince1970)).json")
        try? encoder.encode(report).write(to: url)
        log("saved \(url.lastPathComponent)")
    }

    static func footprintMB() -> Double { EditorSpike.footprintMB() }

    /// How much more the app may allocate before jetsam (os_proc_available_memory).
    static func availableMB() -> Double { Double(os_proc_available_memory()) / 1_048_576 }
}

/// Adapts swift-transformers' tokenizer to mlx-swift-lm (local weights, no downloader).
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
