// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

import ARKit
import DesignKit
import QuickLook
import RunKit
import SwiftUI
import WebKit

/// The Stage tab (PLAN.md §10): a model (glTF/GLB, OBJ, STL) or a scene module (`*.stage.js`)
/// in the bundled three.js, with orbit controls, a native performance HUD and a scene inspector.
/// Saving reloads it with the camera where it was; shader errors land in Problems and the editor.
struct StagePanel: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var palette
    @State private var selected: String?
    @State private var stats: Stage.Stats?
    @State private var status: String?
    @State private var isError = false
    @State private var camera: [Double]?
    @State private var reloads = 0
    @State private var nodes: [Stage.Node] = []
    @State private var selection: String?
    @State private var showInspector = false
    @State private var controller = StageController()
    /// The exported scene, while AR Quick Look shows it.
    @State private var arFile: URL?

    var body: some View {
        let root = model.workspace.rootURL
        let files = root.map { Stage.scenes(in: $0) + Stage.models(in: $0) } ?? []
        VStack(spacing: 0) {
            if let root, !files.isEmpty {
                let current = selected.flatMap { files.contains($0) ? $0 : nil } ?? files[0]
                HStack(spacing: 10) {
                    Menu {
                        ForEach(files, id: \.self) { path in
                            Button { open(path) } label: { Label(path, systemImage: Stage.isScene(path) ? "sparkles" : "cube") }
                        }
                    } label: {
                        Label(current, systemImage: Stage.isScene(current) ? "sparkles" : "cube").font(.system(.caption, design: .monospaced)).lineLimit(1)
                    }
                    Spacer()
                    if controller.editCount > 0, Stage.isScene(current) {
                        Button {
                            let goal = controller.goal(file: current)
                            controller.clearEdits()
                            model.show(.agent)
                            Task { await model.agent.start(goal) }
                        } label: { Label("Write to code (\(controller.editCount))", systemImage: "square.and.pencil") }
                        .font(.caption)
                        .accessibilityHint("Asks the agent to put your inspector changes into the scene's code, for you to review")
                    }
                    Button {
                        Task {
                            do { arFile = try await controller.exportUSDZ(name: current) } catch { status = error.localizedDescription; isError = true }
                        }
                    } label: { Image(systemName: "arkit") }
                        .accessibilityLabel("View in AR")
                        .accessibilityHint("Exports the scene as USDZ and opens it in AR Quick Look")
                    Button { showInspector.toggle() } label: { Image(systemName: "list.bullet.indent") }
                        .accessibilityLabel(showInspector ? "Hide inspector" : "Show inspector")
                        .foregroundStyle(showInspector ? palette.accent.ion.color : palette.text.secondary.color)
                    Button { reload() } label: { Image(systemName: "arrow.clockwise") }.accessibilityLabel("Reload")
                }
                .font(.footnote)
                .padding(.horizontal, 12).padding(.vertical, 8)
                Rectangle().fill(palette.surface.hairline.color).frame(height: Metrics.hairline)
                StageWebView(root: root, url: Stage.url(for: current, camera: camera, reload: reloads), controller: controller) { handle($0, file: current) }
                    .id("\(current)#\(reloads)")
                if showInspector {
                    Rectangle().fill(palette.surface.hairline.color).frame(height: Metrics.hairline)
                    StageInspector(nodes: $nodes, selection: $selection, controller: controller)
                        .frame(maxHeight: 360)
                }
                Rectangle().fill(palette.surface.hairline.color).frame(height: Metrics.hairline)
                hud
            } else {
                NotYet(title: "Stage", detail: root == nil
                       ? "Open a project to view its 3D models here."
                       : "No 3D models (glTF, GLB, OBJ, STL) or scenes in this project. A scene is a file named *.stage.js or *.stage.ts that exports `default ({ THREE, scene, onFrame }: OmnieStage) => …`.")
            }
        }
        .background(palette.surface.pane.color)
        // Saving anything reloads the stage, keeping the camera: scene code and shaders hot-reload.
        .onChange(of: model.workspace.changeCount) { reload() }
        .onChange(of: selection) { _, id in controller.run(Stage.selectScript(id)) }
        .onDisappear { StageSnapshot.shared.file = nil }
        .fullScreenCover(item: $arFile) { url in
            ARQuickLook(url: url).ignoresSafeArea()
        }
    }

    private func open(_ path: String) {
        selected = path
        stats = nil; status = nil; camera = nil; nodes = []; selection = nil
        controller.clearEdits()
        model.workspace.problems.stageDiagnostics = []
    }

    private func reload() {
        controller.clearEdits()
        model.workspace.problems.stageDiagnostics = []
        StageSnapshot.shared.problems = []
        reloads += 1
    }

    private func handle(_ event: Stage.Event, file: String) {
        let snapshot = StageSnapshot.shared
        snapshot.file = file
        switch event {
        case .graph(let list): snapshot.nodes = list
        case .stats(let st): snapshot.stats = st
        case .shaderError(let path, let line, let message): snapshot.problems.append("\(path ?? file):\(line): \(message)")
        default: break
        }
        #if DEBUG
        if case .graph = event {} else { print("[stage] \(event)") }
        #endif
        switch event {
        case .loaded(let meshes, let animations):
            #if DEBUG
            // `-OmnieStageUSDZ`: export the loaded scene and log what came out.
            if ProcessInfo.processInfo.arguments.contains("-OmnieStageUSDZ") {
                Task {
                    let started = Date()
                    do {
                        let url = try await controller.exportUSDZ(name: file)
                        let data = try Data(contentsOf: url)
                        try data.write(to: URL.documentsDirectory.appending(path: url.lastPathComponent))
                        print("[usdz] \(url.lastPathComponent): \(data.count) bytes, valid \(Stage.isUSDZ(data)), \(Int(Date().timeIntervalSince(started) * 1000)) ms")
                    } catch { print("[usdz] failed: \(error.localizedDescription)") }
                }
            }
            #endif
            // A shader error reported during the load stays on show.
            guard model.workspace.problems.stageDiagnostics.isEmpty else { break }
            status = "\(meshes) \(meshes == 1 ? "mesh" : "meshes")" + (animations > 0 ? ", \(animations) animation\(animations == 1 ? "" : "s")" : "")
            isError = false
        case .stats(let s): stats = s
        case .error(let text):
            status = text; isError = true
        case .graph(let list):
            nodes = list
            controller.titles = Dictionary(list.map { ($0.id, $0.title) }, uniquingKeysWith: { a, _ in a })
            #if DEBUG
            // `-OmnieStageWriteDemo`: recolor and move "Cube", then write it to code with the agent.
            if ProcessInfo.processInfo.arguments.contains("-OmnieStageWriteDemo"), controller.editCount == 0, !StageWriteDemo.done,
               let cube = list.first(where: { $0.name == "Cube" }) {
                StageWriteDemo.done = true
                controller.apply(.color("#FF3366"), to: cube.id)
                controller.apply(.position([0, 0.5, 0]), to: cube.id)
                let goal = controller.goal(file: file)
                print("[stage-write] goal: \(goal)")
                controller.clearEdits()
                Task {
                    // `-OmnieStageWriteOnline`: the configured online model does it (consent still asked).
                    let previous = model.models.route
                    if ProcessInfo.processInfo.arguments.contains("-OmnieStageWriteOnline") { model.models.route = .online }
                    defer { model.models.route = previous }
                    await model.agent.start(goal)
                    print("[stage-write] phase \(model.agent.current?.phase.rawValue ?? "none"), error \(model.agent.error ?? "none")")
                    for change in model.agent.changes { print("[stage-write] \(change.patch)") }
                }
            }
            #endif
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-OmnieStageInspect"), selection == nil {
                showInspector = true
                selection = list.first { $0.material != nil }?.id
            }
            #endif
            if let selection, !list.contains(where: { $0.id == selection }) { self.selection = nil }
        case .selected(let id):
            selection = id
            if id != nil { showInspector = true }
        case .camera(let value):
            camera = value
        case .shaderError(let path, let line, let message):
            status = "Shader: " + message; isError = true
            model.workspace.problems.stageDiagnostics.append(diagnostic(path: path ?? file, line: path == nil ? 0 : line, message: message))
        }
    }

    /// A shader error as a problem, with the line's range for the editor mark.
    private func diagnostic(path: String, line: Int, message: String) -> TypeDiagnostic {
        var start: Int?, length: Int?
        if line > 0, let root = model.workspace.rootURL, let text = try? String(contentsOf: root.appending(path: path), encoding: .utf8) {
            let ns = text as NSString
            var location = 0
            for _ in 1..<line where location < ns.length { location = NSMaxRange(ns.lineRange(for: NSRange(location: location, length: 0))) }
            if location <= ns.length {
                let range = ns.lineRange(for: NSRange(location: min(location, ns.length), length: 0))
                let content = ns.substring(with: range)
                let indent = content.prefix { $0 == " " || $0 == "\t" }.utf16.count
                start = range.location + indent
                length = max(1, content.trimmingCharacters(in: .whitespacesAndNewlines).utf16.count)
            }
        }
        return TypeDiagnostic(code: 0, category: .error, message: message, path: path, line: line > 0 ? line : nil, column: 1, start: start, length: length)
    }

    private var hud: some View {
        HStack(spacing: 12) {
            if let status {
                Text(status).foregroundStyle(isError ? palette.status.error.color : palette.text.secondary.color).lineLimit(2)
            }
            Spacer()
            if let stats {
                Text("\(stats.fps) fps").foregroundStyle(stats.fps < 50 ? palette.status.warn.color : palette.text.secondary.color)
                Text(String(format: "%.1f ms max", stats.worstFrameMs))
                Text("\(stats.triangles.formatted()) tris")
                Text("\(stats.drawCalls) calls")
                Text("\(stats.textures) tex · \(stats.programs) prog")
            }
        }
        .font(.system(.caption2, design: .monospaced))
        .foregroundStyle(palette.text.secondary.color)
        .padding(.horizontal, 12).padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }
}

