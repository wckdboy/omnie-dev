// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Creating, renaming, duplicating and deleting files in the navigator. Every change goes through
/// a file coordinator, so the Files app and other apps see it consistently.
public enum FileOperations {
    public enum Failure: Error, Equatable, LocalizedError {
        case badName(String)
        case exists(String)
        case outsideProject

        public var errorDescription: String? {
            switch self {
            case .badName(let n): n.isEmpty ? "Give it a name." : "\"\(n)\" can't be used as a name (no slashes, and not . or ..)."
            case .exists(let n): "\(n) already exists here."
            case .outsideProject: "That's outside the project."
            }
        }
    }

    public static func validate(_ name: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.contains("/"), !trimmed.contains(":"), trimmed != ".", trimmed != ".." else {
            throw Failure.badName(trimmed)
        }
    }

    @discardableResult
    public static func createFile(named name: String, in folder: URL, contents: String = "") throws -> URL {
        try validate(name)
        let url = folder.appendingPathComponent(name.trimmingCharacters(in: .whitespaces))
        guard !FileManager.default.fileExists(atPath: url.path) else { throw Failure.exists(url.lastPathComponent) }
        try coordinate(writing: url, options: .forReplacing) { target in
            try Data(contents.utf8).write(to: target, options: .withoutOverwriting)
        }
        return url
    }

    @discardableResult
    public static func createFolder(named name: String, in folder: URL) throws -> URL {
        try validate(name)
        let url = folder.appendingPathComponent(name.trimmingCharacters(in: .whitespaces), isDirectory: true)
        guard !FileManager.default.fileExists(atPath: url.path) else { throw Failure.exists(url.lastPathComponent) }
        try coordinate(writing: url, options: []) { target in
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        }
        return url
    }

    /// Renames in place (same folder). Returns the new URL.
    @discardableResult
    public static func rename(_ url: URL, to name: String) throws -> URL {
        try validate(name)
        let target = url.deletingLastPathComponent().appendingPathComponent(name.trimmingCharacters(in: .whitespaces))
        guard target.lastPathComponent != url.lastPathComponent else { return url }
        // A case-only rename on a case-insensitive volume is the same file.
        let caseOnly = target.lastPathComponent.lowercased() == url.lastPathComponent.lowercased()
        guard caseOnly || !FileManager.default.fileExists(atPath: target.path) else { throw Failure.exists(target.lastPathComponent) }
        var error: NSError?
        var moveError: Error?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forMoving, writingItemAt: target, options: .forReplacing, error: &error) { from, to in
            do {
                if caseOnly {
                    let temp = from.deletingLastPathComponent().appendingPathComponent(".omnie-rename-\(UUID().uuidString)")
                    try FileManager.default.moveItem(at: from, to: temp)
                    try FileManager.default.moveItem(at: temp, to: to)
                } else {
                    try FileManager.default.moveItem(at: from, to: to)
                }
            } catch { moveError = error }
        }
        if let error { throw error }
        if let moveError { throw moveError }
        return target
    }

    /// Copies next to the original as "name copy.ext" (then "name copy 2.ext"…).
    @discardableResult
    public static func duplicate(_ url: URL) throws -> URL {
        let ext = url.pathExtension, base = url.deletingPathExtension().lastPathComponent
        var n = 1
        var target: URL
        repeat {
            let name = base + (n == 1 ? " copy" : " copy \(n)") + (ext.isEmpty ? "" : "." + ext)
            target = url.deletingLastPathComponent().appendingPathComponent(name)
            n += 1
        } while FileManager.default.fileExists(atPath: target.path)
        let destination = target
        try coordinate(reading: url) { source in
            try FileManager.default.copyItem(at: source, to: destination)
        }
        return target
    }

    public static func delete(_ url: URL) throws {
        try coordinate(writing: url, options: .forDeleting) { target in
            try FileManager.default.removeItem(at: target)
        }
    }

    // MARK: Coordination

    static func coordinate(writing url: URL, options: NSFileCoordinator.WritingOptions, _ body: (URL) throws -> Void) throws {
        var error: NSError?
        var inner: Error?
        NSFileCoordinator().coordinate(writingItemAt: url, options: options, error: &error) { target in
            do { try body(target) } catch { inner = error }
        }
        if let error { throw error }
        if let inner { throw inner }
    }

    static func coordinate(reading url: URL, _ body: (URL) throws -> Void) throws {
        var error: NSError?
        var inner: Error?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &error) { target in
            do { try body(target) } catch { inner = error }
        }
        if let error { throw error }
        if let inner { throw inner }
    }
}
