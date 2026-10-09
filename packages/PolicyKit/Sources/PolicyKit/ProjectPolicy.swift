// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// A repo's own rules, from `.omnie/policy.json`. **Tighten-only:** a repo can deny actions or
/// raise their tier, never lower one, so a malicious repo can't grant itself anything.
///
/// ```json
/// { "deny": ["installPackage"],
///   "minimumTier": { "writeTracked": "askWithBiometrics" },
///   "networkDeny": ["example.com"] }
/// ```
/// Unknown keys are ignored. A file that can't be read makes every agent action ask.
public struct ProjectPolicy: Sendable, Hashable, Decodable {
    public var deny: Set<Action.Kind> = []
    public var minimumTier: [Action.Kind: Tier] = [:]
    public var networkDeny: Set<String> = []
    /// Set when the file exists but is malformed; fails closed.
    public var isMalformed = false

    public static let none = ProjectPolicy()
    public static let relativePath = ".omnie/policy.json"

    public init() {}

    enum CodingKeys: String, CodingKey { case deny, minimumTier, networkDeny }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        deny = Set(try c.decodeIfPresent([Action.Kind].self, forKey: .deny) ?? [])
        let tiers = try c.decodeIfPresent([String: String].self, forKey: .minimumTier) ?? [:]
        for (kind, tier) in tiers {
            guard let k = Action.Kind(rawValue: kind), let t = Tier(named: tier) else {
                throw DecodingError.dataCorruptedError(forKey: .minimumTier, in: c, debugDescription: "\(kind): \(tier)")
            }
            minimumTier[k] = t
        }
        networkDeny = Set((try c.decodeIfPresent([String].self, forKey: .networkDeny) ?? []).map { $0.lowercased() })
    }

    /// Reads the project's policy file. Missing means no rules; unreadable means fail closed.
    public static func load(projectRoot: URL) -> ProjectPolicy {
        let url = projectRoot.appending(path: relativePath)
        guard let data = try? Data(contentsOf: url) else { return .none }
        do { return try JSONDecoder().decode(ProjectPolicy.self, from: data) }
        catch {
            var policy = ProjectPolicy()
            policy.isMalformed = true
            return policy
        }
    }

    /// The tier this policy requires for `action`, if any.
    func tier(for action: Action) -> Tier? {
        if deny.contains(action.kind) { return .deny }
        if case .network(let domain) = action, networkDeny.contains(domain.lowercased()) { return .deny }
        if isMalformed { return .ask }
        return minimumTier[action.kind]
    }
}

extension Tier {
    init?(named name: String) {
        switch name {
        case "auto": self = .auto
        case "ask": self = .ask
        case "askWithBiometrics": self = .askWithBiometrics
        case "deny": self = .deny
        default: return nil
        }
    }
}
