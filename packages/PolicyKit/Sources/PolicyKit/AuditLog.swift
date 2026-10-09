// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

import CryptoKit
import Foundation

/// One policy decision, as recorded.
public struct AuditEntry: Codable, Sendable, Hashable, Identifiable {
    public enum Outcome: String, Codable, Sendable {
        /// Allowed by policy without asking.
        case allowed
        /// You approved it.
        case approved
        /// You declined, or Face ID failed.
        case rejected
        /// Policy forbids it.
        case denied
    }

    public var id: Int { seq }
    public let seq: Int
    /// Milliseconds since 1970; an integer so the hash is reproducible.
    public let timeMs: Int64
    public let actor: Actor
    public let action: Action
    public let tier: Tier
    public let outcome: Outcome
    public let reasons: [String]
    /// Hash of the previous entry, or 64 zeros for the first.
    public let prev: String
    /// SHA-256 of this entry's canonical JSON without `hash`.
    public let hash: String

    public var date: Date { Date(timeIntervalSince1970: Double(timeMs) / 1000) }
}

/// An append-only, hash-chained log of every policy decision (PLAN.md §12). Each entry commits to
/// the one before it, so editing or deleting a past entry breaks every hash after it.
/// Stored as JSON lines; the database (§15) takes over later with the same chain.
public actor AuditLog {
    public enum Verification: Equatable, Sendable {
        case intact(entries: Int)
        /// The first entry whose hash or link doesn't check out (or the line that doesn't parse).
        case broken(atLine: Int)
    }

    public static let genesis = String(repeating: "0", count: 64)

    let url: URL
    private var lastSeq = 0
    private var lastHash = AuditLog.genesis

    public init(url: URL) {
        self.url = url
        if let last = Self.readEntries(url).last.flatMap({ $0 }) {
            lastSeq = last.seq
            lastHash = last.hash
        }
    }

    @discardableResult
    public func append(actor: Actor, action: Action, tier: Tier, outcome: AuditEntry.Outcome,
                       reasons: [String], at date: Date = .now) throws -> AuditEntry {
        let unsigned = Unsigned(seq: lastSeq + 1, timeMs: Int64((date.timeIntervalSince1970 * 1000).rounded()),
                                actor: actor, action: action, tier: tier, outcome: outcome, reasons: reasons, prev: lastHash)
        let entry = unsigned.signed()
        var line = try Self.encoder.encode(entry)
        line.append(0x0A)
        if !FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            #if os(iOS)
            FileManager.default.createFile(atPath: url.path(percentEncoded: false), contents: nil,
                                           attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
            #else
            FileManager.default.createFile(atPath: url.path(percentEncoded: false), contents: nil)
            #endif
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: line)
        lastSeq = entry.seq
        lastHash = entry.hash
        return entry
    }

    /// The most recent entries, newest last.
    public func entries(last count: Int = .max) -> [AuditEntry] {
        Array(Self.readEntries(url).compactMap { $0 }.suffix(count))
    }

    /// Recomputes every hash and link from the start.
    public func verify() -> Verification {
        var prev = Self.genesis
        var count = 0
        for (i, entry) in Self.readEntries(url).enumerated() {
            guard let entry, entry.prev == prev, entry.seq == i + 1,
                  Unsigned(entry).signed().hash == entry.hash else { return .broken(atLine: i + 1) }
            prev = entry.hash
            count += 1
        }
        return .intact(entries: count)
    }

    // MARK: Encoding

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }()

    /// One element per line; nil for a line that doesn't parse.
    static func readEntries(_ url: URL) -> [AuditEntry?] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return data.split(separator: 0x0A).map { try? JSONDecoder().decode(AuditEntry.self, from: Data($0)) }
    }

    /// The entry without its hash: what gets hashed.
    struct Unsigned: Codable {
        let seq: Int, timeMs: Int64, actor: Actor, action: Action, tier: Tier
        let outcome: AuditEntry.Outcome, reasons: [String], prev: String

        init(seq: Int, timeMs: Int64, actor: Actor, action: Action, tier: Tier, outcome: AuditEntry.Outcome,
             reasons: [String], prev: String) {
            (self.seq, self.timeMs, self.actor, self.action, self.tier) = (seq, timeMs, actor, action, tier)
            (self.outcome, self.reasons, self.prev) = (outcome, reasons, prev)
        }

        init(_ e: AuditEntry) {
            self.init(seq: e.seq, timeMs: e.timeMs, actor: e.actor, action: e.action, tier: e.tier,
                      outcome: e.outcome, reasons: e.reasons, prev: e.prev)
        }

        func signed() -> AuditEntry {
            // Encoding with sorted keys is deterministic for these value types.
            let digest = SHA256.hash(data: (try? AuditLog.encoder.encode(self)) ?? Data())
            let hash = digest.map { String(format: "%02x", $0) }.joined()
            return AuditEntry(seq: seq, timeMs: timeMs, actor: actor, action: action, tier: tier,
                              outcome: outcome, reasons: reasons, prev: prev, hash: hash)
        }
    }
}
