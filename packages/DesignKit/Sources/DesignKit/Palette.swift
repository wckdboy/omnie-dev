// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

import SwiftUI

/// A packed sRGB color, 0xRRGGBBAA.
public struct RGBA: Sendable, Hashable {
    public let value: UInt32

    public init(_ value: UInt32) { self.value = value }

    public var red: Double { Double((value >> 24) & 0xFF) / 255 }
    public var green: Double { Double((value >> 16) & 0xFF) / 255 }
    public var blue: Double { Double((value >> 8) & 0xFF) / 255 }
    public var alpha: Double { Double(value & 0xFF) / 255 }

    public var color: Color { Color(.sRGB, red: red, green: green, blue: blue, opacity: alpha) }

    /// WCAG 2.x relative luminance (alpha ignored).
    public var relativeLuminance: Double {
        func channel(_ c: Double) -> Double {
            c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(red) + 0.7152 * channel(green) + 0.0722 * channel(blue)
    }

    /// WCAG 2.x contrast ratio between two opaque colors.
    public func contrast(against other: RGBA) -> Double {
        let (a, b) = (relativeLuminance, other.relativeLuminance)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }
}

public struct SurfaceColors: Sendable, Hashable {
    public var chrome, editor, pane, raised, hairline, selection: RGBA
}

public struct TextColors: Sendable, Hashable {
    public var primary, secondary, tertiary: RGBA
}

public struct AccentColors: Sendable, Hashable {
    /// Human work: focus, caret, selection, links.
    public var ion: RGBA
    /// Reserved for agent-authored work. Never used for syntax.
    public var agent: RGBA
    public var focusRing: RGBA
}

public struct StatusColors: Sendable, Hashable {
    public var ok, warn, error: RGBA
}

public struct SyntaxColors: Sendable, Hashable {
    public var plain, comment, punctuation, keyword, string, number, function, type: RGBA
}

public struct DiffColors: Sendable, Hashable {
    public var addedBg, addedWordBg, removedBg, removedWordBg: RGBA
}

/// One complete color theme. The three built-in themes are generated from design/tokens.json.
public struct Palette: Sendable, Hashable {
    public var surface: SurfaceColors
    public var text: TextColors
    public var accent: AccentColors
    public var status: StatusColors
    public var syntax: SyntaxColors
    public var diff: DiffColors

    /// Picks the theme for the system appearance.
    /// High contrast is a dark theme. Light with Increase Contrast promotes secondary text to primary.
    public static func resolve(colorScheme: ColorScheme, contrast: ColorSchemeContrast) -> Palette {
        switch (colorScheme, contrast) {
        case (.dark, .increased):
            return .highContrast
        case (.light, .increased):
            var p = Palette.light
            p.text.secondary = p.text.primary
            return p
        case (.light, _):
            return .light
        default:
            return .dark
        }
    }
}

public extension EnvironmentValues {
    @Entry var palette: Palette = .dark
}
