// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

import DesignKit
import GitKit
import PolicyKit
import RunKit
import SecretsKit
import SwiftUI
import ToolsKit
import WorkspaceKit

/// The Tools tab (PLAN.md §11.1): the curated, offline tools: the HTTP client, the SQLite browser,
/// the Patterns lab and the diff tool.
struct ToolsPanel: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var palette
    @State private var tool = Tool.http

    enum Tool: String, CaseIterable, Identifiable {
        case http = "HTTP", sqlite = "SQLite", patterns = "Patterns", diff = "Diff", snippets = "Snippets", colors = "Colors"
        var id: Self { self }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Six tools don't fit a segmented control in the side pane: a scrolling row instead.
            ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Tool.allCases) { t in
                        Button { tool = t } label: {
                            Text(t.rawValue).font(.footnote.weight(tool == t ? .semibold : .regular))
                                .padding(.horizontal, 12).padding(.vertical, 6)
                                .background(tool == t ? palette.surface.raised.color : .clear, in: Capsule())
                                .foregroundStyle(tool == t ? palette.text.primary.color : palette.text.secondary.color)
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(tool == t ? .isSelected : [])
                        .id(t)
                    }
                }
                .padding(.horizontal, 12)
            }
            .onChange(of: tool) { withAnimation { proxy.scrollTo(tool, anchor: .center) } }
            .onAppear { proxy.scrollTo(tool, anchor: .center) }
            }
            .padding(.vertical, 10)
            Rectangle().fill(palette.surface.hairline.color).frame(height: Metrics.hairline)
            switch tool {
            case .http: HTTPTool()
            case .sqlite: SQLiteTool()
            case .patterns: PatternsTool()
            case .diff: DiffTool()
            case .snippets: SnippetsTool()
            case .colors: ColorsTool()
            }
        }
        // "Compare open file with…" in the palette lands here.
        .onChange(of: model.diffLeft) { if model.diffLeft != nil { tool = .diff } }
        .onAppear { if model.diffLeft != nil { tool = .diff } else if model.snippetRequest != nil { tool = .snippets } }
        .onChange(of: model.snippetRequest) { if model.snippetRequest != nil { tool = .snippets } }
        #if DEBUG
        // `-OmnieTools Patterns` opens that tool.
        .task {
            let args = ProcessInfo.processInfo.arguments
            if let i = args.firstIndex(of: "-OmnieTools"), args.indices.contains(i + 1), let t = Tool(rawValue: args[i + 1]) { tool = t }
        }
        #endif
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
            .font(.system(.caption2, design: .monospaced))
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
                    } label: { Label(file ?? "Choose a database", systemImage: "cylinder").font(.system(.caption, design: .monospaced)) }
                    Spacer()
                    Toggle("Writes", isOn: Binding(get: { writable }, set: { allow in Task { await setWritable(allow, root: root) } }))
                        .toggleStyle(.switch).font(.caption).fixedSize()
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
                                .buttonStyle(.bordered).font(.caption)
                            }
                        }
                    }
                }
                TextEditor(text: $sql)
                    .font(.system(.caption, design: .monospaced))
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
                            .font(.caption2).foregroundStyle(palette.text.secondary.color)
                        Button("Copy CSV") { UIPasteboard.general.string = SQLiteDatabase.csv(result) }
                    }
                }
                .buttonStyle(.bordered).font(.caption)
                .disabled(database == nil)
                if let error { Text(error).font(.caption).foregroundStyle(palette.status.error.color) }
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
    @State private var filter = ".tags[]"
    @State private var jqOutput: String?
    @State private var jqFailed = false
    @State private var yamlText = "name: demo\ntags:\n  - ide\n  - ipad\nsettings:\n  density: regular\n"
    @State private var cron = "30 9 * * 1-5"

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Mode", selection: $mode) { Text("JSON").tag(0); Text("YAML").tag(2); Text("Regex").tag(1); Text("Cron").tag(3) }
                .pickerStyle(.segmented).fixedSize()
            if mode == 0 {
                editor($json, height: 160)
                HStack {
                    Button("Format and check") { jsonReport = Patterns.json(json) }.buttonStyle(.bordered)
                    if let formatted = jsonReport?.formatted {
                        Button("Use formatted") { json = formatted; jsonReport = nil }.buttonStyle(.bordered)
                    }
                }
                .font(.caption)
                if let report = jsonReport {
                    if let error = report.error {
                        Text(error).foregroundStyle(palette.status.error.color).font(.caption)
                    } else {
                        Label("Valid JSON", systemImage: "checkmark.circle").foregroundStyle(palette.status.ok.color).font(.caption)
                    }
                }
                // jq queries, with the bundled jq running in RunKit's WASI sandbox (PLAN.md §11.1).
                if JSRunner.bundledTools().contains("jq") {
                    HStack {
                        TextField("jq filter", text: $filter)
                            .font(.system(.footnote, design: .monospaced))
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .onSubmit { Task { await runJQ() } }
                        Button("Run jq") { Task { await runJQ() } }.buttonStyle(.bordered).font(.caption)
                    }
                    #if DEBUG
                    Color.clear.frame(height: 0).task { if ProcessInfo.processInfo.arguments.contains("-OmnieRunJQ") { await runJQ() } }
                    Color.clear.frame(height: 0).task {
                        let args = ProcessInfo.processInfo.arguments
                        if let i = args.firstIndex(of: "-OmniePatternsMode"), args.indices.contains(i + 1), let m = Int(args[i + 1]) { mode = m }
                    }
                    #endif
                    if let jqOutput {
                        ScrollView {
                            Text(jqOutput)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(jqFailed ? palette.status.error.color : palette.text.primary.color)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: 220)
                    }
                }
            } else if mode == 2 {
                editor($yamlText, height: 140)
                HStack {
                    Button("From the JSON tab") { if let y = Patterns.yamlFromJSON(json) { yamlText = y } }
                        .buttonStyle(.bordered).font(.caption)
                    Spacer()
                }
                let report = Patterns.yaml(yamlText)
                if let error = report.error {
                    Text(error).foregroundStyle(palette.status.error.color).font(.caption)
                } else if let out = report.json {
                    Text("As JSON").font(.caption).foregroundStyle(palette.text.secondary.color)
                    ScrollView {
                        Text(out).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            } else if mode == 3 {
                TextField("Cron expression", text: $cron)
                    .font(.system(.footnote, design: .monospaced))
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                Text("minute  hour  day  month  weekday, or @daily, @hourly…").font(.caption2).foregroundStyle(palette.text.secondary.color)
                switch Result(catching: { try Cron(cron) }) {
                case .success(let schedule):
                    Text(schedule.description).font(.subheadline)
                    Text("Next runs (local time)").font(.caption).foregroundStyle(palette.text.secondary.color)
                    ForEach(schedule.next(5, after: .now), id: \.self) { date in
                        Text(date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).year().hour().minute()))
                            .font(.system(.caption, design: .monospaced))
                    }
                case .failure(let error):
                    Text(error.localizedDescription).foregroundStyle(palette.status.error.color).font(.caption)
                }
            } else {
                HStack {
                    TextField("Pattern", text: $pattern).font(.system(.footnote, design: .monospaced))
                    TextField("Flags", text: $flags).font(.system(.footnote, design: .monospaced)).frame(width: 50)
                    Picker("Flavor", selection: $flavor) { ForEach(Patterns.Flavor.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                        .fixedSize()
                }
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                editor($sample, height: 100)
                DisclosureGroup("Explain") {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(RegexExplainer.explain(pattern).enumerated()), id: \.offset) { _, part in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(part.token).font(.system(.caption, design: .monospaced)).foregroundStyle(palette.accent.ion.color)
                                    .frame(minWidth: 70, alignment: .leading)
                                Text(part.meaning).font(.caption)
                            }
                            .padding(.leading, CGFloat(part.depth) * 12)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.caption)
                let report = Patterns.regex(pattern, flags: flags, in: sample, flavor: flavor)
                if let error = report.error {
                    Text(error).foregroundStyle(palette.status.error.color).font(.caption)
                } else {
                    Text("\(report.matches.count) \(report.matches.count == 1 ? "match" : "matches")")
                        .font(.caption).foregroundStyle(palette.text.secondary.color)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(Array(report.matches.enumerated()), id: \.offset) { _, m in
                                Text("\(m.range.lowerBound)–\(m.range.upperBound)  \(m.text)"
                                     + (m.groups.isEmpty ? "" : "   " + m.groups.enumerated().map { "$\($0.offset + 1)=\($0.element ?? "∅")" }.joined(separator: " ")))
                            }
                        }
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
    }

    private func runJQ() async {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("jq-scratch", isDirectory: true)
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        guard let runner = try? JSRunner(root: scratch) else { return }
        let result = await runner.runWasm("jq", args: [filter], stdin: json, timeout: 10)
        jqFailed = !result.passed
        jqOutput = result.output.map(\.text).joined(separator: "\n") + (result.ending == .finished ? "" : "\nStopped: took too long.")
    }

    private func editor(_ text: Binding<String>, height: CGFloat) -> some View {
        TextEditor(text: text)
            .font(.system(.caption, design: .monospaced))
            .frame(height: height)
            .scrollContentBackground(.hidden)
            .background(palette.surface.raised.color, in: RoundedRectangle(cornerRadius: Metrics.Radius.sm))
            .autocorrectionDisabled().textInputAutocapitalization(.never)
    }
}

