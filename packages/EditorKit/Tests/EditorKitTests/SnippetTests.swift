// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing
@testable import EditorKit

struct SnippetTests {
    /// Marks stops with «» so expectations read like the snippet.
    func marked(_ expansion: SnippetExpansion) -> String {
        let ns = expansion.text as NSString
        var out = ns as String
        for stop in expansion.stops.sorted(by: { $0.range.location > $1.range.location }) {
            let r = NSRange(location: stop.range.location, length: stop.range.length)
            out = (out as NSString).replacingCharacters(in: r, with: "«\(ns.substring(with: r))»")
        }
        return out
    }

    @Test func expandsSimpleStops() {
        let s = SnippetExpansion("if ($1) {\n  $2\n}")
        #expect(s.text == "if () {\n  \n}")
        #expect(s.stops.map(\.index) == [1, 2])
        #expect(s.stops.map(\.range) == [NSRange(location: 4, length: 0), NSRange(location: 10, length: 0)])
    }

    @Test func expandsDefaultsAndChoices() {
        let defaults = SnippetExpansion("const ${1:name} = ${2:value};")
        #expect(defaults.text == "const name = value;")
        #expect(defaults.stops.map(\.range) == [NSRange(location: 6, length: 4), NSRange(location: 13, length: 5)])
        #expect(marked(defaults) == "const «name» = «value»;")

        let choices = SnippetExpansion("color: ${1|red,green,blue|};")
        #expect(choices.text == "color: red;")
        #expect(choices.stops.map(\.range) == [NSRange(location: 7, length: 3)])
    }

    @Test func dollarZeroComesLastAndSetsTheCaret() {
        let s = SnippetExpansion("try {\n  $1\n} finally {\n  $0\n}")
        #expect(s.stops.map(\.index) == [1, 0])
        #expect(s.stops.last?.range == NSRange(location: 23, length: 0))
        #expect(s.trailingCaret == 23)
    }

    @Test func escapesAreLiteral() {
        let s = SnippetExpansion("cost: \\$5, brace: \\}, dollar: $$")
        #expect(s.text == "cost: $5, brace: }, dollar: $")
        #expect(s.stops.isEmpty)
    }

    @Test func namedVariablesBecomeText() {
        let s = SnippetExpansion("file ${FILE_NAME:index}")
        #expect(s.text == "file index")
        #expect(s.stops.isEmpty)
    }

    @Test func indentsEveryNewLine() {
        let s = SnippetExpansion("if ($1) {\n  $2\n}", indent: "    ")
        #expect(s.text == "if () {\n      \n    }")
        #expect(s.stops.map(\.range) == [NSRange(location: 4, length: 0), NSRange(location: 14, length: 0)])
    }

    @Test func mirrorsKeepTheFirstStop() {
        let s = SnippetExpansion("${1:x} and ${1:x}")
        #expect(s.text == "x and x")
        #expect(s.stops.map(\.index) == [1])
        #expect(s.stops.map(\.range) == [NSRange(location: 0, length: 1)])
    }

    @Test func rangesMoveWithEdits() {
        var session = SnippetSession(stops: [.init(index: 1, range: NSRange(location: 4, length: 0)),
                                            .init(index: 2, range: NSRange(location: 11, length: 0))], trailingCaret: 20)
        // Type "abc" at the first stop: it takes the typed text, the second moves three to the right.
        session.adjust(forEdit: NSRange(location: 4, length: 0), replacementLength: 3)
        #expect(session.stops.map(\.range) == [NSRange(location: 4, length: 3), NSRange(location: 14, length: 0)])
        // Replacing the second stop opens it over the new text.
        session.adjust(forEdit: NSRange(location: 14, length: 0), replacementLength: 2)
        #expect(session.stops.map(\.range) == [NSRange(location: 4, length: 3), NSRange(location: 14, length: 2)])
        // Deleting before a stop pulls it back.
        session.adjust(forEdit: NSRange(location: 0, length: 2), replacementLength: 0)
        #expect(session.stops.map(\.range) == [NSRange(location: 2, length: 3), NSRange(location: 12, length: 2)])
    }

    @Test func tabWalksTheStopsAndFinishes() {
        var session = SnippetSession(stops: [.init(index: 1, range: NSRange(location: 4, length: 3)),
                                             .init(index: 2, range: NSRange(location: 9, length: 0))], trailingCaret: 12)
        #expect(session.previous() == nil)
        #expect(session.next() == NSRange(location: 9, length: 0))
        #expect(session.next() == NSRange(location: 12, length: 0))
        #expect(session.isDone)
        #expect(session.next() == nil)
        #expect(session.previous() == NSRange(location: 9, length: 0))
    }

    @Test func offsetAdjustment() {
        let edit = NSRange(location: 10, length: 2)
        #expect(5.adjustedOffset(forEdit: edit, replacementLength: 0) == 5)
        #expect(12.adjustedOffset(forEdit: edit, replacementLength: 0) == 10)
        #expect(11.adjustedOffset(forEdit: edit, replacementLength: 3) == 13)
    }
}
