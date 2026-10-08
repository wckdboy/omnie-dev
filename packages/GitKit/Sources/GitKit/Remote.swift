// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

import CGitSSH
import Clibgit2
import Foundation
import Synchronization

/// How to authenticate to a remote. Secrets live in SecretsKit; GitKit only sees them for one operation.
public enum Credential: Sendable {
    /// SSH with a signer (Secure Enclave on device). The private key never reaches libgit2.
    case sshSigner(username: String, signer: any SSHSigner)
    /// SSH with an imported private key (OpenSSH or PEM format), held in memory for this operation.
    case sshKey(username: String, privateKey: String, passphrase: String?)
    /// HTTPS with a username and token or password.
    case token(username: String, token: String)

    var username: String {
        switch self {
        case .sshSigner(let u, _), .sshKey(let u, _, _), .token(let u, _): u
        }
    }
}

/// A server's SSH host key, as presented during the handshake.
public struct HostKey: Sendable, Hashable, CustomStringConvertible {
    public let host: String
    /// OpenSSH-style "SHA256:…" fingerprint, comparable with `ssh-keygen -lf`.
    public let fingerprint: String
    public let keyType: String?

    public var description: String { "\(host) \(keyType ?? "key") \(fingerprint)" }
}

public enum HostKeyCheck: Sendable, Equatable {
    case trusted
    case unknown
    case changed(expectedFingerprint: String)
}

/// Everything a network operation needs besides the repository.
public struct RemoteAuth: Sendable {
    public var credential: @Sendable (_ url: String) -> Credential?
    public var checkHostKey: @Sendable (HostKey) -> HostKeyCheck
    public var progress: (@Sendable (TransferProgress) -> Void)?

    public init(credential: @escaping @Sendable (_ url: String) -> Credential?,
                checkHostKey: @escaping @Sendable (HostKey) -> HostKeyCheck,
                progress: (@Sendable (TransferProgress) -> Void)? = nil) {
        self.credential = credential
        self.checkHostKey = checkHostKey
        self.progress = progress
    }
}

public struct TransferProgress: Sendable, Hashable {
    public let receivedObjects: Int
    public let totalObjects: Int
    public let receivedBytes: Int
}

public struct RemoteInfo: Sendable, Hashable {
    public let name: String
    public let url: String
}

/// Trust-on-first-use host keys, persisted as JSON. The UI asks before calling `trust`.
public final class KnownHosts: Sendable {
    private let fileURL: URL?
    private let entries: Mutex<[String: String]>

    public init(fileURL: URL?) {
        self.fileURL = fileURL
        let loaded = fileURL.flatMap { try? Data(contentsOf: $0) }
            .flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
        entries = Mutex(loaded)
    }

    public func check(_ key: HostKey) -> HostKeyCheck {
        entries.withLock { e in
            guard let known = e[key.host] else { return .unknown }
            return known == key.fingerprint ? .trusted : .changed(expectedFingerprint: known)
        }
    }

    public func trust(_ key: HostKey) throws {
        let snapshot = entries.withLock { e in
            e[key.host] = key.fingerprint
            return e
        }
        guard let fileURL else { return }
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(snapshot).write(to: fileURL, options: [.atomic, .completeFileProtection])
    }
}

// MARK: - libgit2 callbacks

/// Per-operation state handed to libgit2 callbacks as their payload.
final class RemoteSession: @unchecked Sendable {
    let auth: RemoteAuth
    var credentialAttempts = 0
    var signerBox: SignerBox?
    var error: GitKitError?
    var rejectedRefs: [(ref: String, reason: String)] = []

    init(_ auth: RemoteAuth) { self.auth = auth }

    static func from(_ payload: UnsafeMutableRawPointer?) -> RemoteSession {
        Unmanaged<RemoteSession>.fromOpaque(payload!).takeUnretainedValue()
    }

    func callbacks() -> git_remote_callbacks {
        var cb = git_remote_callbacks()
        git_remote_init_callbacks(&cb, UInt32(GIT_REMOTE_CALLBACKS_VERSION))
        cb.payload = Unmanaged.passUnretained(self).toOpaque()
        cb.credentials = credentialCallback
        cb.certificate_check = certificateCallback
        cb.push_update_reference = pushUpdateCallback
        if auth.progress != nil { cb.transfer_progress = progressCallback }
        return cb
    }

    /// Prefers our own error (host key, auth) over libgit2's generic one.
    func failure(_ code: Int32, _ operation: String) -> Error {
        if let error { return error }
        if let signerError = signerBox?.lastError { return GitKitError.signingFailed("\(signerError)") }
        return GitError.last(code, operation)
    }
}

