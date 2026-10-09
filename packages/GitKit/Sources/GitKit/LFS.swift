// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

import Clibgit2
import CryptoKit
import Foundation

/// Git LFS (PLAN.md §22, P5): large files live outside git as objects addressed by their SHA-256,
/// and git stores a small pointer. A libgit2 filter does what git-lfs's filter does: files marked
/// `filter=lfs` in .gitattributes are stored in .git/lfs/objects and committed as pointers
/// ("clean"), and checked out from there ("smudge"), so status and diffs see the real files. The
/// batch API moves objects to and from the forge over HTTPS.
public enum LFS {
    /// An LFS pointer: what git stores instead of the file.
    public struct Pointer: Sendable, Hashable {
        public let oid: String
        public let size: Int

        public init(oid: String, size: Int) { self.oid = oid; self.size = size }

        public init(content: Data) {
            oid = SHA256.hash(data: content).map { String(format: "%02x", $0) }.joined()
            size = content.count
        }

        static let version = "https://git-lfs.github.com/spec/v1"

        public var text: String { "version \(Self.version)\noid sha256:\(oid)\nsize \(size)\n" }

        /// A pointer file's contents, or nil when `data` is an ordinary file.
        public static func parse(_ data: Data) -> Pointer? {
            guard data.count < 1024, let text = String(data: data, encoding: .utf8),
                  text.hasPrefix("version \(version)\n") else { return nil }
            var oid: String?, size: Int?
            for line in text.split(separator: "\n") {
                if line.hasPrefix("oid sha256:") { oid = String(line.dropFirst("oid sha256:".count)) }
                if line.hasPrefix("size ") { size = Int(line.dropFirst(5)) }
            }
            guard let oid, oid.count == 64, oid.allSatisfy(\.isHexDigit), let size else { return nil }
            return Pointer(oid: oid, size: size)
        }
    }

    /// .git/lfs/objects/ab/cd/abcd…, as git-lfs lays them out.
    public static func objectURL(_ oid: String, gitDir: URL) -> URL {
        gitDir.appending(path: "lfs/objects/\(oid.prefix(2))/\(oid.dropFirst(2).prefix(2))/\(oid)")
    }

