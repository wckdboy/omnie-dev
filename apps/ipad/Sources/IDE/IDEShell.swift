// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

import SwiftUI
import DesignKit

/// iPad: the editor in the middle with three docks around it (left, right, bottom), status strip
/// below. Every panel is a tab you can move between docks and groups; docks and groups resize by
/// their boundaries (PaneLayout). Side docks show when they fit beside a 480 pt editor, else the
/// one used last; under 700 pt the left dock slides over the editor.
struct IDEShell: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var palette

    var body: some View {
        GeometryReader { geo in
            let layout = LayoutClass(width: geo.size.width)
            let width = Double(geo.size.width)
            let sides = (model.focusMode || layout == .single) ? [] : model.panes.fittingSides(width: width, minEditor: Metrics.minEditorWidth)
            let showsBottom = !model.focusMode && model.panes.isVisible(.bottom)
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    if sides.contains(.left) {
                        DockView(dock: .left).frame(width: model.panes.leftWidth)
                        ResizeHandle(axis: .horizontal, label: "Left dock width") { delta in
                            model.panes.setSize(.left, model.panes.leftWidth + delta, maximum: maxSide(.left, width, sides))
                        } reset: { model.panes.resetSize(.left) }
                    }
                    VStack(spacing: 0) {
                        EditorPane()
                        if showsBottom {
                            ResizeHandle(axis: .vertical, label: "Bottom dock height") { delta in
                                model.panes.setSize(.bottom, model.panes.bottomHeight - delta, maximum: Double(geo.size.height) * 0.7)
                            } reset: { model.panes.resetSize(.bottom) }
                            DockView(dock: .bottom).frame(height: model.panes.bottomHeight)
                        }
                    }
                    .frame(minWidth: layout == .single ? nil : Metrics.minEditorWidth)
                    if sides.contains(.right) {
                        ResizeHandle(axis: .horizontal, label: "Right dock width") { delta in
                            model.panes.setSize(.right, model.panes.rightWidth - delta, maximum: maxSide(.right, width, sides))
                        } reset: { model.panes.resetSize(.right) }
                        DockView(dock: .right).frame(width: model.panes.rightWidth)
                    }
                }
                .overlay {
                    // While a panel is dragged, each dock edge takes it as a new group.
                    if model.draggingPanel != nil {
                        ZStack {
                            HStack { DockDropZone(dock: .left); Spacer(); DockDropZone(dock: .right) }
                            VStack { Spacer(); DockDropZone(dock: .bottom).padding(.horizontal, 60) }
                        }
                        .transition(.opacity)
                    }
                }
                StatusStrip()
            }
            .overlay(alignment: .leading) {
                // Under 700 pt the left dock slides over the editor.
                if layout == .single && model.leftOverlay && !model.focusMode && !model.panes.left.isEmpty {
                    DockView(dock: .left)
                        .frame(width: min(model.panes.leftWidth, geo.size.width * 0.85))
                        .overlay(alignment: .trailing) { hairline }
                        .transition(.move(edge: .leading))
                }
            }
            .overlay(alignment: .top) {
                if model.paletteOpen {
                    CommandPalette()
                        .padding(.top, 12)
                        .padding(.horizontal, 16)
                        .transition(.opacity)
                }
            }
            .animation(Motion.paletteIn, value: model.paletteOpen)
            .animation(Motion.pane, value: model.draggingPanel)
            .onChange(of: layout, initial: true) { model.layout = layout }
            #if DEBUG
            .task(id: "\(Int(width)) \(sides.map(\.rawValue).sorted()) \(showsBottom) \(model.panes.right.count)") {
                let groups = PaneLayout.Dock.allCases.map { dock in
                    "\(dock.rawValue): " + model.panes[dock].map { $0.panels.joined(separator: "+") }.joined(separator: " | ")
                }
                print("[layout] \(Int(width)) pt, showing \(sides.map(\.rawValue).sorted())\(showsBottom ? " + bottom" : ""); \(groups.joined(separator: "; "))")
            }
            #endif
        }
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .folderPicker()
        .gitSheets(model)
        .fullScreenCover(isPresented: Binding(get: { model.welcomeOpen }, set: { model.welcomeOpen = $0 })) {
            WelcomeView().environment(model)
        }
        .onAppear { applyInitialLayout() }
    }

    private var hairline: some View {
        Rectangle().fill(palette.surface.hairline.color).frame(width: Metrics.hairline)
    }

    /// A side dock can grow until the editor would drop under its minimum.
    private func maxSide(_ dock: PaneLayout.Dock, _ width: Double, _ sides: Set<PaneLayout.Dock>) -> Double {
        let other: PaneLayout.Dock = dock == .left ? .right : .left
        return width - Metrics.minEditorWidth - (sides.contains(other) ? model.panes.size(other) : 0)
    }

    private func applyInitialLayout() {
        // First run on this iPad (not when a debug launch opens its own folder).
        if !UserDefaults.standard.bool(forKey: WelcomeView.doneKey) && !model.opensFolderAtLaunch
            && !ProcessInfo.processInfo.arguments.contains("-OmnieNoWelcome") {
            model.welcomeOpen = true
        }
        // With no project, lead with the files panel's "Open folder" (unless one is being opened).
        if model.workspace.root == nil && !model.opensFolderAtLaunch {
            model.show(.files)
        }
    }
}