private let credentialCallback: git_credential_acquire_cb = { out, url, usernameFromURL, allowed, payload in
    let session = RemoteSession.from(payload)
    let urlString = url.map { String(cString: $0) } ?? ""
    session.credentialAttempts += 1
    // libgit2 asks again after every rejection; stop instead of looping.
    guard session.credentialAttempts <= 2 else {
        session.error = .authenticationFailed(urlString)
        return GIT_EAUTH.rawValue
    }
    guard let credential = session.auth.credential(urlString) else {
        session.error = .noCredential(urlString)
        return GIT_EAUTH.rawValue
    }
    let username = usernameFromURL.map { String(cString: $0) } ?? credential.username

    // SSH without a user in the URL: libgit2 first asks for just the username.
    if allowed == GIT_CREDENTIAL_USERNAME.rawValue {
        session.credentialAttempts -= 1
        return git_credential_username_new(out, username)
    }

    switch credential {
    case .sshSigner(_, let signer):
        guard allowed & GIT_CREDENTIAL_SSH_CUSTOM.rawValue != 0 else { break }
        let box = SignerBox(signer)
        session.signerBox = box
        let blob = signer.publicKeyBlob
        return blob.withUnsafeBytes { raw in
            omnie_credential_ssh_custom_new(out, username, raw.bindMemory(to: UInt8.self).baseAddress, blob.count,
                                            Unmanaged.passUnretained(box).toOpaque())
        }
    case .sshKey(_, let key, let passphrase):
        guard allowed & GIT_CREDENTIAL_SSH_MEMORY.rawValue != 0 else { break }
        return git_credential_ssh_key_memory_new(out, username, nil, key, passphrase)
    case .token(let user, let token):
        guard allowed & GIT_CREDENTIAL_USERPASS_PLAINTEXT.rawValue != 0 else { break }
        return git_credential_userpass_plaintext_new(out, user, token)
    }
    session.error = .credentialNotAccepted(urlString)
    return GIT_EAUTH.rawValue
}

private let certificateCallback: git_transport_certificate_check_cb = { cert, valid, host, payload in
    let session = RemoteSession.from(payload)
    guard let cert, cert.pointee.cert_type == GIT_CERT_HOSTKEY_LIBSSH2 else {
        // HTTPS: let the system trust evaluation decide.
        return GIT_PASSTHROUGH.rawValue
    }
    let hostkey = UnsafeRawPointer(cert).assumingMemoryBound(to: git_cert_hostkey.self).pointee
    guard hostkey.type.rawValue & GIT_CERT_SSH_SHA256.rawValue != 0 else {
        session.error = .hostKeyUnverifiable
        return GIT_ECERTIFICATE.rawValue
    }
    let digest = withUnsafeBytes(of: hostkey.hash_sha256) { Data($0) }
    let fingerprint = "SHA256:" + digest.base64EncodedString().trimmingCharacters(in: CharacterSet(charactersIn: "="))
    let key = HostKey(host: host.map { String(cString: $0) } ?? "", fingerprint: fingerprint,
                      keyType: hostkey.type.rawValue & GIT_CERT_SSH_RAW.rawValue != 0 ? hostkey.raw_type.name : nil)
    switch session.auth.checkHostKey(key) {
    case .trusted:
        return 0
    case .unknown:
        session.error = .unknownHostKey(key)
    case .changed(let expected):
        session.error = .hostKeyChanged(key, expected: expected)
    }
    return GIT_ECERTIFICATE.rawValue
}

private let pushUpdateCallback: git_push_update_reference_cb = { ref, status, payload in
    if let status {
        RemoteSession.from(payload).rejectedRefs.append((ref.map { String(cString: $0) } ?? "", String(cString: status)))
    }
    return 0
}

private let progressCallback: git_indexer_progress_cb = { stats, payload in
    guard let stats else { return 0 }
    let s = stats.pointee
    RemoteSession.from(payload).auth.progress?(TransferProgress(
        receivedObjects: Int(s.received_objects), totalObjects: Int(s.total_objects), receivedBytes: s.received_bytes))
    return 0
}

private extension git_cert_ssh_raw_type_t {
    var name: String? {
        switch self {
        case GIT_CERT_SSH_RAW_TYPE_RSA: "ssh-rsa"
        case GIT_CERT_SSH_RAW_TYPE_DSS: "ssh-dss"
        case GIT_CERT_SSH_RAW_TYPE_KEY_ECDSA_256: "ecdsa-sha2-nistp256"
        case GIT_CERT_SSH_RAW_TYPE_KEY_ECDSA_384: "ecdsa-sha2-nistp384"
        case GIT_CERT_SSH_RAW_TYPE_KEY_ECDSA_521: "ecdsa-sha2-nistp521"
        case GIT_CERT_SSH_RAW_TYPE_KEY_ED25519: "ssh-ed25519"
        default: nil
        }
    }
}

// MARK: - Operations

extension Repository {
    public func remotes() throws -> [RemoteInfo] {
        var names = git_strarray()
        try check(git_remote_list(&names, pointer), "list remotes")
        defer { git_strarray_dispose(&names) }
        return try (0..<names.count).compactMap { i in
            guard let cName = names.strings[i] else { return nil }
            var remote: OpaquePointer?
            try check(git_remote_lookup(&remote, pointer, cName), "read remote")
            defer { git_remote_free(remote) }
            return RemoteInfo(name: String(cString: cName), url: git_remote_url(remote).map { String(cString: $0) } ?? "")
        }
    }

