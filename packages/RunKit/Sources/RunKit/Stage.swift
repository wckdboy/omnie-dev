// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

import Foundation
import WebKit

/// The Stage (PLAN.md §10): a model or a scene module from the project in the bundled three.js,
/// with renderer stats for a native HUD, the scene graph for a native inspector, and shader
/// compile errors mapped to files. Same sandbox as previews: read-only project, no network.
@MainActor
public enum Stage {
    public struct Stats: Sendable, Equatable {
        public var fps = 0
        public var worstFrameMs = 0.0
        public var drawCalls = 0
        public var triangles = 0
        public var geometries = 0
        public var textures = 0
        public var programs = 0
    }

    /// One object in the scene graph, depth-first.
    public struct Node: Sendable, Equatable, Identifiable {
        public struct Material: Sendable, Equatable {
            public var type: String
            public var color: String?
            public var emissive: String?
            public var roughness: Double?
            public var metalness: Double?
            public var opacity: Double
            public var wireframe: Bool
            /// Number uniforms and colour uniforms ("#rrggbb") of shader materials.
            public var uniforms: [String: UniformValue]
        }
        public enum UniformValue: Sendable, Equatable { case number(Double), color(String) }

        public let id: String
        public var name: String
        public var type: String
        public var depth: Int
        public var parent: String?
        public var visible: Bool
        public var position: [Double]
        /// Degrees.
        public var rotation: [Double]
        public var scale: [Double]
        public var material: Material?
        public var triangles: Int

        public var title: String { name.isEmpty ? type : name }
    }

    public enum Event: Sendable, Equatable {
        case loaded(meshes: Int, animations: Int)
        case stats(Stats)
        case error(String)
        case graph([Node])
        case selected(String?)
        /// Camera position, target, near and far: passed back on reload so the view stays put.
        case camera([Double])
        /// A shader compile error; `path` is the project file when the shader came from one, and
        /// `line` is 1-based in it.
        case shaderError(path: String?, line: Int, message: String)
    }

    /// Playground scene modules: `export default function (stage) { … }`.
    public nonisolated static let sceneSuffixes = [".stage.js", ".stage.ts", ".stage.mjs", ".stage.tsx"]

    public nonisolated static func isScene(_ path: String) -> Bool { sceneSuffixes.contains { path.lowercased().hasSuffix($0) } }

    /// The project's scene modules.
    public nonisolated static func scenes(in root: URL) -> [String] {
        SchemeHandler.projectFiles(ModuleResolver(root: root).root).filter(isScene)
    }

    public nonisolated static let modelExtensions: Set<String> = ["glb", "gltf", "obj", "stl"]

    /// The project's model files.
    public nonisolated static func models(in root: URL) -> [String] {
        SchemeHandler.projectFiles(ModuleResolver(root: root).root).filter { modelExtensions.contains(($0 as NSString).pathExtension.lowercased()) }
    }

    /// The page for a model or scene file; `camera` (from a `.camera` event) keeps the view.
    public static func url(for file: String, camera: [Double]? = nil, reload: Int = 0) -> URL {
        var components = URLComponents(string: "\(JSRunner.scheme)://local/__omnie/runtime/stage.html")!
        components.queryItems = [URLQueryItem(name: isScene(file) ? "scene" : "model", value: file), URLQueryItem(name: "r", value: String(reload))]
        if let camera, camera.count == 8 { components.queryItems?.append(URLQueryItem(name: "camera", value: camera.map { String($0) }.joined(separator: ","))) }
        return components.url!
    }

    // MARK: Inspector commands (ephemeral: nothing is written to the project)

    public enum Edit: Sendable {
        case visible(Bool), position([Double]), rotation([Double]), scale([Double])
        case color(String), emissive(String), roughness(Double), metalness(Double), opacity(Double), wireframe(Bool)
        case uniform(String, UniformValueInput)
        public enum UniformValueInput: Sendable { case number(Double), color(String) }
    }

