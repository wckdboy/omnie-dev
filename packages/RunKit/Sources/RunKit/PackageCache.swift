// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Libraries RunKit carries, so a project's bare imports work offline (PLAN.md §8, the offline
/// package cache; this is its first, built-in tier; NpmCache is the second). Mapped with an import
/// map, injected into the pages RunKit serves.
public enum PackageCache {
    /// Import-map entries: bare specifier → URL served from RunKit's bundle.
    public static let imports: [String: String] = [
        "three": "omnie-run://local/__omnie/packages/three/build/three.module.js",
        "three/webgpu": "omnie-run://local/__omnie/packages/three/build/three.webgpu.js",
        "three/tsl": "omnie-run://local/__omnie/packages/three/build/three.tsl.js",
        "three/addons/": "omnie-run://local/__omnie/packages/three/examples/jsm/",
        "three/examples/jsm/": "omnie-run://local/__omnie/packages/three/examples/jsm/",
    ]

    /// The import map as a script tag, merged with any extra entries (the test harness adds vitest).
    public static func importMapTag(adding extra: [String: String] = [:]) -> String {
        let all = imports.merging(extra) { _, new in new }
        let data = (try? JSONSerialization.data(withJSONObject: ["imports": all], options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return "<script type=\"importmap\">\(String(decoding: data, as: UTF8.self))</script>"
    }

    /// Adds the import map to an HTML page that doesn't have its own (a page's own map wins; it
    /// usually points at a CDN, which is offline here anyway, so the page will say so).
    static func inject(into html: String, adding extra: [String: String] = [:]) -> String {
        guard html.range(of: "type=\"importmap\"", options: .caseInsensitive) == nil,
              html.range(of: "type='importmap'", options: .caseInsensitive) == nil else { return html }
        let tag = importMapTag(adding: extra)
        // Before the first script, so module resolution sees it.
        for marker in ["<head>", "<HEAD>"] {
            if let range = html.range(of: marker) { return html.replacingCharacters(in: range, with: marker + tag) }
        }
        if let range = html.range(of: "<script", options: .caseInsensitive) {
            return html.replacingCharacters(in: range.lowerBound..<range.lowerBound, with: tag)
        }
        return tag + html
    }
}
