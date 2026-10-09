// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Approval tiers, in increasing strictness (PLAN.md §12).
public enum Tier: Int, Codable, Sendable, Comparable, CaseIterable {
    /// Allowed without asking; still audited.
    case auto
    /// Shows the exact diff, command or URL and asks.
    case ask
    /// Asks, then needs Face ID (or the passcode).
    case askWithBiometrics
    case deny

    public static func < (a: Tier, b: Tier) -> Bool { a.rawValue < b.rawValue }
}

/// Everything a decision depends on besides the action.
public struct PolicyContext: Sendable {
    /// Deny-all networking, local models only.
    public var planeMode: Bool
    /// Domains you allowed for this project. Kept in app settings, never read from the repo.
    public var allowedDomains: Set<String>
    /// Model providers you've already agreed to send this project's code to.
    public var approvedProviders: Set<String>
    /// Rules from the repo's `.omnie/policy.json`; they can only tighten.
    public var project: ProjectPolicy

    public init(planeMode: Bool = false, allowedDomains: Set<String> = [], approvedProviders: Set<String> = [],
                project: ProjectPolicy = .none) {
        self.planeMode = planeMode
        self.allowedDomains = allowedDomains
        self.approvedProviders = approvedProviders
        self.project = project
    }
}

public struct Decision: Sendable, Hashable {
    public let tier: Tier
    /// Why, in order: the base rule, then anything that raised it.
    public let reasons: [String]
}

/// "The model proposes, the policy engine decides." Pure and table-driven, so every rule is testable.
public enum PolicyEngine {
    public static func decide(_ action: Action, by actor: Actor, in context: PolicyContext) -> Decision {
        var (tier, reasons) = base(action, actor, context)
        func raise(to new: Tier, _ reason: String) {
            if new > tier { tier = new; reasons.append(reason) }
        }
        if context.planeMode && action.needsNetwork {
            raise(to: .deny, "Plane mode: no network")
        }
        // Repo rules apply to the agent: a repo shouldn't block you from your own buttons, and
        // can't loosen anything for anyone.
        if actor == .agent {
            if let projectTier = context.project.tier(for: action) {
                raise(to: projectTier, "Project policy (.omnie/policy.json)")
            }
        }
        return Decision(tier: tier, reasons: reasons)
    }

    static func base(_ action: Action, _ actor: Actor, _ context: PolicyContext) -> (Tier, [String]) {
        if actor == .user {
            switch action {
            case .gitPush(_, _, let force):
                return (.askWithBiometrics, [force ? "Force push" : "Push leaves the device"])
            case .deploy: return (.askWithBiometrics, ["Deploy"])
            case .sendToProvider(let p) where !context.approvedProviders.contains(p):
                return (.askWithBiometrics, ["First time sending code to \(p)"])
            case .remoteExec(_, true): return (.askWithBiometrics, ["Remote run with internet access"])
            case .commitWithSuspectedSecrets: return (.ask, ["Possible secrets in the commit"])
            default: return (.auto, ["Your action"])
            }
        }
        switch action {
        case .readProject: return (.auto, ["Project read"])
        case .writeScratch: return (.auto, ["Scratch write"])
        case .writeTaskWorktree: return (.auto, ["Task worktree write, reviewed at merge"])
        case .runSandboxed(_, false): return (.auto, ["Sandboxed run, no network"])
        case .runSandboxed(_, true): return (.ask, ["Sandboxed run with network"])
        case .writeTracked: return (.ask, ["Write to a tracked file on your branch"])
        case .installPackage: return (.ask, ["Package install"])
        case .network(let d):
            return context.allowedDomains.contains(d.lowercased()) ? (.auto, ["Allowed domain"]) : (.ask, ["New network domain"])
        case .sqlWrite: return (.ask, ["Database write"])
        case .commitWithSuspectedSecrets: return (.ask, ["Possible secrets in the commit"])
        case .delete: return (.askWithBiometrics, ["Delete"])
        case .gitPush(_, _, let force): return (.askWithBiometrics, [force ? "Force push" : "Push"])
        case .useSecret: return (.askWithBiometrics, ["Secret use"])
        case .sendToProvider(let p):
            return context.approvedProviders.contains(p) ? (.auto, ["Provider already approved"])
                : (.askWithBiometrics, ["Sending code to a new provider"])
        case .remoteExec(_, let egress):
            return egress ? (.askWithBiometrics, ["Remote run with internet access"]) : (.ask, ["Remote run"])
        case .deploy: return (.askWithBiometrics, ["Deploy"])
        }
    }
}
