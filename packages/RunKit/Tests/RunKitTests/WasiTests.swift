// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing
@testable import RunKit

extension WebKitSuites {
/// RunKit's WASI layer, with a probe program built from Tests/wasi-probe (Rust, wasm32-wasip1).
@MainActor
struct WasiTests {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("wasi-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appending(path: "data/sub"), withIntermediateDirectories: true)
        let probe = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appending(path: "wasi-probe/wasi-probe.wasm")
        try FileManager.default.copyItem(at: probe, to: root.appending(path: "bin/probe.wasm").creatingParent())
        try "hello\n".write(to: root.appending(path: "data/a.txt"), atomically: true, encoding: .utf8)
        try "x".write(to: root.appending(path: "data/sub/b.txt"), atomically: true, encoding: .utf8)
    }

    func run(_ args: String..., stdin: String = "", cwd: String = "", timeout: Double = 20, memory: Int = 1024) async throws -> RunResult {
        await (try JSRunner(root: root)).runWasm("bin/probe.wasm", args: args, stdin: stdin, env: ["GREETING": "hi"], cwd: cwd, timeout: timeout, memoryLimitMB: memory)
    }

    func text(_ r: RunResult) -> [String] { r.output.map(\.text) }

    @Test func argsEnvStdinAndExitCodes() async throws {
        #expect(text(try await run("echo", "a", "b c")) == ["a b c"])
        #expect(text(try await run("env", "GREETING")) == ["hi"])
        #expect(text(try await run("stdin", stdin: "shout\nloud")) == ["SHOUT", "LOUD"])
        #expect(text(try await run("time")) == ["ok"])
        let failed = try await run("exit", "3")
        #expect(failed.exitCode == 3 && !failed.passed && failed.report.contains("Exited with 3."))
        #expect(try await run("echo", "ok").exitCode == 0)
    }

    @Test func readsTheProject() async throws {
        #expect(text(try await run("ls", "data")) == ["a.txt sub/"])
        #expect(text(try await run("ls", "/data/sub")) == ["b.txt"])
        #expect(text(try await run("cat", "data/a.txt")) == ["hello"])
        let inData = try await run("cat", "a.txt", cwd: "data")
        #expect(text(inData) == ["hello"], "\(inData.report)")
        #expect(text(try await run("size", "data/a.txt")) == ["6"])
        let missing = try await run("cat", "data/nope.txt")
        #expect(missing.exitCode == 1 && missing.output.first?.stream == .err)
    }

    @Test func writesAreAppliedAtExit() async throws {
        // No such directory yet: the write fails (a Rust panic), and nothing is written.
        let w = try await run("write", "out/new.txt", "made")
        #expect(w.exitCode != 0 && w.changedFiles.isEmpty)
        let made = try await run("mkdir", "out")
        #expect(made.exitCode == 0, "\(made.report)")
        #expect(FileManager.default.fileExists(atPath: root.appending(path: "out").path))
        let wrote = try await run("write", "out/new.txt", "made")
        #expect(wrote.changedFiles == ["out/new.txt"])
        #expect(try String(contentsOf: root.appending(path: "out/new.txt"), encoding: .utf8) == "made")
        _ = try await run("append", "data/a.txt", "more")
        #expect(try String(contentsOf: root.appending(path: "data/a.txt"), encoding: .utf8) == "hello\nmore")
        _ = try await run("mv", "data/sub/b.txt", "data/c.txt")
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: "data/sub/b.txt").path))
        #expect(try String(contentsOf: root.appending(path: "data/c.txt"), encoding: .utf8) == "x")
        _ = try await run("rm", "data/c.txt")
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: "data/c.txt").path))
    }

    @Test func staysInsideTheProject() async throws {
        let escape = try await run("cat", "../../etc/hosts")
        #expect(escape.exitCode != 0)
        let absolute = try await run("write", "/../outside.txt", "no")
        #expect(absolute.exitCode != 0)
        #expect(!FileManager.default.fileExists(atPath: root.deletingLastPathComponent().appending(path: "outside.txt").path))
        // Swift refuses the same thing if a page ever asked.
        #expect(try JSRunner.apply(["writes": ["../x.txt": "eA==", ".git/config": "eA=="]], to: root).isEmpty)
    }

    @Test func limits() async throws {
        let spin = try await run("spin", timeout: 2)
        #expect(spin.ending == .timedOut(seconds: 2))
        let big = try await run("alloc", "300", memory: 128)
        #expect(big.exitCode == 137 || big.output.contains { $0.text.contains("memory") }, "\(big.report)")
        #expect(text(try await run("alloc", "16")) == ["16"])
    }
}
}

