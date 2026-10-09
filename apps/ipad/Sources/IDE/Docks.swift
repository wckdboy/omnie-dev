// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

import SwiftUI
import UniformTypeIdentifiers
import DesignKit

/// Starting arrangements; everything can be moved from there.
enum LayoutPreset: String, CaseIterable, Identifiable {
    case standard, terminalBelow, previewBeside, focusRight

    var id: Self { self }

    var title: String {
        switch self {
        case .standard: "Standard"
        case .terminalBelow: "Terminal below"
        case .previewBeside: "Preview beside, terminal below"
        case .focusRight: "Everything on the right"
        }
    }

    var layout: PaneLayout {
        typealias G = PaneLayout.Group
        let id = { (tabs: [UtilityTab]) in tabs.map(\.rawValue) }
        switch self {
        case .standard:
            return PaneLayout(left: [G(panels: id([.files]))],
                              right: [G(panels: id([.agent, .timeline, .terminal, .preview, .stage, .tools]))], bottom: [])
        case .terminalBelow:
            return PaneLayout(left: [G(panels: id([.files]))],
                              right: [G(panels: id([.agent, .timeline, .preview, .stage, .tools]))],
                              bottom: [G(panels: id([.terminal]))])
        case .previewBeside:
            return PaneLayout(left: [G(panels: id([.files, .timeline]))],
                              right: [G(panels: id([.preview, .stage]), weight: 3), G(panels: id([.agent, .tools]), weight: 2)],
                              bottom: [G(panels: id([.terminal]))], lastSide: .right)
        case .focusRight:
            return PaneLayout(left: [],
                              right: [G(panels: id([.files, .timeline]), weight: 2), G(panels: id([.agent, .terminal, .preview, .stage, .tools]), weight: 3)],
                              bottom: [], rightWidth: 420)
        }
    }
}

/// One dock: its groups stacked (sides) or side by side (bottom), with resize handles between.
struct DockView: View {
    @Environment(AppModel.self) private var model
    let dock: PaneLayout.Dock

    var body: some View {
        let groups = model.panes[dock]
        GeometryReader { geo in
            let length = dock == .bottom ? geo.size.width : geo.size.height
            let handles = CGFloat(max(0, groups.count - 1)) * ResizeHandle.thickness
            let total = groups.map(\.weight).reduce(0, +)
            let layout = dock == .bottom ? AnyLayout(HStackLayout(spacing: 0)) : AnyLayout(VStackLayout(spacing: 0))
            layout {
                ForEach(Array(groups.enumerated()), id: \.element.id) { index, group in
                    let share = total > 0 ? group.weight / total : 1
                    let size = max(0, (length - handles) * share)
                    GroupView(group: group, dock: dock)
                        .frame(width: dock == .bottom ? size : nil, height: dock == .bottom ? nil : size)
                    if index < groups.count - 1 {
                        ResizeHandle(axis: dock == .bottom ? .horizontal : .vertical, label: "Resize \(group.selected) group") { delta in
                            model.panes.resizeGroups(in: dock, after: index, by: delta, length: Double(length - handles))
                        } reset: {
                            model.panes[dock] = model.panes[dock].map { var g = $0; g.weight = 1; return g }
                        }
                    }
                }
            }
        }
    }
}

