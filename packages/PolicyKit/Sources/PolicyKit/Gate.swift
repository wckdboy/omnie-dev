// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

import CryptoKit
import Foundation

/// What an approval prompt shows: the exact action and artifact, never a model's summary of it.
public struct ApprovalRequest: Sendable, Hashable, Identifiable {
    public let id = UUID()
    public let action: Action
    public let actor: Actor
    public let tier: Tier
    public let reasons: [String]
    /// The diff, command, URL or findings being approved, verbatim.
    public let artifact: String?
}

/// The UI side of approvals.
public protocol Approver: Sendable {
    /// Shows the request and returns your answer. For `.askWithBiometrics` it also runs Face ID
    /// (for your own actions, Face ID alone: pressing the button was the ask).
    func approve(_ request: ApprovalRequest) async -> Bool
}

/// Proof that one exact action was authorized: scoped to its arguments, short-lived, single-use,
/// and MAC'd with a per-session key so it can't be forged or widened.
public struct CapabilityToken: Sendable, Hashable {
    public let id: UUID
    public let action: Action
    public let actor: Actor
    public let expires: Date
    let mac: Data
}

public enum Authorization: Sendable {
    case granted(CapabilityToken)
    case refused(reason: String)

    public var token: CapabilityToken? {
        if case .granted(let t) = self { return t }
        return nil
    }
}

/// Decides, asks if needed, records the outcome, and issues a capability token.
public actor Gate {
    let audit: AuditLog
    let approver: any Approver
    let tokenLifetime: TimeInterval
    private let sessionKey = SymmetricKey(size: .bits256)
    private var redeemed: Set<UUID> = []

    public init(audit: AuditLog, approver: any Approver, tokenLifetime: TimeInterval = 120) {
        self.audit = audit
        self.approver = approver
        self.tokenLifetime = tokenLifetime
    }

    public func authorize(_ action: Action, by actor: Actor, artifact: String? = nil,
                          context: PolicyContext) async -> Authorization {
        let decision = PolicyEngine.decide(action, by: actor, in: context)
        let outcome: AuditEntry.Outcome
        switch decision.tier {
        case .deny: outcome = .denied
        case .auto: outcome = .allowed
        case .ask, .askWithBiometrics:
            let request = ApprovalRequest(action: action, actor: actor, tier: decision.tier,
                                          reasons: decision.reasons, artifact: artifact)
            outcome = await approver.approve(request) ? .approved : .rejected
        }
        // Fail closed: an action that can't be recorded doesn't happen.
        do {
            try await audit.append(actor: actor, action: action, tier: decision.tier, outcome: outcome,
                                   reasons: decision.reasons)
        } catch {
            return .refused(reason: "Couldn't write the audit log: \(error.localizedDescription)")
        }
        switch outcome {
        case .allowed, .approved: return .granted(issue(action, actor))
        case .rejected: return .refused(reason: "Not approved")
        case .denied: return .refused(reason: decision.reasons.last ?? "Not allowed")
        }
    }

    /// Checks a token for exactly this action and uses it up.
    public func redeem(_ token: CapabilityToken, for action: Action, now: Date = .now) -> Bool {
        guard token.action == action, now < token.expires, !redeemed.contains(token.id),
              HMAC<SHA256>.isValidAuthenticationCode(token.mac, authenticating: Self.message(token.id, action, token.actor, token.expires),
                                                     using: sessionKey) else { return false }
        redeemed.insert(token.id)
        return true
    }

    private func issue(_ action: Action, _ actor: Actor) -> CapabilityToken {
        let id = UUID()
        let expires = Date.now.addingTimeInterval(tokenLifetime)
        let mac = Data(HMAC<SHA256>.authenticationCode(for: Self.message(id, action, actor, expires), using: sessionKey))
        return CapabilityToken(id: id, action: action, actor: actor, expires: expires, mac: mac)
    }

    static func message(_ id: UUID, _ action: Action, _ actor: Actor, _ expires: Date) -> Data {
        var data = Data(id.uuidString.utf8)
        data.append((try? AuditLog.encoder.encode(action)) ?? Data())
        data.append(Data(actor.rawValue.utf8))
        data.append(Data(String(expires.timeIntervalSince1970).utf8))
        return data
    }
}
