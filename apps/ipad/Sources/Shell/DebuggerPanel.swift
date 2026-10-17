// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

import DesignKit
import EditorKit
import RunKit
import SwiftUI

/// The debug session's state: which file is running, where it stopped, what's in scope, and the
/// console. One per process, like the other panels' models.
@MainActor
@Observable
final class DebugModel {
    enum State: Equatable { case idle, running, paused, ended }

    private(set) var state: State = .idle
    private(set) var pause: Debugger.Pause?
    private(set) var output: [RunResult.Line] = []
    private(set) var entry: String?
    private(set) var failure: String?
    /// Expressions evaluated at the current stop (newest last).
    private(set) var evaluations: [Debugger.Pause.Evaluation] = []
    /// Watch expressions, re-evaluated at every stop; kept across launches.
    private(set) var watches: [String] = UserDefaults.standard.stringArray(forKey: DebugModel.watchesKey) ?? []
    /// The latest value of each watch, by expression.
    private(set) var watchValues: [String: Debugger.Pause.Evaluation] = [:]
    @ObservationIgnored private var pendingWatches: [String] = []
    @ObservationIgnored private var stopKey = ""
    static let watchesKey = "debug.watches"

    /// Resolved when the app picks an answer at a stop; the runner waits on it.
    @ObservationIgnored private var decision: CheckedContinuation<Debugger.Answer, Never>?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored weak var workspace: WorkspaceModel?

    var isPaused: Bool { state == .paused }
    var isRunning: Bool { state == .running || state == .paused }

    /// Debugs a project-relative file. Starting again replaces any session in progress.
    func start(entry path: String) {
        guard let root = workspace?.rootURL else { return }
        stop()
        entry = path
        output = []
        pause = nil
        failure = nil
        state = .running
        let breakpoints = Set((workspace?.breakpoints ?? [:]).flatMap { file, lines in
            lines.map { Debugger.Breakpoint(file: file, line: $0, condition: workspace?.breakpointConditions[file]?[$0]) }
        })
        task = Task { [weak self] in
            guard let runner = try? JSRunner(root: root) else {
                self?.failure = "The debugger couldn't start."
                self?.state = .ended
                return
            }
            let result = await runner.debug(path, breakpoints: breakpoints) { [weak self] pause in
                guard let self else { return .stop }
                return await self.hold(pause)
            }
            guard let self, !Task.isCancelled else { return }
            output = result.output
            if case .timedOut = result.ending { failure = "The debugger timed out." }
            state = .ended
            pause = nil
        }
    }

    /// Waits at a stop until the app answers (the buttons, an expression, or a key).
    private func hold(_ pause: Debugger.Pause) async -> Debugger.Answer {
        let key = "\(pause.file):\(pause.line)"
        if key != stopKey {
            stopKey = key
            evaluations = []
            watchValues = [:]
            pendingWatches = watches   // refreshed once per stop, before the app decides
        }
        if let evaluated = pause.evaluated {
            if evaluations.last != evaluated { evaluations.append(evaluated) }
            if watches.contains(evaluated.expression) { watchValues[evaluated.expression] = evaluated }
        }
        self.pause = pause
        state = .paused
        if !pendingWatches.isEmpty { return .evaluate(pendingWatches.removeFirst()) }
        return await withCheckedContinuation { continuation in decision = continuation }
    }

    /// Answers the stop in progress.
    func send(_ answer: Debugger.Answer) {
        let continuation = decision
        decision = nil
        pause = nil
        state = answer == .stop ? .ended : .running
        continuation?.resume(returning: answer)
    }

    /// Evaluates an expression in the paused frame; the result arrives with the next stop of the
    /// same line, which is really the same stop held open.
    func evaluate(_ expression: String) {
        let text = expression.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, isPaused else { return }
        send(.evaluate(text))
    }

    /// Adds a watch: it is evaluated now (if stopped) and at every stop after.
    func addWatch(_ expression: String) {
        let text = expression.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !watches.contains(text) else { return }
        watches.append(text)
        UserDefaults.standard.set(watches, forKey: Self.watchesKey)
        evaluate(text)
    }

