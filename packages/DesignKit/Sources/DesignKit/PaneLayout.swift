// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Where the IDE's panels live around the editor: three docks (left, right, bottom), each a stack
/// of tab groups. Any panel can move to any group or dock, groups and docks resize, and a panel
/// can be closed and brought back. Panels are named by string (the app's panel ids), so this
/// stays a plain value the app persists and the tests check.
public struct PaneLayout: Codable, Equatable, Sendable {
    public enum Dock: String, Codable, CaseIterable, Sendable {
        case left, right, bottom
    }

    public struct Group: Codable, Equatable, Identifiable, Sendable {
        public var id: UUID
        public var panels: [String]
        public var selected: String
        /// Share of the dock's length (height for side docks, width for the bottom one).
        public var weight: Double

        public init(id: UUID = UUID(), panels: [String], selected: String? = nil, weight: Double = 1) {
            self.id = id
            self.panels = panels
            self.selected = selected ?? panels.first ?? ""
            self.weight = weight
        }
    }

    public var left: [Group]
    public var right: [Group]
    public var bottom: [Group]
    public var leftWidth: Double
    public var rightWidth: Double
    public var bottomHeight: Double
    /// Docks you've hidden (they keep their panels).
    public var hidden: Set<Dock>
    /// The side dock shown last, which wins when only one side fits.
    public var lastSide: Dock

    public static let defaultLeftWidth = 260.0
    public static let defaultRightWidth = 380.0
    public static let defaultBottomHeight = 240.0
    public static let minSideWidth = 200.0
    public static let minBottomHeight = 120.0

    public init(left: [Group], right: [Group], bottom: [Group], leftWidth: Double = defaultLeftWidth,
                rightWidth: Double = defaultRightWidth, bottomHeight: Double = defaultBottomHeight,
                hidden: Set<Dock> = [], lastSide: Dock = .right) {
        self.left = left; self.right = right; self.bottom = bottom
        self.leftWidth = leftWidth; self.rightWidth = rightWidth; self.bottomHeight = bottomHeight
        self.hidden = hidden; self.lastSide = lastSide
    }

    // MARK: Reading

    public subscript(dock: Dock) -> [Group] {
        get {
            switch dock {
            case .left: left
            case .right: right
            case .bottom: bottom
            }
        }
        set {
            switch dock {
            case .left: left = newValue
            case .right: right = newValue
            case .bottom: bottom = newValue
            }
        }
    }

    /// Which dock and group a panel is in, or nil when it's closed.
    public func location(of panel: String) -> (dock: Dock, group: Int)? {
        for dock in Dock.allCases {
            if let i = self[dock].firstIndex(where: { $0.panels.contains(panel) }) { return (dock, i) }
        }
        return nil
    }

    /// Whether a panel is on screen: in a shown dock and selected in its group.
    public func isShowing(_ panel: String) -> Bool {
        guard let (dock, i) = location(of: panel) else { return false }
        return !hidden.contains(dock) && self[dock][i].selected == panel
    }

    public func isVisible(_ dock: Dock) -> Bool { !hidden.contains(dock) && !self[dock].isEmpty }

    /// The side docks that fit next to an editor at least `minEditor` wide: both when they fit,
    /// else the one shown last (then the other), else none.
    public func fittingSides(width: Double, minEditor: Double) -> Set<Dock> {
        let wanted = [Dock.left, .right].filter { isVisible($0) }
        if wanted.count == 2, leftWidth + rightWidth + minEditor <= width { return [.left, .right] }
        let order: [Dock] = lastSide == .left ? [.left, .right] : [.right, .left]
        for dock in order where wanted.contains(dock) && size(dock) + minEditor <= width { return [dock] }
        return []
    }

    /// Panels in no group, in `all`'s order.
    public func closed(from all: [String]) -> [String] { all.filter { location(of: $0) == nil } }

    // MARK: Changing

    /// Shows a panel: selects it in its group and shows its dock. A closed panel comes back in the
    /// first group of the right dock (or a new one).
    public mutating func reveal(_ panel: String) {
        if location(of: panel) == nil {
            if right.isEmpty { right = [Group(panels: [panel])] } else { right[0].panels.append(panel) }
        }
        guard let (dock, i) = location(of: panel) else { return }
        self[dock][i].selected = panel
        hidden.remove(dock)
        if dock != .bottom { lastSide = dock }
    }

    /// Hides or shows a dock.
    public mutating func toggle(_ dock: Dock) {
        if hidden.contains(dock) || self[dock].isEmpty {
            hidden.remove(dock)
            if dock != .bottom { lastSide = dock }
        } else {
            hidden.insert(dock)
        }
    }

