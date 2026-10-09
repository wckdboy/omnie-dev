// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

#if DEBUG
import Foundation
import RunKit

/// `-OmnieWasiConformance`: runs the bundled wasi-testsuite (the P0 spike's copy) through RunKit's
/// own WASI layer on the device and prints the count, as the Mac test does.
@MainActor
enum WasiConformance {
    static func run() async {
        guard let suite = Bundle.main.url(forResource: "WASISpike", withExtension: nil),
              let data = try? Data(contentsOf: suite.appending(path: "manifest.json")),
              let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tests = manifest["tests"] as? [[String: Any]] else { print("[wasi] no suite bundled"); return }
        var passed = 0
        let start = Date()
        for test in tests {
            let name = "\(test["lang"] ?? "")/\(test["name"] ?? "")"
            let config = test["config"] as? [String: Any] ?? [:]
            let project = FileManager.default.temporaryDirectory.appendingPathComponent("wasi-suite-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: project) }
            if let rootBase = test["rootBase"] as? String {
                try? FileManager.default.copyItem(at: suite.appending(path: rootBase), to: project)
            }
            try? FileManager.default.createDirectory(at: project.appending(path: ".build"), withIntermediateDirectories: true)
            try? FileManager.default.copyItem(at: suite.appending(path: test["wasm"] as? String ?? ""), to: project.appending(path: ".build/test.wasm"))
            guard let runner = try? JSRunner(root: project) else { continue }
            let timeout = name.hasPrefix("omnie/") ? 2.0 : 10
            let result = await runner.runWasm(".build/test.wasm", args: config["args"] as? [String] ?? [], env: config["env"] as? [String: String] ?? [:],
                                              timeout: timeout, preopens: test["rootBase"] is String ? .root : .none)
            let stdout = result.output.filter { $0.stream == .out }.map(\.text).joined(separator: "\n")
            let expected = (config["stdout"] as? String)?.trimmingCharacters(in: .newlines)
            let ok = name == "omnie/timeout-infinite-loop" ? result.ending == .timedOut(seconds: timeout)
                : Int(result.exitCode ?? -1) == (config["exit_code"] as? Int ?? 0) && (expected == nil || stdout == expected)
            if ok { passed += 1 } else { print("[wasi] ✗ \(name): \(result.report.prefix(160))") }
        }
        print("[wasi] RunKit WASI: \(passed) of \(tests.count) pass in \(String(format: "%.1f", Date().timeIntervalSince(start))) s")
    }
}
#endif
