// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

import CGitSSH
import Clibgit2
import Foundation

/// libgit2 must be initialized once per process before any other call.
enum Libgit2 {
    static let initialize: Void = {
        git_libgit2_init()
        omnie_ssh_set_sign_function(sshSignFunction)
        // Files marked filter=lfs go through Git LFS (LFS.swift).
        LFS.register
        return ()
    }()
}

public struct GitError: Error, Sendable, Equatable, CustomStringConvertible {
    public let code: Int32
    public let message: String
    public let operation: String

    public var description: String { "\(operation) failed (\(code)): \(message)" }

    static func last(_ code: Int32, _ operation: String) -> GitError {
        let message = git_error_last().flatMap { $0.pointee.message.map { String(cString: $0) } } ?? "unknown error"
        return GitError(code: code, message: message, operation: operation)
    }

    public var isNotFound: Bool { code == GIT_ENOTFOUND.rawValue }
}

public enum GitKitError: Error, Sendable, Equatable {
    case nothingToCommit
    case notACheckpoint(ObjectID)
    case detachedHead
    /// The server's host key isn't known yet. Show the fingerprint, then trust it and retry.
    case unknownHostKey(HostKey)
    /// The server's host key differs from the one trusted before. Possible interception; never auto-accept.
    case hostKeyChanged(HostKey, expected: String)
    case hostKeyUnverifiable
    case noCredential(String)
    case credentialNotAccepted(String)
    case authenticationFailed(String)
    case signingFailed(String)
    case pushRejected(ref: String, reason: String)
}

@discardableResult
func check(_ code: Int32, _ operation: @autoclosure () -> String) throws -> Int32 {
    if code < 0 { throw GitError.last(code, operation()) }
    return code
}

/// A git object id as 40 hex characters.
public struct ObjectID: Hashable, Sendable, CustomStringConvertible {
    public let hex: String

    public init?(hex: String) {
        var oid = git_oid()
        guard hex.count == 40, git_oid_fromstr(&oid, hex) == 0 else { return nil }
        self.hex = hex.lowercased()
    }

    init(_ oid: git_oid) {
        var copy = oid
        var buffer = [CChar](repeating: 0, count: 41)
        git_oid_tostr(&buffer, 41, &copy)
        hex = buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
    }

    init(_ pointer: UnsafePointer<git_oid>) { self.init(pointer.pointee) }

    var oid: git_oid {
        var o = git_oid()
        git_oid_fromstr(&o, hex)
        return o
    }

    public var short: String { String(hex.prefix(7)) }
    /// All zeros: "no commit" (blame of uncommitted lines).
    public var isZero: Bool { hex.allSatisfy { $0 == "0" } }
    public var description: String { hex }

    /// The tree with no entries.
    public static let emptyTree = ObjectID(hex: "4b825dc642cb6eb9a060e54bf8d69288fbee4904")!
}

public struct Signature: Sendable, Hashable {
    public var name: String
    public var email: String
    public init(name: String, email: String) {
        self.name = name
        self.email = email
    }

    /// Checkpoints are written by the app, not by you, and never pushed.
    public static let checkpoint = Signature(name: "Omnie-dev", email: "checkpoint@omnie.invalid")
}

public struct CommitInfo: Sendable, Hashable, Identifiable {
    public let id: ObjectID
    public let tree: ObjectID
    public let parents: [ObjectID]
    public let message: String
    public let authorName: String
    public let authorEmail: String
    public let date: Date

    /// First line of the message.
    public var summary: String { message.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? "" }

    /// The model id from an `Assisted-by:` trailer, which marks agent-authored commits (PLAN.md §9.3).
    public var assistedBy: String? { Trailers.value(for: "Assisted-by", in: message) }
}

enum Trailers {
    /// Reads a trailer from the last paragraph of a commit message.
    static func value(for key: String, in message: String) -> String? {
        let paragraphs = message.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n\n")
        guard paragraphs.count > 1, let last = paragraphs.last else { return nil }
        let prefix = key.lowercased() + ":"
        for line in last.split(separator: "\n") where line.lowercased().hasPrefix(prefix) {
            return line.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }
}