#if DEBUG
@MainActor enum StageWriteDemo { static var done = false }
#endif

/// What the Stage shows, for the agent's `stage_scene` tool.
@MainActor
final class StageSnapshot {
    static let shared = StageSnapshot()
    var file: String?
    var nodes: [Stage.Node] = []
    var stats: Stage.Stats?
    var problems: [String] = []

    func summary() -> String {
        guard let file else { return "The Stage isn't open. Open the Stage tab with a model or a *.stage.js scene to inspect it." }
        func v(_ a: [Double]) -> String { "[" + a.map { String(format: "%g", $0) }.joined(separator: ", ") + "]" }
        var lines = ["Stage: \(file)"]
        if let s = stats { lines.append("\(s.fps) fps, worst frame \(String(format: "%.1f", s.worstFrameMs)) ms, \(s.triangles) triangles, \(s.drawCalls) draw calls, \(s.programs) shader programs") }
        lines += problems.map { "Shader error: \($0)" }
        for n in nodes.prefix(120) {
            var line = String(repeating: "  ", count: n.depth) + "\(n.title) (\(n.type))"
            if !n.visible { line += " hidden" }
            line += " position \(v(n.position)) rotation° \(v(n.rotation)) scale \(v(n.scale))"
            if n.triangles > 0 { line += " \(n.triangles) tris" }
            if let m = n.material {
                var parts = [m.type]
                if let c = m.color { parts.append("color \(c)") }
                if let r = m.roughness { parts.append("roughness \(String(format: "%g", r))") }
                if let mt = m.metalness { parts.append("metalness \(String(format: "%g", mt))") }
                if m.opacity < 1 { parts.append("opacity \(String(format: "%g", m.opacity))") }
                for (k, u) in m.uniforms.sorted(by: { $0.key < $1.key }) {
                    switch u { case .number(let x): parts.append("\(k)=\(String(format: "%g", x))"); case .color(let c): parts.append("\(k)=\(c)") }
                }
                line += " material " + parts.joined(separator: ", ")
            }
            lines.append(line)
        }
        if nodes.count > 120 { lines.append("… and \(nodes.count - 120) more objects") }
        return lines.joined(separator: "\n")
    }
}

