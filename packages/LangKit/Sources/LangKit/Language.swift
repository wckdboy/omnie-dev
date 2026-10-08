// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

import Foundation
import TreeSitterGrammars

/// A language Omnie-dev can highlight. Grammars are compiled into the app, so this works offline.
public enum Language: String, CaseIterable, Sendable {
    case javascript, typescript, tsx, json, python, swift, css, html

    /// Picks a language by file extension; nil for plain text.
    public init?(fileExtension ext: String) {
        switch ext.lowercased() {
        case "js", "mjs", "cjs", "jsx": self = .javascript
        case "ts", "mts", "cts": self = .typescript
        case "tsx": self = .tsx
        case "json", "jsonc", "webmanifest": self = .json
        case "py", "pyi": self = .python
        case "swift": self = .swift
        case "css": self = .css
        case "html", "htm": self = .html
        default: return nil
        }
    }

    public init?(url: URL) { self.init(fileExtension: url.pathExtension) }

    public var displayName: String {
        switch self {
        case .javascript: "JavaScript"
        case .typescript: "TypeScript"
        case .tsx: "TSX"
        case .json: "JSON"
        case .python: "Python"
        case .swift: "Swift"
        case .css: "CSS"
        case .html: "HTML"
        }
    }

    /// The tree-sitter language (`const TSLanguage *`).
    public var grammar: OpaquePointer {
        switch self {
        case .javascript: tree_sitter_javascript()
        case .typescript: tree_sitter_typescript()
        case .tsx: tree_sitter_tsx()
        case .json: tree_sitter_json()
        case .python: tree_sitter_python()
        case .swift: tree_sitter_swift()
        case .css: tree_sitter_css()
        case .html: tree_sitter_html()
        }
    }

    public var highlightsQuery: String? { Self.query("\(rawValue).highlights") }
    public var injectionsQuery: String? { Self.query("\(rawValue).injections") }

    private static func query(_ name: String) -> String? {
        guard let url = Bundle.module.url(forResource: name, withExtension: "scm", subdirectory: "queries") else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }
}