    func removeWatch(_ expression: String) {
        watches.removeAll { $0 == expression }
        watchValues[expression] = nil
        UserDefaults.standard.set(watches, forKey: Self.watchesKey)
    }

    /// Stops the session (a stop while paused unwinds the worker).
    func stop() {
        if decision != nil { send(.stop) }
        task?.cancel()
        task = nil
        if state != .idle { state = .ended }
        pause = nil
        evaluations = []
        watchValues = [:]
        pendingWatches = []
    }

    /// The project-relative path of the file on screen, if it can be debugged.
    var openDebugTarget: String? {
        guard let path = workspace?.relativePath, [".ts", ".tsx", ".js", ".mjs", ".jsx"].contains(where: path.hasSuffix) else { return nil }
        return path
    }
}

/// The Debug panel: the stop's call stack and locals, the controls, and the console.
struct DebugPanel: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var palette
    @State private var expression = ""

    var body: some View {
        let debug = model.debug
        VStack(alignment: .leading, spacing: 0) {
            header(debug)
            controls(debug)
            Divider().overlay(palette.surface.hairline.color)
            if let pause = debug.pause {
                stop(pause)
            } else if debug.output.isEmpty {
                Text(debug.state == .running ? "Running…" : "No session. F5 debugs the open file.")
                    .font(.caption).foregroundStyle(palette.text.secondary.color).padding(12)
            }
            console(debug)
        }
        .background(palette.surface.pane.color)
    }

    private func header(_ debug: DebugModel) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "ladybug").font(.caption).foregroundStyle(palette.accent.agent.color)
            Text(debug.entry ?? "Debug").font(.footnote.weight(.semibold)).lineLimit(1)
            Spacer()
            Text(status(debug)).font(.caption2).foregroundStyle(palette.text.secondary.color)
        }
        .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 6)
    }

    private func status(_ debug: DebugModel) -> String {
        switch debug.state {
        case .idle: "idle"
        case .running: "running"
        case .paused: debug.pause.map { "\($0.reason == .breakpoint ? "breakpoint" : "paused") · \($0.file):\($0.line)" } ?? "paused"
        case .ended: debug.failure ?? "finished"
        }
    }

    private func controls(_ debug: DebugModel) -> some View {
        HStack(spacing: 8) {
            button("F5", "Continue", "play.fill", enabled: debug.isPaused) { debug.send(.resume) }
            button("F10", "Step over", "arrow.turn.down.right", enabled: debug.isPaused) { debug.send(.stepOver) }
            button("F11", "Step into", "arrow.down.right", enabled: debug.isPaused) { debug.send(.stepInto) }
            button("⇧F11", "Step out", "arrow.up.left", enabled: debug.isPaused) { debug.send(.stepOut) }
            button("⇧F5", "Stop", "stop.fill", enabled: debug.isRunning) { debug.stop() }
            Spacer()
        }
        .padding(.horizontal, 12).padding(.bottom, 8)
    }

    private func button(_ key: String, _ label: String, _ symbol: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.caption).frame(width: 26, height: 24)
        }
        .buttonStyle(.plain)
        .foregroundStyle(enabled ? palette.text.primary.color : palette.text.tertiary.color)
        .disabled(!enabled)
        .accessibilityLabel(label)
        .accessibilityHint(key)
    }

    private func stop(_ pause: Debugger.Pause) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                evaluateField()
                if !model.debug.watches.isEmpty { watchList() }
                if !model.debug.evaluations.isEmpty {
                    section("Evaluated") {
                        ForEach(Array(model.debug.evaluations.enumerated()), id: \.offset) { _, item in
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text(item.expression).font(.system(.caption2, design: .monospaced)).foregroundStyle(palette.text.secondary.color)
                                Text("→").font(.caption2).foregroundStyle(palette.text.tertiary.color)
                                Text(item.result)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(item.failed ? palette.status.error.color : palette.text.primary.color)
                                    .lineLimit(4)
                                Spacer()
                            }
                        }
                    }
                }
                section("Call stack") {
                    ForEach(Array(pause.stack.enumerated()), id: \.offset) { index, frame in
                        Button { model.workspace.open(path: frame.file, line: frame.line, column: frame.column) } label: {
                            HStack(spacing: 6) {
                                Text(frame.name.isEmpty ? "(top level)" : frame.name)
                                    .font(.system(.caption, design: .monospaced))
                                Text("\(frame.file):\(frame.line)")
                                    .font(.caption2).foregroundStyle(palette.text.secondary.color)
                                Spacer()
                            }
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(index == 0 ? palette.accent.ion.color : palette.text.primary.color)
                        .disabled(frame.line <= 0)
                    }
                }
                section("Locals") {
                    if pause.locals.isEmpty {
                        Text("(none)").font(.caption2).foregroundStyle(palette.text.secondary.color)
                    }
                    ForEach(pause.locals, id: \.name) { variable in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(variable.name).font(.system(.caption, design: .monospaced)).foregroundStyle(palette.text.secondary.color)
                            Text(variable.value).font(.system(.caption, design: .monospaced)).lineLimit(3)
                            Spacer()
                        }
                    }
                }
            }
            .padding(12)
        }
    }

    /// The paused frame's REPL: the expression is evaluated where the statement stopped, so it sees
    /// the locals, and the result comes back with the next (same) stop.
    private func evaluateField() -> some View {
        HStack(spacing: 6) {
            Image(systemName: "chevron.right").font(.caption2).foregroundStyle(palette.text.tertiary.color)
            TextField("Evaluate in the paused frame", text: $expression)
                .textFieldStyle(.plain)
                .font(.system(.caption, design: .monospaced))
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .onSubmit(runExpression)
                .accessibilityLabel("Evaluate")
            Button("Eval", action: runExpression)
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(palette.accent.ion.color)
                .disabled(expression.trimmingCharacters(in: .whitespaces).isEmpty)
            Button("Watch") {
                model.debug.addWatch(expression)
                expression = ""
            }
            .buttonStyle(.plain)
            .font(.caption)
            .foregroundStyle(palette.accent.agent.color)
            .disabled(expression.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(6)
        .background(palette.surface.raised.color, in: RoundedRectangle(cornerRadius: Metrics.Radius.sm))
    }

    /// Watch expressions and their value at this stop; a "+" adds the field's expression to them.
    private func watchList() -> some View {
        section("Watch") {
            ForEach(model.debug.watches, id: \.self) { expression in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(expression).font(.system(.caption2, design: .monospaced)).foregroundStyle(palette.text.secondary.color)
                    Text("→").font(.caption2).foregroundStyle(palette.text.tertiary.color)
                    let value = model.debug.watchValues[expression]
                    Text(value?.result ?? "…")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(value?.failed == true ? palette.status.error.color : palette.text.primary.color)
                        .lineLimit(3)
                    Spacer()
                    Button { model.debug.removeWatch(expression) } label: { Image(systemName: "xmark").font(.caption2) }
                        .buttonStyle(.plain)
                        .foregroundStyle(palette.text.tertiary.color)
                        .accessibilityLabel("Remove watch \(expression)")
                }
            }
        }
    }

    private func runExpression() {
        model.debug.evaluate(expression)
        expression = ""
    }

    @ViewBuilder
    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption2.weight(.semibold)).foregroundStyle(palette.text.secondary.color)
            content()
        }
    }

    @ViewBuilder
    private func console(_ debug: DebugModel) -> some View {
        if !debug.output.isEmpty {
            Divider().overlay(palette.surface.hairline.color)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(debug.output.enumerated()), id: \.offset) { _, line in
                        Text(line.text)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(line.stream == .err ? palette.status.error.color : palette.text.secondary.color)
                            .textSelection(.enabled)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
            }
            .frame(maxHeight: 160)
        }
    }
}
