// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

import CryptoKit
import Foundation
import PolicyKit

/// A call the model asked for.
public struct ToolCall: Codable, Sendable, Hashable {
    public let name: String
    public let arguments: [String: JSONValue]

    public init(name: String, arguments: [String: JSONValue]) {
        self.name = name
        self.arguments = arguments
    }

    public func string(_ key: String) throws -> String {
        guard let value = arguments[key]?.string else { throw ToolError.missingArgument(key) }
        return value
    }
}

public enum ToolError: Error, Equatable, LocalizedError {
    case missingArgument(String)
    case outsideProject(String)
    case notFound(String)
    case wrongCase(asked: String, actual: String)
    case staleFile(path: String, current: String)
    case findNotUnique(count: Int)
    case alreadyExists(String)
    case unknownTool(String)
    case wouldBreakSyntax(path: String, reason: String)
    case protectedFile(String)

    public var errorDescription: String? {
        switch self {
        case .missingArgument(let k): "Missing argument \"\(k)\"."
        case .outsideProject(let p): "\(p) is outside the project."
        case .notFound(let p): "\(p) doesn't exist."
        case .wrongCase(let asked, let actual): "\(asked) doesn't exist, but \(actual) does (names are case-sensitive). Use \(actual)."
        case .staleFile(let p, let sha): "That sha isn't \(p)'s (its current sha is \(sha)). Read \(p) and use the sha read returns."
        case .findNotUnique(let n): n == 0 ? "The find text isn't in the file. Copy it exactly from read." : "The find text appears \(n) times; include more surrounding lines so it's unique."
        case .alreadyExists(let p): "\(p) already exists. Use patch to change it."
        case .unknownTool(let n): "There's no tool called \(n)."
        case .protectedFile(let p): "\(p) is project configuration; it isn't changed this way."
        case .wouldBreakSyntax(let p, let reason): "That would leave \(p) invalid, so nothing was written: \(reason)\nEdit inside the existing structure with patch."
        }
    }
}

/// A typed tool (PLAN.md §6.1). Each one names the policy action its arguments amount to, so
/// PolicyKit decides before it runs.
public protocol AgentTool: Sendable {
    var name: String { get }
    var description: String { get }
    /// JSON Schema for the arguments.
    var parameters: [String: JSONValue] { get }
    func action(for call: ToolCall) throws -> Action
    func run(_ call: ToolCall) async throws -> String
}

/// The files an agent task may touch: one folder (the task worktree), nothing outside it, never `.git`.
public struct Sandbox: Sendable {
    public let root: URL

    public init(root: URL) { self.root = URL(filePath: Self.realPath(root.standardizedFileURL.path)) }

    public func resolve(_ path: String) throws -> URL {
        let trimmed = path.trimmingCharacters(in: .whitespaces)
        let relative = trimmed.hasPrefix("/") ? String(trimmed.dropFirst()) : trimmed
        let lexical = (relative.isEmpty || relative == "." ? root : root.appendingPathComponent(relative)).standardizedFileURL
        // Resolve symlinks in every part that exists, including the parents of a file that doesn't
        // yet (Foundation's resolvingSymlinksInPath leaves a missing path alone, which let a planted
        // symlink redirect a new file out of the project).
        let url = URL(filePath: Self.realPath(lexical.path))
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard url.path == root.path || url.path.hasPrefix(rootPath) else { throw ToolError.outsideProject(path) }
        let inside = url.path.dropFirst(rootPath.count)
        if inside == ".git" || inside.hasPrefix(".git/") { throw ToolError.outsideProject(path) }
        return url
    }

    /// `realpath` of the longest existing prefix, with the missing remainder appended.
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

