// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// A small shell of built-in commands over one project folder (PLAN.md §12 L0: "an emulated shell
/// whose commands are built-ins"). No processes, no paths outside the project; running code and
/// git go through hooks the app provides (RunKit, GitKit).
@MainActor
public final class Shell {
    /// A workspace task, as the app resolves it from the project's spec (PLAN.md §8.2).
    public enum TaskLookup: Sendable {
        case run(String)
        /// It can't run on the device; the reason says where it would.
        case unavailable(String)
        case unknown
    }

    public struct Hooks {
        public var run: (_ file: String) async -> String
        public var test: (_ file: String?) async -> String
        public var git: (_ args: [String]) async -> String
        /// Package commands, manager first: ["npm" | "pip", "install", specs…] or [manager, "ls"].
        public var packages: (_ args: [String]) async -> String
        /// A WASI program: a `.wasm` file in the project or a tool's name, its arguments, the
        /// working directory (relative to the project) and its stdin (the pipe's input, if any).
        public var wasm: (_ program: String, _ args: [String], _ cwd: String, _ stdin: String?) async -> String
        /// Tool names `wasm` knows (bundled, plus the project's tools/ and .omnie/tools/).
        public var tools: () -> [String]
        /// A task by name (`npm run dev`, `task test`), and the names there are.
        public var task: (_ name: String) -> TaskLookup
        public var taskNames: () -> [String]
        /// `vite` and friends: show the preview.
        public var preview: () -> String
        /// `tsc`: the type check.
        public var typecheck: () async -> String
        public var open: (_ file: String) -> Void
        /// A file a redirection (`> file`) wrote, relative to the project.
        public var wrote: (_ file: String) -> Void

        public init(run: @escaping (String) async -> String = { _ in "Running isn't available." },
                    test: @escaping (String?) async -> String = { _ in "Tests aren't available." },
                    git: @escaping ([String]) async -> String = { _ in "Git isn't available." },
                    packages: @escaping ([String]) async -> String = { _ in "The package cache isn't available." },
                    wasm: @escaping (String, [String], String, String?) async -> String = { _, _, _, _ in "WASI isn't available." },
                    tools: @escaping () -> [String] = { [] },
                    task: @escaping (String) -> TaskLookup = { _ in .unknown },
                    taskNames: @escaping () -> [String] = { [] },
                    preview: @escaping () -> String = { "The preview isn't available." },
                    typecheck: @escaping () async -> String = { "Type checking isn't available." },
                    open: @escaping (String) -> Void = { _ in },
                    wrote: @escaping (String) -> Void = { _ in }) {
            self.run = run
            self.test = test
            self.git = git
            self.packages = packages
            self.wasm = wasm
            self.tools = tools
            self.task = task
            self.taskNames = taskNames
            self.preview = preview
            self.typecheck = typecheck
            self.open = open
            self.wrote = wrote
        }
    }

    public let root: URL
    /// True while a `time` command runs (hooks add resource use to their output).
    public private(set) var timing = false
    /// The working directory, relative to the project root ("" is the root).
    public private(set) var cwd = ""
    public var hooks: Hooks

    public init(root: URL, hooks: Hooks = Hooks()) {
        self.root = URL(filePath: Self.realPath(root.standardizedFileURL.path))
        self.hooks = hooks
    }

    /// The prompt, e.g. "src $".
    public var prompt: String { (cwd.isEmpty ? root.lastPathComponent : cwd) + " $" }

    /// What the previous command in a pipeline printed, for the one running now.
    private var pipeInput: String?
    /// Whether the last built-in failed (a pipeline stops there).
    private var builtinFailed = false

