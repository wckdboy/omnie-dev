// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// A file's symbols for go-to-symbol (`@` in the palette) and the outline. Line-pattern based:
/// fast on any file size and good enough to jump around; tree-sitter tag queries can replace it
/// language by language.
public enum Outline {
    public struct Symbol: Sendable, Hashable, Identifiable {
        public enum Kind: String, Sendable { case function, method, `class`, interface, type, `enum`, variable, selector, element }
        public var id: Int { offset }
        public let name: String
        public let kind: Kind
        /// 1-based.
        public let line: Int
        /// UTF-16 offset of the name, for selecting it in the editor.
        public let offset: Int
        public let length: Int
        /// Indentation depth in leading spaces (methods sit inside classes).
        public let indent: Int
    }

    struct Rule {
        let kind: Symbol.Kind
        let regex: NSRegularExpression
        init(_ kind: Symbol.Kind, _ pattern: String) {
            self.kind = kind
            regex = try! NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines])
        }
    }

    static let keywords: Set<String> = ["if", "for", "while", "switch", "catch", "return", "function", "else", "do", "with", "await", "new", "typeof"]

    static let script: [Rule] = [
        Rule(.class, #"^[ \t]*(?:export[ \t]+)?(?:default[ \t]+)?(?:abstract[ \t]+)?class[ \t]+([A-Za-z_$][\w$]*)"#),
        Rule(.interface, #"^[ \t]*(?:export[ \t]+)?interface[ \t]+([A-Za-z_$][\w$]*)"#),
        Rule(.type, #"^[ \t]*(?:export[ \t]+)?type[ \t]+([A-Za-z_$][\w$]*)[^=\n]*="#),
        Rule(.enum, #"^[ \t]*(?:export[ \t]+)?(?:const[ \t]+)?enum[ \t]+([A-Za-z_$][\w$]*)"#),
        Rule(.function, #"^[ \t]*(?:export[ \t]+)?(?:default[ \t]+)?(?:async[ \t]+)?function\*?[ \t]+([A-Za-z_$][\w$]*)"#),
        Rule(.function, #"^[ \t]*(?:export[ \t]+)?(?:const|let|var)[ \t]+([A-Za-z_$][\w$]*)[ \t]*(?::[^=\n]+)?=[ \t]*(?:async[ \t]*)?(?:\([^)\n]*\)|[A-Za-z_$][\w$]*)[ \t]*(?::[^=\n]+)?=>"#),
        Rule(.method, #"^[ \t]+(?:public[ \t]+|private[ \t]+|protected[ \t]+|static[ \t]+|async[ \t]+|readonly[ \t]+|override[ \t]+|get[ \t]+|set[ \t]+)*([A-Za-z_$][\w$]*)[ \t]*(?:<[^>\n]*>)?\([^)\n]*\)[ \t]*(?::[^{\n]+)?\{"#),
    ]

    static let python: [Rule] = [
        Rule(.class, #"^[ \t]*class[ \t]+([A-Za-z_]\w*)"#),
        Rule(.function, #"^[ \t]*(?:async[ \t]+)?def[ \t]+([A-Za-z_]\w*)"#),
    ]

    static let swift: [Rule] = [
        Rule(.class, #"^[ \t]*(?:@\w+[ \t]+)*(?:(?:public|private|fileprivate|internal|open|final|nonisolated)[ \t]+)*(?:class|struct|actor|extension)[ \t]+([A-Za-z_][\w.]*)"#),
        Rule(.interface, #"^[ \t]*(?:(?:public|private|fileprivate|internal)[ \t]+)*protocol[ \t]+([A-Za-z_]\w*)"#),
        Rule(.enum, #"^[ \t]*(?:(?:public|private|fileprivate|internal|indirect)[ \t]+)*enum[ \t]+([A-Za-z_]\w*)"#),
        Rule(.function, #"^[ \t]*(?:@\w+[ \t]+)*(?:(?:public|private|fileprivate|internal|open|static|class|override|mutating|nonisolated|final)[ \t]+)*func[ \t]+([A-Za-z_]\w*|[^\s(]+)"#),
        Rule(.function, #"^[ \t]*(?:(?:public|private|fileprivate|internal|convenience|required|override)[ \t]+)*(init)[?!]?[ \t]*\("#),
    ]

    static let css: [Rule] = [Rule(.selector, #"^([^\s{}@/][^{}\n]*?)[ \t]*\{"#)]
    static let html: [Rule] = [Rule(.element, #"\bid=["']([^"']+)["']"#)]

    public static func symbols(in text: String, language: Language) -> [Symbol] {
        let rules: [Rule] = switch language {
        case .javascript, .typescript, .tsx: script
        case .python: python
        case .swift: swift
        case .css: css
        case .html: html
        case .json: []
        }
        let ns = text as NSString
        var found: [Int: Symbol] = [:]
        for rule in rules {
            for match in rule.regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                let range = match.range(at: 1)
                guard range.location != NSNotFound, found[range.location] == nil else { continue }
                let name = ns.substring(with: range).trimmingCharacters(in: .whitespaces)
                if rule.kind == .method && keywords.contains(name) { continue }
                let lineRange = ns.lineRange(for: NSRange(location: range.location, length: 0))
                let line = ns.substring(to: lineRange.location).reduce(into: 1) { if $1 == "\n" { $0 += 1 } }
                let indent = ns.substring(with: lineRange).prefix { $0 == " " || $0 == "\t" }.count
                found[range.location] = Symbol(name: name, kind: rule.kind, line: line, offset: range.location, length: range.length, indent: indent)
            }
        }
        return found.values.sorted { $0.offset < $1.offset }
    }
}
