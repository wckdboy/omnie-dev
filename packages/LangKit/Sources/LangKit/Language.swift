// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

import Foundation
import TreeSitterGrammars

/// A language Omnie-dev can highlight. Grammars are compiled into the app, so this works offline.
public enum Language: String, CaseIterable, Sendable {
    case javascript, typescript, tsx, json, python, swift, css, html, go, rust, c, cpp, java, markdown, markdownInline

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
        case "go": self = .go
        case "rs": self = .rust
        case "c", "h": self = .c
        case "cpp", "cc", "cxx", "hpp", "hh", "hxx", "ipp": self = .cpp
        case "java": self = .java
        case "md", "markdown": self = .markdown
        default: return nil
        }
    }

    public init?(url: URL) { self.init(fileExtension: url.pathExtension) }

    /// A language by the name a grammar's injection names it — tree-sitter grammar names and the
    /// common aliases a Markdown fence's info string uses ("js", "py", "c++", …). `nil` when we
    /// ship no grammar for it (the fenced text then stays unhighlighted).
    public init?(injectionName name: String) {
        switch name.lowercased() {
        case "javascript", "js", "jsx", "mjs", "cjs": self = .javascript
        case "typescript", "ts": self = .typescript
        case "tsx": self = .tsx
        case "json", "jsonc": self = .json
        case "python", "py": self = .python
        case "swift": self = .swift
        case "css": self = .css
        case "html": self = .html
        case "go": self = .go
        case "rust", "rs": self = .rust
        case "c": self = .c
        case "cpp", "c++", "cc", "cxx": self = .cpp
        case "java": self = .java
        case "markdown", "md": self = .markdown
        case "markdown_inline": self = .markdownInline
        default: return nil
        }
    }

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
        case .go: "Go"
        case .rust: "Rust"
        case .c: "C"
        case .cpp: "C++"
        case .java: "Java"
        case .markdown: "Markdown"
        case .markdownInline: "Markdown (inline)"
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
        case .go: tree_sitter_go()
        case .rust: tree_sitter_rust()
        case .c: tree_sitter_c()
        case .cpp: tree_sitter_cpp()
        case .java: tree_sitter_java()
        case .markdown: tree_sitter_markdown()
        case .markdownInline: tree_sitter_markdown_inline()
        }
    }

    public var highlightsQuery: String? { Self.query("\(rawValue).highlights") }
    public var injectionsQuery: String? { Self.query("\(rawValue).injections") }

    private static func query(_ name: String) -> String? {
        guard let url = Bundle.module.url(forResource: name, withExtension: "scm", subdirectory: "queries") else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }
}
