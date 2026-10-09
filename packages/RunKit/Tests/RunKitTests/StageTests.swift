// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing
import WebKit
@testable import RunKit

extension WebKitSuites {
@MainActor
struct StageTests {
    /// A unit cube as OBJ and an ASCII STL triangle: small models written out here.
    let root: URL
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("stage-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("models"), withIntermediateDirectories: true)
        let v = ["0 0 0", "1 0 0", "1 1 0", "0 1 0", "0 0 1", "1 0 1", "1 1 1", "0 1 1"].map { "v \($0)" }
        let f = ["1 2 3 4", "5 6 7 8", "1 2 6 5", "2 3 7 6", "3 4 8 7", "4 1 5 8"].map { "f \($0)" }
        try (v + f).joined(separator: "\n").write(to: root.appendingPathComponent("models/cube.obj"), atomically: true, encoding: .utf8)
        try "solid t\nfacet normal 0 0 1\nouter loop\nvertex 0 0 0\nvertex 1 0 0\nvertex 0 1 0\nendloop\nendfacet\nendsolid t\n"
            .write(to: root.appendingPathComponent("models/tri.stl"), atomically: true, encoding: .utf8)
        try "x".write(to: root.appendingPathComponent("models/notes.txt"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("scenes"), withIntermediateDirectories: true)
        try """
            import frag from "./glow.frag";
            import notes from "../models/notes.txt?raw";
            export default ({ THREE, scene }) => {
              const box = new THREE.Mesh(new THREE.BoxGeometry(1, 1, 1), new THREE.MeshStandardMaterial({ color: "#ff0000", roughness: 0.25 }));
              box.name = "Box";
              const glow = new THREE.Mesh(new THREE.PlaneGeometry(1, 1),
                new THREE.ShaderMaterial({ fragmentShader: frag, uniforms: { strength: { value: 0.5 }, tint: { value: new THREE.Color("#00ff00") } } }));
              glow.name = notes;
              scene.add(glow);
              return box;
            };
            """.write(to: root.appendingPathComponent("scenes/demo.stage.ts"), atomically: true, encoding: .utf8)
        try "uniform float strength;\nuniform vec3 tint;\nvoid main() {\n  gl_FragColor = vec4(tint * strength, 1.0)\n}\n"
            .write(to: root.appendingPathComponent("scenes/glow.frag"), atomically: true, encoding: .utf8)
    }

    final class Events { var list: [Stage.Event] = [] }

    func open(_ model: String, until done: ([Stage.Event]) -> Bool = { !$0.isEmpty }) async throws -> (Events, WKWebView) {
        let events = Events()
        let config = try Stage.configuration(root: root) { events.list.append($0) }
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 400, height: 300), configuration: config)
        webView.load(URLRequest(url: Stage.url(for: model)))
        // A web view outside a window gets no animation frames, so stats are checked in the app;
        // here, loading is.
        for _ in 0..<400 where !done(events.list) {
            try await Task.sleep(for: .milliseconds(25))
        }
        return (events, webView)
    }

    func open(_ model: String) async throws -> [Stage.Event] { try await open(model, until: { !$0.isEmpty }).0.list }

    @Test func runsASceneModuleAndMapsShaderErrors() async throws {
        #expect(Stage.scenes(in: root) == ["scenes/demo.stage.ts"])
        let (box_, webView) = try await open("scenes/demo.stage.ts") { $0.contains { if case .graph = $0 { true } else { false } } }
        let events = box_.list
        // The missing semicolon on line 4 of glow.frag; WebKit reports it on the next line's brace.
        let shaderErrors = events.compactMap { if case .shaderError(let path, let line, _) = $0 { (path, line) } else { nil } }
        #expect(shaderErrors.first?.0 == "scenes/glow.frag")
        #expect([4, 5].contains(shaderErrors.first?.1 ?? 0), "\(events)")
        #expect(events.contains(.loaded(meshes: 2, animations: 0)))
        guard case .graph(let nodes)? = events.first(where: { if case .graph = $0 { true } else { false } }) else { Issue.record("no graph"); return }
        let box = try #require(nodes.first { $0.name == "Box" })
        #expect(box.material?.color == "#ff0000" && box.material?.roughness == 0.25 && box.triangles == 12)
        let glow = try #require(nodes.first { $0.name == "x" })
        #expect(glow.material?.uniforms == ["strength": .number(0.5), "tint": .color("#00ff00")])

        // Ephemeral edits, then the graph again.
        _ = try await webView.evaluateJavaScript(Stage.script(.color("#0000ff"), on: box.id))
        _ = try await webView.evaluateJavaScript(Stage.script(.position([1, 2, 3]), on: box.id))
        _ = try await webView.evaluateJavaScript(Stage.script(.uniform("strength", .number(0.9)), on: glow.id))
        _ = try await webView.evaluateJavaScript(Stage.selectScript(box.id))
        _ = try await webView.evaluateJavaScript("window.omnieStage.graph(); 1")
        try await Task.sleep(for: .milliseconds(200))
        let graphs = box_.list.compactMap { if case .graph(let n) = $0 { n } else { nil } }
        let after = try #require(graphs.last?.first { $0.name == "Box" })
        #expect(after.material?.color == "#0000ff" && after.position == [1, 2, 3])
        #expect(graphs.last?.first { $0.name == "x" }?.material?.uniforms["strength"] == .number(0.9))
    }

    @Test func exportsUSDZForARQuickLook() async throws {
        let (_, webView) = try await open("models/cube.obj") { $0.contains(.loaded(meshes: 1, animations: 0)) }
        let base64 = try await webView.callAsyncJavaScript(Stage.exportUSDZScript, contentWorld: .page) as? String
        let data = try #require(base64.flatMap { Data(base64Encoded: $0) })
        #expect(Stage.isUSDZ(data), "\(data.prefix(64) as NSData)")
        // The grid and highlight stay out: one mesh, so one Mesh prim in the layer.
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("def Mesh"))
        #expect(!Stage.isUSDZ(Data("PK not really".utf8)))
    }

    @Test func findsModels() {
        #expect(Stage.models(in: root) == ["models/cube.obj", "models/tri.stl"])
    }

    @Test func loadsAnOBJ() async throws {
        let events = try await open("models/cube.obj")
        #expect(events.first == .loaded(meshes: 1, animations: 0))
    }

    @Test func loadsAnSTL() async throws {
        #expect(try await open("models/tri.stl").first == .loaded(meshes: 1, animations: 0))
    }

    @Test func saysWhatItCantOpen() async throws {
        let events = try await open("models/notes.txt")
        #expect(events.first == .error("Stage can't open .txt files (glTF, GLB, OBJ and STL work)."))
    }
}
}