/// A tab group: its tab bar (drag tabs between groups, or use their menus) and the selected panel.
struct GroupView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var palette
    @Environment(\.density) private var density
    let group: PaneLayout.Group
    let dock: PaneLayout.Dock
    @State private var targeted = false

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geo in
                // Names when they fit, icons alone when the group is narrow.
                let named = geo.size.width / CGFloat(max(group.panels.count, 1)) >= 92
                HStack(spacing: 0) {
                    ForEach(group.panels, id: \.self) { id in
                        if let tab = UtilityTab(rawValue: id) { tabButton(tab, named: named) }
                    }
                    groupMenu
                }
            }
            .frame(height: density.tab)
            .background(palette.surface.pane.color)
            .overlay(alignment: .bottom) { Rectangle().fill(palette.surface.hairline.color).frame(height: Metrics.hairline) }
            .dropDestination(for: String.self) { items, _ in
                drop(items, at: nil)
            } isTargeted: { targeted = $0 }

            if let tab = UtilityTab(rawValue: group.selected) {
                PanelContent(tab: tab)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .overlay {
            if targeted {
                RoundedRectangle(cornerRadius: 6).stroke(palette.accent.ion.color, lineWidth: 2).padding(2).allowsHitTesting(false)
            }
        }
        .background(palette.surface.pane.color)
    }

    private func tabButton(_ tab: UtilityTab, named: Bool) -> some View {
        let selected = group.selected == tab.rawValue
        return Button {
            withAnimation(Motion.pane) { model.panes.reveal(tab.rawValue) }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: tab.symbol)
                if named { Text(tab.rawValue).font(.caption).lineLimit(1) }
            }
            .frame(maxWidth: .infinity, minHeight: density.tab)
            .foregroundStyle(selected ? palette.accent.ion.color : palette.text.secondary.color)
            .overlay(alignment: .bottom) {
                if selected { Rectangle().fill(palette.accent.ion.color).frame(height: Metrics.focusStroke) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
        .accessibilityLabel(tab.rawValue)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityHint("Its menu moves it to another dock")
        .modifier(PanelDrag(tab: tab))
        .dropDestination(for: String.self) { items, _ in
            drop(items, at: group.panels.firstIndex(of: tab.rawValue))
        }
        .contextMenu { PanelMenu(tab: tab, dock: dock) }
    }

    /// Closed panels come back here; the layout presets.
    private var groupMenu: some View {
        Menu {
            let closed = model.panes.closed(from: UtilityTab.allCases.map(\.rawValue)).compactMap(UtilityTab.init(rawValue:))
            if !closed.isEmpty {
                Section("Add to this group") {
                    ForEach(closed) { tab in
                        Button { withAnimation(Motion.pane) { model.panes.reveal(tab.rawValue); model.panes.move(tab.rawValue, toGroup: group.id) } } label: {
                            Label(tab.rawValue, systemImage: tab.symbol)
                        }
                    }
                }
            }
            Section("Layout") {
                ForEach(LayoutPreset.allCases) { preset in
                    Button(preset.title) { model.applyLayout(preset) }
                }
                Button("Hide this dock") { model.toggle(dock) }
            }
        } label: {
            Image(systemName: "ellipsis")
                .frame(width: 32, height: density.tab)
                .foregroundStyle(palette.text.secondary.color)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("Group options")
    }

    private func drop(_ items: [String], at index: Int?) -> Bool {
        guard let id = items.first, UtilityTab(rawValue: id) != nil else { return false }
        withAnimation(Motion.pane) { model.panes.move(id, toGroup: group.id, at: index) }
        model.draggingPanel = nil
        return true
    }
}

/// Tabs drag to other groups and docks. UI tests leave it off (`-OmnieNoPanelDrag`): with a drag
/// interaction on the same view, XCTest waits a minute for the context menu's animations.
private struct PanelDrag: ViewModifier {
    @Environment(AppModel.self) private var model
    let tab: UtilityTab
    static let enabled = !ProcessInfo.processInfo.arguments.contains("-OmnieNoPanelDrag")

    func body(content: Content) -> some View {
        if Self.enabled {
            content
                .draggable(tab.rawValue) {
                    // Built when a drag starts: the dock edges offer themselves as drop targets until a
                    // drop (drag sessions don't tell SwiftUI about a cancel, so they also give up later).
                    Label(tab.rawValue, systemImage: tab.symbol)
                        .padding(8)
                        .onAppear {
                            model.draggingPanel = tab
                            Task { @MainActor in
                                try? await Task.sleep(for: .seconds(12))
                                if model.draggingPanel == tab { model.draggingPanel = nil }
                            }
                        }
                }
        } else {
            content
        }
    }
}

/// A panel's menu: move it to another dock or a group of its own, or close it.
struct PanelMenu: View {
    @Environment(AppModel.self) private var model
    let tab: UtilityTab
    let dock: PaneLayout.Dock

    var body: some View {
        let id = tab.rawValue
        Section("Move \(tab.rawValue) to") {
            ForEach(PaneLayout.Dock.allCases, id: \.self) { target in
                Button {
                    withAnimation(Motion.pane) { model.panes.move(id, toNewGroupIn: target) }
                } label: {
                    Label(target == dock ? "Its own group here" : "\(target.rawValue.capitalized) dock", systemImage: target.symbol)
                }
            }
            // Joining another group directly.
            ForEach(PaneLayout.Dock.allCases, id: \.self) { target in
                ForEach(model.panes[target].filter { !$0.panels.contains(id) }) { other in
                    Button("Beside \(other.panels.joined(separator: ", ")) (\(target.rawValue))") {
                        withAnimation(Motion.pane) { model.panes.move(id, toGroup: other.id) }
                    }
                }
            }
        }
        Button(role: .destructive) {
            withAnimation(Motion.pane) { model.panes.close(id) }
        } label: {
            Label("Close \(tab.rawValue)", systemImage: "xmark")
        }
    }
}

/// A draggable boundary: a hairline with a wider grip. Double-tap puts the default size back;
/// VoiceOver adjusts it with swipes.
struct ResizeHandle: View {
    @Environment(\.palette) private var palette
    static let thickness: CGFloat = 1

    enum Axis { case horizontal, vertical }
    let axis: Axis
    let label: String
    let onDrag: (Double) -> Void
    let reset: () -> Void
    @State private var last: CGFloat = 0
    @State private var active = false

    var body: some View {
        Rectangle()
            .fill(active ? palette.accent.ion.color : palette.surface.hairline.color)
            .frame(width: axis == .horizontal ? (active ? 2 : Self.thickness) : nil,
                   height: axis == .vertical ? (active ? 2 : Self.thickness) : nil)
            .overlay {
                // The grip: 24 pt to grab, without taking layout space.
                Color.clear
                    .frame(width: axis == .horizontal ? 24 : nil, height: axis == .vertical ? 24 : nil)
                    .contentShape(Rectangle())
                    .hoverEffect(.highlight)
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { value in
                                let now = axis == .horizontal ? value.translation.width : value.translation.height
                                active = true
                                onDrag(Double(now - last))
                                last = now
                            }
                            .onEnded { _ in last = 0; active = false }
                    )
                    .onTapGesture(count: 2) { withAnimation(Motion.pane) { reset() } }
            }
            .zIndex(1)
            .accessibilityElement()
            .accessibilityLabel(label)
            .accessibilityAdjustableAction { direction in
                onDrag(direction == .increment ? 40 : -40)
            }
    }
}

/// Thin targets at the dock edges while a panel is dragged, so it can start a new group anywhere,
/// including a dock that's empty.
struct DockDropZone: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var palette
    let dock: PaneLayout.Dock
    @State private var targeted = false

    var body: some View {
        Rectangle()
            .fill(palette.accent.ion.color.opacity(targeted ? 0.35 : 0.12))
            .overlay(alignment: .center) {
                Image(systemName: dock.symbol).foregroundStyle(palette.accent.ion.color)
            }
            .frame(width: dock == .bottom ? nil : 44, height: dock == .bottom ? 44 : nil)
            .dropDestination(for: String.self) { items, _ in
                guard let id = items.first, UtilityTab(rawValue: id) != nil else { return false }
                withAnimation(Motion.pane) { model.panes.move(id, toNewGroupIn: dock) }
                model.draggingPanel = nil
                return true
            } isTargeted: { targeted = $0 }
            .accessibilityLabel("New group in the \(dock.rawValue) dock")
    }
}

extension PaneLayout.Dock {
    var symbol: String {
        switch self {
        case .left: "rectangle.lefthalf.inset.filled"
        case .right: "rectangle.righthalf.inset.filled"
        case .bottom: "rectangle.bottomhalf.inset.filled"
        }
    }
}
