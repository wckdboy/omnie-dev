// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing
@testable import WorkspaceKit

struct WorkspaceSpecTests {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("spec-\(UUID().uuidString)")

    func write(_ path: String, _ text: String) throws {
        let url = root.appending(path: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    @Test func readsDevcontainerWithComments() throws {
        try write(".devcontainer/devcontainer.json", """
            {
              // the remote image
              "image": "node:22", /* pinned later */
              "forwardPorts": [5173, "localhost:8080"],
              "run": {
                "tasks": { "test": "vitest run", "dev": "vite", "lint": "eslint .", },
                "network": { "allow": ["API.example.com"] },
                "deploy": "podman build -t app ."
              },
            }
            """)
        try write("package.json", #"{ "scripts": { "build": "tsc && vite build", "test": "jest" } }"#)
        let spec = try #require(WorkspaceSpec.load(root: root))
        #expect(spec.source == ".devcontainer/devcontainer.json")
        #expect(spec.image == "node:22" && spec.ports == [5173, 8080])
        #expect(spec.tasks.map(\.name) == ["dev", "test", "lint", "build"])
        #expect(spec.command(for: "test") == "vitest run")   // the spec wins over package.json
        #expect(spec.command(for: "build") == "tsc && vite build")
        #expect(spec.allowedDomains == ["api.example.com"])
        #expect(spec.deploy == "podman build -t app .")
    }

    @Test func fallsBackToPackageScripts() throws {
        try write("package.json", #"{ "scripts": { "zeta": "node z.js", "test": "vitest run", "dev": "vite" } }"#)
        let spec = try #require(WorkspaceSpec.load(root: root))
        #expect(spec.source == "package.json" && spec.tasks.map(\.name) == ["dev", "test", "zeta"])
        #expect(WorkspaceSpec.load(root: root.appending(path: "nowhere")) == nil)
    }

    @Test func saysWhereATaskRuns() {
        #expect(WorkspaceSpec.backend(for: "vitest run") == .device)
        #expect(WorkspaceSpec.backend(for: "NODE_ENV=test npx vitest") == .device)
        #expect(WorkspaceSpec.backend(for: "python -m pytest") == .device)
        #expect(WorkspaceSpec.backend(for: "./tools/lint.wasm src") == .device)
        #expect(WorkspaceSpec.backend(for: "cargo build --release") == .remote(reason: "cargo needs a real toolchain or container"))
        #expect(WorkspaceSpec.backend(for: "tsc && vite build") == .remote(reason: "vite build bundles with Rollup and esbuild's native binary"))
        #expect(WorkspaceSpec.backend(for: "tsc && vitest run") == .device)
    }
}
