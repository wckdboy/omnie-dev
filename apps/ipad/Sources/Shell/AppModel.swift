// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

import AgentKit
import RunKit
import SwiftUI
import ToolsKit
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

/// The IDE's panels. Each one is a tab that can live in any dock group (PaneLayout).
enum UtilityTab: String, CaseIterable, Identifiable {
    case files = "Files"
    case agent = "Agent"
    case timeline = "Timeline"
    case terminal = "Terminal"
    case preview = "Preview"
    case stage = "Stage"
    case tools = "Tools"

    var id: Self { self }

    var symbol: String {
        switch self {
        case .files: "folder"
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
    /// What the palette opens with ("@" for go to symbol).
    var paletteSeed = ""
    var commitSheetOpen = false
    var sshKeySheetOpen = false
    var cloneSheetOpen = false
    var branchSheetOpen = false
    var historySheetOpen = false
    var editorSpikeOpen = false
    var modelSpikeOpen = false
    var webGPUSpikeOpen = false
    var wasiSpikeOpen = false
    var auditLogOpen = false
    var settingsOpen = false
    var quickOpenOpen = false
    var prepareOfflineOpen = false
    var findOpen = false
    var goToLineOpen = false
    var problemsOpen = false
    /// A command for the terminal to run (the palette's "Run task: …").
    var terminalRequest: String?
    /// A file for the diff tool's left side ("Compare open file with…").
    var diffLeft: String?
    /// Terminal commands this session and what they cost (the profiler, PLAN.md §11.2).
    var runLog: [RunRecord] = []
    /// A new snippet to edit ("Save selection as snippet").
    var snippetRequest: SnippetVault.Snippet?
    /// The snippet vault (PLAN.md §11.1), in Application Support.
    let snippets = try? SnippetVault(url: AppPaths.support.appendingPathComponent("snippets.sqlite"))
    /// The docs sheet's starting query, or nil when it's closed.
    var docsQuery: String?
    var focusMode = false
    /// Where the panels are (docks, groups, sizes); yours to rearrange, kept between launches.
    var panes: PaneLayout = AppModel.loadPanes() {
        didSet { if panes != oldValue { AppModel.savePanes(panes) } }
    }
    /// Panels open in windows of their own (out of the docks meanwhile).
    var windowedPanels: Set<String> = []
    /// The editor's minimap; kept between launches.
    var showsMinimap = UserDefaults.standard.object(forKey: "editor.minimap") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showsMinimap, forKey: "editor.minimap") }
    }
    /// Under 700 pt the left dock slides over the editor instead.
    var leftOverlay = false
    /// The panel being dragged, while the dock edges offer themselves as drop targets.
    var draggingPanel: UtilityTab?
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
    let models: ModelsModel
    let docs: DocsModel
    let agent: AgentModel

    var density: Density {
        if let densityOverride { return densityOverride }
        if experience == .vibe { return .touch }
        return hasHardwareKeyboard ? .compact : .touch
    }

    private let pathMonitor = NWPathMonitor()

    init() {
        Packages.activate()
        // The agent's edit guard parses JS/TS with RunKit's transpiler (AgentKit can't see RunKit).
        if let transpiler = try? Transpiler() {
            Sandbox.syntaxChecker = { text, path in transpiler.syntaxError(text, path: path) }
        }
        workspace = WorkspaceModel(policy: policy)
        models = ModelsModel(policy: policy)
        docs = DocsModel(policy: policy)
        agent = AgentModel(workspace: workspace, models: models, policy: policy)
        agent.snippets = snippets
        agent.isOffline = { [weak self] in self?.isOffline ?? false }
        workspace.onProjectOpened = { [agent] root in agent.attach(root) }
        workspace.completionModel = { [models] in
            guard models.inlineSuggestions else { return nil }
            return await models.tinyModel()
        }
        registerCommands()
        #if DEBUG
        // `-OmnieLayout terminalBelow` starts from a preset (screenshots, UI tests), before any
        // other launch argument shows a panel.
        let launch = ProcessInfo.processInfo.arguments
        if let i = launch.firstIndex(of: "-OmnieLayout"), launch.indices.contains(i + 1), let preset = LayoutPreset(rawValue: launch[i + 1]) {
            panes = preset.layout
        }
        #endif
        // Debug launch arguments open their own folder.
        let args = ProcessInfo.processInfo.arguments
        if !args.contains("-OmnieOpenFolder") && !args.contains("-OmnieClone") { workspace.reopenLast() }
        startMonitors()
    }

    /// Brings up the Agent pane (the status pill and "Show agent").
    func showAgent() { show(.agent) }

    /// Runs a workspace task (PLAN.md §8.2) in the terminal, which says where it ran.
    func runTask(_ name: String) {
        guard workspace.rootURL != nil else { return }
        show(.terminal)
        terminalRequest = "task \(name)"
    }

    func show(_ tab: UtilityTab) {
        // It's in a window of its own: that window shows it.
        if windowedPanels.contains(tab.rawValue) { return }
        withAnimation(Motion.pane) {
            panes.reveal(tab.rawValue)
            if layout == .single, panes.location(of: tab.rawValue)?.dock == .left { leftOverlay = true }
        }
    }

    /// Whether a panel is on screen now.
    func isShowing(_ tab: UtilityTab) -> Bool { panes.isShowing(tab.rawValue) }

    func toggle(_ dock: PaneLayout.Dock) {
        withAnimation(Motion.pane) {
            if layout == .single && dock == .left {
                leftOverlay.toggle()
                if leftOverlay { panes.hidden.remove(.left) }
            } else {
                panes.toggle(dock)
            }
        }
    }

    func applyLayout(_ preset: LayoutPreset) {
        withAnimation(Motion.pane) { panes = preset.layout }
    }

    nonisolated static let panesKey = "panes.v1"

    static func loadPanes() -> PaneLayout {
        guard let data = UserDefaults.standard.data(forKey: panesKey),
              var layout = try? JSONDecoder().decode(PaneLayout.self, from: data) else { return LayoutPreset.standard.layout }
        layout.repair(known: UtilityTab.allCases.map(\.rawValue))
        return layout
    }

    static func savePanes(_ layout: PaneLayout) {
        if let data = try? JSONEncoder().encode(layout) { UserDefaults.standard.set(data, forKey: panesKey) }
    }

    private func startMonitors() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let offline = path.status != .satisfied
            Task { @MainActor in
                guard let self else { return }
                let cameOnline = self.isOffline && !offline
                self.isOffline = offline
                // Queued pushes were authorized when queued; send them without asking again.
                if cameOnline && !self.policy.planeMode {
                    await self.workspace.git.flushQueue()
                    // Sketches drawn offline go to the vision model now.
                    await self.agent.sendQueuedSketches()
                }
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
                    shortcut: Shortcut("f", [.command, .control]), surfaces: .ide, keywords: ["zen", "distraction", "full screen"]) { [weak self] in
                guard let self else { return }
                withAnimation(Motion.pane) { self.focusMode.toggle() }
            },
            Command(id: "view.navigator", title: "Toggle left dock", menu: "View",
                    shortcut: Shortcut("1"), surfaces: .ide, keywords: ["sidebar", "files", "navigator"]) { [weak self] in
                self?.toggle(.left)
            },
            Command(id: "view.utility", title: "Toggle right dock", menu: "View",
                    shortcut: Shortcut("3"), surfaces: .ide, keywords: ["utility pane", "inspector"]) { [weak self] in
                self?.toggle(.right)
            },
            Command(id: "view.minimap", title: "Toggle minimap", menu: "View",
                    surfaces: .ide, keywords: ["overview", "scroll map"]) { [weak self] in
                self?.showsMinimap.toggle()
            },
            Command(id: "view.bottom", title: "Toggle bottom dock", menu: "View",
                    shortcut: Shortcut("j"), surfaces: .ide, keywords: ["panel", "terminal"]) { [weak self] in
                guard let self else { return }
                // An empty bottom dock gets the terminal, the usual thing to want there.
                if self.panes.bottom.isEmpty {
                    withAnimation(Motion.pane) { self.panes.move(UtilityTab.terminal.rawValue, toNewGroupIn: .bottom) }
                } else {
                    self.toggle(.bottom)
                }
            },
            Command(id: "file.openFolder", title: "Open folder", menu: "File",
                    shortcut: Shortcut("o"), keywords: ["project", "workspace"]) { [weak self] in
                self?.workspace.isPickingFolder = true
            },
            Command(id: "file.new", title: "New file…", menu: "File",
                    shortcut: Shortcut("n"), keywords: ["create file"]) { [weak self] in
                guard let self, let folder = workspace.currentFolder else { return }
                workspace.namePrompt = .init(kind: .newFile, url: folder)
            },
            Command(id: "file.newFolder", title: "New folder…", menu: "File",
                    shortcut: Shortcut("n", [.command, .shift]), keywords: ["create folder", "directory"]) { [weak self] in
                guard let self, let folder = workspace.currentFolder else { return }
                workspace.namePrompt = .init(kind: .newFolder, url: folder)
            },
            Command(id: "editor.nextTab", title: "Next tab", menu: "View",
                    shortcut: Shortcut("\t", [.control]), surfaces: .ide, keywords: ["switch tab"]) { [weak self] in
                self?.workspace.cycleTab(by: 1)
            },
            Command(id: "editor.previousTab", title: "Previous tab", menu: "View",
                    shortcut: Shortcut("\t", [.control, .shift]), surfaces: .ide, keywords: ["switch tab"]) { [weak self] in
                self?.workspace.cycleTab(by: -1)
            },
            Command(id: "editor.closeTab", title: "Close tab", menu: "File",
                    shortcut: Shortcut("w"), surfaces: .ide, keywords: ["close file"]) { [weak self] in
                guard let self, let file = workspace.openFile else { return }
                workspace.closeTab(file)
            },
            Command(id: "editor.goToSymbol", title: "Go to symbol…", menu: "File",
                    shortcut: Shortcut("o", [.command, .shift]), keywords: ["outline", "function", "class", "@"]) { [weak self] in
                guard let self, workspace.openFile != nil else { return }
                paletteSeed = "@"
                paletteOpen = true
            },
            Command(id: "app.prepareOffline", title: "Prepare for offline…", menu: "File",
                    keywords: ["plane", "flight", "offline", "fetch", "verify"]) { [weak self] in
                self?.prepareOfflineOpen = true
            },
            Command(id: "file.quickOpen", title: "Open file…", menu: "File",
                    shortcut: Shortcut("p"), keywords: ["go to file", "quick open", "find file"]) { [weak self] in
                guard let self, workspace.rootURL != nil else { return }
                quickOpenOpen = true
            },
            Command(id: "search.project", title: "Find in project", menu: "File",
                    shortcut: Shortcut("f", [.command, .shift]), keywords: ["search", "grep", "find all"]) { [weak self] in
                guard let self, workspace.rootURL != nil else { return }
                findOpen = true
            },
            Command(id: "help.docs", title: "Search docs…", menu: "Help",
                    shortcut: Shortcut("d", [.command, .shift]), keywords: ["documentation", "mdn", "reference", "look up", "devdocs"]) { [weak self] in
                guard let self else { return }
                docsQuery = workspace.wordAtCaret ?? ""
            },
            Command(id: "task.dev", title: "Run task: dev", menu: "File", keywords: ["start", "serve", "npm run dev", "workspace"]) { [weak self] in
                self?.runTask("dev")
            },
            Command(id: "task.test", title: "Run task: test", menu: "File", keywords: ["npm test", "vitest", "pytest", "workspace"]) { [weak self] in
                self?.runTask("test")
            },
            Command(id: "task.build", title: "Run task: build", menu: "File", keywords: ["compile", "npm run build", "workspace"]) { [weak self] in
                self?.runTask("build")
            },
            Command(id: "tools.compare", title: "Compare open file with…", menu: "File", keywords: ["diff", "compare", "difference", "clipboard"]) { [weak self] in
                guard let self, let path = workspace.relativePath else { return }
                diffLeft = path
                show(.tools)
            },
            Command(id: "snippets.saveSelection", title: "Save selection as snippet", menu: "File", keywords: ["snippet", "vault", "save code"]) { [weak self] in
                guard let self, workspace.openFile != nil else { return }
                let range = workspace.editor.selectedRange
                guard range.length > 0 else { return }
                let text = (workspace.editor.text as NSString).substring(with: range)
                let firstLine = text.split(separator: "\n").first.map { String($0.prefix(50)).trimmingCharacters(in: .whitespaces) } ?? "Snippet"
                snippetRequest = .init(title: firstLine, language: workspace.language?.rawValue ?? "", body: text)
                show(.tools)
            },
            Command(id: "problems.show", title: "Show problems", menu: "File",
                    shortcut: Shortcut("m", [.command, .shift]), keywords: ["type errors", "diagnostics", "typescript", "tsc", "check types"]) { [weak self] in
                guard let self, workspace.rootURL != nil else { return }
                if let root = workspace.rootURL, workspace.problems.diagnostics.isEmpty { workspace.problems.schedule(root: root, after: .zero) }
                problemsOpen = true
            },
            Command(id: "editor.goToLine", title: "Go to line…", menu: "File",
                    shortcut: Shortcut("l"), keywords: ["line number", "jump"]) { [weak self] in
                guard let self, workspace.openFile != nil else { return }
                goToLineOpen = true
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
            Command(id: "git.editHistory", title: "Edit history…", menu: "Git",
                    keywords: ["interactive rebase", "squash", "reorder commits", "reword", "fixup"]) { [weak self] in
                guard let self, self.workspace.git.repo != nil else { return }
                self.historySheetOpen = true
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
                self.show(.timeline)
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
            Command(id: "agent.show", title: "Show agent", menu: "Agent",
                    shortcut: Shortcut("a", [.command, .shift]), surfaces: .ide, keywords: ["task", "changes", "review"]) { [weak self] in
                self?.showAgent()
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
                self.show(.agent)
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
                self.show(tab)
            }
        } + LayoutPreset.allCases.map { preset in
            Command(id: CommandID(rawValue: "layout.\(preset.rawValue)"), title: "Layout: \(preset.title)",
                    menu: "View", surfaces: .ide, keywords: ["panes", "docks", "reset layout"]) { [weak self] in
                self?.applyLayout(preset)
            }
        }

        for command in commands {
            do { try registry.register(command) }
            catch { assertionFailure("Command registration failed: \(error)") }
        }
    }
}
