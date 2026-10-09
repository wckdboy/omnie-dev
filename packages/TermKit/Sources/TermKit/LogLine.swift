// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// The log viewer's reading of an output line (PLAN.md §11.1): where it points in the project,
/// whether it's an error, and JSON shown readably.
public enum LogLine {
    public struct Location: Equatable, Sendable {
        public let path: String
        public let line: Int
        public let column: Int?
    }

    /// The first project location a line names: `src/a.ts:3:7`, `at f (omnie-run://local/src/a.ts:3:7)`,
    /// Python's `File "app/x.py", line 12`. `exists` says whether a project path is real.
    public static func location(in text: String, exists: (String) -> Bool) -> Location? {
        if let m = text.firstMatch(of: /File "([^"]+)", line (\d+)/) {
            let path = clean(String(m.1))
            if exists(path) { return Location(path: path, line: Int(m.2)!, column: nil) }
        }
        for m in text.matches(of: /((?:omnie-run:\/\/local)?\/?[A-Za-z0-9_.\-\/]+\.[A-Za-z0-9]+):(\d+)(?::(\d+))?/) {
            let path = clean(String(m.1))
            guard !path.isEmpty, exists(path), let line = Int(m.2) else { continue }
            return Location(path: path, line: line, column: m.3.flatMap { Int($0) })
        }
        return nil
    }

    static func clean(_ raw: String) -> String {
        var p = raw
        for prefix in ["omnie-run://local/", "/project/", "/"] where p.hasPrefix(prefix) { p.removeFirst(prefix.count) }
        while p.hasPrefix("./") { p.removeFirst(2) }
        return p
    }

    /// Error-looking output: a stderr line, a failed test, a TypeScript or Python error, a stack frame.
    public static func isError(_ text: String) -> Bool {
        text.hasPrefix("! ") || text.hasPrefix("✗") || text.contains("error TS") || text.hasPrefix("Traceback")
            || text.contains("Error:") || text.hasPrefix("Uncaught") || text.hasPrefix("Exited with") || text.hasPrefix("Stopped")
            || text.range(of: #"^\s+at .+[:(]\d+"#, options: .regularExpression) != nil
    }

    /// A JSON object or array line, pretty-printed; nil if the line isn't JSON.
    public static func prettyJSON(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard (trimmed.hasPrefix("{") && trimmed.hasSuffix("}")) || (trimmed.hasPrefix("[") && trimmed.hasSuffix("]")),
              let value = try? JSONSerialization.jsonObject(with: Data(trimmed.utf8)),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}
