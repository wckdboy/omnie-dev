// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

import DesignKit
import Foundation
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

@MainActor
struct EditorMarkTests {
    @Test func marksUseBrandColorsAndAgentIsViolet() {
        let palette = Palette.dark
        let agent = EditorMark(range: NSRange(location: 0, length: 1), kind: .agentLines).decoration(in: palette)
        guard case .gutterBar(let color) = agent.style else { Issue.record("agent lines should be a gutter bar"); return }
        #expect(color == palette.accent.agent.uiColor)
        let error = EditorMark(range: NSRange(location: 0, length: 1), kind: .error).decoration(in: palette)
        guard case .squiggle(let red) = error.style else { Issue.record("errors should squiggle"); return }
        #expect(red == palette.status.error.uiColor)
    }

    @Test func themeChangeRecolorsMarksAndKeepsLiveRanges() {
        let controller = CodeEditorController(theme: EditorTheme(palette: .dark, density: .regular))
        controller.textView.text = "let alpha = beta;\n"
        controller.setMarks([
            EditorMark(id: "w", range: NSRange(location: 12, length: 4), kind: .warning),
            EditorMark(id: "e", range: NSRange(location: 4, length: 5), kind: .error),
        ])
        controller.textView.replace(NSRange(location: 0, length: 0), withText: "// x\n")
        controller.theme = EditorTheme(palette: .light, density: .regular)
        let byID = Dictionary(uniqueKeysWithValues: controller.textView.decorations.map { ($0.id, $0) })
        #expect(byID["w"]?.range == NSRange(location: 17, length: 4))
        #expect(byID["e"]?.range == NSRange(location: 9, length: 5))
        guard case .dottedUnderline(let amber) = byID["w"]?.style else { Issue.record("warning style"); return }
        #expect(amber == Palette.light.status.warn.uiColor)
    }
}
