// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

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
                    // Debug-only launch arguments, for screenshots and UI tests:
                    // `-OmnieOpenFolder /path` opens a folder; `-OmnieRunCommand <id>` (repeatable) runs a command.
                    let args = ProcessInfo.processInfo.arguments
                    if let i = args.firstIndex(of: "-OmnieOpenFolder"), args.indices.contains(i + 1) {
                        model.workspace.open(folder: URL(filePath: args[i + 1]))
                    }
                    // `-OmnieOpenFile <path relative to the folder>` opens a file in the editor.
                    if let i = args.firstIndex(of: "-OmnieOpenFile"), args.indices.contains(i + 1),
                       let root = model.workspace.rootURL {
                        model.workspace.open(file: root.appending(path: args[i + 1]))
                    }
                    // `-OmnieEnsureSSHKey` creates the SSH key and writes its public line to Application Support.
                    if args.contains("-OmnieEnsureSSHKey") {
                        let git = model.workspace.git
                        if git.identity == nil { git.createIdentity() }
                        if let line = git.identity?.signer.authorizedKeysLine(comment: "omnie-dev-sim") {
                            try? line.write(to: AppPaths.support.appendingPathComponent("debug-ssh-public-key.txt"), atomically: true, encoding: .utf8)
                        }
                    }
                    // `-OmnieClone <url>` clones and opens the result.
                    if let i = args.firstIndex(of: "-OmnieClone"), args.indices.contains(i + 1),
                       let folder = await model.workspace.git.clone(args[i + 1]) {
                        model.workspace.open(folder: folder)
                    }
                }
                #endif
                .task {
                    // `-OmnieRunCommand <id>` (repeatable) runs palette commands at launch, in every build,
                    // so the release-build spike can be started from Xcode's scheme arguments.
                    // Runs after the debug launch helpers above have opened any folder or file.
                    try? await Task.sleep(for: .milliseconds(300))
                    let args = ProcessInfo.processInfo.arguments
                    for (i, arg) in args.enumerated() where arg == "-OmnieRunCommand" && args.indices.contains(i + 1) {
                        model.registry.run(CommandID(rawValue: args[i + 1]))
                    }
                }
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
