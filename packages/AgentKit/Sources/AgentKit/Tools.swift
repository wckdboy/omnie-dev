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
    case staleFile(path: String, current: String)
    case findNotUnique(count: Int)
    case alreadyExists(String)
    case unknownTool(String)

    public var errorDescription: String? {
        switch self {
        case .missingArgument(let k): "Missing argument \"\(k)\"."
        case .outsideProject(let p): "\(p) is outside the project."
        case .notFound(let p): "\(p) doesn't exist."
        case .staleFile(let p, let sha): "\(p) changed since you read it (now sha \(sha)). Read it again before patching."
        case .findNotUnique(let n): n == 0 ? "The find text isn't in the file. Copy it exactly from read." : "The find text appears \(n) times; include more surrounding lines so it's unique."
        case .alreadyExists(let p): "\(p) already exists. Use patch to change it."
        case .unknownTool(let n): "There's no tool called \(n)."
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

    public init(root: URL) { self.root = root.standardizedFileURL.resolvingSymlinksInPath() }

    public func resolve(_ path: String) throws -> URL {
        let trimmed = path.trimmingCharacters(in: .whitespaces)
        let relative = trimmed.hasPrefix("/") ? String(trimmed.dropFirst()) : trimmed
        let url = (relative.isEmpty || relative == "." ? root : root.appendingPathComponent(relative))
            .standardizedFileURL.resolvingSymlinksInPath()
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard url.path == root.path || url.path.hasPrefix(rootPath) else { throw ToolError.outsideProject(path) }
        let inside = url.path.dropFirst(rootPath.count)
        if inside == ".git" || inside.hasPrefix(".git/") { throw ToolError.outsideProject(path) }
        return url
    }

    public func relative(_ url: URL) -> String {
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        return path == root.path ? "." : String(path.dropFirst(root.path.count + 1))
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
        guard let data = try? Data(contentsOf: url) else { throw ToolError.notFound(path) }
        let text = String(decoding: data, as: UTF8.self)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
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
    public let description = "Find lines containing some text (case-insensitive) in the project's files. Returns path:line: text."
    public var parameters: [String: JSONValue] {
        schema(["text": ("string", "Text to look for."), "path": ("string", "Folder to search. Default the whole project.")], required: ["text"])
    }
    public func action(for call: ToolCall) throws -> Action { .readProject(path: call.arguments["path"]?.string ?? ".") }

    public func run(_ call: ToolCall) async throws -> String {
        let needle = try call.string("text")
        let dir = try sandbox.resolve(call.arguments["path"]?.string ?? ".")
        var hits: [String] = []
        let enumerator = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey])
        while let url = enumerator?.nextObject() as? URL {
            if skippedNames.contains(url.lastPathComponent) { enumerator?.skipDescendants(); continue }
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values?.isRegularFile == true, (values?.fileSize ?? 0) < 1_000_000,
                  let data = try? Data(contentsOf: url), !data.prefix(8192).contains(0) else { continue }
            for (i, line) in String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false).enumerated()
            where line.range(of: needle, options: .caseInsensitive) != nil {
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
    public let description = "Replace text in a file. find must appear exactly once in the file, copied exactly from read; sha is the file's sha from read."
    public var parameters: [String: JSONValue] {
        schema(["path": ("string", "File to change."), "sha": ("string", "The sha read returned for this file."),
                "find": ("string", "Exact existing text to replace, including indentation."), "replace": ("string", "The new text.")],
               required: ["path", "sha", "find", "replace"])
    }
    public func action(for call: ToolCall) throws -> Action { .writeTaskWorktree(path: try call.string("path")) }

    public func run(_ call: ToolCall) async throws -> String {
        let path = try call.string("path")
        let url = try sandbox.resolve(path)
        guard let data = try? Data(contentsOf: url) else { throw ToolError.notFound(path) }
        let current = Sandbox.blobSHA(data)
        guard try call.string("sha") == current else { throw ToolError.staleFile(path: path, current: current) }
        let text = String(decoding: data, as: UTF8.self)
        let find = try call.string("find")
        let count = find.isEmpty ? 0 : text.components(separatedBy: find).count - 1
        guard count == 1 else { throw ToolError.findNotUnique(count: count) }
        let updated = text.replacingOccurrences(of: find, with: try call.string("replace"))
        let out = Data(updated.utf8)
        try out.write(to: url, options: .atomic)
        return "Patched \(path). New sha: \(Sandbox.blobSHA(out))"
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
        guard !FileManager.default.fileExists(atPath: url.path) else { throw ToolError.alreadyExists(path) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = Data(try call.string("content").utf8)
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
            PatchTool(sandbox: sandbox), CreateFileTool(sandbox: sandbox), FinishTool()]
}