    /// Takes a panel out of the layout; empty groups go with it.
    public mutating func close(_ panel: String) {
        guard let (dock, i) = location(of: panel) else { return }
        var group = self[dock][i]
        let index = group.panels.firstIndex(of: panel)!
        group.panels.remove(at: index)
        if group.panels.isEmpty {
            self[dock].remove(at: i)
        } else {
            if group.selected == panel { group.selected = group.panels[max(0, index - 1)] }
            self[dock][i] = group
        }
    }

    /// Moves a panel into an existing group (selected there), at `index` or the end.
    public mutating func move(_ panel: String, toGroup id: UUID, at index: Int? = nil) {
        guard location(of: panel) != nil, find(id) != nil else { return }
        let sameGroup = location(of: panel).map { self[$0.dock][$0.group].id == id } ?? false
        if sameGroup {
            // Reordering inside a group.
            guard let (dock, g) = find(id), let from = self[dock][g].panels.firstIndex(of: panel) else { return }
            self[dock][g].panels.remove(at: from)
            let to = min(max(0, (index ?? self[dock][g].panels.count) - (index.map { $0 > from ? 1 : 0 } ?? 0)), self[dock][g].panels.count)
            self[dock][g].panels.insert(panel, at: to)
            self[dock][g].selected = panel
            return
        }
        close(panel)
        guard let (dock, g) = find(id) else { return }
        let to = min(index ?? self[dock][g].panels.count, self[dock][g].panels.count)
        self[dock][g].panels.insert(panel, at: to)
        self[dock][g].selected = panel
        hidden.remove(dock)
    }

    /// Moves a panel (or brings a closed one) into a new group of its own in `dock`, at
    /// `position` or the end.
    public mutating func move(_ panel: String, toNewGroupIn dock: Dock, at position: Int? = nil) {
        // Splitting a panel off its own one-panel group in the same dock changes nothing.
        if let (d, g) = location(of: panel), d == dock, self[d][g].panels.count == 1, position == nil { return }
        close(panel)
        let group = Group(panels: [panel], weight: self[dock].isEmpty ? 1 : self[dock].map(\.weight).reduce(0, +) / Double(self[dock].count))
        self[dock].insert(group, at: min(position ?? self[dock].count, self[dock].count))
        hidden.remove(dock)
        if dock != .bottom { lastSide = dock }
    }

    /// Resizes the boundary after group `index` in `dock` by `delta` of the dock's length (in
    /// points, out of `length`), keeping both neighbours at least `minimum` points.
    public mutating func resizeGroups(in dock: Dock, after index: Int, by delta: Double, length: Double, minimum: Double = 80) {
        var groups = self[dock]
        guard groups.indices.contains(index + 1), length > 0 else { return }
        let total = groups.map(\.weight).reduce(0, +)
        var a = groups[index].weight / total * length, b = groups[index + 1].weight / total * length
        let pair = a + b
        a = min(max(a + delta, minimum), pair - minimum)
        b = pair - a
        groups[index].weight = a / length * total
        groups[index + 1].weight = b / length * total
        self[dock] = groups
    }

    /// Sets a dock's size (width for the sides, height for the bottom), clamped.
    public mutating func setSize(_ dock: Dock, _ value: Double, maximum: Double) {
        switch dock {
        case .left: leftWidth = min(max(value, Self.minSideWidth), max(Self.minSideWidth, maximum))
        case .right: rightWidth = min(max(value, Self.minSideWidth), max(Self.minSideWidth, maximum))
        case .bottom: bottomHeight = min(max(value, Self.minBottomHeight), max(Self.minBottomHeight, maximum))
        }
    }

    public func size(_ dock: Dock) -> Double {
        switch dock {
        case .left: leftWidth
        case .right: rightWidth
        case .bottom: bottomHeight
        }
    }

    /// Puts a dock back to its default size.
    public mutating func resetSize(_ dock: Dock) {
        switch dock {
        case .left: leftWidth = Self.defaultLeftWidth
        case .right: rightWidth = Self.defaultRightWidth
        case .bottom: bottomHeight = Self.defaultBottomHeight
        }
        self[dock] = self[dock].map { var g = $0; g.weight = 1; return g }
    }

    /// Drops groups left empty and selections that point nowhere (after decoding an old layout,
    /// or when the app no longer has a panel).
    public mutating func repair(known: [String]) {
        var seen: Set<String> = []
        for dock in Dock.allCases {
            self[dock] = self[dock].compactMap { group in
                var group = group
                group.panels = group.panels.filter { known.contains($0) && seen.insert($0).inserted }
                guard !group.panels.isEmpty else { return nil }
                if !group.panels.contains(group.selected) { group.selected = group.panels[0] }
                if !(group.weight > 0) { group.weight = 1 }
                return group
            }
        }
    }

    private func find(_ id: UUID) -> (dock: Dock, group: Int)? {
        for dock in Dock.allCases {
            if let i = self[dock].firstIndex(where: { $0.id == id }) { return (dock, i) }
        }
        return nil
    }
}
