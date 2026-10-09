// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

import CryptoKit
import Foundation

/// Gets a URL's bytes into a local file. The app uses URLSession; tests use local files.
public protocol ModelFetcher: Sendable {
    /// Writes `url` to `destination`, calling `progress` with bytes received so far.
    func fetch(_ url: URL, to destination: URL, progress: @escaping @Sendable (Int64) -> Void) async throws
}

public enum ModelStoreError: Error, Equatable, LocalizedError {
    case sizeMismatch(file: String, expected: Int64, got: Int64)
    case hashMismatch(file: String)
    case notEnoughSpace(needed: Int64, available: Int64)

    public var errorDescription: String? {
        switch self {
        case .sizeMismatch(let f, let e, let g): "\(f) is \(g) bytes, expected \(e). The download was cut short or changed."
        case .hashMismatch(let f): "\(f) doesn't match its pinned checksum, so it wasn't installed."
        case .notEnoughSpace(let n, let a):
            "Needs \(ByteCountFormatter.string(fromByteCount: n, countStyle: .file)) free, \(ByteCountFormatter.string(fromByteCount: a, countStyle: .file)) available."
        }
    }
}

/// Installed models under one folder: `<root>/<pack id>/<files>`. Every file is checked against its
/// pinned size and SHA-256 before it's moved into place; a pack counts as installed only when its
/// manifest is written, after the last file verifies. Model folders are excluded from backup.
public actor ModelStore {
    public enum State: Equatable, Sendable {
        case notInstalled
        /// Some files are in place and verified (an install was interrupted).
        case partial(bytes: Int64)
        case installed
    }

    public nonisolated let root: URL
    let fetcher: any ModelFetcher
    private var verified: [String: Set<String>] = [:]

    static let manifestName = ".omnie-pack.json"

    public init(root: URL, fetcher: any ModelFetcher) {
        self.root = root
        self.fetcher = fetcher
    }

    public nonisolated func folder(for pack: ModelPack) -> URL {
        root.appendingPathComponent(pack.id, isDirectory: true)
    }

    public func state(of pack: ModelPack) -> State {
        let dir = folder(for: pack)
        if let data = try? Data(contentsOf: dir.appendingPathComponent(Self.manifestName)),
           let installed = try? JSONDecoder().decode(ModelPack.self, from: data), installed == pack {
            return .installed
        }
        let present = pack.files.filter { file in
            let attrs = try? FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent(file.name).path)
            return (attrs?[.size] as? Int64) == file.size
        }
        return present.isEmpty ? .notInstalled : .partial(bytes: present.reduce(0) { $0 + $1.size })
    }

    /// Downloads and verifies whatever is missing. `progress` gets (bytes done, bytes total).
    public func install(_ pack: ModelPack, freeSpace: Int64? = nil,
                        progress: @escaping @Sendable (Int64, Int64) -> Void = { _, _ in }) async throws {
        let dir = folder(for: pack)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try excludeFromBackup(root)

        var done: Int64 = 0
        var missing: [ModelFile] = []
        for file in pack.files {
            if try isValid(file, in: dir, pack: pack) { done += file.size } else { missing.append(file) }
        }
        let needed = missing.reduce(Int64(0)) { $0 + $1.size }
        if let freeSpace, needed > freeSpace { throw ModelStoreError.notEnoughSpace(needed: needed, available: freeSpace) }
        progress(done, pack.totalBytes)

        for file in missing {
            try Task.checkCancellation()
            let temp = dir.appendingPathComponent(".\(file.name).download")
            try? FileManager.default.removeItem(at: temp)
            let base = done
            try await fetcher.fetch(pack.url(for: file), to: temp) { got in progress(base + got, pack.totalBytes) }
            try verify(temp, against: file)
            let target = dir.appendingPathComponent(file.name)
            try? FileManager.default.removeItem(at: target)
            try FileManager.default.moveItem(at: temp, to: target)
            verified[pack.id, default: []].insert(file.name)
            done += file.size
            progress(done, pack.totalBytes)
        }
        try JSONEncoder().encode(pack).write(to: dir.appendingPathComponent(Self.manifestName), options: .atomic)
    }

    /// Re-hashes every installed file against its pin (before a flight: PLAN.md §13.1). A file that
    /// doesn't match is removed, so the next install fetches it again.
    public func verify(_ pack: ModelPack) throws {
        let dir = folder(for: pack)
        do {
            for file in pack.files { try verify(dir.appendingPathComponent(file.name), against: file) }
        } catch {
            // No longer installed: drop the manifest so the state says so and an install resumes.
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(Self.manifestName))
            verified[pack.id] = nil
            throw error
        }
        verified[pack.id] = Set(pack.files.map(\.name))
    }

    public func remove(_ pack: ModelPack) throws {
        verified[pack.id] = nil
        let dir = folder(for: pack)
        if FileManager.default.fileExists(atPath: dir.path) { try FileManager.default.removeItem(at: dir) }
    }

    // MARK: Verification

    /// A file already on disk counts only if it was verified in this session or hashes correctly now.
    private func isValid(_ file: ModelFile, in dir: URL, pack: ModelPack) throws -> Bool {
        let url = dir.appendingPathComponent(file.name)
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        if verified[pack.id]?.contains(file.name) == true { return true }
        do {
            try verify(url, against: file)
            verified[pack.id, default: []].insert(file.name)
            return true
        } catch {
            try? FileManager.default.removeItem(at: url)
            return false
        }
    }

    func verify(_ url: URL, against file: ModelFile) throws {
        let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? -1
        guard size == file.size else {
            try? FileManager.default.removeItem(at: url)
            throw ModelStoreError.sizeMismatch(file: file.name, expected: file.size, got: size)
        }
        guard try Self.sha256(of: url) == file.sha256 else {
            try? FileManager.default.removeItem(at: url)
            throw ModelStoreError.hashMismatch(file: file.name)
        }
    }

    /// Streams the file in 4 MB chunks, so a 4 GB model doesn't need 4 GB of memory to check.
    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private nonisolated func excludeFromBackup(_ url: URL) throws {
        var url = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
    }
}
