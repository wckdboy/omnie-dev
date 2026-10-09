// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

import CryptoKit
import Foundation
import Testing
@testable import ModelKit

/// Serves files from memory and counts requests.
final class MemoryFetcher: ModelFetcher, @unchecked Sendable {
    var files: [String: Data]
    var requests: [String] = []
    let lock = NSLock()
    init(_ files: [String: Data]) { self.files = files }

    func fetch(_ url: URL, to destination: URL, progress: @escaping @Sendable (Int64) -> Void) async throws {
        let name = url.lastPathComponent
        let data = lock.withLock { requests.append(name); return files[name] } ?? Data()
        try data.write(to: destination)
        progress(Int64(data.count))
    }
}

func sha(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

struct ModelStoreTests {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("models-\(UUID().uuidString)")
    let a = Data("config".utf8), b = Data(repeating: 7, count: 10_000)

    var pack: ModelPack {
        ModelPack(id: "test", displayName: "Test", role: .tiny, repo: "org/test", revision: "abc", license: "MIT",
                  files: [ModelFile("config.json", Int64(a.count), sha(a)), ModelFile("model.safetensors", Int64(b.count), sha(b))])
    }

    @Test func installsVerifiesAndReportsProgress() async throws {
        let fetcher = MemoryFetcher(["config.json": a, "model.safetensors": b])
        let store = ModelStore(root: root, fetcher: fetcher)
        #expect(await store.state(of: pack) == .notInstalled)
        final class Last: @unchecked Sendable { var value: (Int64, Int64) = (0, 0) }
        let last = Last()
        try await store.install(pack) { done, total in last.value = (done, total) }
        #expect(await store.state(of: pack) == .installed)
        #expect(last.value == (pack.totalBytes, pack.totalBytes))
        let backup = try store.root.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup
        #expect(backup == true)
        // Installing again downloads nothing.
        try await store.install(pack)
        #expect(fetcher.requests == ["config.json", "model.safetensors"])
    }

    @Test func rejectsATamperedFileAndResumesTheRest() async throws {
        let fetcher = MemoryFetcher(["config.json": a, "model.safetensors": Data(repeating: 8, count: 10_000)])
        let store = ModelStore(root: root, fetcher: fetcher)
        await #expect(throws: ModelStoreError.hashMismatch(file: "model.safetensors")) { try await store.install(pack) }
        #expect(await store.state(of: pack) == .partial(bytes: Int64(a.count)))
        #expect(!FileManager.default.fileExists(atPath: store.folder(for: pack).appendingPathComponent("model.safetensors").path))

        fetcher.files["model.safetensors"] = b
        try await store.install(pack)
        #expect(await store.state(of: pack) == .installed)
        #expect(fetcher.requests == ["config.json", "model.safetensors", "model.safetensors"])
    }

    @Test func truncatedDownloadIsASizeMismatch() async throws {
        let store = ModelStore(root: root, fetcher: MemoryFetcher(["config.json": a, "model.safetensors": b.prefix(10)]))
        await #expect(throws: ModelStoreError.sizeMismatch(file: "model.safetensors", expected: 10_000, got: 10)) {
            try await store.install(pack)
        }
    }

    @Test func checksFreeSpaceFirstAndRemoves() async throws {
        let fetcher = MemoryFetcher(["config.json": a, "model.safetensors": b])
        let store = ModelStore(root: root, fetcher: fetcher)
        await #expect(throws: ModelStoreError.notEnoughSpace(needed: pack.totalBytes, available: 100)) {
            try await store.install(pack, freeSpace: 100)
        }
        #expect(fetcher.requests.isEmpty)
        try await store.install(pack)
        try await store.remove(pack)
        #expect(await store.state(of: pack) == .notInstalled)
    }
}