    /// The path as it is on disk when `path` names an existing file or folder only by ignoring case
    /// (`src/Orbit.ts` for `src/orbit.ts`); nil when it matches exactly or not at all.
    public func caseVariant(of path: String) -> String? {
        let parts = path.split(separator: "/").map(String.init).filter { $0 != "." }
        var dir = root, actual: [String] = [], differs = false
        for part in parts {
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return nil }
            if names.contains(part) {
                actual.append(part)
            } else if let match = names.first(where: { $0.caseInsensitiveCompare(part) == .orderedSame }) {
                actual.append(match)
                differs = true
            } else {
                return nil
            }
            dir = dir.appendingPathComponent(actual.last!)
        }
        return differs ? actual.joined(separator: "/") : nil
    }

    /// The error for a file that isn't at `path`: naming the one that is, when only the case differs.
    func missing(_ path: String) -> ToolError {
        caseVariant(of: path).map { .wrongCase(asked: path, actual: $0) } ?? .notFound(path)
    }

    public func relative(_ url: URL) -> String {
        let path = URL(filePath: Self.realPath(url.standardizedFileURL.path)).path
        return path == root.path ? "." : String(path.dropFirst(root.path.count + 1))
    }

    /// Parses JavaScript/TypeScript for the edit guard (the app supplies RunKit's transpiler; AgentKit
    /// doesn't depend on it). Returns the syntax error, or nil.
    nonisolated(unsafe) public static var syntaxChecker: (@Sendable (_ text: String, _ path: String) -> String?)?

    static let codeExtensions = [".js", ".mjs", ".cjs", ".jsx", ".ts", ".tsx", ".mts"]

    /// Refuses writes that would break a file the app can check. JSON: a small model appending a
    /// fragment after the closing brace is a common way to break package.json. JS/TS: a change
    /// that leaves the code unparseable (an extra parenthesis) is refused with the line, unless the
    /// file was already broken before it (fixing a broken file must stay possible).
    public static func validate(_ data: Data, path: String, previous: Data? = nil) throws {
        let lower = path.lowercased()
        if codeExtensions.contains(where: { lower.hasSuffix($0) }), !lower.hasSuffix(".d.ts"), let check = syntaxChecker {
            let text = String(decoding: data, as: UTF8.self)
            guard let error = check(text, path) else { return }
            if let previous, check(String(decoding: previous, as: UTF8.self), path) != nil { return }
            var reason = "it wouldn't parse: \(error)"
            if let m = error.firstMatch(of: /\((\d+):(\d+)\)/), let line = Int(m.1) {
                let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
                if line >= 1, line <= lines.count { reason += "\nLine \(line) would be: \(lines[line - 1])" }
            }
            throw ToolError.wouldBreakSyntax(path: path, reason: reason)
        }
        guard lower.hasSuffix(".json") else { return }
        do { _ = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) } catch {
            // Show the would-be file (small ones) so the model can see what went wrong.
            let text = String(decoding: data, as: UTF8.self)
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            let detail = (error as NSError).userInfo[NSDebugDescriptionErrorKey] as? String
            var reason = "not valid JSON" + (detail.map { ": \($0)" } ?? "")
            if lines.count <= 40 { reason += ". The file would have been:\n\(text)" }
            throw ToolError.wouldBreakSyntax(path: path, reason: reason)
        }
    }

    /// Git's blob id for `data`, so the model can name the exact version it read.
    public static func blobSHA(_ data: Data) -> String {
        var hasher = Insecure.SHA1()
        hasher.update(data: Data("blob \(data.count)\0".utf8))
        hasher.update(data: data)
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

func schema(_ properties: [String: (type: String, description: String)], required: [String]) -> [String: JSONValue] {
    [
        "type": .string("object"),
        "properties": .object(properties.mapValues { .object(["type": .string($0.type), "description": .string($0.description)]) }),
        "required": .array(required.map { .string($0) }),
    ]
}

let skippedNames: Set<String> = [".git", "node_modules", ".build", "DerivedData", ".DS_Store", "__pycache__", ".venv"]

/// `list`: the files under a folder.
public struct ListTool: AgentTool {
    let sandbox: Sandbox
    public init(sandbox: Sandbox) { self.sandbox = sandbox }
    public let name = "list"
    public let description = "List files and folders under a path in the project (folders end with /)."
    public var parameters: [String: JSONValue] { schema(["path": ("string", "Folder, relative to the project root. Default \".\".")], required: []) }
    public func action(for call: ToolCall) throws -> Action { .readProject(path: call.arguments["path"]?.string ?? ".") }

    public func run(_ call: ToolCall) async throws -> String {
        let dir = try sandbox.resolve(call.arguments["path"]?.string ?? ".")
        guard let enumerator = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.isDirectoryKey]) else {
            throw ToolError.notFound(call.arguments["path"]?.string ?? ".")
        }
        var lines: [String] = []
        while let url = enumerator.nextObject() as? URL {
            if skippedNames.contains(url.lastPathComponent) { enumerator.skipDescendants(); continue }
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            lines.append(sandbox.relative(url) + (isDir ? "/" : ""))
            if lines.count >= 300 { lines.append("… (more not shown)"); break }
        }
        return lines.sorted().joined(separator: "\n")
    }
}

