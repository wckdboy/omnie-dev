// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

import DesignKit
import Runestone
import UIKit

extension RGBA {
    var uiColor: UIColor { UIColor(red: red, green: green, blue: blue, alpha: alpha) }
}

/// Maps tree-sitter capture names onto the few syntax roles the brand colors (PLAN §3.3).
/// Violet is never used for syntax; it belongs to agent work.
public enum SyntaxRole: String, CaseIterable, Sendable {
    case plain, comment, punctuation, keyword, string, number, function, type

    /// "function.method.call" → function; unknown captures stay plain.
    public init(capture: String) {
        var parts = capture.split(separator: ".").map(String.init)
        while !parts.isEmpty {
            if let role = Self.table[parts.joined(separator: ".")] {
                self = role
                return
            }
            parts.removeLast()
        }
        self = .plain
    }

    private static let table: [String: SyntaxRole] = [
        "comment": .comment,
        "punctuation": .punctuation, "operator": .punctuation, "delimiter": .punctuation,
        "keyword": .keyword, "conditional": .keyword, "repeat": .keyword, "include": .keyword,
        "exception": .keyword, "storageclass": .keyword, "label": .keyword,
        "string": .string, "character": .string, "escape": .string, "string.special": .string,
        "number": .number, "float": .number, "boolean": .number, "constant": .number,
        "constant.builtin": .number,
        "function": .function, "method": .function, "constructor": .function, "attribute": .function,
        "type": .type, "class": .type, "interface": .type, "namespace": .type, "module": .type, "tag": .type,
    ]

    func color(in palette: Palette) -> RGBA {
        switch self {
        case .plain: palette.syntax.plain
        case .comment: palette.syntax.comment
        case .punctuation: palette.syntax.punctuation
        case .keyword: palette.syntax.keyword
        case .string: palette.syntax.string
        case .number: palette.syntax.number
        case .function: palette.syntax.function
        case .type: palette.syntax.type
        }
    }
}

/// Runestone theme built from DesignKit tokens.
public final class EditorTheme: Runestone.Theme {
    public let palette: Palette
    public let density: Density

    // Built once: the engine reads these for every visible line on every layout pass, and building a
    // UIFont or UIColor per read showed up in device profiles of typing.
    public let font: UIFont
    public let textColor: UIColor
    public let gutterBackgroundColor: UIColor
    public let gutterHairlineColor: UIColor
    public let lineNumberColor: UIColor
    public let lineNumberFont: UIFont
    public let selectedLineBackgroundColor: UIColor
    public let selectedLinesLineNumberColor: UIColor
    public let selectedLinesGutterBackgroundColor: UIColor
    public let invisibleCharactersColor: UIColor
    public let pageGuideHairlineColor: UIColor
    public let pageGuideBackgroundColor: UIColor
    public let markedTextBackgroundColor: UIColor
    private let roleColors: [SyntaxRole: UIColor]

    public init(palette: Palette, density: Density) {
        self.palette = palette
        self.density = density
        // Monaspace Neon isn't bundled yet; SF Mono stands in (PLAN §3.4 fallback).
        font = .monospacedSystemFont(ofSize: density.codeSize, weight: .regular)
        textColor = palette.syntax.plain.uiColor
        gutterBackgroundColor = palette.surface.editor.uiColor
        gutterHairlineColor = palette.surface.hairline.uiColor
        lineNumberColor = palette.text.tertiary.uiColor
        lineNumberFont = .monospacedDigitSystemFont(ofSize: max(density.codeSize - 2, 11), weight: .regular)
        selectedLineBackgroundColor = palette.surface.pane.uiColor
        selectedLinesLineNumberColor = palette.text.secondary.uiColor
        selectedLinesGutterBackgroundColor = palette.surface.pane.uiColor
        invisibleCharactersColor = palette.text.tertiary.uiColor.withAlphaComponent(0.5)
        pageGuideHairlineColor = palette.surface.hairline.uiColor
        pageGuideBackgroundColor = palette.surface.pane.uiColor
        markedTextBackgroundColor = palette.surface.selection.uiColor
        roleColors = Dictionary(uniqueKeysWithValues: SyntaxRole.allCases.map { ($0, $0.color(in: palette).uiColor) })
    }

    public func textColor(for highlightName: String) -> UIColor? {
        let role = SyntaxRole(capture: highlightName)
        return role == .plain ? nil : roleColors[role]
    }
}
