// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Indentation rules for the engine's tree-sitter indent controller (Runestone's
/// `TreeSitterIndentationScopes`): the node types that open a block — so the next line gets one more
/// level — the closure nodes that keep their parent's level ("else", "catch") and the nodes that
/// close a block. Node types match the grammar's own names; one that doesn't exist in a grammar
/// simply never matches.
public struct IndentationRules: Sendable, Equatable {
    public var indent: [String]
    public var inheritIndent: [String]
    public var outdent: [String]
    /// Python and YAML: whitespace denotes blocks, so the controller searches for the deepest node
    /// around the caret instead of only the ones it is inside.
    public var whitespaceDenotesBlocks: Bool

    public init(indent: [String], inheritIndent: [String] = [], outdent: [String], whitespaceDenotesBlocks: Bool = false) {
        self.indent = indent
        self.inheritIndent = inheritIndent
        self.outdent = outdent
        self.whitespaceDenotesBlocks = whitespaceDenotesBlocks
    }
}

public extension Language {
    /// How a line break indents in this language, or `nil` when there are no rules (Markdown). The
    /// node types follow the grammar's own names: `indent` lists the block-opening nodes and `outdent`
    /// the closing tokens ("}", "]", "end_tag") — the convention the engine's tests use.
    var indentationRules: IndentationRules? {
        switch self {
        case .javascript, .typescript, .tsx:
            return IndentationRules(indent: ["array", "object", "arguments", "statement_block", "class_body",
                                             "parenthesized_expression", "jsx_element", "jsx_opening_element",
                                             "jsx_expression", "switch_body", "named_imports"],
                                    outdent: ["else", "}", "]"])
        case .json:
            return IndentationRules(indent: ["object", "array"], outdent: ["}", "]"])
        case .python:
            return IndentationRules(indent: ["function_definition", "for_statement", "class_definition",
                                             "elif_clause", "else_clause", "except_clause", "while_statement",
                                             "if_statement", "try_statement"],
                                    outdent: [], whitespaceDenotesBlocks: true)
        case .html:
            return IndentationRules(indent: ["start_tag", "element"], outdent: ["end_tag"])
        case .swift:
            return IndentationRules(indent: ["class_body", "protocol_body", "enum_class_body", "statements"], outdent: ["}"])
        case .go:
            return IndentationRules(indent: ["block", "literal_value", "field_declaration_list", "import_spec_list"],
                                    outdent: ["}", "]"])
        case .rust:
            return IndentationRules(indent: ["block", "declaration_list", "field_declaration_list",
                                             "enum_variant_list", "match_block", "use_list"],
                                    outdent: ["}", "]"])
        case .c, .cpp:
            return IndentationRules(indent: ["compound_statement", "field_declaration_list", "enumerator_list",
                                             "initializer_list"],
                                    outdent: ["}", "]"])
        case .java:
            return IndentationRules(indent: ["block", "class_body", "constructor_body", "array_initializer", "switch_block"],
                                    outdent: ["}", "]"])
        case .css:
            return IndentationRules(indent: ["block"], outdent: ["}"])
        case .markdown, .markdownInline:
            return nil
        }
    }
}
