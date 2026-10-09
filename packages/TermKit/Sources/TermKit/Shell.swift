// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// A small shell of built-in commands over one project folder (PLAN.md §12 L0: "an emulated shell
/// whose commands are built-ins"). No processes, no paths outside the project; running code and
/// git go through hooks the app provides (RunKit, GitKit).
@MainActor
public final class Shell {
    public struct Hooks {
        public var run: (_ file: String) async -> String
        public var test: (_ file: String?) async -> String
        public var git: (_ args: [String]) async -> String
        /// Package commands, manager first: ["npm" | "pip", "install", specs…] or [manager, "ls"].
        public var packages: (_ args: [String]) async -> String
        /// A WASI program: a `.wasm` file in the project or a tool's name, its arguments and the
        /// working directory (relative to the project).
        public var wasm: (_ program: String, _ args: [String], _ cwd: String) async -> String
        /// Tool names `wasm` knows (bundled, plus the project's tools/ and .omnie/tools/).
        public var tools: () -> [String]
        public var open: (_ file: String) -> Void

        public init(run: @escaping (String) async -> String = { _ in "Running isn't available." },
                    test: @escaping (String?) async -> String = { _ in "Tests aren't available." },
                    git: @escaping ([String]) async -> String = { _ in "Git isn't available." },
                    packages: @escaping ([String]) async -> String = { _ in "The package cache isn't available." },
                    wasm: @escaping (String, [String], String) async -> String = { _, _, _ in "WASI isn't available." },
                    tools: @escaping () -> [String] = { [] },
                    open: @escaping (String) -> Void = { _ in }) {
            self.run = run
            self.test = test
            self.git = git
            self.packages = packages
            self.wasm = wasm
            self.tools = tools
            self.open = open
        }
    }

    public let root: URL
    /// The working directory, relative to the project root ("" is the root).
    public private(set) var cwd = ""
    public var hooks: Hooks

    public init(root: URL, hooks: Hooks = Hooks()) {
        self.root = URL(filePath: Self.realPath(root.standardizedFileURL.path))
        self.hooks = hooks
    }

    /// The prompt, e.g. "src $".
    public var prompt: String { (cwd.isEmpty ? root.lastPathComponent : cwd) + " $" }

    /// Runs one command line and returns its output (no trailing newline). "clear" returns nil.
    public func execute(_ line: String) async -> String? {
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
            case "cat":
                guard !args.isEmpty else { throw Failure("cat: name a file") }
                return try args.map { try read($0) }.joined(separator: "\n")
            case "head", "tail":
                let (count, files) = try lineCount(args)
                guard let file = files.first else { throw Failure("\(command): name a file") }
                let lines = try read(file).split(separator: "\n", omittingEmptySubsequences: false)
                return (command == "head" ? lines.prefix(count) : lines.suffix(count)).joined(separator: "\n")
            case "grep": return try grep(args)
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
                if file.hasSuffix(".wasm") { return await hooks.wasm(relative(url), Array(args.dropFirst()), cwd) }
                return await hooks.run(relative(url))
            case "test", "pytest", "vitest", "jest":
                if let file = args.first(where: { !$0.hasPrefix("-") }) { return await hooks.test(relative(try resolve(file))) }
                return await hooks.test(nil)
            case "npm", "npx", "pnpm", "yarn":
                if args.first == "test" || args == ["run", "test"] { return await hooks.test(nil) }
                let sub = args.first ?? ""
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
                    return await hooks.wasm(relative(url), args, cwd)
                }
                if hooks.tools().contains(command) { return await hooks.wasm(command, args, cwd) }
                throw Failure("\(command): not a built-in command. Type help to see them.")
            }
        } catch let failure as Failure {
            return failure.message
        } catch {
            return error.localizedDescription
        }
    }

    static let help = """
        Built-in commands (this is not a Unix shell; everything stays in the project):
          ls [path]  cd <path>  pwd  cat <file>  head|tail [-n N] <file>  grep <text> [path]  echo  clear
          run <file>      run JavaScript, TypeScript or Python (node, python and tsx work too)
          test [file]     run the project's tests (vitest/jest-style and pytest-style)
          npm install [name[@range]…]   fetch packages into the offline cache (asks first)
          npm ls          what the project gets from the cache
          pip install [-r requirements.txt | name…]   the same for Python (PyPI and Pyodide's builds)
          pip list
          jq …, ./tool.wasm …   WASI programs: bundled tools, and .wasm files (tools/ and .omnie/tools/ by name)
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
        let start = try resolve(words.dropFirst().first ?? ".")
        let options: String.CompareOptions = flags.contains("-i") ? .caseInsensitive : []
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