/// Runs inspector commands in the current stage page, and remembers what you changed so it can
/// be written to the scene's code.
@MainActor
@Observable
final class StageController {
    @ObservationIgnored weak var webView: WKWebView?
    /// Object names by id, from the last scene graph.
    @ObservationIgnored var titles: [String: String] = [:]
    /// Object name → property → new value; the last edit of a property wins.
    private(set) var edits: [String: [String: String]] = [:]

    func run(_ script: String) { webView?.evaluateJavaScript(script, completionHandler: nil) }

    enum ExportError: LocalizedError {
        case notLoaded, notUSDZ
        var errorDescription: String? {
            switch self {
            case .notLoaded: "The scene isn't loaded yet."
            case .notUSDZ: "The export didn't produce a USDZ file."
            }
        }
    }

    /// The scene as a .usdz file in the temporary folder, named after the scene file.
    func exportUSDZ(name: String) async throws -> URL {
        guard let webView else { throw ExportError.notLoaded }
        let base64 = try await webView.callAsyncJavaScript(Stage.exportUSDZScript, contentWorld: .page) as? String
        guard let data = base64.flatMap({ Data(base64Encoded: $0) }), Stage.isUSDZ(data) else { throw ExportError.notUSDZ }
        let base = ((name as NSString).lastPathComponent as NSString).deletingPathExtension.replacingOccurrences(of: ".stage", with: "")
        let url = FileManager.default.temporaryDirectory.appending(path: "\(base.isEmpty ? "scene" : base).usdz")
        try data.write(to: url, options: .atomic)
        return url
    }

