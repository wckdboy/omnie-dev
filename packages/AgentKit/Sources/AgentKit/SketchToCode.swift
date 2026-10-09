// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

import Foundation
import ModelKit

/// Pencil whiteboard and screenshot → UI code (PLAN.md §11.2): an online vision model reads the
/// image and writes a component in the project's own stack. The files land in a task worktree and
/// come back as a changeset you review, like any agent task.
public enum SketchToCode {
    public enum Source: String, Codable, Sendable {
        /// A drawing from the Pencil whiteboard: boxes, lines and handwriting.
        case sketch
        /// A screenshot or picture of a finished UI to recreate.
        case screenshot
    }

    /// What the model sees of the project.
    public struct Context: Sendable, Equatable {
        /// "React with TypeScript (.tsx)", "SwiftUI", "plain HTML, CSS and JavaScript"…
        public var stack: String
        /// Where new components usually go ("src/components"), if the project has such a folder.
        public var componentsFolder: String?
        /// Project files, relative, at most 200.
        public var files: [String]
        /// Up to two short existing components, so the style matches.
        public var examples: [(path: String, text: String)]

        public static func == (a: Context, b: Context) -> Bool {
            a.stack == b.stack && a.componentsFolder == b.componentsFolder && a.files == b.files
                && a.examples.map(\.path) == b.examples.map(\.path) && a.examples.map(\.text) == b.examples.map(\.text)
        }
    }

    public struct Result: Sendable, Equatable {
        public var files: [File]
        public var summary: String
        public struct File: Sendable, Equatable {
            public var path: String
            public var content: String
        }
    }

    public enum Failure: Error, Equatable, LocalizedError {
        case noFiles
        public var errorDescription: String? { "The model didn't write any files. Try again, or add a line saying what the sketch is." }
    }

    static let skipped: Set<String> = [".git", "node_modules", "dist", "build", ".build", ".venv", "venv", "__pycache__", ".omnie"]
    static let componentExtensions = [".tsx", ".jsx", ".vue", ".svelte", ".swift", ".html"]

