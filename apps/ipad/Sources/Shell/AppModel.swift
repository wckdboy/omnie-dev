// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

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
    var sshKeySheetOpen = false
    var cloneSheetOpen = false
    var branchSheetOpen = false
    var editorSpikeOpen = false
    var modelSpikeOpen = false
    var webGPUSpikeOpen = false
    var wasiSpikeOpen = false
    var auditLogOpen = false
    var settingsOpen = false
    var focusMode = false
    var navigatorVisible = true
    var utilityVisible = true
    var utilityTab: UtilityTab = .agent
    /// Current iPad window layout, reported by the IDE shell.
    var layout: LayoutClass = .full

    // Environment signals
    private(set) var isOffline = false
    /// Offline, or plane mode on: Sync queues the push instead of connecting.
    var networkUnavailable: Bool { isOffline || policy.planeMode }
    private(set) var hasHardwareKeyboard = GCKeyboard.coalesced != nil
    /// nil means density follows the hands.
    var densityOverride: Density?

    let policy = PolicyModel()
    let workspace: WorkspaceModel

    var density: Density {
        if let densityOverride { return densityOverride }
        if experience == .vibe { return .touch }
        return hasHardwareKeyboard ? .compact : .touch
    }

    private let pathMonitor = NWPathMonitor()

    init() {
        workspace = WorkspaceModel(policy: policy)
        registerCommands()
        // Debug launch arguments open their own folder.
        let args = ProcessInfo.processInfo.arguments
        if !args.contains("-OmnieOpenFolder") && !args.contains("-OmnieClone") { workspace.reopenLast() }
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
            Task { @MainActor in
                guard let self else { return }
                let cameOnline = self.isOffline && !offline
                self.isOffline = offline
                // Queued pushes were authorized when queued; send them without asking again.
                if cameOnline && !self.policy.planeMode { await self.workspace.git.flushQueue() }
            }
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
            Command(id: "git.sync", title: "Sync", menu: "Git",
                    shortcut: Shortcut("s", [.command, .shift]), tier: .askBiometric,
                    keywords: ["push", "pull", "fetch"]) { [weak self] in
                guard let self else { return }
                self.workspace.saveCurrent()
                Task { await self.workspace.git.sync(isOffline: self.networkUnavailable) }
            },
            Command(id: "git.branches", title: "Switch branch", menu: "Git",
                    shortcut: Shortcut("b", [.command, .shift]), keywords: ["checkout", "new branch"]) { [weak self] in
                guard let self, self.workspace.git.repo != nil else { return }
                self.branchSheetOpen = true
            },
            Command(id: "git.undo", title: "Undo last git operation", menu: "Git",
                    shortcut: Shortcut("z", [.command, .option]), keywords: ["revert", "reset", "uncommit"]) { [weak self] in
                guard let self else { return }
                Task { await self.workspace.git.undo() }
            },
            Command(id: "git.clone", title: "Clone repository", menu: "Git", keywords: ["download", "checkout"]) { [weak self] in
                self?.cloneSheetOpen = true
            },
            Command(id: "git.sshKey", title: "SSH key", menu: "Git", keywords: ["public key", "forge", "secure enclave"]) { [weak self] in
                self?.sshKeySheetOpen = true
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
            Command(id: "spike.editor", title: "Run editor spike (P0)", menu: "View",
                    keywords: ["benchmark", "performance", "runestone", "textkit"]) { [weak self] in
                self?.editorSpikeOpen = true
            },
            Command(id: "app.settings", title: "Settings", menu: "Settings",
                    shortcut: Shortcut(","), keywords: ["preferences", "author", "ssh", "plane mode", "licenses"]) { [weak self] in
                self?.settingsOpen = true
            },
            Command(id: "policy.planeMode", title: "Toggle plane mode", menu: "View",
                    keywords: ["offline", "airplane", "network", "local only"]) { [weak self] in
                guard let self else { return }
                policy.planeMode.toggle()
                if !policy.planeMode && !isOffline { Task { await self.workspace.git.flushQueue() } }
            },
            Command(id: "policy.auditLog", title: "Show audit log", menu: "View",
                    keywords: ["policy", "approvals", "security", "history"]) { [weak self] in
                self?.auditLogOpen = true
            },
            Command(id: "spike.wasi", title: "Run WASI spike (P0)", menu: "View",
                    keywords: ["wasm", "sandbox", "runkit"]) { [weak self] in
                self?.wasiSpikeOpen = true
            },
            Command(id: "spike.webgpu", title: "Run WebGPU spike (P0)", menu: "View",
                    keywords: ["webgl", "stage", "three.js", "gpu"]) { [weak self] in
                self?.webGPUSpikeOpen = true
            },
            Command(id: "spike.model", title: "Run model spike (P0)", menu: "View",
                    keywords: ["mlx", "llm", "benchmark", "7b"]) { [weak self] in
                self?.modelSpikeOpen = true
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