    func apply(_ edit: Stage.Edit, to id: String) {
        run(Stage.script(edit, on: id))
        let (property, value) = Self.describe(edit)
        edits[titles[id] ?? id, default: [:]][property] = value
    }

    func clearEdits() { edits = [:] }

    var editCount: Int { edits.values.reduce(0) { $0 + $1.count } }

    static func describe(_ edit: Stage.Edit) -> (String, String) {
        func v(_ a: [Double]) -> String { "[" + a.map { String(format: "%g", $0) }.joined(separator: ", ") + "]" }
        return switch edit {
        case .visible(let b): ("visible", b ? "true" : "false")
        case .position(let a): ("position", v(a))
        case .rotation(let a): ("rotation (degrees)", v(a))
        case .scale(let a): ("scale", v(a))
        case .color(let h): ("material color", h)
        case .emissive(let h): ("material emissive", h)
        case .roughness(let x): ("material roughness", String(format: "%.2f", x))
        case .metalness(let x): ("material metalness", String(format: "%.2f", x))
        case .opacity(let x): ("material opacity", String(format: "%.2f", x))
        case .wireframe(let b): ("material wireframe", b ? "true" : "false")
        case .uniform(let name, .number(let x)): ("uniform \(name)", String(format: "%g", x))
        case .uniform(let name, .color(let h)): ("uniform \(name)", h)
        }
    }

    /// The agent's task for writing the edits into the scene module.
    func goal(file: String) -> String {
        let lines = edits.keys.sorted().map { name in
            "- \(name): " + edits[name]!.keys.sorted().map { "\($0) \(edits[name]![$0]!)" }.joined(separator: "; ")
        }
        return "In \(file), change the scene's code so these objects start with these values (I set them in the Stage inspector). "
            + "Change only these values, where each object is created:\n" + lines.joined(separator: "\n")
    }
}