    static func store(_ content: Data, gitDir: URL) throws -> Pointer {
        let pointer = Pointer(content: content)
        let url = objectURL(pointer.oid, gitDir: gitDir)
        if !FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try content.write(to: url, options: .atomic)
        }
        return pointer
    }

    /// Clean: a file's content as it's committed (a pointer). Smudge: a pointer as it's checked
    /// out (the object, when it's here; the pointer itself until it's downloaded).
    static func transform(_ data: Data, clean: Bool, gitDir: URL) -> Data {
        if clean {
            if Pointer.parse(data) != nil { return data }
            return (try? store(data, gitDir: gitDir)).map { Data($0.text.utf8) } ?? data
        }
        guard let pointer = Pointer.parse(data),
              let object = try? Data(contentsOf: objectURL(pointer.oid, gitDir: gitDir)), object.count == pointer.size
        else { return data }
        return object
    }

    // MARK: The libgit2 filter

    /// Per-stream state, found by the stream's address (libgit2 hands back only the C struct).
    final class StreamState: @unchecked Sendable {
        let next: UnsafeMutablePointer<git_writestream>
        let clean: Bool
        let gitDir: URL
        var buffer = Data()
        init(next: UnsafeMutablePointer<git_writestream>, clean: Bool, gitDir: URL) {
            self.next = next; self.clean = clean; self.gitDir = gitDir
        }
    }

    nonisolated(unsafe) static var streams: [UnsafeMutableRawPointer: StreamState] = [:]
    static let lock = NSLock()

    static func state(_ stream: UnsafeMutablePointer<git_writestream>?) -> StreamState? {
        guard let stream else { return nil }
        lock.lock(); defer { lock.unlock() }
        return streams[UnsafeMutableRawPointer(stream)]
    }

    /// Registers the "lfs" filter with libgit2 (once, with libgit2's initialisation).
    static let register: Void = {
        let filter = UnsafeMutablePointer<git_filter>.allocate(capacity: 1)
        filter.initialize(to: git_filter())
        git_filter_init(filter, UInt32(GIT_FILTER_VERSION))
        filter.pointee.attributes = UnsafePointer(strdup("filter=lfs"))
        filter.pointee.stream = { out, _, _, source, next in
            guard let out, let source, let next else { return -1 }
            let clean = git_filter_source_mode(source) == GIT_FILTER_CLEAN
            guard let repo = git_filter_source_repo(source), let path = git_repository_path(repo) else { return -1 }
            let stream = UnsafeMutablePointer<git_writestream>.allocate(capacity: 1)
            stream.initialize(to: git_writestream())
            stream.pointee.write = { stream, bytes, length in
                guard let state = LFS.state(stream), let bytes else { return -1 }
                state.buffer.append(UnsafeRawPointer(bytes).assumingMemoryBound(to: UInt8.self), count: length)
                return 0
            }
            stream.pointee.close = { stream in
                guard let state = LFS.state(stream) else { return -1 }
                let output = LFS.transform(state.buffer, clean: state.clean, gitDir: state.gitDir)
                let rc = output.withUnsafeBytes { raw -> Int32 in
                    guard let base = raw.baseAddress else { return 0 }
                    return state.next.pointee.write(state.next, base.assumingMemoryBound(to: CChar.self), raw.count)
                }
                guard rc == 0 else { return rc }
                return state.next.pointee.close(state.next)
            }
            stream.pointee.free = { stream in
                guard let stream else { return }
                LFS.lock.lock()
                LFS.streams[UnsafeMutableRawPointer(stream)] = nil
                LFS.lock.unlock()
                stream.deinitialize(count: 1)
                stream.deallocate()
            }
            let state = StreamState(next: next, clean: clean, gitDir: URL(filePath: String(cString: path), directoryHint: .isDirectory))
            LFS.lock.lock()
            LFS.streams[UnsafeMutableRawPointer(stream)] = state
            LFS.lock.unlock()
            out.pointee = stream
            return 0
        }
        git_filter_register("lfs", filter, Int32(GIT_FILTER_DRIVER_PRIORITY))
    }()

    // MARK: The batch API

    public enum Failure: Error, Sendable, Equatable, LocalizedError {
        case http(status: Int, message: String)
        case badResponse
        case objectError(oid: String, message: String)
        case checksum(oid: String)
        case sshOnly(String)

        public var errorDescription: String? {
            switch self {
            case .http(401, _), .http(403, _): "The LFS server refused the credentials. Check the token for this host."
            case .http(let status, let message): "The LFS server returned \(status): \(message)"
            case .badResponse: "The LFS server's answer couldn't be read."
            case .objectError(let oid, let message): "LFS object \(oid.prefix(12)): \(message)"
            case .checksum(let oid): "LFS object \(oid.prefix(12)) didn't match its checksum; it wasn't saved."
            case .sshOnly(let url): "\(url) is an SSH remote; LFS needs its HTTPS address (the same host usually serves both)."
            }
        }
    }

    /// `https://host/owner/repo.git/info/lfs` for a remote URL (SSH remotes map to the host's HTTPS).
    public static func endpoint(for remote: String) -> URL? {
        var url = remote
        if !url.contains("://"), let at = url.firstIndex(of: "@"), let colon = url[at...].firstIndex(of: ":") {
            url = "https://" + url[url.index(after: at)..<colon] + "/" + url[url.index(after: colon)...]
        } else if url.hasPrefix("ssh://") {
            url = "https://" + url.dropFirst("ssh://".count).split(separator: "@", maxSplits: 1).last!
        }
        if !url.hasSuffix(".git") { url += ".git" }
        return URL(string: url + "/info/lfs")
    }

    public struct Client: Sendable {
        public let endpoint: URL
        /// "Basic …" or nil for public repositories.
        public let authorization: String?
        let session: URLSession

        public init(endpoint: URL, authorization: String?, session: URLSession = .shared) {
            self.endpoint = endpoint; self.authorization = authorization; self.session = session
        }

        struct Action: Decodable { let href: String; let header: [String: String]? }
        struct Object: Decodable {
            let oid: String; let size: Int
            let actions: [String: Action]?
            let error: ObjectError?
        }
        struct ObjectError: Decodable { let code: Int; let message: String }
        struct Batch: Decodable { let objects: [Object] }

        func batch(_ operation: String, _ pointers: [Pointer]) async throws -> [Object] {
            var request = URLRequest(url: endpoint.appending(path: "objects/batch"))
            request.httpMethod = "POST"
            request.setValue("application/vnd.git-lfs+json", forHTTPHeaderField: "Accept")
            request.setValue("application/vnd.git-lfs+json", forHTTPHeaderField: "Content-Type")
            if let authorization { request.setValue(authorization, forHTTPHeaderField: "Authorization") }
            let body: [String: Any] = ["operation": operation, "transfers": ["basic"],
                                       "objects": pointers.map { ["oid": $0.oid, "size": $0.size] }]
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw Failure.badResponse }
            guard (200..<300).contains(http.statusCode) else {
                throw Failure.http(status: http.statusCode, message: String(decoding: data.prefix(200), as: UTF8.self))
            }
            guard let batch = try? JSONDecoder().decode(Batch.self, from: data) else { throw Failure.badResponse }
            return batch.objects
        }

        func request(_ action: Action, method: String) throws -> URLRequest {
            guard let url = URL(string: action.href) else { throw Failure.badResponse }
            var request = URLRequest(url: url)
            request.httpMethod = method
            for (key, value) in action.header ?? [:] { request.setValue(value, forHTTPHeaderField: key) }
            if action.header?["Authorization"] == nil, let authorization, url.host() == endpoint.host() {
                request.setValue(authorization, forHTTPHeaderField: "Authorization")
            }
            return request
        }

        /// Downloads `pointers` into the store, each checked against its oid and size.
        public func download(_ pointers: [Pointer], gitDir: URL) async throws -> Int {
            guard !pointers.isEmpty else { return 0 }
            var count = 0
            for object in try await batch("download", pointers) {
                if let error = object.error { throw Failure.objectError(oid: object.oid, message: error.message) }
                guard let action = object.actions?["download"] else { continue }
                let (data, response) = try await session.data(for: try request(action, method: "GET"))
                guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                    throw Failure.http(status: (response as? HTTPURLResponse)?.statusCode ?? 0, message: "download \(object.oid.prefix(12))")
                }
                guard Pointer(content: data).oid == object.oid, data.count == object.size else { throw Failure.checksum(oid: object.oid) }
                _ = try store(data, gitDir: gitDir)
                count += 1
            }
            return count
        }

        /// Uploads the objects the server doesn't have yet.
        public func upload(_ pointers: [Pointer], gitDir: URL) async throws -> Int {
            guard !pointers.isEmpty else { return 0 }
            var count = 0
            for object in try await batch("upload", pointers) {
                if let error = object.error { throw Failure.objectError(oid: object.oid, message: error.message) }
                guard let action = object.actions?["upload"] else { continue } // already there
                let data = try Data(contentsOf: objectURL(object.oid, gitDir: gitDir))
                var put = try request(action, method: "PUT")
                put.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
                let (_, response) = try await session.upload(for: put, from: data)
                guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                    throw Failure.http(status: (response as? HTTPURLResponse)?.statusCode ?? 0, message: "upload \(object.oid.prefix(12))")
                }
                if let verify = object.actions?["verify"] {
                    var post = try request(verify, method: "POST")
                    post.setValue("application/vnd.git-lfs+json", forHTTPHeaderField: "Content-Type")
                    post.httpBody = try JSONSerialization.data(withJSONObject: ["oid": object.oid, "size": object.size])
                    _ = try await session.data(for: post)
                }
                count += 1
            }
            return count
        }
    }
}

