import SwiftUI
import Network
import GameController
import CommandKit
import DesignKit
import WorkspaceKit

enum Experience {
    /// iPad: navigator, editor, utility pane.
    case ide
    /// iPhone: agent-first. Describe, review, preview, sync.
    case vibe

    var surface: Surfaces { self == .ide ? .ide : .vibe }
}

enum UtilityTab: String, CaseIterable, Identifiable {
    case agent = "Agent"
    case timeline = "Timeline"
    case terminal = "Terminal"
    case preview = "Preview"
    case stage = "Stage"
    case tools = "Tools"

    var id: Self { self }

    var symbol: String {
        switch self {
        case .agent: "text.bubble"
        case .timeline: "clock.arrow.trianglehead.counterclockwise.rotate.90"
        case .terminal: "terminal"
        case .preview: "safari"
        case .stage: "cube"
        case .tools: "wrench.and.screwdriver"
        }
    }
}

/// App-wide UI state and the command registry. One per process.
@MainActor
@Observable
final class AppModel {
    let registry = CommandRegistry()
    let experience: Experience = UIDevice.current.userInterfaceIdiom == .pad ? .ide : .vibe

    // Layout
    var paletteOpen = false
    var commitSheetOpen = false
    var focusMode = false
    var navigatorVisible = true
    var utilityVisible = true
    var utilityTab: UtilityTab = .agent
    /// Current iPad window layout, reported by the IDE shell.
    var layout: LayoutClass = .full

    // Environment signals
    private(set) var isOffline = false
    private(set) var hasHardwareKeyboard = GCKeyboard.coalesced != nil
    /// nil means density follows the hands.
    var densityOverride: Density?

    let workspace = WorkspaceModel()

    var density: Density {
        if let densityOverride { return densityOverride }
        if experience == .vibe { return .touch }
        return hasHardwareKeyboard ? .compact : .touch
    }

    private let pathMonitor = NWPathMonitor()

    init() {
        registerCommands()
        startMonitors()
    }

    /// In the split layout only one side pane fits, so showing the utility pane closes the navigator.
    private var utilityHiddenBySplit: Bool { layout == .split && navigatorVisible }

    private func showUtility(_ show: Bool) {
        utilityVisible = show
        if show && layout == .split { navigatorVisible = false }
    }

    private func startMonitors() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let offline = path.status != .satisfied
            Task { @MainActor in self?.isOffline = offline }
        }
        pathMonitor.start(queue: DispatchQueue(label: "ai.wckd.omniedev.network"))

        let center = NotificationCenter.default
        for name in [Notification.Name.GCKeyboardDidConnect, .GCKeyboardDidDisconnect] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.hasHardwareKeyboard = GCKeyboard.coalesced != nil
                }
            }
        }
    }

    private func registerCommands() {
        let commands: [Command] = [
            Command(id: "palette.open", title: "Open command palette", menu: "View",
                    shortcut: Shortcut("k"), keywords: ["commands", "search"]) { [weak self] in
                self?.paletteOpen.toggle()
            },
            Command(id: "palette.openAlt", title: "Show all commands", menu: "View",
                    shortcut: Shortcut("p", [.command, .shift]), surfaces: .ide) { [weak self] in
                self?.paletteOpen = true
            },
            Command(id: "view.focus", title: "Toggle focus mode", menu: "View",
                    shortcut: Shortcut("f", [.command, .shift]), surfaces: .ide, keywords: ["zen", "distraction"]) { [weak self] in
                guard let self else { return }
                withAnimation(Motion.pane) { self.focusMode.toggle() }
            },
            Command(id: "view.navigator", title: "Toggle navigator", menu: "View",
                    shortcut: Shortcut("1"), surfaces: .ide, keywords: ["sidebar", "files"]) { [weak self] in
                guard let self else { return }
                withAnimation(Motion.pane) { self.navigatorVisible.toggle() }
            },
            Command(id: "view.utility", title: "Toggle utility pane", menu: "View",
                    shortcut: Shortcut("3"), surfaces: .ide) { [weak self] in
                guard let self else { return }
                withAnimation(Motion.pane) { self.showUtility(!self.utilityVisible || self.utilityHiddenBySplit) }
            },
            Command(id: "file.openFolder", title: "Open folder", menu: "File",
                    shortcut: Shortcut("o"), keywords: ["project", "workspace"]) { [weak self] in
                self?.workspace.isPickingFolder = true
            },
            Command(id: "file.save", title: "Save", menu: "File",
                    shortcut: Shortcut("s")) { [weak self] in
                self?.workspace.saveCurrent()
            },
            Command(id: "git.commit", title: "Commit", menu: "Git",
                    shortcut: Shortcut("c", [.command, .shift]), keywords: ["save", "snapshot"]) { [weak self] in
                guard let self, self.workspace.git.repo != nil else { return }
                self.commitSheetOpen = true
            },
            Command(id: "git.checkpoint", title: "Take checkpoint now", menu: "Git", keywords: ["snapshot", "backup"]) { [weak self] in
                guard let self else { return }
                self.workspace.saveCurrent()
                Task { await self.workspace.git.checkpoint(.manual) }
            },
            Command(id: "git.timeline", title: "Show timeline", menu: "Git",
                    shortcut: Shortcut("t", [.command, .shift]), keywords: ["history", "log"]) { [weak self] in
                guard let self else { return }
                self.showUtility(true)
                self.utilityTab = .timeline
            },
            Command(id: "git.init", title: "Initialize git repository", menu: "Git") { [weak self] in
                guard let self, let root = self.workspace.rootURL else { return }
                Task { await self.workspace.git.initialize(root) }
            },
            Command(id: "agent.ask", title: "Ask agent", menu: "Agent",
                    shortcut: Shortcut("i"), keywords: ["ai", "prompt"]) { [weak self] in
                guard let self else { return }
                self.showUtility(true)
                self.utilityTab = .agent
            },
            Command(id: "density.auto", title: "Density: follow input device", menu: "View", surfaces: .ide) { [weak self] in
                self?.densityOverride = nil
            },
            Command(id: "density.compact", title: "Density: compact", menu: "View", surfaces: .ide) { [weak self] in
                self?.densityOverride = .compact
            },
            Command(id: "density.touch", title: "Density: touch", menu: "View", surfaces: .ide) { [weak self] in
                self?.densityOverride = .touch
            },
        ] + UtilityTab.allCases.filter { $0 != .timeline }.map { tab in
            Command(id: CommandID(rawValue: "utility.\(tab.rawValue.lowercased())"), title: "Show \(tab.rawValue.lowercased())",
                    menu: "View", surfaces: .ide) { [weak self] in
                guard let self else { return }
                self.showUtility(true)
                self.utilityTab = tab
            }
        }

        for command in commands {
            do { try registry.register(command) }
            catch { assertionFailure("Command registration failed: \(error)") }
        }
    }
}
