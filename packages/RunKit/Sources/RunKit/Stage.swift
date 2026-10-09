// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

import Foundation
import WebKit

/// The Stage (PLAN.md §10): a model from the project in the bundled three.js, with renderer
/// stats for a native HUD. Same sandbox as previews: read-only project, no network.
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

    public enum Event: Sendable, Equatable {
        case loaded(meshes: Int, animations: Int)
        case stats(Stats)
        case error(String)
    }

    public nonisolated static let modelExtensions: Set<String> = ["glb", "gltf", "obj", "stl"]

    /// The project's model files.
    public nonisolated static func models(in root: URL) -> [String] {
        SchemeHandler.projectFiles(ModuleResolver(root: root).root).filter { modelExtensions.contains(($0 as NSString).pathExtension.lowercased()) }
    }

    public static func url(for model: String) -> URL {
        var components = URLComponents(string: "\(JSRunner.scheme)://local/__omnie/runtime/stage.html")!
        components.queryItems = [URLQueryItem(name: "model", value: model)]
        return components.url!
    }

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
            default: nil
            }
            if let event { MainActor.assumeIsolated { handler(event) } }
        }
    }
}