    /// JavaScript for the page to apply an edit.
    public static func script(_ edit: Edit, on id: String) -> String {
        func js(_ value: Any) -> String {
            String(decoding: (try? JSONSerialization.data(withJSONObject: [value], options: [.fragmentsAllowed])) ?? Data("[null]".utf8), as: UTF8.self)
                .dropFirst().dropLast().description
        }
        let (key, value): (String, Any) = switch edit {
        case .visible(let v): ("visible", v)
        case .position(let v): ("position", v)
        case .rotation(let v): ("rotation", v)
        case .scale(let v): ("scale", v)
        case .color(let v): ("color", v)
        case .emissive(let v): ("emissive", v)
        case .roughness(let v): ("roughness", v)
        case .metalness(let v): ("metalness", v)
        case .opacity(let v): ("opacity", v)
        case .wireframe(let v): ("wireframe", v)
        case .uniform(let name, .number(let v)): ("uniform:" + name, v)
        case .uniform(let name, .color(let v)): ("uniform:" + name, v)
        }
        return "window.omnieStage?.set(\(js(id)), \(js(key)), \(js(value)))"
    }

    public static func selectScript(_ id: String?) -> String {
        "window.omnieStage?.select(\(id.map { SchemeHandler.jsString($0) } ?? "null"))"
    }

    public static func frameScript(_ id: String) -> String { "window.omnieStage?.frame(\(SchemeHandler.jsString(id)))" }

    public static func configuration(root: URL, onEvent: @escaping @MainActor (Event) -> Void) throws -> WKWebViewConfiguration {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.setURLSchemeHandler(SchemeHandler(resolver: ModuleResolver(root: root), transpiler: try Transpiler()), forURLScheme: JSRunner.scheme)
        config.userContentController.add(Relay(onEvent), name: "stage")
        return config
    }

    final class Relay: NSObject, WKScriptMessageHandler {
        let handler: @MainActor (Event) -> Void
        init(_ handler: @escaping @MainActor (Event) -> Void) { self.handler = handler }
        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
            func int(_ key: String) -> Int { (body[key] as? NSNumber)?.intValue ?? 0 }
            let event: Event? = switch type {
            case "loaded": .loaded(meshes: int("meshes"), animations: int("animations"))
            case "error": .error(body["text"] as? String ?? "error")
            case "stats": .stats(Stats(fps: int("fps"), worstFrameMs: (body["worstMs"] as? NSNumber)?.doubleValue ?? 0,
                                       drawCalls: int("calls"), triangles: int("triangles"), geometries: int("geometries"),
                                       textures: int("textures"), programs: int("programs")))
            case "graph": .graph((body["nodes"] as? [[String: Any]] ?? []).compactMap(Self.node))
            case "selected": .selected(body["id"] as? String)
            case "camera": .camera((body["value"] as? [NSNumber] ?? []).map(\.doubleValue))
            case "shaderError": .shaderError(path: body["path"] as? String, line: int("line"), message: body["message"] as? String ?? "")
            default: nil
            }
            if let event { MainActor.assumeIsolated { handler(event) } }
        }

        static func node(_ d: [String: Any]) -> Node? {
            guard let id = d["id"] as? String else { return nil }
            func doubles(_ k: String) -> [Double] { (d[k] as? [NSNumber] ?? []).map(\.doubleValue) }
            var material: Node.Material?
            if let m = d["material"] as? [String: Any] {
                var uniforms: [String: Node.UniformValue] = [:]
                for (name, value) in m["uniforms"] as? [String: Any] ?? [:] {
                    if let n = value as? NSNumber { uniforms[name] = .number(n.doubleValue) } else if let c = value as? String { uniforms[name] = .color(c) }
                }
                material = Node.Material(type: m["type"] as? String ?? "", color: m["color"] as? String, emissive: m["emissive"] as? String,
                                         roughness: (m["roughness"] as? NSNumber)?.doubleValue, metalness: (m["metalness"] as? NSNumber)?.doubleValue,
                                         opacity: (m["opacity"] as? NSNumber)?.doubleValue ?? 1, wireframe: m["wireframe"] as? Bool ?? false, uniforms: uniforms)
            }
            return Node(id: id, name: d["name"] as? String ?? "", type: d["type"] as? String ?? "Object3D", depth: (d["depth"] as? NSNumber)?.intValue ?? 0,
                        parent: d["parent"] as? String, visible: d["visible"] as? Bool ?? true, position: doubles("position"),
                        rotation: doubles("rotation"), scale: doubles("scale"), material: material,
                        triangles: (d["triangles"] as? NSNumber)?.intValue ?? 0)
        }
    }
}