/// The HTTP client (PLAN.md §11.1): requests from the project's `.http` files, sent with
/// URLSession under the network policy (plane mode blocks them), secrets filled from the Keychain.
private struct HTTPTool: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var palette
    @State private var file: String?
    @State private var requests: [HTTPRequestSpec] = []
    @State private var selected: Int?
    @State private var result: HTTPResult?
    @State private var error: String?
    @State private var sending = false
    @State private var showSecrets = false
    @State private var lastRequest: URLRequest?
    @State private var mocked: String?

    var body: some View {
        let root = model.workspace.rootURL
        let files = root.map(Self.httpFiles(in:)) ?? []
        VStack(alignment: .leading, spacing: 8) {
            if let root {
                HStack {
                    if files.isEmpty {
                        Button("Create requests.http") { createSample(root) }.buttonStyle(.bordered)
                    } else {
                        Menu {
                            ForEach(files, id: \.self) { f in Button(f) { load(f, root: root) } }
                        } label: { Label(file ?? "Choose a .http file", systemImage: "network").font(.system(.caption, design: .monospaced)) }
                    }
                    Spacer()
                    Button("Secrets") { showSecrets = true }.disabled(requests.isEmpty)
                }
                .font(.footnote)
                .onAppear {
                    if file == nil, let first = files.first { load(first, root: root) }
                    #if DEBUG
                    if ProcessInfo.processInfo.arguments.contains("-OmnieHTTPSend"), let first = requests.first { Task { await send(first) } }
                    #endif
                }
                ForEach(requests) { spec in
                    HStack {
                        Text(spec.method).font(.system(.caption2, design: .monospaced).weight(.semibold)).frame(width: 52, alignment: .leading)
                            .foregroundStyle(palette.accent.ion.color)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(spec.name).font(.footnote).lineLimit(1)
                            Text(spec.url).font(.system(.caption2, design: .monospaced)).foregroundStyle(palette.text.secondary.color).lineLimit(1)
                        }
                        Spacer()
                        Button(sending && selected == spec.line ? "…" : "Send") { Task { await send(spec) } }
                            .buttonStyle(.bordered).font(.caption).disabled(sending)
                    }
                }
                if let error { Text(error).font(.caption).foregroundStyle(palette.status.error.color) }
                if let result {
                    HStack {
                        Text("\(result.status)").fontWeight(.semibold)
                            .foregroundStyle(result.status < 300 ? palette.status.ok.color : result.status < 500 ? palette.status.warn.color : palette.status.error.color)
                        Text("\(result.ms) ms · \(ByteCountFormatter.string(fromByteCount: Int64(result.bytes), countStyle: .file))")
                            .foregroundStyle(palette.text.secondary.color)
                        Spacer()
                        Button(mocked ?? "Save as mock") { saveMock(result, root: root) }
                            .help("Serves this response to previews at the same path, offline (.omnie/mocks.json)")
                        Button("Copy") { UIPasteboard.general.string = result.displayBody }
                    }
                    .font(.caption)
                    ScrollView {
                        Text(result.displayBody.prefix(200_000))
                            .font(.system(.caption2, design: .monospaced)).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else {
                    Spacer()
                }
            } else {
                NotYet(title: "HTTP", detail: "Open a project to send the requests in its .http files.")
            }
        }
        .padding(12)
        .sheet(isPresented: $showSecrets) { SecretsSheet(names: Array(Set(requests.flatMap(HTTPFile.secrets(in:)))).sorted()) }
    }

    static func httpFiles(in root: URL) -> [String] {
        var found: [String] = []
        let base = root.standardizedFileURL.resolvingSymlinksInPath()
        let e = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil)
        while let url = e?.nextObject() as? URL {
            if [".git", "node_modules", ".build"].contains(url.lastPathComponent) { e?.skipDescendants(); continue }
            if ["http", "rest"].contains(url.pathExtension.lowercased()) {
                found.append(String(url.standardizedFileURL.resolvingSymlinksInPath().path.dropFirst(base.path.count + 1)))
            }
        }
        return found.sorted()
    }

    private func load(_ path: String, root: URL) {
        file = path
        requests = HTTPFile.parse((try? String(contentsOf: root.appending(path: path), encoding: .utf8)) ?? "")
        result = nil
        error = nil
    }

    /// Records the response as a mock route for previews (RunKit serves it at the same path).
    private func saveMock(_ result: HTTPResult, root: URL) {
        guard let request = lastRequest, let url = request.url else { return }
        let type = result.headers.first { $0.key.lowercased() == "content-type" }?.value ?? "application/json"
        do {
            try MockRoutes.record(MockRoute(method: request.httpMethod ?? "GET", path: url.path.isEmpty ? "/" : url.path,
                                            status: result.status, contentType: type, body: result.body), root: root)
            mocked = "Saved for \(url.path)"
            model.workspace.reload()
        } catch { self.error = error.localizedDescription }
    }

    private func createSample(_ root: URL) {
        let sample = """
            # Requests for this project. Run them from Tools › HTTP.
            # Secrets go in {{secret NAME}} placeholders and are kept in the Keychain, not here.
            @host = https://httpbin.org

            ### Echo a GET
            GET {{host}}/get?from=omnie
            Accept: application/json

            ### Post JSON
            POST {{host}}/post
            Content-Type: application/json

            {"hello": "world"}

            """
        try? sample.write(to: root.appending(path: "requests.http"), atomically: true, encoding: .utf8)
        model.workspace.reload()
        load("requests.http", root: root)
    }

    private func send(_ spec: HTTPRequestSpec) async {
        error = nil
        selected = spec.line
        do {
            let request = try HTTPClient.request(spec) { HTTPSecrets.load($0) }
            let host = request.url?.host() ?? ""
            guard await model.policy.authorize(.network(domain: host)) else {
                error = model.policy.lastRefusal ?? "Not sent."
                return
            }
            sending = true
            defer { sending = false }
            result = try await HTTPClient.send(request)
            lastRequest = request
            mocked = nil
        } catch {
            self.error = error.localizedDescription
            result = nil
        }
    }
}

