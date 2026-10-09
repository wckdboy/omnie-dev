// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing
@testable import WorkspaceKit

struct FileOperationsTests {
    let root: URL
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ops-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path) }

    @Test func createRenameDuplicateDelete() throws {
        let src = try FileOperations.createFolder(named: "src", in: root)
        let file = try FileOperations.createFile(named: "app.ts", in: src, contents: "x")
        #expect(throws: FileOperations.Failure.exists("app.ts")) { try FileOperations.createFile(named: "app.ts", in: src) }
        let renamed = try FileOperations.rename(file, to: "main.ts")
        #expect(exists("src/main.ts") && !exists("src/app.ts"))
        let copy = try FileOperations.duplicate(renamed)
        #expect(copy.lastPathComponent == "main copy.ts")
        #expect(try FileOperations.duplicate(renamed).lastPathComponent == "main copy 2.ts")
        // A case-only rename works on a case-insensitive volume.
        let cased = try FileOperations.rename(renamed, to: "Main.ts")
        #expect(try FileManager.default.contentsOfDirectory(atPath: src.path).contains("Main.ts"))
        try FileOperations.delete(cased)
        #expect(!exists("src/Main.ts"))
        try FileOperations.delete(src)
        #expect(!exists("src"))
    }

    @Test func rejectsBadNames() {
        for name in ["", "  ", "a/b", "..", "."] {
            #expect(throws: FileOperations.Failure.self, "\(name)") { try FileOperations.validate(name) }
        }
    }
}