/// `read`: a file's lines, with the blob sha that `patch` needs.
public struct ReadTool: AgentTool {
    let sandbox: Sandbox
    public init(sandbox: Sandbox) { self.sandbox = sandbox }
    public let name = "read"
    public let description = "Read a text file. Returns its sha (needed by patch) and up to 200 lines starting at start_line."
    public var parameters: [String: JSONValue] {
        schema(["path": ("string", "File, relative to the project root."), "start_line": ("integer", "First line to show, 1-based. Default 1.")],
               required: ["path"])
    }
    public func action(for call: ToolCall) throws -> Action { .readProject(path: try call.string("path")) }

    public func run(_ call: ToolCall) async throws -> String {
        let path = try call.string("path")
        let url = try sandbox.resolve(path)
        guard sandbox.caseVariant(of: path) == nil, let data = try? Data(contentsOf: url) else { throw sandbox.missing(path) }
        let text = String(decoding: data, as: UTF8.self)
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        // A final newline ends the last line; it doesn't start an empty one.
        if text.hasSuffix("\n") { lines.removeLast() }
        let start = max(1, call.arguments["start_line"]?.int ?? 1)
        let end = min(lines.count, start + 199)
        let shown = start <= lines.count ? lines[(start - 1)..<end].joined(separator: "\n") : ""
        return "path: \(path)\nsha: \(Sandbox.blobSHA(data))\nlines \(start)-\(end) of \(lines.count)\n---\n\(shown)"
    }
}

/// `grep`: lines containing some text (case-insensitive), across the project or one folder.
public struct GrepTool: AgentTool {
    let sandbox: Sandbox
    public init(sandbox: Sandbox) { self.sandbox = sandbox }
    public let name = "grep"
    public let description = "Find lines containing some text (case-insensitive; a regular expression works too) in the project's files. Returns path:line: text."
    public var parameters: [String: JSONValue] {
        schema(["text": ("string", "Text to look for."), "path": ("string", "Folder to search. Default the whole project.")], required: ["text"])
    }
    public func action(for call: ToolCall) throws -> Action { .readProject(path: call.arguments["path"]?.string ?? ".") }

    public func run(_ call: ToolCall) async throws -> String {
        let needle = try call.string("text")
        // Models write both "total(" and "total\\(": match the text literally, or as a regex.
        let regex = try? NSRegularExpression(pattern: needle, options: [.caseInsensitive])
        let dir = try sandbox.resolve(call.arguments["path"]?.string ?? ".")
        var hits: [String] = []
        let enumerator = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey])
        while let url = enumerator?.nextObject() as? URL {
            if skippedNames.contains(url.lastPathComponent) { enumerator?.skipDescendants(); continue }
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            // Only files that really live in the project (a symlink could point anywhere).
            guard values?.isRegularFile == true, (values?.fileSize ?? 0) < 1_000_000,
                  Sandbox.realPath(url.path).hasPrefix(sandbox.root.path + "/"),
                  let data = try? Data(contentsOf: url), !data.prefix(8192).contains(0) else { continue }
            for (i, line) in String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false).enumerated()
            where line.range(of: needle, options: .caseInsensitive) != nil
                || regex?.firstMatch(in: String(line), range: NSRange(line.startIndex..., in: line)) != nil {
                hits.append("\(sandbox.relative(url)):\(i + 1): \(line.prefix(200))")
                if hits.count >= 50 { return hits.joined(separator: "\n") + "\n… (more matches not shown)" }
            }
        }
        return hits.isEmpty ? "No matches." : hits.joined(separator: "\n")
    }
}

