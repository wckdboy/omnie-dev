// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// How much human approval a command needs before it runs. See PLAN.md §12.
public enum PolicyTier: Int, Sendable, Comparable, CaseIterable {
    /// Project reads, scratch writes, sandboxed runs with no network.
    case auto
    /// Shows the exact diff, command or URL and waits for a tap.
    case ask
    /// Ask, plus Face ID: deletes, push, secrets, deploy.
    case askBiometric

    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

/// Which experiences a command shows up in.
public struct Surfaces: OptionSet, Sendable, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    /// The full IDE on iPad.
    public static let ide = Surfaces(rawValue: 1 << 0)
    /// The vibecoding experience on iPhone.
    public static let vibe = Surfaces(rawValue: 1 << 1)
    public static let all: Surfaces = [.ide, .vibe]
}

/// A keyboard shortcut, independent of UIKit/SwiftUI so the registry stays testable.
public struct Shortcut: Sendable, Hashable, CustomStringConvertible {
    public struct Modifiers: OptionSet, Sendable, Hashable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let control = Modifiers(rawValue: 1 << 0)
        public static let option = Modifiers(rawValue: 1 << 1)
        public static let shift = Modifiers(rawValue: 1 << 2)
        public static let command = Modifiers(rawValue: 1 << 3)
    }

    public let key: String
    public let modifiers: Modifiers

    public init(_ key: String, _ modifiers: Modifiers = .command) {
        self.key = key
        self.modifiers = modifiers
    }

    /// macOS-style glyph order: ⌃⌥⇧⌘ then the key.
    public var description: String {
        var s = ""
        if modifiers.contains(.control) { s += "⌃" }
        if modifiers.contains(.option) { s += "⌥" }
        if modifiers.contains(.shift) { s += "⇧" }
        if modifiers.contains(.command) { s += "⌘" }
        switch key {
        case "\r": s += "↩"
        case "\t": s += "⇥"
        case " ": s += "Space"
        default: s += key.uppercased()
        }
        return s
    }
}

public struct CommandID: RawRepresentable, Hashable, Sendable, ExpressibleByStringLiteral, CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }
    public var description: String { rawValue }
}

/// Every action in Omnie-dev is a command: the palette, the menu bar, the hold-⌘ overlay
/// and the agent's tools all read from the same registry.
public struct Command: Identifiable, Sendable {
    public let id: CommandID
    /// Verb first, sentence case: "Push 3 commits", "Toggle focus mode".
    public let title: String
    /// Menu-bar grouping, e.g. "File", "View", "Git".
    public let menu: String
    public let shortcut: Shortcut?
    public let tier: PolicyTier
    public let surfaces: Surfaces
    /// Extra words the palette matches on.
    public let keywords: [String]
    public let perform: @MainActor @Sendable () -> Void

    public init(
        id: CommandID,
        title: String,
        menu: String,
        shortcut: Shortcut? = nil,
        tier: PolicyTier = .auto,
        surfaces: Surfaces = .all,
        keywords: [String] = [],
        perform: @escaping @MainActor @Sendable () -> Void
    ) {
        self.id = id
        self.title = title
        self.menu = menu
        self.shortcut = shortcut
        self.tier = tier
        self.surfaces = surfaces
        self.keywords = keywords
        self.perform = perform
    }
}
