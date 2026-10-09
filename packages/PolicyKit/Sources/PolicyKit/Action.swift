// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

/// Who asked for an action. The agent's actions go through every tier; yours skip the "ask"
/// step (you pressed the button) but outward actions still need Face ID.
public enum Actor: String, Codable, Sendable, Hashable {
    case user
    case agent
}

/// Something that needs a policy decision, with its exact arguments (PLAN.md §12). Capability
/// tokens are scoped to these arguments, and the audit log records them.
public enum Action: Codable, Sendable, Hashable {
    case readProject(path: String)
    case writeScratch(path: String)
    /// A write inside an agent task worktree; reviewed when the task merges.
    case writeTaskWorktree(path: String)
    case writeTracked(path: String)
    case delete(path: String)
    case runSandboxed(command: String, network: Bool)
    case installPackage(name: String, fromNetwork: Bool)
    case network(domain: String)
    case sqlWrite(database: String)
    case gitPush(remote: String, branch: String, force: Bool)
    case useSecret(name: String)
    case sendToProvider(provider: String)
    case remoteExec(host: String, egress: Bool)
    case deploy(target: String)
    /// Committing changes in which the secret scanner found something.
    case commitWithSuspectedSecrets(findings: [String])

    /// The kind without arguments, for project rules ("deny installPackage").
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case readProject, writeScratch, writeTaskWorktree, writeTracked, delete, runSandboxed,
             installPackage, network, sqlWrite, gitPush, useSecret, sendToProvider, remoteExec,
             deploy, commitWithSuspectedSecrets
    }

    public var kind: Kind {
        switch self {
        case .readProject: .readProject
        case .writeScratch: .writeScratch
        case .writeTaskWorktree: .writeTaskWorktree
        case .writeTracked: .writeTracked
        case .delete: .delete
        case .runSandboxed: .runSandboxed
        case .installPackage: .installPackage
        case .network: .network
        case .sqlWrite: .sqlWrite
        case .gitPush: .gitPush
        case .useSecret: .useSecret
        case .sendToProvider: .sendToProvider
        case .remoteExec: .remoteExec
        case .deploy: .deploy
        case .commitWithSuspectedSecrets: .commitWithSuspectedSecrets
        }
    }

    /// Whether the action needs the network right now. Plane mode denies these.
    /// A push doesn't: offline it's authorized now and queued.
    public var needsNetwork: Bool {
        switch self {
        case .runSandboxed(_, let network): network
        case .installPackage(_, let fromNetwork): fromNetwork
        case .network, .sendToProvider, .remoteExec, .deploy: true
        default: false
        }
    }

    /// One line naming exactly what will happen, for approvals and the audit log viewer.
    public var summary: String {
        switch self {
        case .readProject(let p): "Read \(p)"
        case .writeScratch(let p): "Write scratch file \(p)"
        case .writeTaskWorktree(let p): "Write \(p) in a task worktree"
        case .writeTracked(let p): "Write \(p)"
        case .delete(let p): "Delete \(p)"
        case .runSandboxed(let c, let n): "Run `\(c)`" + (n ? " with network" : " offline")
        case .installPackage(let name, let n): "Install \(name)" + (n ? " from the network" : " from the cache")
        case .network(let d): "Connect to \(d)"
        case .sqlWrite(let db): "Write to database \(db)"
        case .gitPush(let r, let b, let f): (f ? "Force-push " : "Push ") + "\(b) to \(r)"
        case .useSecret(let n): "Use secret \(n)"
        case .sendToProvider(let p): "Send code to \(p)"
        case .remoteExec(let h, let e): "Run on \(h)" + (e ? " with internet access" : "")
        case .deploy(let t): "Deploy to \(t)"
        case .commitWithSuspectedSecrets(let f): "Commit with \(f.count) possible secret\(f.count == 1 ? "" : "s")"
        }
    }
}