/// `patch`: replace one exact, unique piece of a file, guarded by the sha from `read`. Small local
/// models write find/replace pairs far more reliably than unified diffs; the sha keeps the plan's
/// rule that an edit applies only to the exact version the agent saw (PLAN.md §6.1).
public struct PatchTool: AgentTool {
    let sandbox: Sandbox
    public init(sandbox: Sandbox) { self.sandbox = sandbox }
    public let name = "patch"
    public let description = "Replace text in a file. find must appear exactly once in the file, copied exactly from read; sha is the file's sha from read. To add code without removing any, put existing text in find and that same text plus your addition in replace. To delete code, put it in find and use an empty replace."
    public var parameters: [String: JSONValue] {
        schema(["path": ("string", "File to change."), "sha": ("string", "The sha read returned for this file."),
                "find": ("string", "Exact existing text to replace, including indentation."), "replace": ("string", "The new text.")],
               required: ["path", "sha", "find", "replace"])
    }
    public func action(for call: ToolCall) throws -> Action { .writeTaskWorktree(path: try call.string("path")) }

    public func run(_ call: ToolCall) async throws -> String {
        let path = try call.string("path")
        let url = try sandbox.resolve(path)
        guard sandbox.caseVariant(of: path) == nil, let data = try? Data(contentsOf: url) else { throw sandbox.missing(path) }
        let current = Sandbox.blobSHA(data)
        guard try call.string("sha") == current else { throw ToolError.staleFile(path: path, current: current) }
        let text = String(decoding: data, as: UTF8.self)
        var find = try call.string("find")
        var replace = try call.string("replace")
        var count = Self.occurrences(of: find, in: text)
        if count == 0 {
            // Models often add or drop blank lines at the edges of find. Retry without them; the
            // replacement loses the same edges, so the file's own line breaks stay as they were.
            let trimmedFind = find.trimmingCharacters(in: .newlines)
            if trimmedFind != find, Self.occurrences(of: trimmedFind, in: text) == 1 {
                find = trimmedFind
                replace = replace.trimmingCharacters(in: .newlines)
                count = 1
            }
        }
        var updated: String?
        if count == 0, let span = Self.looseMatch(find, in: text) {
            // Last resort: the same lines, ignoring blank lines (and trailing spaces). Unique matches only.
            updated = text.replacingCharacters(in: span, with: replace.trimmingCharacters(in: .newlines))
            count = 1
        }
        guard count == 1 else { throw ToolError.findNotUnique(count: count) }
        if let updated {
            let out = Data(updated.utf8)
            try Sandbox.validate(out, path: path, previous: Data(text.utf8))
            try out.write(to: url, options: .atomic)
            return "Patched \(path) (matched ignoring blank lines). New sha: \(Sandbox.blobSHA(out))"
        }
        // A replace that repeats the lines right after find (find was a block's first line, replace
        // the whole block) means those lines are part of the change: extend find over them.
        // Reporting it as an error led the model to drop code while "fixing" its patch.
        var note = ""
        if let extended = Self.extendOverRepeatedLines(text: text, find: find, replace: replace) {
            find = extended
            note = " (the change covers the following lines your replace already included)"
        }
        let out = Data(text.replacingOccurrences(of: find, with: replace).utf8)
        try Sandbox.validate(out, path: path, previous: Data(text.utf8))
        try out.write(to: url, options: .atomic)
        return "Patched \(path)\(note). New sha: \(Sandbox.blobSHA(out))"
    }

