// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

import DesignKit
import PolicyKit
import SwiftUI
import ToolsKit

/// The Tools tab (PLAN.md §11.1): the curated, offline tools. First two: the SQLite browser and
/// the Patterns lab.
struct ToolsPanel: View {
    @Environment(\.palette) private var palette
    @State private var tool = Tool.sqlite

    enum Tool: String, CaseIterable, Identifiable {
        case sqlite = "SQLite", patterns = "Patterns"
        var id: Self { self }
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Tool", selection: $tool) {
                ForEach(Tool.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(12)
            Rectangle().fill(palette.surface.hairline.color).frame(height: Metrics.hairline)
            switch tool {
            case .sqlite: SQLiteTool()
            case .patterns: PatternsTool()
            }
        }
        .background(palette.surface.pane.color)
    }
}

/// Grid of a query result, monospaced, scrolling both ways.
private struct ResultGrid: View {
    @Environment(\.palette) private var palette
    let result: SQLiteDatabase.Result

    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 4) {
                GridRow {
                    ForEach(Array(result.columns.enumerated()), id: \.offset) { _, c in
                        Text(c).fontWeight(.semibold).foregroundStyle(palette.text.secondary.color)
                    }
                }
                ForEach(Array(result.rows.enumerated()), id: \.offset) { _, row in
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { _, value in
                            Text(value.count > 80 ? value.prefix(80) + "…" : value)
                                .foregroundStyle(value == "NULL" ? palette.text.tertiary.color : palette.text.primary.color)
                                .lineLimit(1)
                        }
                    }
                }
            }
            .font(.system(size: 11, design: .monospaced))
            .textSelection(.enabled)
            .padding(12)
        }
    }
}