extension Repository {
    var gitDir: URL { URL(filePath: String(cString: git_repository_path(pointer)), directoryHint: .isDirectory) }

    /// Whether .gitattributes marks anything for LFS.
    public func usesLFS() -> Bool {
        let attributes = (try? String(contentsOf: workdir.appending(path: ".gitattributes"), encoding: .utf8)) ?? ""
        return attributes.contains("filter=lfs")
    }

    /// LFS pointers in HEAD's tree, by path.
    public func lfsPointers() throws -> [String: LFS.Pointer] {
        guard let commit = try head().commit else { return [:] }
        var treeOid = try treeOf(commit).oid
        var tree: OpaquePointer?
        try check(git_tree_lookup(&tree, pointer, &treeOid), "read tree")
        defer { git_tree_free(tree) }
        final class Box { var found: [(String, ObjectID)] = [] }
        let box = Box()
        let payload = Unmanaged.passUnretained(box).toOpaque()
        git_tree_walk(tree, GIT_TREEWALK_PRE, { root, entry, payload in
            guard let entry, let payload, git_tree_entry_type(entry) == GIT_OBJECT_BLOB else { return 0 }
            let box = Unmanaged<Box>.fromOpaque(payload).takeUnretainedValue()
            let name = String(cString: git_tree_entry_name(entry))
            box.found.append(((root.map { String(cString: $0) } ?? "") + name, ObjectID(git_tree_entry_id(entry)!)))
            return 0
        }, payload)
        var result: [String: LFS.Pointer] = [:]
        for (path, id) in box.found {
            var oid = id.oid
            var blob: OpaquePointer?
            guard git_blob_lookup(&blob, pointer, &oid) == 0 else { continue }
            defer { git_blob_free(blob) }
            let size = Int(git_blob_rawsize(blob))
            guard size < 1024 else { continue }
            if let p = LFS.Pointer.parse(Data(bytes: git_blob_rawcontent(blob), count: size)) { result[path] = p }
        }
        return result
    }

