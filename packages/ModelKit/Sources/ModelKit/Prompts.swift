// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Fill-in-the-middle prompts for ghost text (PLAN.md §7, Tiny pack).
public enum FIM {
    /// Qwen2.5-Coder's FIM format. Keeps the end of the prefix and the start of the suffix,
    /// cut at line boundaries, so the prompt stays small enough for a fast first token.
    public static func qwen(prefix: String, suffix: String, maxPrefix: Int = 6_000, maxSuffix: Int = 2_000) -> String {
        "<|fim_prefix|>\(tail(prefix, maxPrefix))<|fim_suffix|>\(head(suffix, maxSuffix))<|fim_middle|>"
    }

    /// Small models often finish the gap and keep going, re-typing the code after the cursor and
    /// beyond. Cuts the completion where it starts repeating the suffix's first line, and drops
    /// trailing whitespace.
    public static func trim(_ completion: String, suffix: String) -> String {
        var result = completion
        let anchor = suffix.split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty }
        if let anchor {
            var offset = result.startIndex
            for line in result.split(separator: "\n", omittingEmptySubsequences: false) {
                if line.trimmingCharacters(in: .whitespaces) == anchor {
                    result = String(result[..<offset])
                    break
                }
                offset = result.index(line.endIndex, offsetBy: 1, limitedBy: result.endIndex) ?? result.endIndex
            }
        }
        while let last = result.last, last.isWhitespace { result.removeLast() }
        return result
    }

    public static let qwenStops = ["<|endoftext|>", "<|fim_pad|>", "<|file_sep|>", "<|im_end|>", "<|fim_prefix|>", "<|fim_suffix|>", "<|fim_middle|>"]

    static func tail(_ text: String, _ limit: Int) -> String {
        guard text.count > limit else { return text }
        let cut = text.suffix(limit)
        // Start at the next full line.
        return cut.firstIndex(of: "\n").map { String(cut[cut.index(after: $0)...]) } ?? String(cut)
    }

    static func head(_ text: String, _ limit: Int) -> String {
        guard text.count > limit else { return text }
        let cut = text.prefix(limit)
        return cut.lastIndex(of: "\n").map { String(cut[...$0]) } ?? String(cut)
    }
}

/// Commit-message drafts from the local model (PLAN.md §9.3; P2: "AI commit messages run on the local model").
public enum CommitDraft {
    public struct Change: Sendable, Hashable {
        public let path: String
        /// "added", "modified", "deleted", "renamed".
        public let kind: String
        public init(path: String, kind: String) {
            self.path = path
            self.kind = kind
        }
    }

    public static let system = """
        You write git commit messages. Reply with exactly one line: an imperative summary of the change, \
        at most 72 characters, no trailing period, no quotes, no prefix like "Commit message:".
        """

    /// The user turn: the file list, then added lines per file within a character budget.
    public static func prompt(changes: [Change], added: [(path: String, text: String)], budget: Int = 3_000) -> String {
        var out = "Changed files:\n"
        for change in changes.prefix(40) { out += "- \(change.kind) \(change.path)\n" }
        if changes.count > 40 { out += "- …and \(changes.count - 40) more\n" }
        var remaining = budget
        var byFile: [String: [String]] = [:]
        var order: [String] = []
        for line in added where !line.text.trimmingCharacters(in: .whitespaces).isEmpty {
            if byFile[line.path] == nil { order.append(line.path) }
            byFile[line.path, default: []].append(line.text)
        }
        if !order.isEmpty { out += "\nAdded lines:\n" }
        for path in order {
            guard remaining > 0 else { break }
            let header = "\(path):\n"
            out += header
            remaining -= header.count
            for text in byFile[path]!.prefix(30) {
                let line = "+ \(text.prefix(160))\n"
                guard remaining - line.count > 0 else { remaining = 0; break }
                out += line
                remaining -= line.count
            }
        }
        out += "\nWrite the commit message."
        return out
    }

    /// Turns model output into a subject line, or nil if there's nothing usable.
    public static func clean(_ raw: String) -> String? {
        let fence = CharacterSet(charactersIn: "`\"'“”‘’*")
        guard var line = raw.split(whereSeparator: \.isNewline)
            .map({ $0.trimmingCharacters(in: .whitespaces) })
            .first(where: { !$0.isEmpty && !$0.hasPrefix("```") }) else { return nil }
        for prefix in ["commit message:", "commit:", "message:", "subject:", "summary:", "- ", "* "] {
            if line.lowercased().hasPrefix(prefix) { line = String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces) }
        }
        line = line.trimmingCharacters(in: fence).trimmingCharacters(in: .whitespaces)
        while line.hasSuffix(".") { line.removeLast() }
        if let first = line.first, first.isLowercase, !line.contains(":") { line = first.uppercased() + line.dropFirst() }
        if line.count > 72 {
            let cut = line.prefix(72)
            line = cut.lastIndex(of: " ").map { String(cut[..<$0]) } ?? String(cut)
        }
        return line.count >= 3 ? line : nil
    }
}
