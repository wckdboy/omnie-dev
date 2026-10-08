// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

import DesignKit
import Testing
@testable import EditorKit

struct SyntaxRoleTests {
    @Test func mapsCapturesByLongestPrefix() {
        #expect(SyntaxRole(capture: "function.method.call") == .function)
        #expect(SyntaxRole(capture: "keyword.return") == .keyword)
        #expect(SyntaxRole(capture: "string.special.regex") == .string)
        #expect(SyntaxRole(capture: "constant.builtin") == .number)
        #expect(SyntaxRole(capture: "variable") == .plain)
        #expect(SyntaxRole(capture: "type.builtin") == .type)
    }

    @Test func syntaxNeverUsesAgentViolet() {
        for palette in [Palette.dark, .light, .highContrast] {
            for role in SyntaxRole.allCases {
                #expect(role.color(in: palette) != palette.accent.agent)
            }
        }
    }
}
