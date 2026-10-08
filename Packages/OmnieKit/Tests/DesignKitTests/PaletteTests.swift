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

    @Test("Contrast math matches the ratios published in PLAN.md §3.3")
    func matchesPublishedRatios() {
        let cases: [(RGBA, RGBA, Double)] = [
            (Palette.dark.text.primary, Palette.dark.surface.editor, 15.16),
            (Palette.dark.accent.agent, Palette.dark.surface.editor, 8.46),
            (Palette.light.accent.ion, Palette.light.surface.editor, 4.82),
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
