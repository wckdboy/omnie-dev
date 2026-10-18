// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing
import TreeSitter
@testable import LangKit

struct LanguageTests {
    static let samples: [Language: String] = [
        .javascript: "const x = () => <div>{1}</div>;\n",
        .typescript: "interface A { b: number }\nconst a: A = { b: 1 };\n",
        .tsx: "const C = (p: { n: string }) => <b>{p.n}</b>;\n",
        .json: "{\"a\": [1, true, null]}\n",
        .python: "def f(x: int) -> int:\n    return x + 1\n",
        .swift: "struct S { let x: Int }\nfunc f() async throws -> S { S(x: 1) }\n",
        .css: ".a > b { color: #fff; }\n",
        .html: "<p class=\"x\">Hi <b>there</b></p>\n",
        .go: "package m\n\nfunc Add(a, b int) int { return a + b }\n\ntype Point struct{ X int }\n",
        .rust: "pub struct P { x: i32 }\npub fn f(p: &P) -> i32 { p.x }\nenum E { A }\n",
        .c: "static int add(int a, int b) { return a + b; }\nstruct P { int x; };\n",
        .cpp: "#include <vector>\nclass P { public: int x; };\nint add(int a, int b) { return a + b; }\n",
        .java: "package p;\n\npublic class C {\n    private final int x = 1;\n    int add(int a, int b) { return a + b; }\n}\n",
        .markdown: "# Title\n\nSome *text* with `code`.\n\n```java\nint x = 1;\n```\n",
        .markdownInline: "Some **bold** and a [link](x) with `code`.\n",
    ]

    @Test("Each grammar loads in the tree-sitter runtime and parses without errors", arguments: Language.allCases)
    func parses(_ language: Language) throws {
        let parser = ts_parser_new()
        defer { ts_parser_delete(parser) }
        #expect(ts_parser_set_language(parser, language.grammar))
        let source = try #require(Self.samples[language])
        let tree = try #require(ts_parser_parse_string(parser, nil, source, UInt32(source.utf8.count)))
        defer { ts_tree_delete(tree) }
        let root = ts_tree_root_node(tree)
        #expect(!ts_node_has_error(root), "\(String(cString: ts_node_string(root)))")
    }

    @Test("Each highlights query compiles against its grammar", arguments: Language.allCases)
    func highlightsQueryCompiles(_ language: Language) throws {
        let source = try #require(language.highlightsQuery)
        var errorOffset: UInt32 = 0
        var errorType = TSQueryErrorNone
        let query = ts_query_new(language.grammar, source, UInt32(source.utf8.count), &errorOffset, &errorType)
        defer { ts_query_delete(query) }
        #expect(query != nil, "query error \(errorType.rawValue) at byte \(errorOffset)")
        #expect(ts_query_capture_count(query) > 0)
    }

    @Test func detectsByExtension() {
        #expect(Language(fileExtension: "TS") == .typescript)
        #expect(Language(fileExtension: "tsx") == .tsx)
        #expect(Language(fileExtension: "mjs") == .javascript)
        #expect(Language(fileExtension: "go") == .go)
        #expect(Language(fileExtension: "rs") == .rust)
        #expect(Language(fileExtension: "c") == .c && Language(fileExtension: "h") == .c)
        #expect(Language(fileExtension: "cpp") == .cpp && Language(fileExtension: "hpp") == .cpp)
        #expect(Language(fileExtension: "java") == .java)
        #expect(Language(fileExtension: "md") == .markdown && Language(fileExtension: "markdown") == .markdown)
        #expect(Language(fileExtension: "txt") == nil)
    }

    @Test func detectsInjectedLanguagesByName() {
        #expect(Language(injectionName: "java") == .java)
        #expect(Language(injectionName: "js") == .javascript && Language(injectionName: "JavaScript") == .javascript)
        #expect(Language(injectionName: "c++") == .cpp && Language(injectionName: "python") == .python)
        #expect(Language(injectionName: "markdown_inline") == .markdownInline)
        #expect(Language(injectionName: "yaml") == nil, "no grammar for it; the fence stays plain")
    }

    @Test func knowsItsIndentationRules() {
        #expect(Language.javascript.indentationRules?.indent.contains("statement_block") == true)
        #expect(Language.javascript.indentationRules?.outdent.contains("}") == true)
        #expect(Language.python.indentationRules?.whitespaceDenotesBlocks == true)
        #expect(Language.json.indentationRules?.indent.contains("object") == true)
        #expect(Language.markdown.indentationRules == nil, "no rules; a line break keeps the indent")
    }
}