    /// Reads the project: its stack (from package.json, Package.swift, tsconfig), files and a
    /// couple of example components.
    public static func context(root: URL) -> Context {
        var files: [String] = []
        let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey])
        while let url = e?.nextObject() as? URL {
            if skipped.contains(url.lastPathComponent) { e?.skipDescendants(); continue }
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            files.append(String(url.standardizedFileURL.path.dropFirst(root.standardizedFileURL.path.count + 1)))
            if files.count >= 400 { break }
        }
        files.sort()
        let has = { (name: String) in files.contains(name) }
        var deps: [String: Any] = [:]
        if let data = try? Data(contentsOf: root.appending(path: "package.json")),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for key in ["dependencies", "devDependencies"] { deps.merge(json[key] as? [String: Any] ?? [:]) { a, _ in a } }
        }
        let typescript = has("tsconfig.json") || deps["typescript"] != nil
        let stack: String
        if deps["react"] != nil || deps["preact"] != nil {
            stack = typescript ? "React with TypeScript (.tsx function components)" : "React (.jsx function components)"
        } else if deps["vue"] != nil {
            stack = "Vue 3 single-file components (.vue, <script setup" + (typescript ? " lang=\"ts\"" : "") + ">)"
        } else if deps["svelte"] != nil {
            stack = "Svelte components (.svelte)"
        } else if has("Package.swift") || files.contains(where: { $0.hasSuffix(".swift") }) {
            stack = "SwiftUI views (.swift)"
        } else {
            stack = "plain HTML, CSS and JavaScript (no framework)"
        }
        let folders = ["src/components", "components", "src/lib/components", "app/components", "Sources/Views", "src"]
        let componentsFolder = folders.first { folder in files.contains { $0.hasPrefix(folder + "/") } }
        var examples: [(String, String)] = []
        for path in files where componentExtensions.contains(where: { path.hasSuffix($0) }) && examples.count < 2 {
            guard let text = try? String(contentsOf: root.appending(path: path), encoding: .utf8), text.utf8.count <= 3_000 else { continue }
            examples.append((path, text))
        }
        return Context(stack: stack, componentsFolder: componentsFolder, files: Array(files.prefix(200)), examples: examples)
    }

    static let system = """
        You turn a picture of a user interface into code for the user's project. Match the project's stack and style. \
        Write complete, working files: no placeholders such as "TODO" or "…", no explanations outside the format. \
        Reply with one or more blocks exactly like
        <file path="relative/path.ext">
        the whole file
        </file>
        and finish with <summary>one sentence: what you built and where</summary>. \
        Prefer one new component file. Change an existing file only when the new component must be shown somewhere \
        (then give that whole file). Never touch package.json, lockfiles or configuration.
        """

    /// The text that goes with the image.
    public static func request(source: Source, instruction: String, context: Context) -> String {
        var text = source == .sketch
            ? "The image is a hand-drawn wireframe from a Pencil whiteboard. Boxes are containers, cards or images; " +
              "lines in a box are text fields or text; a filled or labelled small box is a button. Read the handwriting " +
              "as labels. Lay it out as drawn, cleaned up, with sensible spacing.\n"
            : "The image is a screenshot of an interface. Recreate its layout, text, colors and spacing as closely as the stack allows.\n"
        let note = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        if !note.isEmpty { text += "\nWhat the user says about it: \(note)\n" }
        text += "\nStack: \(context.stack)."
        if let folder = context.componentsFolder { text += " New components go in \(folder)/." }
        text += "\n\nProject files:\n" + (context.files.isEmpty ? "(empty project)" : context.files.joined(separator: "\n"))
        for example in context.examples {
            text += "\n\nAn existing component, for style (\(example.path)):\n```\n\(example.text)\n```"
        }
        return text
    }

    nonisolated(unsafe) static let fileBlock = try! Regex(#"<file path="([^"]+)">\n?((?s).*?)</file>"#, as: (Substring, Substring, Substring).self)
    nonisolated(unsafe) static let fence = try! Regex(#"^\s*```[A-Za-z0-9_+-]*\n((?s).*?)\n?```\s*$"#, as: (Substring, Substring).self)
    nonisolated(unsafe) static let summaryBlock = try! Regex(#"<summary>((?s).*?)</summary>"#, as: (Substring, Substring).self)

    /// The files and summary in a reply.
    public static func parse(_ reply: String) throws -> Result {
        var files: [Result.File] = []
        for match in reply.matches(of: fileBlock) {
            var content = String(match.output.2)
            // A code fence inside the block is wrapping, not content.
            if let fenced = content.firstMatch(of: fence) { content = String(fenced.output.1) }
            if !content.hasSuffix("\n") { content += "\n" }
            let path = String(match.output.1).trimmingCharacters(in: .whitespaces)
            if let i = files.firstIndex(where: { $0.path == path }) { files[i].content = content } else { files.append(.init(path: path, content: content)) }
        }
        guard !files.isEmpty else { throw Failure.noFiles }
        let summary = reply.firstMatch(of: summaryBlock).map { String($0.output.1).trimmingCharacters(in: .whitespacesAndNewlines) }
        return Result(files: files, summary: summary ?? "Built the UI from the image in \(files.map(\.path).joined(separator: ", ")).")
    }

    static let protected: [String] = ["package.json", "package-lock.json", "pnpm-lock.yaml", "yarn.lock", "bun.lockb", ".gitignore"]

    /// Writes the files inside `root` (a task worktree) under the agent's rules: no paths out of
    /// the project or into .git, no configuration, and JS/TS that parses. Returns the paths.
    @discardableResult
    public static func write(_ result: Result, into root: URL) throws -> [String] {
        let sandbox = Sandbox(root: root)
        var written: [String] = []
        for file in result.files {
            let url = try sandbox.resolve(file.path)
            let relative = sandbox.relative(url)
            if protected.contains(relative) || relative.hasPrefix(".github/") { throw ToolError.protectedFile(relative) }
            let data = Data(file.content.utf8)
            try Sandbox.validate(data, path: relative, previous: try? Data(contentsOf: url))
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            written.append(relative)
        }
        return written
    }

    /// The whole step: context, the vision call, parse, write.
    public static func run(model: RemoteModel, image: RemoteModel.Image, source: Source, instruction: String,
                           root: URL) async throws -> (result: Result, written: [String]) {
        let context = context(root: root)
        let reply = try await model.complete(system: system, text: request(source: source, instruction: instruction, context: context),
                                             images: [image], maxTokens: 8_000)
        let result = try parse(reply)
        return (result, try write(result, into: root))
    }
}
