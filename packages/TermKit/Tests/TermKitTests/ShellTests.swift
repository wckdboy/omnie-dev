// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing
@testable import TermKit

@MainActor
struct ShellTests {
    let root: URL
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("shell-\(UUID().uuidString)")
        for (path, text) in ["src/a.ts": "export const a = 1;\nexport const b = 2;\n", "README.md": "# Demo\nHello there\n", ".env": "X=1\n"] {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    @Test func splitsLikeAShell() throws {
        #expect(try Shell.split(#"grep "export const" src"#) == ["grep", "export const", "src"])
        #expect(try Shell.split(#"echo a\ b 'c d' "e\"f""#) == ["echo", "a b", "c d", "e\"f"])
        #expect(throws: (any Error).self) { try Shell.split("echo \"oops") }
    }

    @Test func navigatesAndReads() async {
        let shell = Shell(root: root)
        #expect(await shell.execute("ls") == "README.md  src/")
        #expect(await shell.execute("ls -a") == ".env  README.md  src/")
        #expect(await shell.execute("cd src") == "")
        #expect(shell.prompt == "src $")
        #expect(await shell.execute("pwd") == "/src")
        #expect(await shell.execute("cat a.ts") == "export const a = 1;\nexport const b = 2;")
        #expect(await shell.execute("head -n 1 a.ts") == "export const a = 1;")
        #expect(await shell.execute("grep -i hello /") == "README.md:2: Hello there")
        #expect(await shell.execute("cd ..") == "")
        #expect(await shell.execute("pwd") == "/")
        #expect(await shell.execute("clear") == nil)
    }

    @Test func staysInTheProject() async {
        let shell = Shell(root: root)
        #expect(await shell.execute("cd ../..")?.contains("outside the project") == true)
        #expect(await shell.execute("cat ../../../etc/hosts")?.contains("outside the project") == true)
        #expect(await shell.execute("rm -rf /")?.contains("not a built-in") == true)
    }

    @Test func runsThroughHooks() async {
        var opened: String?
        let shell = Shell(root: root, hooks: .init(run: { "ran \($0)" }, test: { "tested \($0 ?? "all")" },
                                                  git: { "git \($0.joined(separator: " "))" }, open: { opened = $0 }))
        #expect(await shell.execute("node src/a.ts") == "ran src/a.ts")
        #expect(await shell.execute("npm test") == "tested all")
        #expect(await shell.execute("pytest") == "tested all")
        #expect(await shell.execute("git status") == "git status")
        #expect(await shell.execute("git push")?.contains("Git menu") == true)
        #expect(await shell.execute("npm install three")?.contains("offline package cache") == true)
        _ = await shell.execute("open README.md")
        #expect(opened == "README.md")
    }
}
