import SwiftUI
import CommandKit
import DesignKit

@main
struct OmnieDevApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ExperienceRoot()
                .environment(model)
                #if DEBUG
                .task {
                    // Debug-only: `-OmnieOpenFolder /path` opens a folder at launch, for screenshots and UI tests.
                    let args = ProcessInfo.processInfo.arguments
                    if let i = args.firstIndex(of: "-OmnieOpenFolder"), args.indices.contains(i + 1) {
                        model.workspace.open(folder: URL(filePath: args[i + 1]))
                    }
                }
                #endif
        }
        .commands {
            RegistryMenus(model: model)
        }
    }
}

/// Picks the experience by device, not window width: iPad always gets the IDE
/// (with its own single-pane layout when narrow), iPhone gets the vibecoding app.
struct ExperienceRoot: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let palette = Palette.resolve(colorScheme: colorScheme, contrast: contrast)
        Group {
            switch model.experience {
            case .ide: IDEShell()
            case .vibe: VibeShell()
            }
        }
        .environment(\.palette, palette)
        .environment(\.density, model.density)
        .tint(palette.accent.ion.color)
        .background(palette.surface.chrome.color)
    }
}