extension WebKitSuites {
/// The conformance gate (PLAN.md §26.1): WebAssembly/wasi-testsuite's prebuilt wasm32-wasip1 tests,
/// vendored by scripts/vendor-wasi-spike.py. Skipped when they aren't there.
@MainActor
struct WasiConformanceTests {
    nonisolated static let suite = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../../../../apps/ipad/Resources/WASISpike").standardized

    @Test(.enabled(if: FileManager.default.fileExists(atPath: suite.appending(path: "manifest.json").path)))
    func wasiTestsuite() async throws {
        let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: Self.suite.appending(path: "manifest.json"))) as! [String: Any]
        var passed: [String] = [], failed: [String] = []
        for test in manifest["tests"] as! [[String: Any]] {
            let name = "\(test["lang"]!)/\(test["name"]!)"
            let config = test["config"] as? [String: Any] ?? [:]
            let project = FileManager.default.temporaryDirectory.appendingPathComponent("wasi-suite-\(UUID().uuidString)")
            if let rootBase = test["rootBase"] as? String {
                try FileManager.default.copyItem(at: Self.suite.appending(path: rootBase), to: project)
            } else {
                try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
            }
            // Out of sight of the test's directory listings.
            try FileManager.default.createDirectory(at: project.appending(path: ".build"), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: Self.suite.appending(path: test["wasm"] as! String), to: project.appending(path: ".build/test.wasm"))
            let result = await (try JSRunner(root: project)).runWasm(".build/test.wasm", args: config["args"] as? [String] ?? [],
                                                                    env: config["env"] as? [String: String] ?? [:], timeout: name.hasPrefix("omnie/") ? 2 : 10,
                                                                    preopens: test["rootBase"] is String ? .root : .none)
            let stdout = result.output.filter { $0.stream == .out }.map(\.text).joined(separator: "\n")
            let expectedOut = (config["stdout"] as? String).map { $0.trimmingCharacters(in: .newlines) }
            // The suite's own timeout test passes by being stopped.
            let ok = name == "omnie/timeout-infinite-loop" ? result.ending == .timedOut(seconds: 2)
                : Int(result.exitCode ?? -1) == (config["exit_code"] as? Int ?? 0) && (expectedOut == nil || stdout == expectedOut)
            if ok { passed.append(name) } else { failed.append("\(name): exit \(result.exitCode.map(String.init) ?? "none") \(result.output.prefix(2).map(\.text))") }
        }
        print("wasi-testsuite: \(passed.count) of \(passed.count + failed.count) pass")
        for f in failed { print("  ✗ \(f)") }
        #expect(failed.isEmpty)
    }
}
}

private extension URL {
    func creatingParent() throws -> URL {
        try FileManager.default.createDirectory(at: deletingLastPathComponent(), withIntermediateDirectories: true)
        return self
    }
}

extension WebKitSuites {
/// The bundled tools (built by scripts/vendor-runkit.sh; skipped when they aren't there).
@MainActor
struct WasiToolTests {
    @Test(.enabled(if: JSRunner.bundledTools().contains("jq")))
    func jq() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("wasi-jq-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try #"{"users": [{"name": "Ada", "age": 36}, {"name": "Alan", "age": 41}]}"#
            .write(to: root.appending(path: "data.json"), atomically: true, encoding: .utf8)
        let runner = try JSRunner(root: root)
        let names = await runner.runWasm("jq", args: ["-r", ".users[] | select(.age > 40) | .name", "data.json"])
        #expect(names.output.map(\.text) == ["Alan"] && names.exitCode == 0, "\(names.report)")
        let pretty = await runner.runWasm("jq", args: ["{n: (.users | length)}"], stdin: try String(contentsOf: root.appending(path: "data.json"), encoding: .utf8))
        #expect(pretty.output.map(\.text) == ["{", "  \"n\": 2", "}"])
        let compact = await runner.runWasm("jq", args: ["-c", "--arg", "who", "Ada", "[.users[] | .name == $who]", "data.json"])
        #expect(compact.output.map(\.text) == ["[true,false]"])
        let bad = await runner.runWasm("jq", args: [".users[", "data.json"])
        #expect(bad.exitCode == 3 && bad.output.first?.text.hasPrefix("jq: error") == true, "\(bad.report)")
    }
}
}