    /// When the lines right after `find` also appear in `replace`, contiguously and in order (after
    /// the part standing in for find), returns find extended over them; otherwise nil.
    static func extendOverRepeatedLines(text: String, find: String, replace: String) -> String? {
        guard let range = text.range(of: find) else { return nil }
        let trim = { (s: Substring) in s.trimmingCharacters(in: .whitespaces) }
        // The file's lines after find, each with where it ends.
        var following: [(text: String, end: String.Index)] = []
        var cursor = range.upperBound
        if cursor < text.endIndex, text[cursor] == "\n" { cursor = text.index(after: cursor) }
        while cursor < text.endIndex, following.count < 400 {
            let end = text[cursor...].firstIndex(of: "\n") ?? text.endIndex
            following.append((trim(text[cursor..<end]), end))
            cursor = end < text.endIndex ? text.index(after: end) : end
        }
        let replaceLines = replace.split(separator: "\n", omittingEmptySubsequences: false).map(trim)
        let findLineCount = find.split(separator: "\n", omittingEmptySubsequences: false).count
        // Skip leading blank lines in the file; the first repeated line must have content.
        var first = 0
        while first < following.count, following[first].text.isEmpty { first += 1 }
        guard first < following.count, following[first].text.count >= 3 else { return nil }
        let searchFrom = min(findLineCount, replaceLines.count)
        guard let start = replaceLines[searchFrom...].firstIndex(of: following[first].text) else { return nil }
        // How many of the file's following lines replace repeats from there, in order.
        var matched = 0
        while first + matched < following.count, start + matched < replaceLines.count,
              following[first + matched].text == replaceLines[start + matched] {
            matched += 1
        }
        guard matched > 0 else { return nil }
        return String(text[range.lowerBound..<following[first + matched - 1].end])
    }

    /// Where `find`'s non-blank lines appear as consecutive non-blank lines of `text`, compared
    /// without trailing spaces. Indentation must match: matching around it let a bad patch replace
    /// the wrong lines (seen on the device), and a failed patch is better than a wrong one.
    /// nil unless there's exactly one such place.
    static func looseMatch(_ find: String, in text: String) -> Range<String.Index>? {
        func trailingTrimmed(_ s: Substring) -> String {
            var t = String(s)
            while let last = t.last, last == " " || last == "\t" || last == "\r" { t.removeLast() }
            return t
        }
        let wanted = find.split(separator: "\n").map(trailingTrimmed).filter { !$0.allSatisfy(\.isWhitespace) }
        guard !wanted.isEmpty else { return nil }
        // Non-blank lines of the file with their ranges.
        var lines: [(text: String, range: Range<String.Index>)] = []
        var start = text.startIndex
        while start < text.endIndex {
            let end = text[start...].firstIndex(of: "\n") ?? text.endIndex
            let trimmed = trailingTrimmed(text[start..<end])
            if !trimmed.allSatisfy(\.isWhitespace) { lines.append((trimmed, start..<end)) }
            start = end < text.endIndex ? text.index(after: end) : end
        }
        var matches: [Range<String.Index>] = []
        if lines.count >= wanted.count {
            for i in 0...(lines.count - wanted.count) where (0..<wanted.count).allSatisfy({ lines[i + $0].text == wanted[$0] }) {
                matches.append(lines[i].range.lowerBound..<lines[i + wanted.count - 1].range.upperBound)
            }
        }
        return matches.count == 1 ? matches[0] : nil
    }

    static func occurrences(of find: String, in text: String) -> Int {
        find.isEmpty ? 0 : text.components(separatedBy: find).count - 1
    }
}

