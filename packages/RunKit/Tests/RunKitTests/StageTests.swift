// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing
import WebKit
@testable import RunKit

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
    }

    func open(_ model: String) async throws -> [Stage.Event] {
        var events: [Stage.Event] = []
        let config = try Stage.configuration(root: root) { events.append($0) }
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 400, height: 300), configuration: config)
        webView.load(URLRequest(url: Stage.url(for: model)))
        // A web view outside a window gets no animation frames, so stats are checked in the app;
        // here, loading is.
        for _ in 0..<400 where events.isEmpty {
            try await Task.sleep(for: .milliseconds(25))
        }
        return events
    }

    @Test func findsModels() {
        #expect(Stage.models(in: root) == ["models/cube.obj", "models/tri.stl"])
    }

    @Test func loadsAnOBJ() async throws {
        #expect(try await open("models/cube.obj").first == .loaded(meshes: 1, animations: 0))
    }

    @Test func loadsAnSTL() async throws {
        #expect(try await open("models/tri.stl").first == .loaded(meshes: 1, animations: 0))
    }

    @Test func saysWhatItCantOpen() async throws {
        let events = try await open("models/notes.txt")
        #expect(events.first == .error("Stage can't open .txt files (glTF, GLB, OBJ and STL work)."))
    }
}
