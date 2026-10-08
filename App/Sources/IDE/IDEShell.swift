import SwiftUI
import DesignKit

/// iPad: navigator | editor | utility pane, separated by hairlines, status strip below.
/// Over 1100 pt all three show; 700 to 1100 the editor plus one side; under 700 the editor alone
/// with the others as overlays. The editor is never narrower than 480 pt.
struct IDEShell: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var palette
    @State private var cursor: (line: Int, column: Int)?

    private let navigatorWidth: CGFloat = 260
    private let utilityWidth: CGFloat = 380

    var body: some View {
        GeometryReader { geo in
            let layout = LayoutClass(width: geo.size.width)
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    if showsNavigator(layout) {
                        Navigator()
                            .frame(width: navigatorWidth)
                        hairline
                    }
                    EditorPane(cursor: $cursor)
                        .frame(minWidth: layout == .single ? nil : Metrics.minEditorWidth)
                    if showsUtility(layout) {
                        hairline
                        UtilityPane()
                            .frame(width: utilityWidth)
                    }
                }
                StatusStrip(cursor: cursor)
            }
            .overlay(alignment: .leading) {
                // Under 700 pt the navigator slides over the editor.
                if layout == .single && model.navigatorVisible && !model.focusMode {
                    Navigator(onOpen: { _ in withAnimation(Motion.pane) { model.navigatorVisible = false } })
                        .frame(width: navigatorWidth)
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
            .onChange(of: layout, initial: true) { model.layout = layout }
        }
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .folderPicker()
        .gitSheets(model)
        .onAppear { applyInitialLayout() }
    }

    private var hairline: some View {
        Rectangle().fill(palette.surface.hairline.color).frame(width: Metrics.hairline)
    }

    /// Full: both sides. Split: one side, and the navigator wins while it's open.
    private func showsNavigator(_ layout: LayoutClass) -> Bool {
        !model.focusMode && model.navigatorVisible && layout != .single
    }

    private func showsUtility(_ layout: LayoutClass) -> Bool {
        guard !model.focusMode, model.utilityVisible else { return false }
        switch layout {
        case .full: return true
        case .split: return !model.navigatorVisible
        case .single: return false
        }
    }

    private func applyInitialLayout() {
        // With no project, lead with the navigator's "Open folder".
        if model.workspace.root == nil { model.navigatorVisible = true }
    }
}