/// `append_to_file`: add text at the end of a file, the common case of adding a function or a
/// section. Small models do this far more reliably as an append than as a find/replace.
public struct AppendTool: AgentTool {
    let sandbox: Sandbox
    public init(sandbox: Sandbox) { self.sandbox = sandbox }
    public let name = "append_to_file"
    public let description = "Add text at the end of an existing file without changing anything already in it. sha is the file's sha from read."
    public var parameters: [String: JSONValue] {
        schema(["path": ("string", "File to add to."), "sha": ("string", "The sha read returned for this file."),
                "text": ("string", "The text to add at the end.")], required: ["path", "sha", "text"])
    }
    public func action(for call: ToolCall) throws -> Action { .writeTaskWorktree(path: try call.string("path")) }

    public func run(_ call: ToolCall) async throws -> String {
        let path = try call.string("path")
        let url = try sandbox.resolve(path)
        guard sandbox.caseVariant(of: path) == nil, let data = try? Data(contentsOf: url) else { throw sandbox.missing(path) }
        let current = Sandbox.blobSHA(data)
        guard try call.string("sha") == current else { throw ToolError.staleFile(path: path, current: current) }
        var text = String(decoding: data, as: UTF8.self)
        if !text.isEmpty && !text.hasSuffix("\n") { text += "\n" }
        var addition = try call.string("text")
        if !addition.hasSuffix("\n") { addition += "\n" }
        // Keep one blank line between the old end and the addition.
        if !text.isEmpty && !text.hasSuffix("\n\n") && !addition.hasPrefix("\n") { text += "\n" }
        let out = Data((text + addition).utf8)
        try Sandbox.validate(out, path: path, previous: data)
        try out.write(to: url, options: .atomic)
        return "Appended to \(path). New sha: \(Sandbox.blobSHA(out))"
    }
}

/// `create_file`: a new file. Existing files are changed with `patch`.
public struct CreateFileTool: AgentTool {
    let sandbox: Sandbox
    public init(sandbox: Sandbox) { self.sandbox = sandbox }
    public let name = "create_file"
    public let description = "Create a new file with the given content. Fails if the file exists."
    public var parameters: [String: JSONValue] {
        schema(["path": ("string", "New file, relative to the project root."), "content": ("string", "The whole file.")], required: ["path", "content"])
    }
    public func action(for call: ToolCall) throws -> Action { .writeTaskWorktree(path: try call.string("path")) }

    public func run(_ call: ToolCall) async throws -> String {
        let path = try call.string("path")
        let url = try sandbox.resolve(path)
        // src/Orbit.ts beside src/orbit.ts is a model's typo, not a new file (and the same file on
        // a case-insensitive disk).
        if let actual = sandbox.caseVariant(of: path) { throw ToolError.wrongCase(asked: path, actual: actual) }
        guard !FileManager.default.fileExists(atPath: url.path) else { throw ToolError.alreadyExists(path) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = Data(try call.string("content").utf8)
        try Sandbox.validate(data, path: path)
        try data.write(to: url, options: .atomic)
        return "Created \(path). sha: \(Sandbox.blobSHA(data))"
    }
}

/// `finish`: the task is done; the summary is shown above the changeset.
public struct FinishTool: AgentTool {
    public init() {}
    public let name = "finish"
    public let description = "Call when the task is complete. summary says what you changed and why, in one or two sentences."
    public var parameters: [String: JSONValue] { schema(["summary": ("string", "What changed and why.")], required: ["summary"]) }
    public func action(for call: ToolCall) throws -> Action { .readProject(path: ".") }
    public func run(_ call: ToolCall) async throws -> String { try call.string("summary") }
}

extension AgentTool {
    /// The tool as Qwen-style function JSON for the system prompt.
    var signature: JSONValue {
        .object(["type": .string("function"),
                 "function": .object(["name": .string(name), "description": .string(description), "parameters": .object(parameters)])])
    }
}

/// The standard tool set for a task folder.
public func standardTools(root: URL) -> [any AgentTool] {
    let sandbox = Sandbox(root: root)
    return [ListTool(sandbox: sandbox), ReadTool(sandbox: sandbox), GrepTool(sandbox: sandbox),
            PatchTool(sandbox: sandbox), AppendTool(sandbox: sandbox), CreateFileTool(sandbox: sandbox), FinishTool()]
}
