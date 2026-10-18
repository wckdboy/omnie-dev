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
import EditorKit
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
    case editor2 = "Editor 2"
    case timeline = "Timeline"
    case terminal = "Terminal"
    case preview = "Preview"
    case stage = "Stage"
    case tools = "Tools"
    case tests = "Tests"
    case debug = "Debug"

    var id: Self { self }

    var symbol: String {
        switch self {
        case .files: "folder"
        case .editor2: "rectangle.split.2x1"
        case .agent: "text.bubble"
        case .timeline: "clock.arrow.trianglehead.counterclockwise.rotate.90"
        case .terminal: "terminal"
        case .preview: "safari"
        case .stage: "cube"
        case .tools: "wrench.and.screwdriver"
        case .tests: "testtube.2"
        case .debug: "ladybug"
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
    var remotesSheetOpen = false
    var projectsOpen = false
    var newProjectOpen = false
    var pullRequestsOpen = false
    /// First run, or Help › Welcome.
    var welcomeOpen = false
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
    /// The breakpoint condition being edited (the debugger's "Edit breakpoint condition…").
    struct BreakpointPrompt: Identifiable, Equatable {
        var line: Int
        var text: String
        var id: Int { line }
    }
    var breakpointPrompt: BreakpointPrompt?
    var problemsOpen = false
    var snapshotsOpen = false
    var workspaceSymbolOpen = false
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
    /// Textastic-simple: a file list and the editor, without the workbench (View › Simple mode).
    var simpleMode = UserDefaults.standard.bool(forKey: "view.simpleMode") {
        didSet { UserDefaults.standard.set(simpleMode, forKey: "view.simpleMode") }
    }
    /// Where the panels are (docks, groups, sizes); yours to rearrange, kept between launches.
    var panes: PaneLayout = AppModel.loadPanes() {
        didSet {
            guard panes != oldValue else { return }
            AppModel.savePanes(panes)
            if let projectLayoutKey { AppModel.savePanes(panes, key: projectLayoutKey) }
        }
    }
    /// The open project's layout key (PLAN.md §13: layout is saved per project).
    @ObservationIgnored private var projectLayoutKey: String?
    /// Panels open in windows of their own (out of the docks meanwhile).
    var windowedPanels: Set<String> = []
    /// A debug launch argument opens a folder itself, a moment after launch.
    private(set) var opensFolderAtLaunch = false
    /// Panel windows opened in this run (restored ones aren't in it).
    var openedPanelWindows: Set<String> = []
    /// The blame column beside the code (PLAN.md §9.10).
    var showsBlame = false
    /// A commit the timeline scrolls to and marks (tapped in blame).
    var timelineFocus: String?
    #if DEBUG
    /// Set once the debug launch fixtures have opened their folder; launch commands wait for it.
    var launchFolderReady = false
    #else
    let launchFolderReady = true
    #endif
    /// The editor's minimap; kept between launches.
    /// Long lines wrap at the editor's edge (⌥Z), so a narrow editor beside the docks hides
    /// nothing. On by default; VS Code's is off, but an iPad's editor is narrower.
    var wordWrap = UserDefaults.standard.object(forKey: "editor.wordWrap") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(wordWrap, forKey: "editor.wordWrap")
            applyWordWrap()
        }
    }

    func applyWordWrap() {
        workspace.editor.textView.isLineWrappingEnabled = wordWrap
        split.editor.textView.isLineWrappingEnabled = wordWrap
    }

    /// View › Render whitespace: spaces as dots and tabs as arrows. Off by default.
    var showsWhitespace = UserDefaults.standard.bool(forKey: "editor.whitespace") {
        didSet {
            UserDefaults.standard.set(showsWhitespace, forKey: "editor.whitespace")
            applyEditorGuides()
        }
    }
    /// View › Indent guides: a hairline at each level of indentation. On by default.
    var showsIndentGuides = UserDefaults.standard.object(forKey: "editor.indentGuides") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(showsIndentGuides, forKey: "editor.indentGuides")
            applyEditorGuides()
        }
    }
    /// View › Ruler: a column guide at 100 characters, as VS Code's `editor.rulers` does.
    var showsRuler = UserDefaults.standard.bool(forKey: "editor.ruler") {
        didSet {
            UserDefaults.standard.set(showsRuler, forKey: "editor.ruler")
            applyEditorGuides()
        }
    }

    /// Whitespace, indent guides and the ruler on both editors.
    func applyEditorGuides() {
        for editor in [workspace.editor, split.editor] {
            editor.showsWhitespace = showsWhitespace
            editor.showsIndentGuides = showsIndentGuides
            editor.rulerColumn = showsRuler ? 100 : 0
        }
    }

    var showsMinimap = UserDefaults.standard.object(forKey: "editor.minimap") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showsMinimap, forKey: "editor.minimap") }
    }
    /// The folder › file › symbols strip above the code.
    var showsBreadcrumbs = UserDefaults.standard.object(forKey: "editor.breadcrumbs") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showsBreadcrumbs, forKey: "editor.breadcrumbs") }
    }
    /// The enclosing scopes pinned at the top while scrolling.
    var showsStickyScroll = UserDefaults.standard.object(forKey: "editor.stickyScroll") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showsStickyScroll, forKey: "editor.stickyScroll") }
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
    /// Definitions, references, rename, quick info and completions (TypeScript, JavaScript, Python).
    let language: LanguageModel
    let models: ModelsModel
    let docs: DocsModel
    let agent: AgentModel
    /// The second editor (the Editor 2 panel).
    let split = SplitEditorModel()
    /// Find & replace in the open file (⌘F).
    let find = FindModel()
    /// The debug session (PLAN.md §5.3).
    let debug = DebugModel()
    /// Local project snapshots (File › Snapshots).
    let snapshots = SnapshotsModel()

    /// The snapshot taken just before the last applied agent changeset, so it can be undone in one tap.
    private(set) var undoableAgentSnapshot: ProjectSnapshot?

    /// Puts a landed agent changeset back the way it was: restores the snapshot the app took just
    /// before the merge. The restore snapshots the current state first, so it is itself undoable.
    func undoAgentApply() {
        guard let snapshot = undoableAgentSnapshot else { return }
        snapshots.restore(snapshot)
        undoableAgentSnapshot = nil
    }
    /// The test explorer (Tests panel).
    let tests = TestsModel()

    var density: Density {
        if let densityOverride { return densityOverride }
        if experience == .vibe { return .touch }
        return hasHardwareKeyboard ? .compact : .touch
    }

    private let pathMonitor = NWPathMonitor()
    @ObservationIgnored nonisolated(unsafe) private var observers: [NSObjectProtocol] = []

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
        language = LanguageModel(workspace: workspace)
        agent.snippets = snippets
        agent.beforeApply = { [weak self] in
            // Keep the snapshot so a landed changeset can be undone in one tap.
            self?.undoableAgentSnapshot = self?.snapshots.take(reason: "Before agent changes")
        }
        agent.isOffline = { [weak self] in self?.isOffline ?? false }
        workspace.onProjectOpened = { [weak self, agent] root in
            agent.attach(root)
            self?.language.reset()
            self?.restoreLayout(for: root)
        }
        workspace.onEdited = { [weak self] in
            self?.language.edited()
            self?.find.textChanged()
        }
        workspace.onProjectClosed = { [weak self] in self?.language.reset() }
        workspace.suppressesGhostText = { [weak self] in self?.language.completions != nil }
        workspace.completionModel = { [models] in
            guard models.inlineSuggestions else { return nil }
            return await models.tinyModel()
        }
        split.workspace = workspace
        find.workspace = workspace
        debug.workspace = workspace
        snapshots.workspace = workspace
        tests.workspace = workspace
        registerCommands()
        #if DEBUG
        // `-OmnieLayout terminalBelow` starts from a preset (screenshots, UI tests), before any
        // other launch argument shows a panel.
        let launch = ProcessInfo.processInfo.arguments
        if let i = launch.firstIndex(of: "-OmnieLayout"), launch.indices.contains(i + 1), let preset = LayoutPreset(rawValue: launch[i + 1]) {
            panes = preset.layout
        }
        #endif
        let args = ProcessInfo.processInfo.arguments
        // Debug launch arguments open their own folder (fixtures rebuild theirs, so don't reopen it).
        opensFolderAtLaunch = ["-OmnieOpenFolder", "-OmnieClone", "-OmnieUIFixture", "-OmnieUIHistoryFixture", "-OmnieUIAgentFixture", "-OmniePRFixture", "-OmnieUIPyFixture"].contains { args.contains($0) }
        #if DEBUG
        // Fixtures and launch files set up the editor themselves; an earlier run's tabs would leak in.
        if args.contains(where: { $0.hasPrefix("-OmnieUI") || $0 == "-OmniePRFixture" || $0 == "-OmnieOpenFile" }), !args.contains("-OmnieRestoreSessions") {
            workspace.restoresSessions = false
            // A UI test shouldn't inherit the previous run's Simple mode.
            if !args.contains("-OmnieSimpleMode") { simpleMode = false }
        }
        #endif
        if !opensFolderAtLaunch { workspace.reopenLast() }
        applyWordWrap()
        applyEditorGuides()
        // The line moves: ⌥↑/⌥↓ would otherwise move the caret by paragraph before the menu sees them.
        workspace.editor.keyCommands = [
            EditorKeyCommand(input: UIKeyCommand.inputUpArrow, modifiers: .alternate, id: "editor.moveLineUp"),
            EditorKeyCommand(input: UIKeyCommand.inputDownArrow, modifiers: .alternate, id: "editor.moveLineDown"),
            EditorKeyCommand(input: UIKeyCommand.inputUpArrow, modifiers: [.alternate, .shift], id: "editor.copyLineUp"),
            EditorKeyCommand(input: UIKeyCommand.inputDownArrow, modifiers: [.alternate, .shift], id: "editor.copyLineDown"),
            EditorKeyCommand(input: UIKeyCommand.inputUpArrow, modifiers: [.alternate, .command], id: "editor.addCursorAbove"),
            EditorKeyCommand(input: UIKeyCommand.inputDownArrow, modifiers: [.alternate, .command], id: "editor.addCursorBelow"),
            // ⌃ shortcuts don't reach the menu while the editor has focus.
            EditorKeyCommand(input: "r", modifiers: .control, id: "file.projects"),
            EditorKeyCommand(input: " ", modifiers: .control, id: "editor.suggest"),
            EditorKeyCommand(input: UIKeyCommand.f12, modifiers: [], id: "editor.goToDefinition"),
            EditorKeyCommand(input: UIKeyCommand.f12, modifiers: .shift, id: "editor.findReferences"),
            // ⌘F/⌘G/⌘D don't reach the menu while the editor has focus.
            EditorKeyCommand(input: "f", modifiers: .command, id: "editor.find"),
            EditorKeyCommand(input: "g", modifiers: .command, id: "editor.findNext"),
            EditorKeyCommand(input: "g", modifiers: [.command, .shift], id: "editor.findPrevious"),
            EditorKeyCommand(input: "d", modifiers: .command, id: "editor.selectNextOccurrence"),
            // ⇧⌘\ and its chord for brackets don't reach the menu while the editor has focus.
            EditorKeyCommand(input: "\\", modifiers: [.command, .shift], id: "editor.goToBracket"),
            EditorKeyCommand(input: "\\", modifiers: [.command, .shift, .control], id: "editor.selectToBracket"),
            // ⌃J joins lines, F8/⇧F8 walk the problems, all while the editor has focus.
            EditorKeyCommand(input: "j", modifiers: .control, id: "editor.joinLines"),
            EditorKeyCommand(input: UIKeyCommand.f8, modifiers: [], id: "editor.nextProblem"),
            EditorKeyCommand(input: UIKeyCommand.f8, modifiers: .shift, id: "editor.previousProblem"),
            EditorKeyCommand(input: "l", modifiers: [.alternate, .command], id: "editor.findInSelection"),
            EditorKeyCommand(input: "\r", modifiers: .command, id: "editor.insertLineBelow"),
            EditorKeyCommand(input: "\r", modifiers: [.command, .shift], id: "editor.insertLineAbove"),
            EditorKeyCommand(input: UIKeyCommand.inputRightArrow, modifiers: [.control, .shift], id: "editor.expandSelection"),
            EditorKeyCommand(input: UIKeyCommand.inputLeftArrow, modifiers: [.control, .shift], id: "editor.shrinkSelection"),
            EditorKeyCommand(input: "-", modifiers: .control, id: "navigation.back"),
            EditorKeyCommand(input: "-", modifiers: [.control, .shift], id: "navigation.forward"),
            EditorKeyCommand(input: "\u{8}", modifiers: .command, id: "editor.deleteToLineStart"),
            EditorKeyCommand(input: "\u{7F}", modifiers: .command, id: "editor.deleteToLineStart"),
            // The debugger's function keys, while the editor has focus.
            EditorKeyCommand(input: UIKeyCommand.f5, modifiers: [], id: "debug.startOrContinue"),
            EditorKeyCommand(input: UIKeyCommand.f5, modifiers: .shift, id: "debug.stop"),
            EditorKeyCommand(input: UIKeyCommand.f9, modifiers: [], id: "debug.toggleBreakpoint"),
            EditorKeyCommand(input: UIKeyCommand.f10, modifiers: [], id: "debug.stepOver"),
            EditorKeyCommand(input: UIKeyCommand.f11, modifiers: [], id: "debug.stepInto"),
            EditorKeyCommand(input: UIKeyCommand.f11, modifiers: .shift, id: "debug.stepOut"),
        ]
        // A long press on code offers what VS Code's context menu does (TypeScript, JavaScript, Python).
        workspace.editor.textView.additionalEditMenuElements = { [weak self] _ in
            guard let self, self.language.isAvailable else { return [] }
            let run = { (id: String) in { (_: UIAction) in self.registry.run(CommandID(rawValue: id)) } }
            return [
                UIAction(title: "Go to Definition", image: UIImage(systemName: "arrow.turn.down.right"), handler: run("editor.goToDefinition")),
                UIAction(title: "Find All References", image: UIImage(systemName: "list.bullet.indent"), handler: run("editor.findReferences")),
                UIAction(title: "Rename Symbol…", image: UIImage(systemName: "pencil"), handler: run("editor.rename")),
                UIAction(title: "Type & Docs", image: UIImage(systemName: "info.circle"), handler: run("editor.quickInfo")),
            ]
        }
        // A completion list takes ↑ ↓ ⏎ ⇥ ⎋ while it shows.
        workspace.editor.dynamicKeyCommands = { [weak self] in
            guard let self else { return [] }
            if self.language.completions != nil {
                return [
                    EditorKeyCommand(input: UIKeyCommand.inputUpArrow, modifiers: [], id: "completion.previous"),
                    EditorKeyCommand(input: UIKeyCommand.inputDownArrow, modifiers: [], id: "completion.next"),
                    EditorKeyCommand(input: "\r", modifiers: [], id: "completion.accept"),
                    EditorKeyCommand(input: "\t", modifiers: [], id: "completion.accept"),
                    EditorKeyCommand(input: UIKeyCommand.inputEscape, modifiers: [], id: "completion.dismiss"),
                ]
            }
            // A snippet being filled in takes Tab and Shift-Tab to walk its placeholders.
            if self.workspace.editor.snippet != nil {
                return [
                    EditorKeyCommand(input: "\t", modifiers: [], id: "snippet.next"),
                    EditorKeyCommand(input: "\t", modifiers: .shift, id: "snippet.previous"),
                    EditorKeyCommand(input: UIKeyCommand.inputEscape, modifiers: [], id: "snippet.end"),
                ]
            }
            // Esc closes the find bar first, then goes back to one cursor.
            if self.find.isOpen {
                return [EditorKeyCommand(input: UIKeyCommand.inputEscape, modifiers: [], id: "find.close")]
            }
            return self.workspace.hasExtraCarets
                ? [EditorKeyCommand(input: UIKeyCommand.inputEscape, modifiers: [], id: "carets.clear")] : []
        }
        workspace.editor.onKeyCommand = { [weak self] id in
            guard let self else { return }
            switch id {
            case "completion.previous": language.moveSelection(-1)
            case "completion.next": language.moveSelection(1)
            case "completion.accept": language.accept()
            case "completion.dismiss": language.dismiss()
            case "snippet.next": workspace.editor.snippetNext()
            case "snippet.previous": workspace.editor.snippetPrevious()
            case "snippet.end": workspace.editor.endSnippet()
            case "carets.clear": workspace.clearExtraCarets()
            case "find.close": find.close()
            default: registry.run(CommandID(rawValue: id))
            }
        }
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

    /// What an empty dock shows when it's asked for, as VS Code's sidebar opens on the explorer.
    static func defaultPanel(for dock: PaneLayout.Dock) -> UtilityTab {
        switch dock {
        case .left: .files
        case .right: .agent
        case .bottom: .terminal
        }
    }

    func toggle(_ dock: PaneLayout.Dock) {
        if panes[dock].isEmpty {
            let panel = Self.defaultPanel(for: dock).rawValue
            if !windowedPanels.contains(panel) {
                withAnimation(Motion.pane) { panes.move(panel, toNewGroupIn: dock) }
                if layout == .single && dock == .left { leftOverlay = true }
            }
            return
        }
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

    /// Leaves Simple mode for the full workbench (POSITIONING.md: the graduation path): the standard
    /// layout comes back and the agent is to hand.
    func graduate() {
        withAnimation(Motion.pane) {
            simpleMode = false
            focusMode = false
            applyLayout(.standard)
            show(.agent)
        }
    }

    /// A one-time pointer to the Workbench button, the first time Simple mode is turned on.
    private func hintAtGraduation() {
        let key = "view.simpleHintShown"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        workspace.banner = "Simple mode: the file list and the editor. Tap Workbench for docks, terminal and the agent."
    }

    nonisolated static let panesKey = "panes.v1"

    static func loadPanes() -> PaneLayout {
        guard let data = UserDefaults.standard.data(forKey: panesKey),
              var layout = try? JSONDecoder().decode(PaneLayout.self, from: data) else { return LayoutPreset.standard.layout }
        layout.repair(known: UtilityTab.allCases.map(\.rawValue))
        return layout
    }

    static func savePanes(_ layout: PaneLayout, key: String = panesKey) {
        if let data = try? JSONEncoder().encode(layout) { UserDefaults.standard.set(data, forKey: key) }
    }

    /// The key a project's layout is kept under: its path from the app's home, which survives
    /// reinstalls (the container's own path doesn't). A folder from a bookmark ends in "/" and one
    /// opened by path doesn't; both are the same project.
    nonisolated static func layoutKey(for root: URL) -> String {
        var path = root.standardizedFileURL.path(percentEncoded: false)
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        let home = URL(filePath: NSHomeDirectory()).standardizedFileURL.path(percentEncoded: false)
        return panesKey + "@" + (path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path)
    }

    /// Opening a project brings back the layout it had; a new one keeps the current layout.
    private func restoreLayout(for root: URL) {
        let key = Self.layoutKey(for: root)
        projectLayoutKey = key
        #if DEBUG
        // A preset from the launch arguments wins (UI tests, screenshots).
        if ProcessInfo.processInfo.arguments.contains("-OmnieLayout") { return }
        #endif
        guard let data = UserDefaults.standard.data(forKey: key),
              var layout = try? JSONDecoder().decode(PaneLayout.self, from: data) else {
            Self.savePanes(panes, key: key)
            return
        }
        layout.repair(known: UtilityTab.allCases.map(\.rawValue))
        if layout != panes { withAnimation(Motion.pane) { panes = layout } }
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
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.hasHardwareKeyboard = GCKeyboard.coalesced != nil
                }
            })
        }
    }

    deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
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
            Command(id: "view.simple", title: "Simple mode", menu: "View",
                    shortcut: Shortcut("m", [.command, .control]), surfaces: .ide, keywords: ["textastic", "minimal", "plain", "basic", "beginner", "clean"]) { [weak self] in
                guard let self else { return }
                withAnimation(Motion.pane) {
                    self.simpleMode.toggle()
                    // Simple mode keeps one panel: the file list.
                    if self.simpleMode {
                        self.focusMode = false
                        self.show(.files)
                        self.hintAtGraduation()
                    }
                }
            },
            Command(id: "view.graduate", title: "Graduate to the workbench", menu: "View",
                    surfaces: .ide, keywords: ["simple", "workbench", "docks", "terminal", "agent", "advanced", "graduate"]) { [weak self] in
                self?.graduate()
            },
            Command(id: "view.navigator", title: "Toggle left dock", menu: "View",
                    shortcut: Shortcut("1"), surfaces: .ide, keywords: ["sidebar", "files", "navigator"]) { [weak self] in
                self?.toggle(.left)
            },
            Command(id: "view.utility", title: "Toggle right dock", menu: "View",
                    shortcut: Shortcut("3"), surfaces: .ide, keywords: ["utility pane", "inspector"]) { [weak self] in
                self?.toggle(.right)
            },
            Command(id: "view.split", title: "Open in split", menu: "View",
                    shortcut: Shortcut("\\"), surfaces: .ide, keywords: ["split editor", "side by side", "editor 2"]) { [weak self] in
                guard let self else { return }
                if let file = self.workspace.openFile { self.split.open(file) }
                // Its first time: a group of its own on the right, beside whatever's there.
                if self.panes.location(of: UtilityTab.editor2.rawValue) == nil {
                    withAnimation(Motion.pane) { self.panes.move(UtilityTab.editor2.rawValue, toNewGroupIn: .right, at: 0) }
                }
                self.show(.editor2)
            },
            Command(id: "view.minimap", title: "Toggle minimap", menu: "View",
                    surfaces: .ide, keywords: ["overview", "scroll map"]) { [weak self] in
                self?.showsMinimap.toggle()
            },
            Command(id: "view.breadcrumbs", title: "Toggle breadcrumbs", menu: "View",
                    surfaces: .ide, keywords: ["path", "symbols", "strip", "navigation"]) { [weak self] in
                self?.showsBreadcrumbs.toggle()
            },
            Command(id: "view.stickyScroll", title: "Toggle sticky scroll", menu: "View",
                    surfaces: .ide, keywords: ["pinned", "scopes", "headers", "context"]) { [weak self] in
                self?.showsStickyScroll.toggle()
            },
            Command(id: "view.bottom", title: "Toggle bottom dock", menu: "View",
                    shortcut: Shortcut("j"), surfaces: .ide, keywords: ["panel", "terminal"]) { [weak self] in
                // An empty bottom dock gets the terminal, the usual thing to want there.
                self?.toggle(.bottom)
            },
            Command(id: "editor.goToDefinition", title: "Go to definition", menu: "Edit",
                    shortcut: Shortcut("j", [.command, .control]), surfaces: .ide, keywords: ["jump", "declaration", "f12"]) { [weak self] in
                guard let self else { return }
                Task { await self.language.goToDefinition() }
            },
            Command(id: "editor.findReferences", title: "Find all references", menu: "Edit",
                    shortcut: Shortcut("j", [.command, .control, .shift]), surfaces: .ide, keywords: ["usages", "callers", "where used"]) { [weak self] in
                guard let self else { return }
                Task { await self.language.findReferences() }
            },
            Command(id: "editor.find", title: "Find in file", menu: "Edit",
                    shortcut: Shortcut("f"), surfaces: .ide, keywords: ["search", "replace", "find"]) { [weak self] in
                guard let self else { return }
                let selection = self.workspace.editor.selectedRange
                let text = self.workspace.editor.text as NSString
                let seed = selection.length > 0 && NSMaxRange(selection) <= text.length ? text.substring(with: selection) : nil
                self.find.open(seed: seed)
            },
            Command(id: "editor.findNext", title: "Find next", menu: "Edit",
                    shortcut: Shortcut("g"), surfaces: .ide, keywords: ["search", "find"]) { [weak self] in
                guard let self, self.find.isOpen else { return }
                self.find.next()
            },
            Command(id: "editor.findPrevious", title: "Find previous", menu: "Edit",
                    shortcut: Shortcut("g", [.shift]), surfaces: .ide, keywords: ["search", "find"]) { [weak self] in
                guard let self, self.find.isOpen else { return }
                self.find.previous()
            },
            Command(id: "editor.findInSelection", title: "Find in selection", menu: "Edit",
                    shortcut: Shortcut("l", [.option, .command]), surfaces: .ide, keywords: ["scope", "within selection", "restrict", "find"]) { [weak self] in
                guard let self else { return }
                if !self.find.isOpen { self.find.open(seed: nil) }
                self.find.toggleInSelection()
            },
            Command(id: "editor.workspaceSymbols", title: "Go to symbol in workspace…", menu: "Edit",
                    shortcut: Shortcut("t"), surfaces: .ide, keywords: ["symbols", "outline", "navigate", "function", "class"]) { [weak self] in
                self?.workspaceSymbolOpen = true
            },
            Command(id: "test.runAll", title: "Run all tests", menu: "View",
                    surfaces: .ide, keywords: ["test", "vitest", "pytest", "spec"]) { [weak self] in
                guard let self else { return }
                self.show(.tests)
                Task { await self.tests.run() }
            },
            Command(id: "editor.rename", title: "Rename symbol…", menu: "Edit",
                    shortcut: Shortcut("e", [.command, .control]), surfaces: .ide, keywords: ["refactor", "f2"]) { [weak self] in
                guard let self else { return }
                Task { await self.language.startRename() }
            },
            Command(id: "editor.quickInfo", title: "Show type and docs", menu: "Edit",
                    shortcut: Shortcut("i", [.command, .control]), surfaces: .ide, keywords: ["hover", "quick info", "signature", "documentation"]) { [weak self] in
                guard let self else { return }
                Task { await self.language.showInfo() }
            },
            Command(id: "editor.suggest", title: "Show completions", menu: "Edit",
                    surfaces: .ide, keywords: ["intellisense", "autocomplete", "suggest"]) { [weak self] in
                guard let self else { return }
                Task { await self.language.complete() }
            },
            Command(id: "editor.addCursorAbove", title: "Add cursor above", menu: "Edit",
                    shortcut: Shortcut("↑", [.option, .command]), surfaces: .ide, keywords: ["multi-cursor", "multiple cursors", "column"]) { [weak self] in
                self?.workspace.addCursor(above: true)
            },
            Command(id: "editor.addCursorBelow", title: "Add cursor below", menu: "Edit",
                    shortcut: Shortcut("↓", [.option, .command]), surfaces: .ide, keywords: ["multi-cursor", "multiple cursors", "column"]) { [weak self] in
                self?.workspace.addCursor(above: false)
            },
            Command(id: "editor.changeAllOccurrences", title: "Change all occurrences", menu: "Edit",
                    shortcut: Shortcut("l", [.command, .shift]), surfaces: .ide, keywords: ["multi-cursor", "select all occurrences", "edit all"]) { [weak self] in
                self?.workspace.changeAllOccurrences()
            },
            Command(id: "editor.selectNextOccurrence", title: "Select next occurrence", menu: "Edit",
                    shortcut: Shortcut("d"), surfaces: .ide, keywords: ["multi-cursor", "add cursor", "next match", "occurrence"]) { [weak self] in
                self?.workspace.selectNextOccurrence()
            },
            Command(id: "editor.expandSelection", title: "Expand selection", menu: "Edit",
                    shortcut: Shortcut("→", [.control, .shift]), surfaces: .ide, keywords: ["grow", "smart select", "word", "brackets"]) { [weak self] in
                self?.workspace.editor.expandSelection()
            },
            Command(id: "editor.shrinkSelection", title: "Shrink selection", menu: "Edit",
                    shortcut: Shortcut("←", [.control, .shift]), surfaces: .ide, keywords: ["shrink", "smaller", "smart select"]) { [weak self] in
                self?.workspace.editor.shrinkSelection()
            },
            Command(id: "editor.goToBracket", title: "Go to matching bracket", menu: "Edit",
                    shortcut: Shortcut("\\", [.command, .shift]), surfaces: .ide, keywords: ["jump", "parenthesis", "brace", "paren"]) { [weak self] in
                self?.workspace.editor.goToMatchingBracket()
            },
            Command(id: "editor.selectToBracket", title: "Select to matching bracket", menu: "Edit",
                    shortcut: Shortcut("\\", [.command, .shift, .control]), surfaces: .ide, keywords: ["select", "parenthesis", "brace"]) { [weak self] in
                self?.workspace.editor.selectToMatchingBracket()
            },
            Command(id: "editor.nextSnippetStop", title: "Next snippet placeholder", menu: "Edit",
                    surfaces: .ide, keywords: ["snippet", "tab stop", "placeholder", "tab"]) { [weak self] in
                self?.workspace.editor.snippetNext()
            },
            Command(id: "editor.previousSnippetStop", title: "Previous snippet placeholder", menu: "Edit",
                    surfaces: .ide, keywords: ["snippet", "tab stop", "placeholder", "shift tab"]) { [weak self] in
                self?.workspace.editor.snippetPrevious()
            },
            Command(id: "editor.endSnippet", title: "Leave snippet", menu: "Edit",
                    surfaces: .ide, keywords: ["snippet", "escape", "stop filling"]) { [weak self] in
                self?.workspace.editor.endSnippet()
            },
            Command(id: "editor.fold", title: "Fold", menu: "Edit",
                    shortcut: Shortcut("[", [.option, .command]), surfaces: .ide, keywords: ["collapse", "code folding", "hide block"]) { [weak self] in
                self?.workspace.editor.foldAtCaret()
            },
            Command(id: "editor.unfold", title: "Unfold", menu: "Edit",
                    shortcut: Shortcut("]", [.option, .command]), surfaces: .ide, keywords: ["expand", "code folding"]) { [weak self] in
                self?.workspace.editor.unfoldAtCaret()
            },
            Command(id: "editor.foldAll", title: "Fold all", menu: "Edit",
                    shortcut: Shortcut("[", [.control, .option, .command]), surfaces: .ide, keywords: ["collapse all", "outline"]) { [weak self] in
                self?.workspace.editor.foldAll()
            },
            Command(id: "editor.unfoldAll", title: "Unfold all", menu: "Edit",
                    shortcut: Shortcut("]", [.control, .option, .command]), surfaces: .ide, keywords: ["expand all"]) { [weak self] in
                self?.workspace.editor.unfoldAll()
            },
            Command(id: "editor.toggleComment", title: "Toggle line comment", menu: "Edit",
                    shortcut: Shortcut("/"), surfaces: .ide, keywords: ["comment out", "uncomment"]) { [weak self] in
                self?.workspace.perform(.toggleComment)
            },
            Command(id: "editor.moveLineUp", title: "Move line up", menu: "Edit",
                    shortcut: Shortcut("↑", [.option]), surfaces: .ide, keywords: ["swap lines"]) { [weak self] in
                self?.workspace.perform(.moveUp)
            },
            Command(id: "editor.moveLineDown", title: "Move line down", menu: "Edit",
                    shortcut: Shortcut("↓", [.option]), surfaces: .ide, keywords: ["swap lines"]) { [weak self] in
                self?.workspace.perform(.moveDown)
            },
            Command(id: "editor.copyLineUp", title: "Copy line up", menu: "Edit",
                    shortcut: Shortcut("↑", [.option, .shift]), surfaces: .ide, keywords: ["duplicate line"]) { [weak self] in
                self?.workspace.perform(.copyUp)
            },
            Command(id: "editor.copyLineDown", title: "Copy line down", menu: "Edit",
                    shortcut: Shortcut("↓", [.option, .shift]), surfaces: .ide, keywords: ["duplicate line"]) { [weak self] in
                self?.workspace.perform(.copyDown)
            },
            Command(id: "editor.deleteLine", title: "Delete line", menu: "Edit",
                    shortcut: Shortcut("k", [.command, .shift]), surfaces: .ide, keywords: ["remove line"]) { [weak self] in
                self?.workspace.perform(.delete)
            },
            Command(id: "editor.deleteToLineStart", title: "Delete all left", menu: "Edit",
                    shortcut: Shortcut("\u{8}", [.command]), surfaces: .ide, keywords: ["delete to start of line", "backspace", "to beginning"]) { [weak self] in
                self?.workspace.perform(.deleteToLineStart)
            },
            Command(id: "editor.deleteToLineEnd", title: "Delete all right", menu: "Edit",
                    surfaces: .ide, keywords: ["delete to end of line", "forward delete", "to end"]) { [weak self] in
                self?.workspace.perform(.deleteToLineEnd)
            },
            Command(id: "editor.convertToSpaces", title: "Convert indentation to spaces", menu: "Edit",
                    surfaces: .ide, keywords: ["tabs", "spaces", "indentation", "indent"]) { [weak self] in
                self?.workspace.convertIndentation(toSpaces: true)
            },
            Command(id: "editor.convertToTabs", title: "Convert indentation to tabs", menu: "Edit",
                    surfaces: .ide, keywords: ["spaces", "tabs", "indentation", "indent"]) { [weak self] in
                self?.workspace.convertIndentation(toSpaces: false)
            },
            Command(id: "editor.indent", title: "Indent line", menu: "Edit",
                    shortcut: Shortcut("]"), surfaces: .ide, keywords: ["tab", "shift right"]) { [weak self] in
                self?.workspace.perform(.indent)
            },
            Command(id: "editor.outdent", title: "Outdent line", menu: "Edit",
                    shortcut: Shortcut("["), surfaces: .ide, keywords: ["untab", "shift left", "dedent"]) { [weak self] in
                self?.workspace.perform(.outdent)
            },
            Command(id: "editor.sortLinesAscending", title: "Sort lines ascending", menu: "Edit",
                    surfaces: .ide, keywords: ["sort", "order", "alphabetical", "a-z"]) { [weak self] in
                self?.workspace.perform(.sortAscending)
            },
            Command(id: "editor.sortLinesDescending", title: "Sort lines descending", menu: "Edit",
                    surfaces: .ide, keywords: ["sort", "order", "reverse", "z-a"]) { [weak self] in
                self?.workspace.perform(.sortDescending)
            },
            Command(id: "editor.trimTrailingWhitespace", title: "Trim trailing whitespace", menu: "Edit",
                    surfaces: .ide, keywords: ["whitespace", "clean", "trailing spaces", "trim"]) { [weak self] in
                self?.workspace.perform(.trimTrailingWhitespace)
            },
            Command(id: "editor.joinLines", title: "Join lines", menu: "Edit",
                    shortcut: Shortcut("j", [.control]), surfaces: .ide, keywords: ["merge lines", "combine", "reflow", "unwrap"]) { [weak self] in
                self?.workspace.perform(.joinLines)
            },
            Command(id: "editor.insertLineAbove", title: "Insert line above", menu: "Edit",
                    shortcut: Shortcut("\r", [.command, .shift]), surfaces: .ide, keywords: ["new line", "above", "blank line"]) { [weak self] in
                self?.workspace.perform(.insertLineAbove)
            },
            Command(id: "editor.insertLineBelow", title: "Insert line below", menu: "Edit",
                    shortcut: Shortcut("\r", [.command]), surfaces: .ide, keywords: ["new line", "below", "blank line"]) { [weak self] in
                self?.workspace.perform(.insertLineBelow)
            },
            Command(id: "file.copyPath", title: "Copy path", menu: "File",
                    surfaces: .ide, keywords: ["clipboard", "absolute path", "full path", "location"]) { [weak self] in
                guard let url = self?.workspace.openFile else { return }
                UIPasteboard.general.string = url.path(percentEncoded: false)
            },
            Command(id: "file.copyRelativePath", title: "Copy relative path", menu: "File",
                    surfaces: .ide, keywords: ["clipboard", "project path", "relative"]) { [weak self] in
                guard let path = self?.workspace.relativePath else { return }
                UIPasteboard.general.string = path
            },
            Command(id: "editor.nextProblem", title: "Go to next problem", menu: "View",
                    surfaces: .ide, keywords: ["problem", "error", "warning", "diagnostic", "f8", "issues"]) { [weak self] in
                self?.workspace.goToProblem(forward: true)
            },
            Command(id: "editor.previousProblem", title: "Go to previous problem", menu: "View",
                    surfaces: .ide, keywords: ["problem", "error", "warning", "diagnostic", "f8", "issues"]) { [weak self] in
                self?.workspace.goToProblem(forward: false)
            },
            Command(id: "navigation.back", title: "Go back", menu: "View",
                    shortcut: Shortcut("-", [.control]), surfaces: .ide, keywords: ["history", "previous", "navigate", "return"]) { [weak self] in
                self?.workspace.goBack()
            },
            Command(id: "navigation.forward", title: "Go forward", menu: "View",
                    shortcut: Shortcut("-", [.control, .shift]), surfaces: .ide, keywords: ["history", "next", "navigate"]) { [weak self] in
                self?.workspace.goForward()
            },
            Command(id: "debug.startOrContinue", title: "Start debugging", menu: "Debug",
                    surfaces: .ide, keywords: ["debug", "run", "breakpoint", "f5", "continue"]) { [weak self] in
                guard let self else { return }
                if self.debug.isPaused { self.debug.send(.resume); return }
                guard let target = self.debug.openDebugTarget else {
                    self.workspace.banner = "Open a JavaScript, TypeScript or Python file to debug."
                    return
                }
                self.show(.debug)
                self.debug.start(entry: target)
            },
            Command(id: "debug.toggleBreakpoint", title: "Toggle breakpoint", menu: "Debug",
                    surfaces: .ide, keywords: ["debug", "breakpoint", "f9", "stop here"]) { [weak self] in
                guard let self, self.workspace.openFile != nil else { return }
                self.workspace.editor.toggleBreakpoint(line: self.workspace.editor.currentLine)
            },
            Command(id: "debug.editCondition", title: "Edit breakpoint condition…", menu: "Debug",
                    surfaces: .ide, keywords: ["debug", "conditional", "when", "breakpoint", "expression"]) { [weak self] in
                guard let self, self.workspace.openFile != nil else { return }
                let line = self.workspace.editor.currentLine
                let existing = self.workspace.breakpointConditions[self.workspace.relativePath ?? ""]?[line] ?? ""
                self.breakpointPrompt = .init(line: line, text: existing)
            },
            Command(id: "debug.stepOver", title: "Step over", menu: "Debug",
                    surfaces: .ide, keywords: ["debug", "f10", "next line"]) { [weak self] in
                self?.debug.send(.stepOver)
            },
            Command(id: "debug.stepInto", title: "Step into", menu: "Debug",
                    surfaces: .ide, keywords: ["debug", "f11", "into function"]) { [weak self] in
                self?.debug.send(.stepInto)
            },
            Command(id: "debug.stepOut", title: "Step out", menu: "Debug",
                    surfaces: .ide, keywords: ["debug", "return", "out of function"]) { [weak self] in
                self?.debug.send(.stepOut)
            },
            Command(id: "debug.stop", title: "Stop debugging", menu: "Debug",
                    surfaces: .ide, keywords: ["debug", "end session", "kill"]) { [weak self] in
                self?.debug.stop()
            },
            Command(id: "editor.transformUpper", title: "Transform to uppercase", menu: "Edit",
                    surfaces: .ide, keywords: ["case", "upper", "capital"]) { [weak self] in
                self?.workspace.editor.transformCase(.upper)
            },
            Command(id: "editor.transformLower", title: "Transform to lowercase", menu: "Edit",
                    surfaces: .ide, keywords: ["case", "lower", "small"]) { [weak self] in
                self?.workspace.editor.transformCase(.lower)
            },
            Command(id: "editor.transformTitle", title: "Transform to title case", menu: "Edit",
                    surfaces: .ide, keywords: ["case", "title", "capitalize"]) { [weak self] in
                self?.workspace.editor.transformCase(.title)
            },
            Command(id: "view.zoomIn", title: "Zoom in (editor text)", menu: "View",
                    shortcut: Shortcut("="), surfaces: .ide, keywords: ["font size", "bigger", "larger"]) { [weak self] in
                self?.workspace.fontScale += 0.1
            },
            Command(id: "view.zoomOut", title: "Zoom out (editor text)", menu: "View",
                    shortcut: Shortcut("-"), surfaces: .ide, keywords: ["font size", "smaller"]) { [weak self] in
                self?.workspace.fontScale -= 0.1
            },
            Command(id: "view.zoomReset", title: "Reset zoom (editor text)", menu: "View",
                    shortcut: Shortcut("0"), surfaces: .ide, keywords: ["font size", "actual size"]) { [weak self] in
                self?.workspace.fontScale = 1
            },
            Command(id: "file.revert", title: "Revert file", menu: "File",
                    surfaces: .ide, keywords: ["discard changes", "reload from disk"]) { [weak self] in
                guard let self, self.workspace.openFile != nil else { return }
                self.workspace.revertFile()
            },
            Command(id: "snapshot.take", title: "Take a snapshot", menu: "File",
                    surfaces: .ide, keywords: ["backup", "save point", "snapshot", "restore"]) { [weak self] in
                _ = self?.snapshots.take(reason: "Manual")
            },
            Command(id: "snapshot.browse", title: "Snapshots…", menu: "File",
                    surfaces: .ide, keywords: ["backup", "restore", "history", "snapshot", "unevaporate"]) { [weak self] in
                guard let self else { return }
                self.snapshots.opening()
                self.snapshotsOpen = true
            },
            Command(id: "view.wordWrap", title: "Toggle word wrap", menu: "View",
                    shortcut: Shortcut("z", [.option]), surfaces: .ide, keywords: ["wrap lines", "long lines", "soft wrap"]) { [weak self] in
                self?.wordWrap.toggle()
            },
            Command(id: "view.whitespace", title: "Toggle render whitespace", menu: "View",
                    surfaces: .ide, keywords: ["spaces", "tabs", "dots", "invisible", "whitespace"]) { [weak self] in
                self?.showsWhitespace.toggle()
            },
            Command(id: "view.indentGuides", title: "Toggle indent guides", menu: "View",
                    surfaces: .ide, keywords: ["guides", "indentation", "vertical lines"]) { [weak self] in
                self?.showsIndentGuides.toggle()
            },
            Command(id: "view.ruler", title: "Toggle ruler", menu: "View",
                    surfaces: .ide, keywords: ["column", "guide", "margin", "100"]) { [weak self] in
                self?.showsRuler.toggle()
            },
            Command(id: "view.sidebar", title: "Toggle sidebar", menu: "View",
                    shortcut: Shortcut("b"), surfaces: .ide, keywords: ["left dock", "explorer", "files"]) { [weak self] in
                self?.toggle(.left)
            },
            Command(id: "view.resetLayout", title: "Reset layout", menu: "View",
                    surfaces: .ide, keywords: ["panes", "docks", "panels", "restore", "default"]) { [weak self] in
                guard let self else { return }
                self.focusMode = false
                self.applyLayout(.standard)
            },
            Command(id: "view.closeAllPanels", title: "Close all panels", menu: "View",
                    surfaces: .ide, keywords: ["docks", "hide", "editor only"]) { [weak self] in
                guard let self else { return }
                withAnimation(Motion.pane) { for dock in PaneLayout.Dock.allCases { self.panes.hidden.insert(dock) } }
                self.leftOverlay = false
            },
            Command(id: "file.projects", title: "Open recent project…", menu: "File",
                    shortcut: Shortcut("r", [.control]), keywords: ["switch project", "recent", "workspace", "folder"]) { [weak self] in
                self?.projectsOpen = true
            },
            Command(id: "file.newProject", title: "New project…", menu: "File",
                    shortcut: Shortcut("n", [.command, .control]), keywords: ["create project", "template", "start"]) { [weak self] in
                self?.newProjectOpen = true
            },
            Command(id: "file.closeFolder", title: "Close folder", menu: "File",
                    keywords: ["close project", "close workspace"]) { [weak self] in
                guard let self, self.workspace.rootURL != nil else { return }
                self.workspace.closeFolder()
            },
            Command(id: "editor.closeAll", title: "Close all tabs", menu: "File",
                    shortcut: Shortcut("w", [.command, .option]), surfaces: .ide, keywords: ["close all editors"]) { [weak self] in
                self?.workspace.closeTabs()
            },
            Command(id: "editor.closeOthers", title: "Close other tabs", menu: "File",
                    surfaces: .ide, keywords: ["close other editors"]) { [weak self] in
                guard let self, let file = self.workspace.openFile else { return }
                self.workspace.closeTabs(except: file)
            },
            Command(id: "editor.closeSaved", title: "Close saved tabs", menu: "File",
                    surfaces: .ide, keywords: ["close saved editors"]) { [weak self] in
                self?.workspace.closeSavedTabs()
            },
            Command(id: "editor.reopenClosed", title: "Reopen closed tab", menu: "File",
                    shortcut: Shortcut("t", [.command, .option]), surfaces: .ide, keywords: ["undo close", "reopen editor"]) { [weak self] in
                self?.workspace.reopenClosedTab()
            },
            Command(id: "file.openFolder", title: "Open folder", menu: "File",
                    shortcut: Shortcut("o"), keywords: ["project", "workspace"]) { [weak self] in
                self?.workspace.isPickingFolder = true
            },
            Command(id: "file.addFolder", title: "Add folder to workspace…", menu: "File",
                    keywords: ["multi-root", "multi root", "workspace", "extra folder", "another folder"]) { [weak self] in
                guard let self, workspace.rootURL != nil else { return }
                workspace.isAddingFolder = true
            },
            Command(id: "file.removeFolder", title: "Remove folder from workspace", menu: "File",
                    keywords: ["multi-root", "multi root", "workspace", "extra folder", "drop folder"]) { [weak self] in
                guard let self else { return }
                guard let file = workspace.openFile, let extra = workspace.extraFolder(containing: file) else {
                    workspace.banner = "Open a file in an added folder, then remove that folder."
                    return
                }
                workspace.removeFolder(extra)
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
                guard let self else { return }
                // Format on save (Settings), on an explicit save only, as VS Code does.
                if self.language.formatsOnSave, self.language.canFormat {
                    Task {
                        await self.language.formatDocument(quiet: true)
                        self.workspace.saveCurrent()
                    }
                } else {
                    self.workspace.saveCurrent()
                }
            },
            Command(id: "file.saveAll", title: "Save all", menu: "File",
                    shortcut: Shortcut("s", [.option, .command]), keywords: ["save everything", "write", "all files"]) { [weak self] in
                guard let self else { return }
                self.workspace.saveCurrent()
                self.split.save()
            },
            Command(id: "editor.format", title: "Format document", menu: "Edit",
                    shortcut: Shortcut("f", [.option, .shift]), surfaces: .ide, keywords: ["prettier", "beautify", "pretty print", "indent"]) { [weak self] in
                guard let self else { return }
                Task { await self.language.formatDocument() }
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
            Command(id: "git.blame", title: "Toggle blame", menu: "Git",
                    shortcut: Shortcut("b", [.command, .option]), surfaces: .ide, keywords: ["annotate", "who changed", "author"]) { [weak self] in
                guard let self, self.workspace.git.repo != nil else { return }
                self.showsBlame.toggle()
            },
            Command(id: "help.welcome", title: "Welcome", menu: "Help", keywords: ["onboarding", "sample project", "get started"]) { [weak self] in
                self?.welcomeOpen = true
            },
            Command(id: "git.lfsPull", title: "Download Git LFS files", menu: "Git", keywords: ["large files", "lfs", "pull"]) { [weak self] in
                guard let self, self.workspace.git.repo != nil else { return }
                Task { await self.workspace.git.lfsPull(isOffline: self.networkUnavailable) }
            },
            Command(id: "git.remotes", title: "Remotes…", menu: "Git",
                    keywords: ["move repo", "migrate", "mirror", "forge", "upstream", "add remote"]) { [weak self] in
                guard let self, self.workspace.git.repo != nil else { return }
                self.remotesSheetOpen = true
            },
            Command(id: "git.pullRequests", title: "Pull Requests…", menu: "Git",
                    keywords: ["merge request", "pr", "mr", "review", "checks", "ci", "forgejo", "gitea", "gitlab", "github"]) { [weak self] in
                guard let self, self.workspace.git.repo != nil else { return }
                self.pullRequestsOpen = true
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
            Command(id: "agent.undoApply", title: "Undo agent changes", menu: "Agent",
                    surfaces: .ide, keywords: ["undo", "revert", "agent", "snapshot", "restore"]) { [weak self] in
                self?.undoAgentApply()
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
        } + UtilityTab.allCases.map { tab in
            Command(id: CommandID(rawValue: "panel.close.\(tab.rawValue.lowercased().replacingOccurrences(of: " ", with: ""))"),
                    title: "Close \(tab.rawValue.lowercased()) panel", menu: "View", surfaces: .ide, keywords: ["hide", "panel"]) { [weak self] in
                guard let self else { return }
                withAnimation(Motion.pane) { self.panes.close(tab.rawValue) }
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
