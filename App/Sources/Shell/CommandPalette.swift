import SwiftUI
import CommandKit
import DesignKit

/// Top-center popover, 640 pt wide. `>` commands is the only live prefix for now;
/// `@` symbols and `?` agent arrive with LangKit and AgentKit.
struct CommandPalette: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var palette
    @Environment(\.density) private var density
    @State private var query = ""
    @State private var selection = 0
    @FocusState private var fieldFocused: Bool

    private var effectiveQuery: String {
        query.hasPrefix(">") ? String(query.dropFirst()) : query
    }

    private var results: [Command] {
        Array(model.registry.search(effectiveQuery, surface: model.experience.surface).prefix(12))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "command")
                    .foregroundStyle(palette.text.tertiary.color)
                TextField("Type a command", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .foregroundStyle(palette.text.primary.color)
                    .focused($fieldFocused)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .onSubmit(runSelected)
                    .onKeyPress(.downArrow) { move(1); return .handled }
                    .onKeyPress(.upArrow) { move(-1); return .handled }
                    .onKeyPress(.escape) { close(); return .handled }
            }
            .padding(.horizontal, 12)
            .frame(height: max(density.hitTarget, 40))

            Rectangle().fill(palette.surface.hairline.color).frame(height: Metrics.hairline)

            if results.isEmpty {
                Text("No matching commands")
                    .font(.system(size: 13))
                    .foregroundStyle(palette.text.tertiary.color)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(results.enumerated()), id: \.element.id) { index, command in
                            row(command, selected: index == selection)
                                .onTapGesture { run(command) }
                        }
                    }
                }
                .frame(maxHeight: 12 * density.row)
            }
        }
        .frame(maxWidth: Metrics.paletteWidth)
        .background(.ultraThinMaterial)
        .background(palette.surface.raised.color.opacity(0.85))
        .clipShape(RoundedRectangle(cornerRadius: Metrics.Radius.md))
        .overlay(RoundedRectangle(cornerRadius: Metrics.Radius.md).stroke(palette.surface.hairline.color, lineWidth: Metrics.hairline))
        .shadow(color: .black.opacity(0.24), radius: 12, y: 4)
        .onAppear { fieldFocused = true }
        .onChange(of: query) { selection = 0 }
    }

    private func row(_ command: Command, selected: Bool) -> some View {
        HStack {
            Text(command.title)
                .font(.system(size: 13))
                .foregroundStyle(palette.text.primary.color)
            if command.tier != .auto {
                Image(systemName: command.tier == .askBiometric ? "faceid" : "hand.raised")
                    .font(.system(size: 11))
                    .foregroundStyle(palette.text.tertiary.color)
                    .accessibilityLabel(command.tier == .askBiometric ? "Needs Face ID" : "Asks first")
            }
            Spacer()
            Text(command.menu)
                .font(.system(size: 12))
                .foregroundStyle(palette.text.tertiary.color)
            if let shortcut = command.shortcut {
                Text(shortcut.description)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(palette.text.secondary.color)
                    .frame(minWidth: 44, alignment: .trailing)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: density.row)
        .background(selected ? palette.surface.selection.color : .clear)
        .contentShape(Rectangle())
    }

    private func move(_ delta: Int) {
        guard !results.isEmpty else { return }
        selection = (selection + delta + results.count) % results.count
    }

    private func runSelected() {
        guard results.indices.contains(selection) else { return }
        run(results[selection])
    }

    private func run(_ command: Command) {
        close()
        // Let the palette dismiss before the command changes layout.
        Task { @MainActor in model.registry.run(command.id) }
    }

    private func close() {
        query = ""
        model.paletteOpen = false
    }
}