    public func addRemote(name: String, url: String) throws {
        var remote: OpaquePointer?
        try check(git_remote_create(&remote, pointer, name, url), "add remote \(name)")
        git_remote_free(remote)
    }

    /// Fetches all branches of `remote` into refs/remotes/<remote>/*.
    public func fetch(remote name: String = "origin", auth: RemoteAuth) throws {
        var remote: OpaquePointer?
        try check(git_remote_lookup(&remote, pointer, name), "find remote \(name)")
        defer { git_remote_free(remote) }

        let session = RemoteSession(auth)
        var opts = git_fetch_options()
        git_fetch_options_init(&opts, UInt32(GIT_FETCH_OPTIONS_VERSION))
        opts.callbacks = session.callbacks()
        opts.prune = GIT_FETCH_PRUNE
        let rc = withExtendedLifetime(session) { git_remote_fetch(remote, nil, &opts, "fetch") }
        if rc < 0 { throw session.failure(rc, "fetch \(name)") }
    }

    /// Pushes `refspecs` (e.g. "refs/heads/main:refs/heads/main") to `remote`.
    /// Throws `pushRejected` if the server refuses any ref (non-fast-forward, hooks, protection).
    public func push(remote name: String = "origin", refspecs: [String], auth: RemoteAuth) throws {
        var remote: OpaquePointer?
        try check(git_remote_lookup(&remote, pointer, name), "find remote \(name)")
        defer { git_remote_free(remote) }

        let session = RemoteSession(auth)
        var opts = git_push_options()
        git_push_options_init(&opts, UInt32(GIT_PUSH_OPTIONS_VERSION))
        opts.callbacks = session.callbacks()

        let rc = withExtendedLifetime(session) {
            withStrArray(refspecs) { specs in git_remote_push(remote, specs, &opts) }
        }
        if rc == GIT_ENONFASTFORWARD.rawValue {
            // libgit2 refuses locally when the remote has commits we don't; same outcome as a server rejection.
            let ref = refspecs.first.map { String($0.split(separator: ":").last ?? Substring($0)) } ?? ""
            throw GitKitError.pushRejected(ref: ref, reason: "non-fast-forward")
        }
        if rc < 0 { throw session.failure(rc, "push to \(name)") }
        if let rejected = session.rejectedRefs.first {
            throw GitKitError.pushRejected(ref: rejected.ref, reason: rejected.reason)
        }
    }

    /// Pushes the current branch to its upstream, or to `origin/<branch>` if none is set,
    /// and sets the upstream after a first push.
    public func pushCurrentBranch(auth: RemoteAuth) throws {
        guard let branch = try head().branch else { throw GitKitError.detachedHead }
        let remoteName = try upstreamRemoteName(of: branch) ?? "origin"
        try push(remote: remoteName, refspecs: ["refs/heads/\(branch):refs/heads/\(branch)"], auth: auth)
        if try upstreamRemoteName(of: branch) == nil {
            var ref: OpaquePointer?
            try check(git_branch_lookup(&ref, pointer, branch, GIT_BRANCH_LOCAL), "find branch")
            defer { git_reference_free(ref) }
            try check(git_branch_set_upstream(ref, "\(remoteName)/\(branch)"), "set upstream")
        }
    }

    func upstreamRemoteName(of branch: String) throws -> String? {
        var buf = git_buf()
        defer { git_buf_dispose(&buf) }
        let rc = git_branch_upstream_remote(&buf, pointer, "refs/heads/\(branch)")
        if rc == GIT_ENOTFOUND.rawValue { return nil }
        try check(rc, "read upstream of \(branch)")
        return String(cString: buf.ptr)
    }

    /// Clones `url` into `directory`. Runs on a background thread; libgit2 network calls block.
    public static func clone(from url: String, to directory: URL, auth: RemoteAuth) async throws -> Repository {
        Libgit2.initialize
        let path = directory.path(percentEncoded: false)
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let session = RemoteSession(auth)
                var opts = git_clone_options()
                git_clone_options_init(&opts, UInt32(GIT_CLONE_OPTIONS_VERSION))
                opts.fetch_opts.callbacks = session.callbacks()
                var repo: OpaquePointer?
                let rc = withExtendedLifetime(session) { git_clone(&repo, url, path, &opts) }
                if rc < 0 {
                    continuation.resume(throwing: session.failure(rc, "clone \(url)"))
                } else {
                    continuation.resume(returning: Repository(adopting: repo!))
                }
            }
        }
    }
}

/// Calls `body` with a git_strarray view of `strings`.
func withStrArray<R>(_ strings: [String], _ body: (UnsafePointer<git_strarray>) -> R) -> R {
    let cStrings = strings.map { strdup($0) }
    defer { cStrings.forEach { free($0) } }
    var pointers: [UnsafeMutablePointer<CChar>?] = cStrings
    return pointers.withUnsafeMutableBufferPointer { buffer in
        var array = git_strarray(strings: buffer.baseAddress, count: strings.count)
        return body(&array)
    }
}
