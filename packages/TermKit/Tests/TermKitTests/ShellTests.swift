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

    @Test func pipes() async throws {
        let shell = Shell(root: root)
        #expect(try Shell.pipeline("a | b 'c|d' \\| e || f") == ["a ", " b 'c|d' \\| e || f"])
        #expect(await shell.execute("cat src/a.ts | wc -l") == "      2")
        #expect(await shell.execute("wc src/a.ts") == "      2      10      40 src/a.ts")
        #expect(await shell.execute("cat src/a.ts | grep b") == "export const b = 2;")
        #expect(await shell.execute("cat src/a.ts | grep -v b | wc -w") == "      5")
        #expect(await shell.execute("echo b a b c | sort") == "b a b c")
        #expect(await shell.execute("cat src/a.ts README.md | sort -r | head -n 2") == "export const b = 2;\nexport const a = 1;")
        #expect(await shell.execute("cat src/a.ts src/a.ts | sort | uniq -c") == "      2 export const a = 1;\n      2 export const b = 2;")
        #expect(await shell.execute("wc") == "wc: name a file, or pipe text into it")
        // A failing stage stops the pipeline with its message.
        #expect(await shell.execute("cat nope.txt | wc -l") == "nope.txt: no such file")
        #expect(await shell.execute("echo hi | ") == "|: a command is missing")

        var wrote: [String] = []
        shell.hooks.wrote = { wrote.append($0) }
        #expect(await shell.execute("cat src/a.ts | grep a > out.txt") == "")
        #expect(await shell.execute("echo more >> out.txt") == "")
        #expect(await shell.execute("cat out.txt") == "export const a = 1;\nmore")
        #expect(await shell.execute("echo 'a > b' > \"q.txt\"") == "")
        #expect(await shell.execute("cat q.txt") == "a > b")
        #expect(wrote == ["out.txt", "out.txt", "q.txt"])
        #expect(await shell.execute("echo x > ../escape.txt")?.contains("outside the project") == true)
        #expect(await shell.execute("echo x > src") == "src: is a folder")
        #expect(await shell.execute("echo x >") == ">: name a file")
        // A failing command doesn't truncate the file.
        #expect(await shell.execute("cat nope > out.txt") == "nope: no such file")
        #expect(await shell.execute("wc -l out.txt") == "      2 out.txt")
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
                                                  git: { "git \($0.joined(separator: " "))" },
                                                  packages: { "packages \($0.joined(separator: " "))" },
                                                  wasm: { "wasm \($0) \($1.joined(separator: " ")) in /\($2)" + ($3.map { " <<\($0)" } ?? "") }, tools: { ["jq"] },
                                                  open: { opened = $0 }))
        #expect(await shell.execute("node src/a.ts") == "ran src/a.ts")
        #expect(await shell.execute("npm test") == "tested all")
        #expect(await shell.execute("pytest") == "tested all")
        #expect(await shell.execute("git status") == "git status")
        #expect(await shell.execute("git push")?.contains("Git menu") == true)
        #expect(await shell.execute("npm install three zod@^3 --save") == "packages npm install three zod@^3")
        #expect(await shell.execute("pnpm add react") == "packages npm install react")
        #expect(await shell.execute("npm i") == "packages npm install")
        #expect(await shell.execute("npm ls") == "packages npm ls")
        #expect(await shell.execute("pip install numpy 'attrs>=23'") == "packages pip install numpy attrs>=23")
        #expect(await shell.execute("pip install -r requirements.txt") == "packages pip install")
        #expect(await shell.execute("uv pip list") == "packages pip ls")
        #expect(await shell.execute("jq -r '.a b' x.json") == "wasm jq -r .a b x.json in /")
        // `time` keeps the command's quoting.
        #expect(await shell.execute("time jq -n '[range(3)] | add'")?.hasPrefix("wasm jq -n [range(3)] | add in /\nreal ") == true)
        #expect((try? Shell.split(Shell.join(["a b", "it's", "", "|", "plain"]))) == ["a b", "it's", "", "|", "plain"])
        #expect(await shell.execute("rg x")?.contains("not a built-in") == true)
        // A pipe gives a WASI tool its input; quoted bars stay in the argument.
        #expect(await shell.execute("cat README.md | jq '.a | .b'") == "wasm jq .a | .b in / <<# Demo\nHello there")
        _ = await shell.execute("open README.md")
        #expect(opened == "README.md")
    }

    @Test func runsTasks() async {
        let tasks: [String: String] = ["dev": "vite", "test": "vitest run", "check": "tsc && NODE_ENV=test vitest run src/a.test.ts", "ship": "cargo build"]
        let shell = Shell(root: root, hooks: .init(test: { "tested \($0 ?? "all")" }, task: { name in
            guard let line = tasks[name] else { return .unknown }
            return name == "ship" ? .unavailable("cargo needs a real toolchain") : .run(line)
        }, taskNames: { tasks.keys.sorted() }, preview: { "preview shown" }, typecheck: { "No type errors." }))
        #expect(await shell.execute("npm run dev") == "> vite   (on this iPad)\npreview shown")
        #expect(await shell.execute("yarn test") == "> vitest run   (on this iPad)\ntested all")
        #expect(await shell.execute("npm test") == "> vitest run   (on this iPad)\ntested all")
        #expect(await shell.execute("task check") == "> tsc && NODE_ENV=test vitest run src/a.test.ts   (on this iPad)\nNo type errors.\ntested src/a.test.ts")
        #expect(await shell.execute("task ship")?.contains("remote host") == true)
        #expect(await shell.execute("npm run nope") == "No task \"nope\". Tasks: check, dev, ship, test.")
        #expect(await shell.execute("task") == "check  dev  ship  test")
        #expect(await shell.execute("npx vitest") == "tested all")
        #expect(await shell.execute("vite build")?.contains("remote host") == true)
        #expect(await shell.execute("time npm test")?.hasSuffix(" ms") == true)
        #expect(await shell.execute("time npm test")?.contains("> vitest run") == true)
        #expect(await shell.execute("npm publish")?.contains("offline cache") == true)
    }
}