/// Values for the `{{secret NAME}}` placeholders in the open file, stored in the Keychain.
private struct SecretsSheet: View {
    @Environment(\.dismiss) private var dismiss
    let names: [String]
    @State private var values: [String: String] = [:]
    @State private var revision = 0

    var body: some View {
        NavigationStack {
            Form {
                if names.isEmpty {
                    Text("This file has no {{secret NAME}} placeholders.")
                }
                ForEach(names, id: \.self) { name in
                    Section(name) {
                        let _ = revision
                        if HTTPSecrets.load(name) != nil {
                            HStack {
                                Label("Saved", systemImage: "key.fill")
                                Spacer()
                                Button("Remove", role: .destructive) { HTTPSecrets.delete(name); revision += 1 }
                            }
                        } else {
                            HStack {
                                SecureField("Value", text: Binding(get: { values[name] ?? "" }, set: { values[name] = $0 }))
                                Button("Save") { try? HTTPSecrets.save(values[name] ?? "", name: name); values[name] = nil; revision += 1 }
                                    .disabled((values[name] ?? "").isEmpty)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Secrets")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}

/// The diff tool (PLAN.md §11.1): any two files, or pasted text, compared with git's diff, the
/// same engine and colors as reviews and the conflict resolver.
private struct DiffTool: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var palette
    @State private var left = Side()
    @State private var right = Side()
    @State private var files: [String] = []

    struct Side: Equatable {
        var file: String?
        var text = ""
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                sideEditor("Before", $left)
                Button { swap(&left, &right) } label: { Image(systemName: "arrow.left.arrow.right") }
                    .accessibilityLabel("Swap sides").padding(.top, 6)
                sideEditor("After", $right)
            }
            let diff = FileDiff.texts(contents(left), contents(right), oldName: left.file ?? "before", newName: right.file ?? "after")
            HStack {
                Text("+\(diff.additions)").foregroundStyle(palette.status.ok.color)
                Text("−\(diff.deletions)").foregroundStyle(palette.status.error.color)
                Text(diff.hunks.isEmpty ? "No differences" : "\(diff.hunks.count) \(diff.hunks.count == 1 ? "change" : "changes")")
                    .foregroundStyle(palette.text.secondary.color)
            }
            .font(.caption)
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(diff.hunks) { hunk in
                        VStack(alignment: .leading, spacing: 0) {
                            Text(hunk.header.components(separatedBy: "@@").dropFirst().first.map { "@@\($0)@@" } ?? hunk.header)
                                .foregroundStyle(palette.text.tertiary.color)
                            ForEach(Array(hunk.lines.prefix(400).enumerated()), id: \.offset) { _, line in
                                Text(line.isEmpty ? " " : line)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(line.hasPrefix("+") ? palette.diff.addedBg.color : line.hasPrefix("-") ? palette.diff.removedBg.color : .clear)
                            }
                        }
                    }
                }
                .font(.system(.caption2, design: .monospaced))
                .textSelection(.enabled)
            }
        }
        .padding(12)
        .task(id: model.workspace.rootURL) {
            if let root = model.workspace.rootURL { files = await Task.detached { ProjectSearch.files(in: root) }.value }
        }
        .onAppear(perform: takeRequest)
        .onChange(of: model.diffLeft) { takeRequest() }
    }

    private func takeRequest() {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-OmnieDiffRight"), args.indices.contains(i + 1) { right = Side(file: args[i + 1]) }
        #endif
        guard let path = model.diffLeft else { return }
        left = Side(file: path)
        model.diffLeft = nil
    }

    private func contents(_ side: Side) -> String {
        guard let file = side.file, let root = model.workspace.rootURL else { return side.text }
        // The open file as you see it, saved or not.
        if model.workspace.relativePath == file { return model.workspace.editor.text }
        return (try? String(contentsOf: root.appending(path: file), encoding: .utf8)) ?? ""
    }

    private func sideEditor(_ title: String, _ side: Binding<Side>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Menu {
                    Button("Text") { side.wrappedValue.file = nil }
                    Divider()
                    ForEach(files.prefix(300), id: \.self) { path in Button(path) { side.wrappedValue.file = path } }
                } label: {
                    Label(side.wrappedValue.file ?? "\(title): text", systemImage: side.wrappedValue.file == nil ? "text.alignleft" : "doc")
                        .lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                if side.wrappedValue.file == nil {
                    Button { side.wrappedValue.text = UIPasteboard.general.string ?? "" } label: { Image(systemName: "doc.on.clipboard") }
                        .accessibilityLabel("Paste the clipboard as \(title.lowercased())")
                }
            }
            .font(.caption)
            if side.wrappedValue.file == nil {
                TextEditor(text: side.text)
                    .font(.system(.caption, design: .monospaced))
                    .frame(height: 110)
                    .scrollContentBackground(.hidden)
                    .background(palette.surface.raised.color, in: RoundedRectangle(cornerRadius: Metrics.Radius.sm))
                    .autocorrectionDisabled().textInputAutocapitalization(.never)
            }
        }
        .frame(maxWidth: .infinity)
    }
}
