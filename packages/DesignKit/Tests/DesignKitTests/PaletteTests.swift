// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

import Testing
import SwiftUI
@testable import DesignKit

struct PaletteTests {
    static let themes: [(String, Palette, Double)] = [
        ("dark", .dark, 4.5),
        ("light", .light, 4.5),
        ("highContrast", .highContrast, 7.0),
    ]

    @Test("Every text and syntax color meets its contrast target on the editor surface",
          arguments: ["dark", "light", "highContrast"])
    func contrastTargets(name: String) {
        let (_, palette, target) = Self.themes.first { $0.0 == name }!
        let bg = palette.surface.editor
        let foregrounds: [(String, RGBA)] = [
            ("text.primary", palette.text.primary),
            ("text.secondary", palette.text.secondary),
            ("text.tertiary", palette.text.tertiary),
            ("accent.ion", palette.accent.ion),
            ("accent.agent", palette.accent.agent),
            ("status.ok", palette.status.ok),
            ("status.warn", palette.status.warn),
            ("status.error", palette.status.error),
            ("syntax.comment", palette.syntax.comment),
            ("syntax.keyword", palette.syntax.keyword),
            ("syntax.string", palette.syntax.string),
            ("syntax.number", palette.syntax.number),
            ("syntax.function", palette.syntax.function),
            ("syntax.type", palette.syntax.type),
        ]
        for (role, fg) in foregrounds {
            #expect(fg.contrast(against: bg) >= target, "\(name).\(role) is \(fg.contrast(against: bg))")
        }
    }

    /// Labels read on any surface, not just the editor's: tertiary text on the raised/chrome/pane
    /// surfaces must meet AA too (the Colors tool flags the brand file for exactly this). The accent
    /// roles are text too — a link, a selected row, the status strip's branch — and the CI runner's
    /// simulator caught the light theme's ion at 4.41:1 on chrome.
    @Test("Text roles meet their contrast target on every surface",
          arguments: ["dark", "light", "highContrast"])
    func textOnEverySurface(name: String) {
        let (_, palette, target) = Self.themes.first { $0.0 == name }!
        let surfaces: [(String, RGBA)] = [
            ("chrome", palette.surface.chrome), ("editor", palette.surface.editor),
            ("pane", palette.surface.pane), ("raised", palette.surface.raised),
        ]
        let text: [(String, RGBA)] = [
            ("text.primary", palette.text.primary),
            ("text.secondary", palette.text.secondary),
            ("text.tertiary", palette.text.tertiary),
            ("accent.ion", palette.accent.ion),
            ("accent.agent", palette.accent.agent),
        ]
        for (surface, bg) in surfaces {
            for (role, fg) in text {
                #expect(fg.contrast(against: bg) >= target, "\(name).\(role) on \(surface) is \(fg.contrast(against: bg))")
            }
        }
    }

    /// A bordered button's text sits on its own tint at about 18% (measured from a light-theme
    /// screenshot: pane #F5F5F3 under ion #00748D gave #C9DEE1), not on a surface. At 4.5:1 that fill
    /// is the tightest place an accent is read; it is why light `accent.ion` is #006174, not #00748D.
    @Test("Accent text meets AA on a bordered control's tinted fill",
          arguments: ["dark", "light", "highContrast"])
    func accentOnTintedControl(name: String) {
        let (_, palette, target) = Self.themes.first { $0.0 == name }!
        let surfaces: [(String, RGBA)] = [
            ("chrome", palette.surface.chrome), ("editor", palette.surface.editor),
            ("pane", palette.surface.pane), ("raised", palette.surface.raised),
        ]
        for (surface, background) in surfaces {
            // 20% covers the 18% a `.bordered` button draws, with room for a runtime's rounding.
            let fill = background.mixed(with: palette.accent.ion, fraction: 0.2)
            #expect(palette.accent.ion.contrast(against: fill) >= target,
                    "\(name).accent.ion on its tinted fill over \(surface) is \(palette.accent.ion.contrast(against: fill))")
        }
    }

    @Test("Contrast math matches the ratios published in PLAN.md §3.3")
    func matchesPublishedRatios() {
        let cases: [(RGBA, RGBA, Double)] = [
            (Palette.dark.text.primary, Palette.dark.surface.editor, 15.16),
            (Palette.dark.accent.agent, Palette.dark.surface.editor, 8.46),
            (Palette.light.accent.ion, Palette.light.surface.editor, 6.85),
            (Palette.highContrast.status.error, Palette.highContrast.surface.editor, 9.25),
        ]
        for (fg, bg, expected) in cases {
            #expect(abs(fg.contrast(against: bg) - expected) < 0.01)
        }
    }

    @Test("Syntax highlighting never uses the agent violet")
    func syntaxAvoidsAgentColor() {
        for (_, p, _) in Self.themes {
            let syntax = [p.syntax.plain, p.syntax.comment, p.syntax.punctuation, p.syntax.keyword,
                          p.syntax.string, p.syntax.number, p.syntax.function, p.syntax.type]
            #expect(!syntax.contains(p.accent.agent))
        }
    }

    @Test func resolveFollowsSystemAppearance() {
        #expect(Palette.resolve(colorScheme: .dark, contrast: .standard) == .dark)
        #expect(Palette.resolve(colorScheme: .dark, contrast: .increased) == .highContrast)
        #expect(Palette.resolve(colorScheme: .light, contrast: .standard) == .light)
        let lightIncreased = Palette.resolve(colorScheme: .light, contrast: .increased)
        #expect(lightIncreased.text.secondary == Palette.light.text.primary)
    }

    @Test func layoutBreakpoints() {
        #expect(LayoutClass(width: 699) == .single)
        #expect(LayoutClass(width: 700) == .split)
        #expect(LayoutClass(width: 1100) == .split)
        #expect(LayoutClass(width: 1101) == .full)
    }
}