/// The scene tree and the selected object's properties. Edits are live and last until the stage
/// reloads; they're never written to the project (PLAN.md §10.2).
private struct StageInspector: View {
    @Binding var nodes: [Stage.Node]
    @Binding var selection: String?
    let controller: StageController
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(spacing: 0) {
            List(nodes) { node in
                HStack(spacing: 6) {
                    Button { update(node.id) { $0.visible.toggle() }; controller.apply(.visible(!node.visible), to: node.id) } label: {
                        Image(systemName: node.visible ? "eye" : "eye.slash").font(.caption2)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(node.visible ? "Hide \(node.title)" : "Show \(node.title)")
                    Text(node.title).font(.system(.caption, design: .monospaced)).lineLimit(1)
                    Text(node.type).font(.caption2).foregroundStyle(palette.text.secondary.color)
                    Spacer()
                }
                .padding(.leading, CGFloat(node.depth) * 12)
                .contentShape(Rectangle())
                .onTapGesture { selection = node.id }
                .listRowBackground(node.id == selection ? palette.accent.ion.color.opacity(0.18) : Color.clear)
                .listRowInsets(EdgeInsets(top: 2, leading: 10, bottom: 2, trailing: 10))
            }
            .listStyle(.plain)
            .frame(minHeight: 100)
            if let index = nodes.firstIndex(where: { $0.id == selection }) {
                Rectangle().fill(palette.surface.hairline.color).frame(height: Metrics.hairline)
                ScrollView { properties(index).padding(10) }
                    .frame(maxHeight: 200)
            }
        }
    }

    private func update(_ id: String, _ change: (inout Stage.Node) -> Void) {
        if let i = nodes.firstIndex(where: { $0.id == id }) { change(&nodes[i]) }
    }

    @ViewBuilder
    private func properties(_ i: Int) -> some View {
        let node = nodes[i]
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(node.title).font(.footnote.weight(.semibold))
                Text("\(node.type)\(node.triangles > 0 ? " · \(node.triangles.formatted()) tris" : "")").font(.caption2).foregroundStyle(palette.text.secondary.color)
                Spacer()
                Button("Frame") { controller.run(Stage.frameScript(node.id)) }.font(.caption)
            }
            vector("Position", node.position) { v in nodes[i].position = v; controller.apply(.position(v), to: node.id) }
            vector("Rotation °", node.rotation) { v in nodes[i].rotation = v; controller.apply(.rotation(v), to: node.id) }
            vector("Scale", node.scale) { v in nodes[i].scale = v; controller.apply(.scale(v), to: node.id) }
            if let material = node.material {
                Text(material.type).font(.caption2).foregroundStyle(palette.text.secondary.color)
                if let color = material.color {
                    ColorPicker("Color", selection: colorBinding(color) { hex in nodes[i].material?.color = hex; controller.apply(.color(hex), to: node.id) }, supportsOpacity: false)
                }
                if let emissive = material.emissive {
                    ColorPicker("Emissive", selection: colorBinding(emissive) { hex in nodes[i].material?.emissive = hex; controller.apply(.emissive(hex), to: node.id) }, supportsOpacity: false)
                }
                if let roughness = material.roughness {
                    slider("Roughness", roughness, 0...1) { v in nodes[i].material?.roughness = v; controller.apply(.roughness(v), to: node.id) }
                }
                if let metalness = material.metalness {
                    slider("Metalness", metalness, 0...1) { v in nodes[i].material?.metalness = v; controller.apply(.metalness(v), to: node.id) }
                }
                slider("Opacity", material.opacity, 0...1) { v in nodes[i].material?.opacity = v; controller.apply(.opacity(v), to: node.id) }
                Toggle("Wireframe", isOn: Binding(get: { material.wireframe }, set: { v in nodes[i].material?.wireframe = v; controller.apply(.wireframe(v), to: node.id) }))
                ForEach(material.uniforms.keys.sorted(), id: \.self) { name in
                    switch material.uniforms[name] {
                    case .number(let value)?:
                        slider(name, value, min(0, value * 2)...max(1, abs(value) * 2)) { v in
                            nodes[i].material?.uniforms[name] = .number(v); controller.apply(.uniform(name, .number(v)), to: node.id)
                        }
                    case .color(let hex)?:
                        ColorPicker(name, selection: colorBinding(hex) { h in
                            nodes[i].material?.uniforms[name] = .color(h); controller.apply(.uniform(name, .color(h)), to: node.id)
                        }, supportsOpacity: false)
                    case nil: EmptyView()
                    }
                }
            }
            Text("Edits last until the stage reloads.").font(.caption2).foregroundStyle(palette.text.secondary.color)
        }
        .font(.caption)
    }

    private func vector(_ label: String, _ value: [Double], set: @escaping ([Double]) -> Void) -> some View {
        HStack(spacing: 6) {
            Text(label).frame(width: 70, alignment: .leading)
            ForEach(0..<3, id: \.self) { axis in
                TextField(["x", "y", "z"][axis], value: Binding(get: { value.indices.contains(axis) ? value[axis] : 0 }, set: { v in
                    var next = value.count == 3 ? value : [0, 0, 0]
                    next[axis] = v
                    set(next)
                }), format: .number.precision(.fractionLength(0...3)))
                .textFieldStyle(.roundedBorder)
                .keyboardType(.numbersAndPunctuation)
                .font(.system(.caption, design: .monospaced))
            }
        }
    }

    private func slider(_ label: String, _ value: Double, _ range: ClosedRange<Double>, set: @escaping (Double) -> Void) -> some View {
        HStack {
            Text(label).frame(width: 70, alignment: .leading).lineLimit(1)
            Slider(value: Binding(get: { value }, set: set), in: range)
            Text(String(format: "%.2f", value)).font(.system(.caption2, design: .monospaced)).frame(width: 40)
        }
    }

    private func colorBinding(_ hex: String, set: @escaping (String) -> Void) -> Binding<Color> {
        Binding(get: { Color(hex: hex) }, set: { color in set(color.hexString) })
    }
}


