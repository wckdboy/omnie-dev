// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing
@testable import EditorKit

struct BracketTests {
    func match(_ marked: String) -> String? {
        // "|" marks the caret.
        let caret = (marked as NSString).range(of: "|").location
        let text = marked.replacingOccurrences(of: "|", with: "") as NSString
        guard let (a, b) = Brackets.match(in: text, caret: caret) else { return nil }
        return "\(a),\(b)"
    }

    @Test func findsThePartner() {
        #expect(match("f(a, (b))|") == "1,8")       // after the closing paren
        #expect(match("f|(a, (b))") == "1,8")       // before the opening one
        #expect(match("{ x: [1, 2]| }") == "5,10")
        #expect(match("if (a) {\n  b()\n}|") == "7,15")
        #expect(match("abc|") == nil)
        #expect(match("(unclosed|") == nil)
    }

    @Test func skipsBracketsInStrings() {
        #expect(match("f(\")\", 'x(')|") == "1,11")
        #expect(match("s = \"(|\"") == nil)          // a bracket inside a string doesn't match
        #expect(match("g(`[`)|") == "1,5")
    }
}
