// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

#if DEBUG
import AgentKit
import Foundation
import ModelKit

/// A real agent task (worktree, tools, policy, journal, review) driven by a scripted model, for
/// checking the agent UI in the simulator. `-OmnieAgentDemo` with a git project open.
@MainActor
enum AgentDemo {
    final class Script: TextModel, @unchecked Sendable {
        var replies: [String]
        init(_ replies: [String]) { self.replies = replies }
        func stream(_ prompt: ModelPrompt, maxTokens: Int, temperature: Float) async throws -> AsyncThrowingStream<String, Error> {
            let reply = replies.isEmpty ? "" : replies.removeFirst()
            try await Task.sleep(for: .milliseconds(400))
            return AsyncThrowingStream { c in
                c.yield(reply)
                c.finish()
            }
        }
    }

    static func call(_ name: String, _ args: [String: String]) -> String {
        let json = (try? JSONSerialization.data(withJSONObject: args, options: [.sortedKeys])).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        return "<tool_call>\n{\"name\": \"\(name)\", \"arguments\": \(json)}\n</tool_call>"
    }

    static func run(_ app: AppModel) async {
        guard let root = app.workspace.rootURL else { print("[demo] open a project first"); return }
        let readme = (try? Data(contentsOf: root.appending(path: "README.md"))) ?? Data()
        let sha = Sandbox.blobSHA(readme)
        let partial = ProcessInfo.processInfo.arguments.contains("-OmnieAgentDemoPartial")
        let readmeText = String(decoding: readme, as: UTF8.self)
        let firstLine = readmeText.split(separator: "\n").first.map(String.init) ?? ""
        app.agent.modelOverride = Script(partial ? [
            call("read", ["path": "README.md"]),
            call("patch", ["path": "README.md", "sha": sha, "find": firstLine, "replace": firstLine + " (renamed by the agent)"]),
            "Adding a Usage section at the end.\n" + call("read", ["path": "README.md"]),
            "<<APPEND>>",
            call("finish", ["summary": "Renamed the title and added a Usage section."]),
            call("finish", ["summary": "Renamed the title and added a Usage section."]),
        ] : [
            "I'll look at the README first.\n" + call("read", ["path": "README.md"]),
            "Adding a Usage section at the end.\n" + call("append_to_file", ["path": "README.md", "sha": sha,
                                                                             "text": "## Usage\n\nRun `npm start`, then open http://localhost:3000.\n"]),
            call("finish", ["summary": "Added a Usage section to README.md."]),
            call("finish", ["summary": "Added a Usage section to README.md."]),
        ])
        if partial, let script = app.agent.modelOverride as? Script, let i = script.replies.firstIndex(of: "<<APPEND>>") {
            // The append needs the sha after the first patch: compute it from the patched text.
            let patched = readmeText.replacingOccurrences(of: firstLine, with: firstLine + " (renamed by the agent)")
            script.replies[i] = call("append_to_file", ["path": "README.md", "sha": Sandbox.blobSHA(Data(patched.utf8)),
                                                        "text": "## Usage\n\nRun `npm start`.\n"])
        }
        await app.agent.start("Add a Usage section to the README")
        if partial { app.agent.rejected["README.md"] = [0] }
        print("[demo] phase \(app.agent.current?.phase.rawValue ?? "none"), \(app.agent.changes.count) changed file(s)")
        if ProcessInfo.processInfo.arguments.contains("-OmnieAgentDemoAccept") {
            try? await Task.sleep(for: .seconds(2))
            await app.agent.accept()
            let log = (try? await app.workspace.git.repo?.log(limit: 3)) ?? []
            print("[demo] after accept: phase \(app.agent.current?.phase.rawValue ?? "none"), error \(app.agent.error ?? "none")")
            for commit in log { print("[demo] commit \(commit.id.short) \(commit.summary.debugDescription) by \(commit.authorName)") }
            if let head = log.first { print("[demo] message:\n\(head.message)") }
        }
    }
}
#endif
