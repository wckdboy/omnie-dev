// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

import DesignKit
import GitKit
import RunKit
import SwiftUI
import TermKit

/// The Terminal tab: TermKit's built-in commands over the open project, with RunKit for running
/// code and tests and GitKit for git (PLAN.md §12 L0). Not a Unix shell; `help` lists what works.
struct TerminalPanel: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var palette
    @State private var shell: Shell?
    @State private var lines: [Line] = []
    @State private var input = ""
    @State private var history: [String] = []
    @State private var historyIndex: Int?
    @State private var busy = false
    @FocusState private var focused: Bool

    struct Line: Identifiable {
        let id = UUID()
        enum Kind { case command, output, error }
        let kind: Kind
        let text: String
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button { Task { await submit("test") } } label: { Label("Run tests", systemImage: "checkmark.diamond") }
                    .disabled(shell == nil || busy)
                Button { Task { await submit("run \(model.workspace.relativePath ?? "")") } } label: { Label("Run file", systemImage: "play") }
                    .disabled(!canRunOpenFile || busy)
                Spacer()
                if busy { ProgressView().controlSize(.small) }
            }
            .buttonStyle(.bordered)
            .font(.system(size: 13))
            .padding(12)
            Rectangle().fill(palette.surface.hairline.color).frame(height: Metrics.hairline)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        if lines.isEmpty {
                            Text(shell == nil ? "Open a project to use the terminal." : "Type help to see the built-in commands.")
                                .foregroundStyle(palette.text.secondary.color)
                        }
                        ForEach(lines) { line in
                            Text(line.text.isEmpty ? " " : line.text)
                                .foregroundStyle(color(for: line))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        Color.clear.frame(height: 1).id("end")
                    }
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(12)
                }
                .onChange(of: lines.count) { proxy.scrollTo("end", anchor: .bottom) }
            }
            Rectangle().fill(palette.surface.hairline.color).frame(height: Metrics.hairline)
            HStack(spacing: 6) {
                Text(shell?.prompt ?? "$")
                    .foregroundStyle(palette.accent.ion.color)
                TextField("", text: $input)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($focused)
                    .onSubmit { Task { await submit(input) } }
                    .onKeyPress(.upArrow) { recall(-1); return .handled }
                    .onKeyPress(.downArrow) { recall(1); return .handled }
                    .disabled(shell == nil || busy)
                    .accessibilityLabel("Command")
            }
            .font(.system(size: 13, design: .monospaced))
            .padding(12)
        }
        .background(palette.surface.pane.color)
        .onAppear(perform: attach)
        .onChange(of: model.workspace.rootURL) { attach() }
        #if DEBUG
        .task {
            let args = ProcessInfo.processInfo.arguments
            try? await Task.sleep(for: .milliseconds(300))
            if args.contains("-OmnieRunTests") { await submit("test") }
            // `-OmnieTerminal "ls; cd src; cat a.ts"` types commands into the terminal.
            if let i = args.firstIndex(of: "-OmnieTerminal"), args.indices.contains(i + 1) {
                for command in args[i + 1].split(separator: ";") { await submit(String(command)) }
            }
        }
        #endif
    }

    private var canRunOpenFile: Bool {
        guard let path = model.workspace.relativePath else { return false }
        return [".ts", ".tsx", ".js", ".mjs", ".jsx", ".py"].contains { path.hasSuffix($0) }
    }

    private func color(for line: Line) -> Color {
        switch line.kind {
        case .command: return palette.accent.ion.color
        case .error: return palette.status.error.color
        case .output:
            if line.text.hasPrefix("✗") || line.text.hasPrefix("! ") || line.text.hasPrefix("Stopped") { return palette.status.error.color }
            if line.text.hasPrefix("✓") { return palette.status.ok.color }
            return palette.text.primary.color
        }
    }

    private func attach() {
        guard let root = model.workspace.rootURL else { shell = nil; return }
        guard shell?.root.standardizedFileURL != root.standardizedFileURL else { return }
        let workspace = model.workspace
        shell = Shell(root: root, hooks: .init(
            run: { file in
                workspace.saveCurrent()
                do { return await (try JSRunner(root: root)).runFile(file).report } catch { return error.localizedDescription }
            },
            test: { file in
                workspace.saveCurrent()
                return await AgentRuns.tests(root: root, file: file)
            },
            git: { args in await Self.git(args, workspace: workspace) },
            open: { file in workspace.open(file: root.appending(path: file)) }))
        lines = []
    }

    private func submit(_ command: String) async {
        let command = command.trimmingCharacters(in: .whitespaces)
        input = ""
        historyIndex = nil
        guard let shell, !command.isEmpty else { return }
        if history.last != command { history.append(command) }
        lines.append(Line(kind: .command, text: "\(shell.prompt) \(command)"))
        busy = true
        let started = Date()
        let output = await shell.execute(command)
        busy = false
        #if DEBUG
        print("[term] $ \(command)  (\(Int(Date().timeIntervalSince(started) * 1000)) ms)\n\(output ?? "")")
        #endif
        guard let output else { lines = []; return }
        let isError = output.hasSuffix("not a built-in command. Type help to see them.") || output.contains(": outside the project")
        for text in output.split(separator: "\n", omittingEmptySubsequences: false) where !(output.isEmpty) {
            lines.append(Line(kind: isError ? .error : .output, text: String(text)))
        }
        if lines.count > 4_000 { lines.removeFirst(lines.count - 4_000) }
        focused = true
    }

    private func recall(_ step: Int) {
        guard !history.isEmpty else { return }
        let next = (historyIndex ?? history.count) + step
        guard next >= 0 else { return }
        if next >= history.count { historyIndex = nil; input = ""; return }
        historyIndex = next
        input = history[next]
    }

    /// git status, log, diff and branch from GitKit, in the familiar short forms.
    static func git(_ args: [String], workspace: WorkspaceModel) async -> String {
        guard let repo = workspace.git.repo else { return "Not a git repository." }
        do {
            switch args.first {
            case "status":
                let status = try await repo.status()
                let head = "On branch \(status.head.branch ?? "(detached)")"
                guard !status.entries.isEmpty else { return head + "\nnothing to commit, working tree clean" }
                return head + "\n" + status.entries.map { "\(Self.code($0.kind)) \($0.path)" }.joined(separator: "\n")
            case "log":
                return try await repo.log(limit: 20).map {
                    "\($0.id.short) \($0.summary)  (\($0.authorName), \($0.date.formatted(date: .abbreviated, time: .shortened)))"
                }.joined(separator: "\n")
            case "diff":
                let added = try await repo.pendingAddedLines(limit: 2_000)
                guard !added.isEmpty else { return "No added lines since the last commit." }
                return "Lines added since the last commit (deletions aren't shown here; the Timeline has full diffs):\n"
                    + added.map { "\($0.path):\($0.line) + \($0.text)" }.joined(separator: "\n")
            case "branch":
                let current = try await repo.head().branch
                return try await repo.branches().map { ($0.name == current ? "* " : "  ") + $0.name }.joined(separator: "\n")
            default:
                return "git: status, log, diff and branch work here."
            }
        } catch {
            return error.localizedDescription
        }
    }

    static func code(_ kind: StatusEntry.Kind) -> String {
        switch kind {
        case .added: "A "
        case .modified: " M"
        case .deleted: " D"
        case .renamed: "R "
        case .typeChanged: " T"
        case .untracked: "??"
        case .conflicted: "UU"
        }
    }
}
