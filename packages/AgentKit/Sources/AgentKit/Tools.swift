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
    case duplicatesFollowingLines(String)
    case wouldBreakSyntax(path: String, reason: String)

    public var errorDescription: String? {
        switch self {
        case .missingArgument(let k): "Missing argument \"\(k)\"."
        case .outsideProject(let p): "\(p) is outside the project."
        case .notFound(let p): "\(p) doesn't exist."
        case .staleFile(let p, let sha): "That sha isn't \(p)'s (its current sha is \(sha)). Read \(p) and use the sha read returns."
        case .findNotUnique(let n): n == 0 ? "The find text isn't in the file. Copy it exactly from read." : "The find text appears \(n) times; include more surrounding lines so it's unique."
        case .alreadyExists(let p): "\(p) already exists. Use patch to change it."
        case .unknownTool(let n): "There's no tool called \(n)."
        case .wouldBreakSyntax(let p, let reason): "That would leave \(p) invalid, so nothing was written: \(reason)\nEdit inside the existing structure with patch."
        case .duplicatesFollowingLines(let line): "replace includes \"\(line)\", which already comes right after find in the file, so it would appear twice. Put those lines in find as well, or leave them out of replace."
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

    public func relative(_ url: URL) -> String {
        let path = URL(filePath: Self.realPath(url.standardizedFileURL.path)).path
        return path == root.path ? "." : String(path.dropFirst(root.path.count + 1))
    }

    /// Refuses writes that would break a file the app can check: JSON for now. A small model
    /// appending a fragment after the closing brace is a common way to break package.json.
    public static func validate(_ data: Data, path: String) throws {
        guard path.lowercased().hasSuffix(".json") else { return }
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
        guard let data = try? Data(contentsOf: url) else { throw ToolError.notFound(path) }
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
    public let description = "Replace text in a file. find must appear exactly once in the file, copied exactly from read; sha is the file's sha from read. To add code without removing any, put existing text in find and that same text plus your addition in replace."
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
            // Last resort: the same lines, ignoring blank lines and indentation. Unique matches only.
            updated = text.replacingCharacters(in: span, with: replace.trimmingCharacters(in: .newlines))
            count = 1
        }
        guard count == 1 else { throw ToolError.findNotUnique(count: count) }
        if let updated {
            let out = Data(updated.utf8)
            try Sandbox.validate(out, path: path)
            try out.write(to: url, options: .atomic)
            return "Patched \(path) (matched ignoring blank lines and indentation). New sha: \(Sandbox.blobSHA(out))"
        }
        if let repeated = Self.repeatedTail(text: text, find: find, replace: replace) {
            throw ToolError.duplicatesFollowingLines(repeated)
        }
        let out = Data(text.replacingOccurrences(of: find, with: replace).utf8)
        try Sandbox.validate(out, path: path)
        try out.write(to: url, options: .atomic)
        return "Patched \(path). New sha: \(Sandbox.blobSHA(out))"
    }

    /// Catches a replace that ends with lines the file already has right after find (find was the
    /// first line of a block, replace the whole block), which would duplicate them.
    static func repeatedTail(text: String, find: String, replace: String) -> String? {
        guard let range = text.range(of: find) else { return nil }
        let following = text[range.upperBound...].split(separator: "\n", omittingEmptySubsequences: true)
            .prefix(3).map { $0.trimmingCharacters(in: .whitespaces) }
        let replaceLines = replace.split(separator: "\n", omittingEmptySubsequences: true).map { $0.trimmingCharacters(in: .whitespaces) }
        let findLines = find.split(separator: "\n", omittingEmptySubsequences: true).count
        guard let first = following.first, first.count >= 3, replaceLines.count > findLines else { return nil }
        // The line that follows find appears in replace after the part that stands in for find.
        return replaceLines.dropFirst(findLines).contains(first) ? first : nil
    }

    /// Where `find`'s non-blank lines appear as consecutive non-blank lines of `text`, compared
    /// without surrounding whitespace. nil unless there's exactly one such place.
    static func looseMatch(_ find: String, in text: String) -> Range<String.Index>? {
        let wanted = find.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !wanted.isEmpty else { return nil }
        // Non-blank lines of the file with their ranges.
        var lines: [(text: String, range: Range<String.Index>)] = []
        var start = text.startIndex
        while start < text.endIndex {
            let end = text[start...].firstIndex(of: "\n") ?? text.endIndex
            let trimmed = text[start..<end].trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { lines.append((trimmed, start..<end)) }
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
        guard let data = try? Data(contentsOf: url) else { throw ToolError.notFound(path) }
        let current = Sandbox.blobSHA(data)
        guard try call.string("sha") == current else { throw ToolError.staleFile(path: path, current: current) }
        var text = String(decoding: data, as: UTF8.self)
        if !text.isEmpty && !text.hasSuffix("\n") { text += "\n" }
        var addition = try call.string("text")
        if !addition.hasSuffix("\n") { addition += "\n" }
        // Keep one blank line between the old end and the addition.
        if !text.isEmpty && !text.hasSuffix("\n\n") && !addition.hasPrefix("\n") { text += "\n" }
        let out = Data((text + addition).utf8)
        try Sandbox.validate(out, path: path)
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
