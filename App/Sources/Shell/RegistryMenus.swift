import SwiftUI
import CommandKit

/// Builds the iPadOS menu bar and hardware-keyboard shortcuts from the command registry.
struct RegistryMenus: Commands {
    let model: AppModel

    /// Commands in menus other than these are reachable only from the palette.
    /// (`Commands` builders don't support ForEach, so the menus are listed one by one.)
    var body: some Commands {
        // ⌘S, ⌘O and the like belong to our commands, not the system's default document items.
        CommandGroup(replacing: .saveItem) {}
        CommandGroup(replacing: .newItem) {}

        CommandMenu("File") { MenuItems(model: model, menu: "File") }
        CommandMenu("View") { MenuItems(model: model, menu: "View") }
        CommandMenu("Agent") { MenuItems(model: model, menu: "Agent") }
    }
}

private struct MenuItems: View {
    let model: AppModel
    let menu: String

    var body: some View {
        let items = model.registry.commands(for: model.experience.surface).filter { $0.menu == menu }
        ForEach(items) { command in
            Button(command.title) { model.registry.run(command.id) }
                .keyboardShortcut(command.shortcut?.swiftUI)
        }
    }
}

extension Shortcut {
    var swiftUI: KeyboardShortcut? {
        guard let ch = key.first else { return nil }
        var mods: EventModifiers = []
        if modifiers.contains(.command) { mods.insert(.command) }
        if modifiers.contains(.shift) { mods.insert(.shift) }
        if modifiers.contains(.option) { mods.insert(.option) }
        if modifiers.contains(.control) { mods.insert(.control) }
        let equivalent: KeyEquivalent = switch key {
        case "\r": .return
        case "\t": .tab
        case "\u{1B}": .escape
        default: KeyEquivalent(ch)
        }
        return KeyboardShortcut(equivalent, modifiers: mods)
    }
}
