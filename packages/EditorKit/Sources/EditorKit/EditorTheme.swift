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

    public init(palette: Palette, density: Density) {
        self.palette = palette
        self.density = density
    }

    /// Monaspace Neon isn't bundled yet; SF Mono stands in (PLAN §3.4 fallback).
    public var font: UIFont { .monospacedSystemFont(ofSize: density.codeSize, weight: .regular) }
    public var textColor: UIColor { palette.syntax.plain.uiColor }
    public var gutterBackgroundColor: UIColor { palette.surface.editor.uiColor }
    public var gutterHairlineColor: UIColor { palette.surface.hairline.uiColor }
    public var lineNumberColor: UIColor { palette.text.tertiary.uiColor }
    public var lineNumberFont: UIFont { .monospacedDigitSystemFont(ofSize: max(density.codeSize - 2, 11), weight: .regular) }
    public var selectedLineBackgroundColor: UIColor { palette.surface.pane.uiColor }
    public var selectedLinesLineNumberColor: UIColor { palette.text.secondary.uiColor }
    public var selectedLinesGutterBackgroundColor: UIColor { palette.surface.pane.uiColor }
    public var invisibleCharactersColor: UIColor { palette.text.tertiary.uiColor.withAlphaComponent(0.5) }
    public var pageGuideHairlineColor: UIColor { palette.surface.hairline.uiColor }
    public var pageGuideBackgroundColor: UIColor { palette.surface.pane.uiColor }
    public var markedTextBackgroundColor: UIColor { palette.surface.selection.uiColor }

    public func textColor(for highlightName: String) -> UIColor? {
        let role = SyntaxRole(capture: highlightName)
        return role == .plain ? nil : role.color(in: palette).uiColor
    }
}