private struct StageWebView: UIViewRepresentable {
    let root: URL
    let url: URL
    let controller: StageController
    let onEvent: @MainActor (Stage.Event) -> Void

    /// Loads once the view has a size, and reloads if WebKit's content process is killed (§10.3).
    final class Container: UIView, WKNavigationDelegate {
        let webView: WKWebView
        let url: URL
        let onEvent: @MainActor (Stage.Event) -> Void
        private var loaded = false

        init(webView: WKWebView, url: URL, onEvent: @escaping @MainActor (Stage.Event) -> Void) {
            self.webView = webView
            self.url = url
            self.onEvent = onEvent
            super.init(frame: .zero)
            addSubview(webView)
            webView.navigationDelegate = self
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func layoutSubviews() {
            super.layoutSubviews()
            webView.frame = bounds
            if !loaded, bounds.width > 0, bounds.height > 0 {
                loaded = true
                webView.load(URLRequest(url: url))
            }
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            onEvent(.error("Stage reloaded: the system stopped it, usually for memory."))
            webView.load(URLRequest(url: url))
        }
    }

    func makeUIView(context: Context) -> Container {
        let config = (try? Stage.configuration(root: root, onEvent: onEvent)) ?? WKWebViewConfiguration()
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.isInspectable = true
        controller.webView = webView
        return Container(webView: webView, url: url, onEvent: onEvent)
    }

    func updateUIView(_ container: Container, context: Context) {}
}

extension URL: @retroactive Identifiable {
    public var id: String { absoluteString }
}

/// AR Quick Look for an exported scene: on the floor at real size, with Share (Save to Files).
struct ARQuickLook: UIViewControllerRepresentable {
    let url: URL
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UINavigationController {
        let preview = QLPreviewController()
        preview.dataSource = context.coordinator
        preview.delegate = context.coordinator
        return UINavigationController(rootViewController: preview)
    }

    func updateUIViewController(_ controller: UINavigationController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(url: url, dismiss: { dismiss() }) }

    final class Coordinator: NSObject, @MainActor QLPreviewControllerDataSource, @MainActor QLPreviewControllerDelegate {
        let url: URL
        let dismiss: () -> Void
        init(url: URL, dismiss: @escaping () -> Void) { self.url = url; self.dismiss = dismiss }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }

        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> any QLPreviewItem {
            let item = ARQuickLookPreviewItem(fileAt: url)
            item.allowsContentScaling = true
            return item
        }

        func previewControllerDidDismiss(_ controller: QLPreviewController) { dismiss() }
    }
}