    /// The LFS client for a remote: its HTTPS endpoint and the token git uses for that host.
    func lfsClient(remote name: String, auth: RemoteAuth, session: URLSession = .shared) throws -> LFS.Client {
        guard let url = try remotes().first(where: { $0.name == name })?.url else { throw MigrationError.noSuchRemote(name) }
        guard let endpoint = LFS.endpoint(for: url) else { throw LFS.Failure.badResponse }
        var authorization: String?
        if case .token(let user, let token)? = auth.credential(endpoint.absoluteString) {
            authorization = "Basic " + Data("\(user):\(token)".utf8).base64EncodedString()
        }
        return LFS.Client(endpoint: endpoint, authorization: authorization, session: session)
    }

    /// Downloads the LFS objects HEAD needs that aren't here, then checks those files out again so
    /// the folder has their contents. Returns how many were downloaded.
    @discardableResult
    public func lfsPull(remote: String = "origin", auth: RemoteAuth, session: URLSession = .shared) async throws -> Int {
        let pointers = try lfsPointers()
        let missing = Array(Set(pointers.values.filter {
            !FileManager.default.fileExists(atPath: LFS.objectURL($0.oid, gitDir: gitDir).path(percentEncoded: false))
        }))
        let client = try lfsClient(remote: remote, auth: auth, session: session)
        let count = try await client.download(missing, gitDir: gitDir)
        // A file still holding its pointer looks unchanged to git (cleaning a pointer gives the
        // pointer), so checkout would skip it: take those away first, then check them out.
        let stale = pointers.keys.filter { path in
            let url = workdir.appending(path: path)
            return (try? Data(contentsOf: url)).flatMap(LFS.Pointer.parse) != nil
                && FileManager.default.fileExists(atPath: LFS.objectURL(pointers[path]!.oid, gitDir: gitDir).path(percentEncoded: false))
        }
        for path in stale { try? FileManager.default.removeItem(at: workdir.appending(path: path)) }
        try checkoutPaths(stale)
        return count
    }

    /// Uploads the LFS objects HEAD refers to that the server doesn't have (before a push).
    @discardableResult
    public func lfsPush(remote: String = "origin", auth: RemoteAuth, session: URLSession = .shared) async throws -> Int {
        let pointers = Array(Set(try lfsPointers().values.filter {
            FileManager.default.fileExists(atPath: LFS.objectURL($0.oid, gitDir: gitDir).path(percentEncoded: false))
        }))
        return try await lfsClient(remote: remote, auth: auth, session: session).upload(pointers, gitDir: gitDir)
    }

    /// Re-checks-out `paths` from HEAD (the smudge filter fills in LFS content).
    func checkoutPaths(_ paths: [String]) throws {
        guard !paths.isEmpty else { return }
        var opts = git_checkout_options()
        git_checkout_options_init(&opts, UInt32(GIT_CHECKOUT_OPTIONS_VERSION))
        opts.checkout_strategy = GIT_CHECKOUT_FORCE.rawValue
        let rc = withStrArray(paths) { array -> Int32 in
            opts.paths = array.pointee
            return git_checkout_head(pointer, &opts)
        }
        try check(rc, "check out LFS files")
    }
}
