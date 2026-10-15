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
        do {
            let warmUp = LMInput(tokens: MLXArray(await container.encode("let x = 1\n")))
            for await _ in try await container.generate(input: warmUp, parameters: GenerateParameters(maxTokens: 8, temperature: 0)) {}
        } catch {
            log("warm-up failed: \(error)")
        }
        for promptTokens in [1_000, 4_000, 8_000] {
            Memory.peakMemory = 0
            // A realistic code prompt, repeated to the target length.
            let unit = "export function total(order: Order): number {\n  return order.items.reduce((sum, item) => sum + item.qty * item.price, 0);\n}\n\n"
            var tokens: [Int] = []
            while tokens.count < promptTokens { tokens += await container.encode(unit) }
            tokens = Array(tokens.prefix(promptTokens))
            let parameters = GenerateParameters(maxTokens: 128, temperature: 0)
            var info: GenerateCompletionInfo?
            if let stream = try? await container.generate(input: LMInput(tokens: MLXArray(tokens)), parameters: parameters) {
                for await event in stream {
                    if case .info(let value) = event { info = value; break }
                }
            }
            guard let info else {
                record("prompt \(promptTokens)", [:], note: "generation failed")
                continue
            }
            record("prompt \(promptTokens) tokens",
                   ["ttftSeconds": info.promptTime, "prefillTokPerS": info.promptTokensPerSecond,
                    "decodeTokPerS": info.tokensPerSecond, "generatedTokens": Double(info.generationTokenCount),
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
