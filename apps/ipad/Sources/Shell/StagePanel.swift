// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

import DesignKit
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
                        Label(current, systemImage: Stage.isScene(current) ? "sparkles" : "cube").font(.system(size: 12, design: .monospaced)).lineLimit(1)
                    }
                    Spacer()
                    Button { showInspector.toggle() } label: { Image(systemName: "list.bullet.indent") }
                        .accessibilityLabel(showInspector ? "Hide inspector" : "Show inspector")
                        .foregroundStyle(showInspector ? palette.accent.ion.color : palette.text.secondary.color)
                    Button { reload() } label: { Image(systemName: "arrow.clockwise") }.accessibilityLabel("Reload")
                }
                .font(.system(size: 13))
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
                       : "No 3D models (glTF, GLB, OBJ, STL) or scenes in this project. A scene is a file named *.stage.js that exports `default ({ THREE, scene, onFrame }) => …`.")
            }
        }
        .background(palette.surface.pane.color)
        // Saving anything reloads the stage, keeping the camera: scene code and shaders hot-reload.
        .onChange(of: model.workspace.changeCount) { reload() }
        .onChange(of: selection) { _, id in controller.run(Stage.selectScript(id)) }
    }

    private func open(_ path: String) {
        selected = path
        stats = nil; status = nil; camera = nil; nodes = []; selection = nil
        model.workspace.problems.stageDiagnostics = []
    }

    private func reload() {
        model.workspace.problems.stageDiagnostics = []
        reloads += 1
    }

    private func handle(_ event: Stage.Event, file: String) {
        #if DEBUG
        if case .graph = event {} else { print("[stage] \(event)") }
        #endif
        switch event {
        case .loaded(let meshes, let animations):
            // A shader error reported during the load stays on show.
            guard model.workspace.problems.stageDiagnostics.isEmpty else { break }
            status = "\(meshes) \(meshes == 1 ? "mesh" : "meshes")" + (animations > 0 ? ", \(animations) animation\(animations == 1 ? "" : "s")" : "")
            isError = false
        case .stats(let s): stats = s
        case .error(let text):
            status = text; isError = true
        case .graph(let list):
            nodes = list
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
        .font(.system(size: 11, design: .monospaced))
        .foregroundStyle(palette.text.secondary.color)
        .padding(.horizontal, 12).padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }
}

/// Runs inspector commands in the current stage page.
@MainActor
final class StageController {
    weak var webView: WKWebView?
    func run(_ script: String) { webView?.evaluateJavaScript(script, completionHandler: nil) }
    func apply(_ edit: Stage.Edit, to id: String) { run(Stage.script(edit, on: id)) }
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
                        Image(systemName: node.visible ? "eye" : "eye.slash").font(.system(size: 11))
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(node.visible ? "Hide \(node.title)" : "Show \(node.title)")
                    Text(node.title).font(.system(size: 12, design: .monospaced)).lineLimit(1)
                    Text(node.type).font(.system(size: 10)).foregroundStyle(palette.text.secondary.color)
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
                Text(node.title).font(.system(size: 13, weight: .semibold))
                Text("\(node.type)\(node.triangles > 0 ? " · \(node.triangles.formatted()) tris" : "")").font(.system(size: 11)).foregroundStyle(palette.text.secondary.color)
                Spacer()
                Button("Frame") { controller.run(Stage.frameScript(node.id)) }.font(.system(size: 12))
            }
            vector("Position", node.position) { v in nodes[i].position = v; controller.apply(.position(v), to: node.id) }
            vector("Rotation °", node.rotation) { v in nodes[i].rotation = v; controller.apply(.rotation(v), to: node.id) }
            vector("Scale", node.scale) { v in nodes[i].scale = v; controller.apply(.scale(v), to: node.id) }
            if let material = node.material {
                Text(material.type).font(.system(size: 11)).foregroundStyle(palette.text.secondary.color)
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
            Text("Edits last until the stage reloads.").font(.system(size: 10)).foregroundStyle(palette.text.secondary.color)
        }
        .font(.system(size: 12))
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
                .font(.system(size: 12, design: .monospaced))
            }
        }
    }

    private func slider(_ label: String, _ value: Double, _ range: ClosedRange<Double>, set: @escaping (Double) -> Void) -> some View {
        HStack {
            Text(label).frame(width: 70, alignment: .leading).lineLimit(1)
            Slider(value: Binding(get: { value }, set: set), in: range)
            Text(String(format: "%.2f", value)).font(.system(size: 11, design: .monospaced)).frame(width: 40)
        }
    }

    private func colorBinding(_ hex: String, set: @escaping (String) -> Void) -> Binding<Color> {
        Binding(get: { Color(hex: hex) }, set: { color in set(color.hexString) })
    }
}

private extension Color {
    init(hex: String) {
        let value = UInt32(hex.dropFirst(), radix: 16) ?? 0
        self.init(red: Double((value >> 16) & 0xff) / 255, green: Double((value >> 8) & 0xff) / 255, blue: Double(value & 0xff) / 255)
    }

    var hexString: String {
        let c = UIColor(self).cgColor.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil)?.components ?? [0, 0, 0]
        let rgb = c.prefix(3).map { Int((max(0, min(1, $0)) * 255).rounded()) }
        return String(format: "#%02x%02x%02x", rgb[0], rgb.count > 1 ? rgb[1] : 0, rgb.count > 2 ? rgb[2] : 0)
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
