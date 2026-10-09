// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

import Foundation
import ModelKit

/// Agent proposals in the conflict resolver (PLAN.md §9.7, P3): the model reads each conflict
/// block (both sides and the lines around it) and writes the merged lines. You review the result
/// before completing the merge; nothing is written until then.
public enum MergeProposer {
    /// One conflict: both sides and a few lines either side.
    public struct Conflict: Sendable, Hashable {
        public let ours: [String]
        public let theirs: [String]
        public let before: [String]
        public let after: [String]
        public init(ours: [String], theirs: [String], before: [String], after: [String]) {
            self.ours = ours; self.theirs = theirs; self.before = before; self.after = after
        }
    }

    static let system = """
        You resolve git merge conflicts. You get one conflict: the lines just before it, "yours" (the current branch), \
        "theirs" (the incoming branch) and the lines just after it. Write the lines that should replace the conflict so \
        the code keeps the intent of both sides: keep both changes when they're compatible, combine them when they \
        touch the same thing, and prefer yours only when they truly contradict. Reply with the merged lines in one \
        ``` code block and nothing else. Don't repeat the lines before or after, and never write conflict markers.
        """

    public static func prompt(path: String, block: Conflict) -> ModelPrompt {
        func fence(_ lines: [String]) -> String { "```\n" + lines.joined(separator: "\n") + "\n```" }
        let user = """
            File: \(path)

            Before the conflict:
            \(fence(block.before))

            Yours:
            \(fence(block.ours))

            Theirs:
            \(fence(block.theirs))

            After the conflict:
            \(fence(block.after))
            """
        return .chat(system: system, user: user)
    }

    /// The merged lines from a reply: the first code block, or the whole reply. Nil if it still
    /// has conflict markers.
    public static func parse(_ reply: String) -> String? {
        var text = reply
        if let open = reply.range(of: "```") {
            let afterOpen = reply[open.upperBound...]
            let body = afterOpen.drop { $0 != "\n" }.dropFirst()  // skip a language tag
            if let close = body.range(of: "```") { text = String(body[..<close.lowerBound]) } else { text = String(body) }
        }
        while text.hasSuffix("\n") { text.removeLast() }
        let markers = text.split(separator: "\n", omittingEmptySubsequences: false)
            .contains { $0.hasPrefix("<<<<<<< ") || $0 == "=======" || $0.hasPrefix(">>>>>>> ") }
        guard !markers else { return nil }
        return text
    }

    /// Small models often repeat the context they were shown: drop lines at the start that repeat
    /// the end of "before", and lines at the end that repeat the start of "after".
    static func trimContext(_ text: String, _ conflict: Conflict) -> String {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        func same(_ a: String, _ b: String) -> Bool { a.trimmingCharacters(in: .whitespaces) == b.trimmingCharacters(in: .whitespaces) }
        let after = conflict.after.drop { $0.trimmingCharacters(in: .whitespaces).isEmpty }
        // Where a run of lines matching the start of `after` (blank lines skipped) begins.
        for start in lines.indices where !after.isEmpty && same(lines[start], after.first!) {
            var i = start, j = after.startIndex
            while i < lines.count, j < after.endIndex, same(lines[i], after[j]) { i += 1; j += 1 }
            if i == lines.count, j - after.startIndex >= min(2, after.count) {
                lines.removeSubrange(start...)
                while lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true, conflict.ours.last?.isEmpty != true { lines.removeLast() }
                break
            }
        }
        // Lines at the start that are the tail of `before`.
        let before = conflict.before.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        for n in stride(from: min(before.count, lines.count), through: 1, by: -1)
        where n >= min(2, before.count) && zip(lines.prefix(n), before.suffix(n)).allSatisfy({ same($0, $1) }) {
            lines.removeFirst(n)
            break
        }
        return lines.joined(separator: "\n")
    }

    /// Proposes merged lines for each conflict; nil where the model didn't give usable ones.
    public static func propose(path: String, conflicts: [Conflict], model: any TextModel, maxTokensPerBlock: Int = 1024) async throws -> [String?] {
        var resolutions: [String?] = []
        for conflict in conflicts {
            try Task.checkCancellation()
            let reply = try await model.complete(prompt(path: path, block: conflict), maxTokens: maxTokensPerBlock)
            resolutions.append(parse(reply).map { trimContext($0, conflict) })
        }
        return resolutions
    }
}
