// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Maps a module request inside the project to a file, the way bundlers resolve
/// extensionless imports: `./greet` → greet.ts, greet.tsx, greet.js…, or greet/index.ts. Never
/// leaves the project folder (symlinks are resolved first) and never serves `.git`.
public struct ModuleResolver: Sendable {
    public let root: URL

    public init(root: URL) { self.root = URL(filePath: Self.realPath(root.standardizedFileURL.path)) }

    static let extensions = ["", ".ts", ".tsx", ".mts", ".js", ".mjs", ".jsx", ".json"]
    static let indexes = ["/index.ts", "/index.tsx", "/index.js", "/index.mjs"]

    /// `path` is relative to the project root (a URL path without the leading slash).
    public func resolve(_ path: String) -> URL? {
        let clean = path.removingPercentEncoding ?? path
        for suffix in Self.extensions + Self.indexes {
            let candidate = URL(filePath: Self.realPath(root.appendingPathComponent(clean + suffix).standardizedFileURL.path))
            guard inside(candidate) else { return nil }
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory), !isDirectory.boolValue {
                return candidate
            }
        }
        return nil
    }

    func inside(_ url: URL) -> Bool {
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard url.path.hasPrefix(rootPath) else { return false }
        let relative = url.path.dropFirst(rootPath.count)
        return relative != ".git" && !relative.hasPrefix(".git/")
    }

    /// `realpath` of the longest existing prefix, with the missing remainder appended.
    static func realPath(_ path: String) -> String {
        var existing = path
        var missing: [String] = []
        while !existing.isEmpty, existing != "/", access(existing, F_OK) != 0 {
            missing.insert((existing as NSString).lastPathComponent, at: 0)
            existing = (existing as NSString).deletingLastPathComponent
        }
        guard let resolved = realpath(existing, nil) else { return path }
        defer { free(resolved) }
        return ([String(cString: resolved)] + missing).joined(separator: "/").replacingOccurrences(of: "//", with: "/")
    }
}
