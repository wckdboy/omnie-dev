// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// One file of a model, pinned by size and SHA-256 (PLAN.md §7: "model files are data … SHA-256 pinned").
public struct ModelFile: Codable, Sendable, Hashable {
    public let name: String
    public let size: Int64
    public let sha256: String

    public init(_ name: String, _ size: Int64, _ sha256: String) {
        self.name = name
        self.size = size
        self.sha256 = sha256
    }
}

/// A downloadable model: an exact repository revision and the files the app needs from it.
public struct ModelPack: Codable, Sendable, Hashable, Identifiable {
    public enum Role: String, Codable, Sendable {
        /// Small and fast: completion and commit-message drafts.
        case tiny
        /// The offline agent.
        case standard
    }

    public let id: String
    public let displayName: String
    public let role: Role
    /// Hugging Face repository, e.g. "mlx-community/Qwen2.5-Coder-0.5B-Instruct-4bit".
    public let repo: String
    /// The commit the files are pinned to.
    public let revision: String
    public let license: String
    public let files: [ModelFile]

    public var totalBytes: Int64 { files.reduce(0) { $0 + $1.size } }

    public func url(for file: ModelFile) -> URL {
        URL(string: "https://huggingface.co/\(repo)/resolve/\(revision)/\(file.name)")!
    }

    /// The host downloads come from, for the network policy.
    public static let host = "huggingface.co"
}

extension ModelPack {
    /// Qwen2.5-Coder tokenizer files, identical across sizes.
    private static func qwenTokenizer(config: ModelFile, tokenizerConfig: ModelFile) -> [ModelFile] {
        [config,
         ModelFile("tokenizer.json", 7_031_673, "a8506e7111b80c6d8635951a02eab0f4e1a8e4e5772da83846579e97b16f61bf"),
         tokenizerConfig,
         ModelFile("added_tokens.json", 605, "58b54bbe36fc752f79a24a271ef66a0a0830054b4dfad94bde757d851968060b"),
         ModelFile("special_tokens_map.json", 613, "76862e765266b85aa9459767e33cbaf13970f327a0e88d1c65846c2ddd3a1ecd"),
         ModelFile("vocab.json", 2_776_833, "ca10d7e9fb3ed18575dd1e277a2579c16d108e32f27439684afa0e10b1440910"),
         ModelFile("merges.txt", 1_671_853, "8831e4f1a044471340f7c0a83d7bd71306a5b867e95fd870f74d0c5308a904d5")]
    }

    public static let tiny = ModelPack(
        id: "qwen2.5-coder-0.5b-instruct-4bit", displayName: "Qwen2.5-Coder 0.5B (4-bit)", role: .tiny,
        repo: "mlx-community/Qwen2.5-Coder-0.5B-Instruct-4bit", revision: "6b16732e5af5cd9bd600186ad59fa618867ef7a4",
        license: "Apache-2.0",
        files: qwenTokenizer(
            config: ModelFile("config.json", 863, "3542f21e28bfe8422fe98249af39a5b7770fa41ca7d60cda1b72906c2c53b998"),
            tokenizerConfig: ModelFile("tokenizer_config.json", 7_306, "7e88129d9769a0b14b1587a7d5e829fe93ac0e1511636471fdfc0811951418e6"))
            + [ModelFile("model.safetensors.index.json", 44_209, "54001cb4c11197119c206dde28e7be08e5872aab6c6d271aed339ec77e84f870"),
               ModelFile("model.safetensors", 278_064_920, "162e6341bc937d1880cc7f76fbb80831f4fb30684345c59a7b055a5c716d25bd")])

    public static let standard = ModelPack(
        id: "qwen2.5-coder-7b-instruct-4bit", displayName: "Qwen2.5-Coder 7B (4-bit)", role: .standard,
        repo: "mlx-community/Qwen2.5-Coder-7B-Instruct-4bit", revision: "019cc73c45c770444708a6dd8690c66243cc5c80",
        license: "Apache-2.0",
        files: qwenTokenizer(
            config: ModelFile("config.json", 787, "08762352ba9fded858f24bdd7b8d2fe61aabe7bce1dfdb663db242d574c3e678"),
            tokenizerConfig: ModelFile("tokenizer_config.json", 7_308, "f7c61e32b7a17d19bf8e7037dcb74079a833e53ea9801f24008cac68458f03b7"))
            + [ModelFile("model.safetensors.index.json", 51_711, "23cd562592dd96686d2e799eb02e4b578a4038b6045eaefe860d270cc060e24f"),
               ModelFile("model.safetensors", 4_284_346_255, "56a3d94706833f753e6c6b47ea57af8ef638cd8cc1d74eca1142ba640b26060e")])

    public static let catalog: [ModelPack] = [.tiny, .standard]
}