struct CatalogTests {
    @Test func everyPackIsFullyPinned() {
        for pack in ModelPack.catalog {
            #expect(pack.revision.count == 40)
            #expect(Set(pack.files.map(\.name)).count == pack.files.count)
            #expect(pack.files.contains { $0.name == "model.safetensors" })
            #expect(pack.files.contains { $0.name == "tokenizer.json" })
            for file in pack.files {
                #expect(file.sha256.count == 64 && file.sha256.allSatisfy(\.isHexDigit), "\(file.name)")
                #expect(file.size > 0)
            }
            #expect(pack.url(for: pack.files[0]).absoluteString.hasPrefix("https://huggingface.co/\(pack.repo)/resolve/\(pack.revision)/"))
        }
        #expect(MemoryBudget.required(for: .tiny) < 1 << 30)
        #expect(MemoryBudget.canLoad(.standard, available: 12_000 << 20))
        #expect(!MemoryBudget.canLoad(.standard, available: 4_000 << 20))
    }
}

struct PromptTests {
    struct ScriptedModel: TextModel {
        let chunks: [String]
        func stream(_ prompt: ModelPrompt, maxTokens: Int, temperature: Float) async throws -> AsyncThrowingStream<String, Error> {
            AsyncThrowingStream { c in
                for chunk in chunks { c.yield(chunk) }
                c.finish()
            }
        }
    }

    @Test func completeStopsAtTheFirstStopSequence() async throws {
        let model = ScriptedModel(chunks: ["return a", " + b;<|endo", "ftext|>junk", "more"])
        #expect(try await model.complete(.raw("x"), maxTokens: 10, stop: FIM.qwenStops) == "return a + b;")
        #expect(try await ScriptedModel(chunks: ["ab", "c"]).complete(.raw("x"), maxTokens: 10) == "abc")
    }

    @Test func fimKeepsTheNearbyContextAtLineBoundaries() {
        let prefix = (1...1000).map { "line \($0)" }.joined(separator: "\n") + "\nlet x = "
        let prompt = FIM.qwen(prefix: prefix, suffix: "\nprint(x)\n", maxPrefix: 100)
        #expect(prompt.hasPrefix("<|fim_prefix|>line "))
        #expect(prompt.contains("let x = <|fim_suffix|>\nprint(x)\n<|fim_middle|>"))
        let kept = prompt.components(separatedBy: "<|fim_suffix|>")[0].dropFirst("<|fim_prefix|>".count)
        #expect(kept.count <= 100)
    }

    @Test func fimTrimStopsWhereTheSuffixResumes() {
        // What the 0.5B model produced on the iPad for `return |` in a Swift fibonacci.
        let raw = "fibonacci(n - 1) + fibonacci(n - 2)\n}\n\nprint(fibonacci(10)) //"
        #expect(FIM.trim(raw, suffix: "\n}\n") == "fibonacci(n - 1) + fibonacci(n - 2)")
        #expect(FIM.trim("a + b  \n", suffix: "") == "a + b")
        #expect(FIM.trim("let y = 2\n    return y\n", suffix: "\n    return y\n}") == "let y = 2")
        #expect(FIM.trim("x", suffix: "\n}") == "x")
    }

    @Test func commitPromptListsFilesAndStaysInBudget() {
        let added = (1...500).map { (path: "src/app.ts", text: "const value\($0) = compute(\($0));") }
        let prompt = CommitDraft.prompt(changes: [.init(path: "src/app.ts", kind: "modified"), .init(path: "README.md", kind: "added")],
                                        added: added, budget: 600)
        #expect(prompt.contains("- modified src/app.ts"))
        #expect(prompt.contains("+ const value1 = compute(1);"))
        #expect(!prompt.contains("value400"))
        #expect(prompt.count < 900)
    }

    @Test func cleanUpModelOutput() {
        #expect(CommitDraft.clean("Commit message: \"add retry to sync.\"\n\nMore text") == "Add retry to sync")
        #expect(CommitDraft.clean("```\nFix crash when the folder is empty\n```") == "Fix crash when the folder is empty")
        #expect(CommitDraft.clean("feat: add plane mode") == "feat: add plane mode")
        #expect(CommitDraft.clean("  \n ") == nil)
        let long = CommitDraft.clean(String(repeating: "word ", count: 30))!
        #expect(long.count <= 72 && !long.hasSuffix(" "))
    }
}