    /// Runs one command line and returns its output (no trailing newline). "clear" returns nil.
    /// `a | b` gives a's output to b as its input; a failing stage stops the pipeline.
    public func execute(_ line: String) async -> String? {
        var stages: [String]
        let redirect: (path: String, append: Bool)?
        do {
            stages = try Self.pipeline(line)
            (stages[stages.count - 1], redirect) = try Self.redirection(stages[stages.count - 1])
        } catch { return "\(error)" }
        guard let redirect else { return await runPipeline(stages) }
        // `> file` / `>> file`: the output goes into the file (inside the project) instead.
        builtinFailed = false
        let output = await runPipeline(stages) ?? ""
        if builtinFailed || Self.failed(output) { return output }
        do {
            let url = try resolve(redirect.path)
            guard !isDirectory(url) else { throw Failure("\(redirect.path): is a folder") }
            guard FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path) else { throw Failure("\(redirect.path): no such folder") }
            let text = output.isEmpty ? "" : output + "\n"
            if redirect.append, let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: Data(text.utf8))
            } else {
                try Data(text.utf8).write(to: url, options: .atomic)
            }
            hooks.wrote(relative(url))
            return ""
        } catch let failure as Failure {
            return failure.message
        } catch {
            return error.localizedDescription
        }
    }

    private func runPipeline(_ stages: [String]) async -> String? {
        guard stages.count > 1 else { return await executeOne(stages[0]) }
        var output: String? = ""
        for (i, stage) in stages.enumerated() {
            guard !stage.trimmingCharacters(in: .whitespaces).isEmpty else { return "|: a command is missing" }
            pipeInput = i == 0 ? nil : output ?? ""
            defer { pipeInput = nil }
            builtinFailed = false
            output = await executeOne(stage)
            if builtinFailed { return output }
            if let out = output, Self.failed(out) { return out }
        }
        return output
    }

    /// The text a command reads: its files, else the pipe's input.
    private func input(_ files: [String], _ command: String) throws -> String {
        if !files.isEmpty { return try files.map { try read($0) }.joined(separator: "\n") }
        guard let piped = pipeInput else { throw Failure("\(command): name a file, or pipe text into it") }
        return piped
    }

    private func executeOne(_ line: String) async -> String? {
        let words: [String]
        do { words = try Self.split(line) } catch { return "\(error)" }
        guard let command = words.first else { return "" }
        let args = Array(words.dropFirst())
        do {
            switch command {
            case "help": return Self.help
            case "clear": return nil
            case "pwd": return "/" + cwd
            case "echo": return args.joined(separator: " ")
            case "cd":
                let target = try resolve(args.first ?? "/")
                guard isDirectory(target) else { throw Failure("cd: \(args.first ?? ""): not a folder") }
                cwd = relative(target)
                return ""
            case "ls": return try list(args)
            case "cat": return try input(args, command)
            case "head", "tail":
                let (count, files) = try lineCount(args)
                let lines = try input(Array(files.prefix(1)), command).split(separator: "\n", omittingEmptySubsequences: false)
                return (command == "head" ? lines.prefix(count) : lines.suffix(count)).joined(separator: "\n")
            case "grep": return try grep(args)
            case "wc": return try wordCount(args)
            case "sort":
                let flags = args.filter { $0.hasPrefix("-") }.joined()
                var lines = try input(args.filter { !$0.hasPrefix("-") }, command).split(separator: "\n").map(String.init)
                if flags.contains("n") {
                    lines.sort { (Double($0.trimmingCharacters(in: .whitespaces).prefix { "0123456789.-".contains($0) }) ?? 0) < (Double($1.trimmingCharacters(in: .whitespaces).prefix { "0123456789.-".contains($0) }) ?? 0) }
                } else if flags.contains("f") {
                    lines.sort { $0.lowercased() < $1.lowercased() }
                } else {
                    lines.sort { Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8)) }
                }
                if flags.contains("r") { lines.reverse() }
                if flags.contains("u") { lines = lines.reduce(into: []) { if $0.last != $1 { $0.append($1) } } }
                return lines.joined(separator: "\n")
            case "uniq":
                let count = args.contains("-c")
                var runs: [(String, Int)] = []
                for line in try input(args.filter { !$0.hasPrefix("-") }, command).split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
                    if runs.last?.0 == line { runs[runs.count - 1].1 += 1 } else { runs.append((line, 1)) }
                }
                return runs.map { count ? String(repeating: " ", count: max(0, 7 - String($0.1).count)) + "\($0.1) \($0.0)" : $0.0 }.joined(separator: "\n")
            case "open":
                guard let file = args.first else { throw Failure("open: name a file") }
                let url = try resolve(file)
                guard FileManager.default.fileExists(atPath: url.path), !isDirectory(url) else { throw Failure("open: \(file): no such file") }
                hooks.open(relative(url))
                return ""
            case "run", "node", "python", "python3", "tsx", "ts-node", "deno", "bun", "wasm", "wasmtime":
                guard let file = args.first else { throw Failure("\(command): name a file to run") }
                let url = try resolve(file)
                guard FileManager.default.fileExists(atPath: url.path) else { throw Failure("\(command): \(file): no such file") }
                if file.hasSuffix(".wasm") { return await hooks.wasm(relative(url), Array(args.dropFirst()), cwd, pipeInput) }
                return await hooks.run(relative(url))
            case "test", "pytest", "vitest", "jest":
                // `vitest run`, `vitest watch`: subcommands, not files.
                if let file = args.first(where: { !$0.hasPrefix("-") && !["run", "watch", "related"].contains($0) }) {
                    return await hooks.test(relative(try resolve(file)))
                }
                return await hooks.test(nil)
            case "npm", "npx", "pnpm", "yarn":
                let sub = args.first ?? ""
                // A script: npm run dev, npm start, npm test, yarn build, pnpm dev.
                let script: String? = sub == "run" || sub == "run-script" ? args.dropFirst().first
                    : ["start", "test"].contains(sub) ? sub
                    : command != "npm" && command != "npx" && !["install", "i", "add", "ci", "ls", "list"].contains(sub) && !sub.isEmpty ? sub : nil
                if let script {
                    if case .unknown = hooks.task(script), script == "test" { return await hooks.test(nil) }
                    return try await runTask(script)
                }
                if command == "npx", !sub.isEmpty {
                    // npx vitest → vitest
                    return await execute(Self.join(args)) ?? ""
                }
                if ["install", "i", "add", "ci"].contains(sub) {
                    return await hooks.packages(["npm", "install"] + args.dropFirst().filter { !$0.hasPrefix("-") })
                }
                if ["ls", "list"].contains(sub) { return await hooks.packages(["npm", "ls"]) }
                throw Failure("\(command): install, ls and test work here. Packages go into the offline cache, not node_modules.")
            case "pip", "pip3", "uv":
                var rest = args
                if command == "uv", rest.first == "pip" { rest.removeFirst() }
                let sub = rest.first ?? ""
                if sub == "install" || sub == "add" {
                    let specs = rest.dropFirst().filter { !$0.hasPrefix("-") }
                    // "-r requirements.txt" means the project's requirements.
                    if rest.contains("-r") { return await hooks.packages(["pip", "install"]) }
                    return await hooks.packages(["pip", "install"] + specs)
                }
                if ["list", "freeze"].contains(sub) { return await hooks.packages(["pip", "ls"]) }
                throw Failure("\(command): install and list work here. Packages go into the offline cache.")
            case "time":
                // Wall-clock time for any command; WASI runs add their fuel and memory.
                guard !args.isEmpty else { throw Failure("time: name a command to time") }
                let start = Date()
                timing = true
                defer { timing = false }
                let output = await execute(Self.join(args)) ?? ""
                let ms = Int(Date().timeIntervalSince(start) * 1000)
                return (output.isEmpty ? "" : output + "\n") + "real \(ms) ms"
            case "task":
                guard let name = args.first else {
                    let names = hooks.taskNames()
                    return names.isEmpty ? "No tasks: add them to .devcontainer/devcontainer.json (run.tasks) or package.json scripts." : names.joined(separator: "  ")
                }
                return try await runTask(name)
            case "vite", "next", "astro", "parcel", "serve", "http-server":
                if args.first == "build" { throw Failure("\(command) build bundles with native tools: it runs on a remote host (P4). The preview needs no build.") }
                return hooks.preview()
            case "tsc":
                return await hooks.typecheck()
            case "git":
                guard let sub = args.first, ["status", "log", "diff", "branch"].contains(sub) else {
                    throw Failure("git: status, log, diff and branch work here. Commit, sync and branches are in the Git menu.")
                }
                return await hooks.git(args)
            default:
                // ./tool.wasm, or a WASI tool by name.
                if command.hasSuffix(".wasm") {
                    let url = try resolve(command)
                    guard FileManager.default.fileExists(atPath: url.path) else { throw Failure("\(command): no such file") }
                    return await hooks.wasm(relative(url), args, cwd, pipeInput)
                }
                if hooks.tools().contains(command) { return await hooks.wasm(command, args, cwd, pipeInput) }
                throw Failure("\(command): not a built-in command. Type help to see them.")
            }
        } catch let failure as Failure {
            builtinFailed = true
            return failure.message
        } catch {
            builtinFailed = true
            return error.localizedDescription
        }
    }

    /// Words back into a command line that splits the same way: anything with spaces or quotes
    /// is single-quoted.
    static func join(_ words: [String]) -> String {
        words.map { word in
            guard word.isEmpty || word.contains(where: { " \t'\"\\|;&<>()$`*?[]{}".contains($0) }) else { return word }
            return "'" + word.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }.joined(separator: " ")
    }

    /// Runs a task's command line, part by part (`a && b` stops at the first failure).
    private var taskDepth = 0
    private func runTask(_ name: String) async throws -> String {
        switch hooks.task(name) {
        case .unknown:
            let names = hooks.taskNames()
            throw Failure("No task \"\(name)\"" + (names.isEmpty ? "." : ". Tasks: \(names.joined(separator: ", "))."))
        case .unavailable(let reason):
            throw Failure("\(name): \(reason). It runs on a remote host (P4); on the device, run its parts that work here.")
        case .run(let line):
            guard taskDepth < 4 else { throw Failure("\(name): tasks call each other too deeply.") }
            taskDepth += 1
            defer { taskDepth -= 1 }
            var outputs: [String] = ["> \(line)   (on this iPad)"]
            for part in line.components(separatedBy: "&&").map({ $0.trimmingCharacters(in: .whitespaces) }) where !part.isEmpty {
                var words = part.split(separator: " ").map(String.init)
                while let first = words.first, first.contains("="), !first.hasPrefix("-") { words.removeFirst() }
                let output = await execute(words.joined(separator: " ")) ?? ""
                if !output.isEmpty { outputs.append(output) }
                if Self.failed(output) { break }
            }
            return outputs.joined(separator: "\n")
        }
    }

    /// Whether a command's output reads as a failure (stops `a && b`).
    public static func failed(_ output: String) -> Bool {
        output.contains("not a built-in command") || output.contains(" failed, ") || output.hasPrefix("Exited with")
            || output.contains("\nExited with") || output.contains("error TS") || output.hasPrefix("No task")
    }

    static let help = """
        Built-in commands (this is not a Unix shell; everything stays in the project):
          ls [path]  cd <path>  pwd  cat <file>  head|tail [-n N] <file>  grep [-i] <text> [path]  echo  clear
          wc [-l|-w|-c]  sort [-n|-f|-r|-u]  uniq [-c]   on a file or a pipe: rg TODO | wc -l
          command > file, command >> file   write or append the output to a project file
          run <file>      run JavaScript, TypeScript or Python (node, python and tsx work too)
          test [file]     run the project's tests (vitest/jest-style and pytest-style)
          npm run <script>, task [name]   the project's tasks (devcontainer.json run.tasks or package.json scripts)
          vite, tsc       the preview; the type check
          time <command>  how long it took (and fuel and memory for WASI programs)
          npm install [name[@range]…]   fetch packages into the offline cache (asks first)
          npm ls          what the project gets from the cache
          pip install [-r requirements.txt | name…]   the same for Python (PyPI and Pyodide's builds)
          pip list
          jq …, rg …, ./x.wasm  WASI programs: bundled tools, and .wasm files (tools/ and .omnie/tools/ by name)
          git status|log|diff|branch
          open <file>     open in the editor
        """

    // MARK: Commands

    func list(_ args: [String]) throws -> String {
        let showHidden = args.contains("-a") || args.contains("-la") || args.contains("-al")
        let target = try resolve(args.first { !$0.hasPrefix("-") } ?? ".")
        guard isDirectory(target) else { return relative(target) }
        let names = try FileManager.default.contentsOfDirectory(atPath: target.path)
            .filter { showHidden || !$0.hasPrefix(".") }
            .filter { !(relative(target).isEmpty && $0 == ".git") || showHidden }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        return names.map { isDirectory(target.appendingPathComponent($0)) ? $0 + "/" : $0 }.joined(separator: "  ")
    }

    func read(_ path: String) throws -> String {
        let url = try resolve(path)
        guard !isDirectory(url) else { throw Failure("\(path): is a folder") }
        guard let data = try? Data(contentsOf: url) else { throw Failure("\(path): no such file") }
        if data.prefix(8192).contains(0) { throw Failure("\(path): binary file") }
        let text = String(decoding: data, as: UTF8.self)
        return text.hasSuffix("\n") ? String(text.dropLast()) : text
    }

    func lineCount(_ args: [String]) throws -> (Int, [String]) {
        var count = 10
        var rest: [String] = []
        var i = 0
        while i < args.count {
            if args[i] == "-n", i + 1 < args.count, let n = Int(args[i + 1]) { count = n; i += 2; continue }
            if args[i].hasPrefix("-"), let n = Int(args[i].dropFirst()) { count = n; i += 1; continue }
            rest.append(args[i]); i += 1
        }
        return (count, rest)
    }

    func grep(_ args: [String]) throws -> String {
        let flags = args.filter { $0.hasPrefix("-") }
        let words = args.filter { !$0.hasPrefix("-") }
        guard let needle = words.first else { throw Failure("grep: grep <text> [path]") }
        let options: String.CompareOptions = flags.contains("-i") ? .caseInsensitive : []
        let invert = flags.contains("-v")
        if words.count == 1, let piped = pipeInput {
            let lines = piped.split(separator: "\n", omittingEmptySubsequences: false).filter { ($0.range(of: needle, options: options) != nil) != invert }
            if flags.contains("-c") { return String(lines.count) }
            return lines.joined(separator: "\n")
        }
        let start = try resolve(words.dropFirst().first ?? ".")
        var hits: [String] = []
        let files: [URL]
        if isDirectory(start) {
            var found: [URL] = []
            let e = FileManager.default.enumerator(at: start, includingPropertiesForKeys: [.isRegularFileKey])
            while let url = e?.nextObject() as? URL {
                if [".git", "node_modules", ".build", "dist"].contains(url.lastPathComponent) { e?.skipDescendants(); continue }
                if (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true { found.append(url) }
            }
            files = found.sorted { $0.path < $1.path }
        } else {
            files = [start]
        }
        for url in files where Self.realPath(url.path).hasPrefix(root.path + "/") {
            guard let data = try? Data(contentsOf: url), data.count < 2_000_000, !data.prefix(8192).contains(0) else { continue }
            for (i, line) in String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false).enumerated()
            where line.range(of: needle, options: options) != nil {
                hits.append("\(relative(url)):\(i + 1): \(line)")
                if hits.count >= 200 { return hits.joined(separator: "\n") + "\n…" }
            }
        }
        return hits.joined(separator: "\n")
    }

    /// `wc [-l|-w|-c] [file]`: lines, words and bytes, like wc's columns.
    func wordCount(_ args: [String]) throws -> String {
        let flags = args.filter { $0.hasPrefix("-") }.joined()
        let files = args.filter { !$0.hasPrefix("-") }
        let text = try input(Array(files.prefix(1)), "wc")
        // Piped text lost its last newline; a file's was dropped by read() too.
        let lines = text.isEmpty ? 0 : text.split(separator: "\n", omittingEmptySubsequences: false).count
        let counts = [("l", lines), ("w", text.split(whereSeparator: \.isWhitespace).count), ("c", text.utf8.count + (text.isEmpty ? 0 : 1))]
        let chosen = flags.isEmpty ? counts : counts.filter { flags.contains($0.0) }
        let columns = chosen.map { String(repeating: " ", count: max(0, 7 - String($0.1).count)) + String($0.1) }.joined(separator: " ")
        return columns + (files.first.map { " " + $0 } ?? "")
    }

    // MARK: Paths

    struct Failure: Error, CustomStringConvertible {
        let message: String
        init(_ message: String) { self.message = message }
        var description: String { message }
    }

    /// A path from the user, relative to cwd ("/" is the project root). Never leaves the project.
    func resolve(_ path: String) throws -> URL {
        let base = path.hasPrefix("/") ? root : root.appendingPathComponent(cwd)
        let joined = path.hasPrefix("/") ? String(path.dropFirst()) : path
        let url = URL(filePath: Self.realPath(base.appendingPathComponent(joined).standardizedFileURL.path))
        guard url.path == root.path || url.path.hasPrefix(root.path + "/") else {
            throw Failure("\(path): outside the project")
        }
        return url
    }

    func relative(_ url: URL) -> String {
        url.path == root.path ? "" : String(url.path.dropFirst(root.path.count + 1))
    }

    func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    static func realPath(_ path: String) -> String {
        var existing = path
        var missing: [String] = []
        while !existing.isEmpty, existing != "/", access(existing, F_OK) != 0 {
            missing.insert((existing as NSString).lastPathComponent, at: 0)
            existing = (existing as NSString).deletingLastPathComponent
        }
        guard let resolved = realpath(existing, nil) else { return path }
        defer { free(resolved) }
        return ([String(cString: resolved)] + missing).joined(separator: "/").replacingOccurrences(of: "//", with: "/")
    }

    /// A command line's pipeline stages: split at `|` outside quotes (`||` isn't a pipe).
    static func pipeline(_ line: String) throws -> [String] {
        var stages: [String] = []
        var current = ""
        var quote: Character?
        var escaped = false
        let chars = Array(line)
        for (i, c) in chars.enumerated() {
            if escaped { current.append(c); escaped = false; continue }
            if c == "\\" && quote != "'" { escaped = true; current.append(c); continue }
            if let q = quote { if c == q { quote = nil }; current.append(c); continue }
            if c == "\"" || c == "'" { quote = c; current.append(c); continue }
            if c == "|", chars.indices.contains(i + 1) ? chars[i + 1] != "|" : true, i == 0 || chars[i - 1] != "|" {
                stages.append(current); current = ""; continue
            }
            current.append(c)
        }
        if quote != nil { throw Failure("unclosed quote") }
        stages.append(current)
        return stages
    }

    /// A trailing `> file` or `>> file` outside quotes, split off the command.
    static func redirection(_ stage: String) throws -> (String, (path: String, append: Bool)?) {
        var quote: Character?
        var escaped = false
        var at: String.Index?
        for i in stage.indices {
            let c = stage[i]
            if escaped { escaped = false; continue }
            if c == "\\" && quote != "'" { escaped = true; continue }
            if let q = quote { if c == q { quote = nil }; continue }
            if c == "\"" || c == "'" { quote = c; continue }
            if c == ">" { at = i; break }
        }
        guard let at else { return (stage, nil) }
        let append = stage[at...].hasPrefix(">>")
        let rest = stage[stage.index(at, offsetBy: append ? 2 : 1)...]
        let words = try split(String(rest))
        guard words.count == 1 else { throw Failure(words.isEmpty ? ">: name a file" : ">: one file, at the end of the line") }
        return (String(stage[..<at]), (words[0], append))
    }

    /// Splits a command line into words: spaces separate, quotes group, backslash escapes.
    static func split(_ line: String) throws -> [String] {
        var words: [String] = []
        var current = ""
        var quote: Character?
        var inWord = false
        var escaped = false
        for c in line {
            if escaped { current.append(c); escaped = false; inWord = true; continue }
            if c == "\\" && quote != "'" { escaped = true; continue }
            if let q = quote {
                if c == q { quote = nil } else { current.append(c) }
                continue
            }
            if c == "\"" || c == "'" { quote = c; inWord = true; continue }
            if c.isWhitespace {
                if inWord { words.append(current); current = ""; inWord = false }
                continue
            }
            current.append(c); inWord = true
        }
        if quote != nil { throw Failure("unclosed quote") }
        if inWord { words.append(current) }
        return words
    }
}