private struct SQLiteTool: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var palette
    @State private var file: String?
    @State private var writable = false
    @State private var database: SQLiteDatabase?
    @State private var tables: [SQLiteDatabase.Table] = []
    @State private var sql = ""
    @State private var result: SQLiteDatabase.Result?
    @State private var error: String?

    var body: some View {
        let root = model.workspace.rootURL
        let files = root.map { SQLiteDatabase.files(in: $0) } ?? []
        if let root, !files.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Menu {
                        ForEach(files, id: \.self) { f in Button(f) { open(f, root: root) } }
                    } label: { Label(file ?? "Choose a database", systemImage: "cylinder").font(.system(size: 12, design: .monospaced)) }
                    Spacer()
                    Toggle("Writes", isOn: Binding(get: { writable }, set: { allow in Task { await setWritable(allow, root: root) } }))
                        .toggleStyle(.switch).font(.system(size: 12)).fixedSize()
                        .disabled(file == nil)
                }
                if !tables.isEmpty {
                    ScrollView(.horizontal) {
                        HStack {
                            ForEach(tables) { t in
                                Button("\(t.name) (\(t.rows))") {
                                    sql = "SELECT * FROM \"\(t.name)\" LIMIT 200"
                                    run()
                                }
                                .buttonStyle(.bordered).font(.system(size: 12))
                            }
                        }
                    }
                }
                TextEditor(text: $sql)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(height: 80)
                    .scrollContentBackground(.hidden)
                    .background(palette.surface.raised.color, in: RoundedRectangle(cornerRadius: Metrics.Radius.sm))
                    .autocorrectionDisabled().textInputAutocapitalization(.never)
                HStack {
                    Button("Run", action: run).keyboardShortcut(.return, modifiers: .command)
                    Button("Explain") { run(explain: true) }
                    Spacer()
                    if let result {
                        Text("\(result.rows.count)\(result.truncated ? "+" : "") rows · \(result.ms) ms" + (result.changes > 0 ? " · \(result.changes) changed" : ""))
                            .font(.system(size: 11)).foregroundStyle(palette.text.secondary.color)
                        Button("Copy CSV") { UIPasteboard.general.string = SQLiteDatabase.csv(result) }
                    }
                }
                .buttonStyle(.bordered).font(.system(size: 12))
                .disabled(database == nil)
                if let error { Text(error).font(.system(size: 12)).foregroundStyle(palette.status.error.color) }
            }
            .padding(12)
            .onAppear { if file == nil, let first = files.first { open(first, root: root) } }
            if let result { ResultGrid(result: result) } else { Spacer() }
        } else {
            NotYet(title: "SQLite", detail: root == nil ? "Open a project to browse its databases." : "No SQLite databases in this project (.db, .sqlite, or any file with the SQLite header).")
        }
    }

    private func open(_ path: String, root: URL) {
        do {
            let db = try SQLiteDatabase(url: root.appending(path: path), readOnly: !writable)
            database = db
            file = path
            tables = try db.tables()
            result = nil
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    /// Writes are your explicit choice, recorded in the audit log (the agent's are Ask-tier).
    private func setWritable(_ allow: Bool, root: URL) async {
        guard let file else { return }
        if allow, !(await model.policy.authorize(.sqlWrite(database: file))) { return }
        writable = allow
        open(file, root: root)
    }

    private func run() { run(explain: false) }

    private func run(explain: Bool) {
        guard let database, !sql.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        do {
            result = explain ? try database.explain(sql) : try database.query(sql)
            error = nil
            if !explain, (result?.changes ?? 0) > 0 { tables = (try? database.tables()) ?? tables }
        } catch {
            self.error = error.localizedDescription + (database.isReadOnly && "\(error)".contains("readonly") ? " Turn on Writes to change data." : "")
        }
    }
}

private struct PatternsTool: View {
    @Environment(\.palette) private var palette
    @State private var mode = 0
    @State private var json = "{\"name\": \"Omnie\", \"tags\": [\"ide\", \"ipad\"]}"
    @State private var jsonReport: Patterns.JSONReport?
    @State private var pattern = #"(\w+)@(\w+)\.com"#
    @State private var flags = "i"
    @State private var flavor = Patterns.Flavor.javascript
    @State private var sample = "ada@example.com, grace@navy.com"

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Mode", selection: $mode) { Text("JSON").tag(0); Text("Regex").tag(1) }
                .pickerStyle(.segmented).fixedSize()
            if mode == 0 {
                editor($json, height: 160)
                HStack {
                    Button("Format and check") { jsonReport = Patterns.json(json) }.buttonStyle(.bordered)
                    if let formatted = jsonReport?.formatted {
                        Button("Use formatted") { json = formatted; jsonReport = nil }.buttonStyle(.bordered)
                    }
                }
                .font(.system(size: 12))
                if let report = jsonReport {
                    if let error = report.error {
                        Text(error).foregroundStyle(palette.status.error.color).font(.system(size: 12))
                    } else {
                        Label("Valid JSON", systemImage: "checkmark.circle").foregroundStyle(palette.status.ok.color).font(.system(size: 12))
                    }
                }
            } else {
                HStack {
                    TextField("Pattern", text: $pattern).font(.system(size: 13, design: .monospaced))
                    TextField("Flags", text: $flags).font(.system(size: 13, design: .monospaced)).frame(width: 50)
                    Picker("Flavor", selection: $flavor) { ForEach(Patterns.Flavor.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                        .fixedSize()
                }
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                editor($sample, height: 100)
                let report = Patterns.regex(pattern, flags: flags, in: sample, flavor: flavor)
                if let error = report.error {
                    Text(error).foregroundStyle(palette.status.error.color).font(.system(size: 12))
                } else {
                    Text("\(report.matches.count) \(report.matches.count == 1 ? "match" : "matches")")
                        .font(.system(size: 12)).foregroundStyle(palette.text.secondary.color)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(Array(report.matches.enumerated()), id: \.offset) { _, m in
                                Text("\(m.range.lowerBound)–\(m.range.upperBound)  \(m.text)"
                                     + (m.groups.isEmpty ? "" : "   " + m.groups.enumerated().map { "$\($0.offset + 1)=\($0.element ?? "∅")" }.joined(separator: " ")))
                            }
                        }
                        .font(.system(size: 12, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
    }

    private func editor(_ text: Binding<String>, height: CGFloat) -> some View {
        TextEditor(text: text)
            .font(.system(size: 12, design: .monospaced))
            .frame(height: height)
            .scrollContentBackground(.hidden)
            .background(palette.surface.raised.color, in: RoundedRectangle(cornerRadius: Metrics.Radius.sm))
            .autocorrectionDisabled().textInputAutocapitalization(.never)
    }
}
