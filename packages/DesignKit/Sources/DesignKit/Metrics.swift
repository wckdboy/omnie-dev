// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

import SwiftUI

/// Density follows the hands: compact with keyboard + trackpad, touch without a hardware keyboard.
public enum Density: String, Sendable, CaseIterable {
    case compact, regular, touch

    public var row: CGFloat { switch self { case .compact: 24; case .regular: 28; case .touch: 44 } }
    public var tab: CGFloat { switch self { case .compact: 30; case .regular: 34; case .touch: 44 } }
    public var statusStrip: CGFloat { switch self { case .compact: 22; case .regular: 24; case .touch: 28 } }
    public var hitTarget: CGFloat { switch self { case .compact: 28; case .regular: 32; case .touch: 44 } }
    public var codeSize: CGFloat { switch self { case .compact: 13; case .regular: 14; case .touch: 16 } }
    public var codeLineHeight: CGFloat { switch self { case .compact: 20; case .regular: 22; case .touch: 24 } }
}

/// Window-width layout classes for the iPad IDE.
public enum LayoutClass: Sendable {
    /// Under 700 pt: one pane, the others as overlays.
    case single
    /// 700 to 1100 pt: editor plus one side pane.
    case split
    /// Over 1100 pt: navigator, editor and utility pane.
    case full

    public init(width: CGFloat) {
        if width < Metrics.splitBreakpoint { self = .single }
        else if width <= Metrics.fullBreakpoint { self = .split }
        else { self = .full }
    }
}

public enum Metrics {
    public static let unit: CGFloat = 4
    public static let hairline: CGFloat = 1
    public static let focusStroke: CGFloat = 2
    public static let minEditorWidth: CGFloat = 480
    public static let splitBreakpoint: CGFloat = 700
    public static let fullBreakpoint: CGFloat = 1100
    public static let paletteWidth: CGFloat = 640

    public enum Radius {
        public static let xs: CGFloat = 4
        public static let sm: CGFloat = 6
        public static let md: CGFloat = 10
        public static let lg: CGFloat = 14
    }
}

public enum Motion {
    public static let micro: Duration = .milliseconds(80)
    public static let short: Duration = .milliseconds(140)
    public static let palette: Duration = .milliseconds(120)
    public static let agentBreathe: Duration = .milliseconds(1200)

    /// Pane transitions: critically damped, no bounce.
    public static let pane: Animation = .spring(response: 0.25, dampingFraction: 1.0)
    public static let paletteIn: Animation = .easeOut(duration: 0.12)
}

public enum Typography {
    /// Code font. Monaspace Neon is not bundled yet, so this falls back to SF Mono.
    public static func code(_ density: Density) -> Font {
        .system(size: density.codeSize, design: .monospaced)
    }

    /// Agent-authored prose. Monaspace Xenon once bundled; SF Mono italic until then.
    public static func agent(_ density: Density) -> Font {
        .system(size: density.codeSize, design: .monospaced).italic()
    }
}

public extension EnvironmentValues {
    @Entry var density: Density = .regular
}

/// The agent's voice (mono italic at the code size) that also follows Dynamic Type; `otherwise`
/// is the font when the text isn't the agent's.
public struct AgentVoice: ViewModifier {
    @Environment(\.dynamicTypeSize) private var typeSize
    let density: Density
    let isAgent: Bool
    let otherwise: Font

    public func body(content: Content) -> some View {
        content.font(isAgent ? Self.font(density, typeSize) : otherwise)
    }

    static func font(_ density: Density, _ typeSize: DynamicTypeSize) -> Font {
        #if canImport(UIKit)
        let traits = UITraitCollection(preferredContentSizeCategory: UIContentSizeCategory(typeSize))
        let size = UIFontMetrics(forTextStyle: .body).scaledValue(for: density.codeSize, compatibleWith: traits)
        #else
        let size = density.codeSize
        #endif
        return .system(size: size, design: .monospaced).italic()
    }
}

public extension View {
    func agentVoice(_ density: Density, when isAgent: Bool = true, otherwise: Font = .body) -> some View {
        modifier(AgentVoice(density: density, isAgent: isAgent, otherwise: otherwise))
    }
}
