// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing
@testable import PolicyKit

struct PolicyEngineTests {
    let open = PolicyContext()

    func tier(_ action: Action, _ actor: Actor = .agent, _ context: PolicyContext? = nil) -> Tier {
        PolicyEngine.decide(action, by: actor, in: context ?? open).tier
    }

    /// PLAN.md §12's tier table, row by row, for the agent.
    @Test func agentTiers() {
        let table: [(Action, Tier)] = [
            (.readProject(path: "a.ts"), .auto),
            (.writeScratch(path: "tmp/x"), .auto),
            (.runSandboxed(command: "npm test", network: false), .auto),
            (.writeTaskWorktree(path: "a.ts"), .auto),
            (.writeTracked(path: "a.ts"), .ask),
            (.installPackage(name: "three", fromNetwork: false), .ask),
            (.installPackage(name: "three", fromNetwork: true), .ask),
            (.network(domain: "registry.npmjs.org"), .ask),
            (.sqlWrite(database: "app.db"), .ask),
            (.delete(path: "a.ts"), .askWithBiometrics),
            (.gitPush(remote: "origin", branch: "main", force: false), .askWithBiometrics),
            (.gitPush(remote: "origin", branch: "main", force: true), .askWithBiometrics),
            (.useSecret(name: "OPENAI"), .askWithBiometrics),
            (.sendToProvider(provider: "anthropic"), .askWithBiometrics),
            (.remoteExec(host: "mac-mini", egress: true), .askWithBiometrics),
            (.deploy(target: "prod"), .askWithBiometrics),
        ]
        for (action, expected) in table {
            #expect(tier(action) == expected, "\(action.summary)")
        }
    }

    @Test func yourOwnActionsOnlyNeedFaceIDWhenOutward() {
        #expect(tier(.delete(path: "a.ts"), .user) == .auto)
        #expect(tier(.writeTracked(path: "a.ts"), .user) == .auto)
        #expect(tier(.gitPush(remote: "origin", branch: "main", force: false), .user) == .askWithBiometrics)
        #expect(tier(.deploy(target: "prod"), .user) == .askWithBiometrics)
        #expect(tier(.commitWithSuspectedSecrets(findings: ["a"]), .user) == .ask)
    }

    @Test func allowlistsAndApprovedProviders() {
        let context = PolicyContext(allowedDomains: ["registry.npmjs.org"], approvedProviders: ["anthropic"])
        #expect(tier(.network(domain: "registry.npmjs.org"), .agent, context) == .auto)
        #expect(tier(.network(domain: "evil.example"), .agent, context) == .ask)
        #expect(tier(.sendToProvider(provider: "anthropic"), .agent, context) == .auto)
        #expect(tier(.sendToProvider(provider: "openai"), .agent, context) == .askWithBiometrics)
    }

    @Test func planeModeDeniesTheNetworkButNotAQueuedPush() {
        let plane = PolicyContext(planeMode: true, allowedDomains: ["registry.npmjs.org"], approvedProviders: ["anthropic"])
        #expect(tier(.network(domain: "registry.npmjs.org"), .agent, plane) == .deny)
        #expect(tier(.sendToProvider(provider: "anthropic"), .agent, plane) == .deny)
        #expect(tier(.installPackage(name: "three", fromNetwork: true), .agent, plane) == .deny)
        #expect(tier(.installPackage(name: "three", fromNetwork: false), .agent, plane) == .ask)
        #expect(tier(.runSandboxed(command: "curl x", network: true), .user, plane) == .deny)
        #expect(tier(.gitPush(remote: "origin", branch: "main", force: false), .user, plane) == .askWithBiometrics)
    }

    @Test func projectPolicyOnlyTightens() throws {
        let json = #"{"deny":["installPackage"],"minimumTier":{"writeTracked":"askWithBiometrics","delete":"auto","gitPush":"auto"},"networkDeny":["Tracker.example"]}"#
        let project = try JSONDecoder().decode(ProjectPolicy.self, from: Data(json.utf8))
        let context = PolicyContext(allowedDomains: ["tracker.example"], project: project)
        #expect(tier(.installPackage(name: "x", fromNetwork: false), .agent, context) == .deny)
        #expect(tier(.writeTracked(path: "a"), .agent, context) == .askWithBiometrics)
        // "auto" in the repo can't loosen anything.
        #expect(tier(.delete(path: "a"), .agent, context) == .askWithBiometrics)
        #expect(tier(.gitPush(remote: "o", branch: "m", force: false), .agent, context) == .askWithBiometrics)
        // A repo deny beats your allowlist.
        #expect(tier(.network(domain: "tracker.example"), .agent, context) == .deny)
        // It doesn't apply to you.
        #expect(tier(.installPackage(name: "x", fromNetwork: false), .user, context) == .auto)
    }

    @Test func malformedProjectPolicyFailsClosed() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "policy-\(UUID())")
        try FileManager.default.createDirectory(at: root.appending(path: ".omnie"), withIntermediateDirectories: true)
        #expect(ProjectPolicy.load(projectRoot: root) == .none)
        try Data(#"{"minimumTier":{"writeTracked":"whenever"}}"#.utf8).write(to: root.appending(path: ProjectPolicy.relativePath))
        let policy = ProjectPolicy.load(projectRoot: root)
        #expect(policy.isMalformed)
        #expect(tier(.readProject(path: "a"), .agent, PolicyContext(project: policy)) == .ask)
    }
}

struct AuditLogTests {
    let url = FileManager.default.temporaryDirectory.appending(path: "audit-\(UUID()).jsonl")

    @Test func chainsAndReopens() async throws {
        let log = AuditLog(url: url)
        let a = try await log.append(actor: .agent, action: .readProject(path: "a"), tier: .auto, outcome: .allowed, reasons: ["r"])
        let b = try await log.append(actor: .user, action: .gitPush(remote: "o", branch: "m", force: false),
                                     tier: .askWithBiometrics, outcome: .approved, reasons: [])
        #expect(a.prev == AuditLog.genesis && b.prev == a.hash && b.seq == 2)
        // A new instance continues the same chain.
        let reopened = AuditLog(url: url)
        let c = try await reopened.append(actor: .agent, action: .delete(path: "x"), tier: .askWithBiometrics,
                                          outcome: .rejected, reasons: [])
        #expect(c.prev == b.hash && c.seq == 3)
        #expect(await reopened.verify() == .intact(entries: 3))
        #expect(await reopened.entries(last: 2).map(\.seq) == [2, 3])
    }

    @Test func detectsEditsAndDeletions() async throws {
        let log = AuditLog(url: url)
        for i in 1...4 {
            try await log.append(actor: .agent, action: .writeTracked(path: "f\(i)"), tier: .ask, outcome: .approved, reasons: [])
        }
        let original = try String(contentsOf: url, encoding: .utf8)

        // Rewrite history: change the path recorded on line 2.
        // Only the quoted path: hex hashes contain "f2" often enough to make a bare replace flaky.
        #expect(original.components(separatedBy: "\"f2\"").count == 2)
        try original.replacingOccurrences(of: "\"f2\"", with: "\"f9\"").write(to: url, atomically: true, encoding: .utf8)
        #expect(await log.verify() == .broken(atLine: 2))

        // Delete a line.
        var lines = original.split(separator: "\n")
        lines.remove(at: 2)
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        #expect(await log.verify() == .broken(atLine: 3))

        try original.write(to: url, atomically: true, encoding: .utf8)
        #expect(await log.verify() == .intact(entries: 4))
    }
}

struct GateTests {
    final class ScriptedApprover: Approver, @unchecked Sendable {
        var answer: Bool
        var seen: [ApprovalRequest] = []
        init(_ answer: Bool) { self.answer = answer }
        func approve(_ request: ApprovalRequest) async -> Bool { seen.append(request); return answer }
    }

    let url = FileManager.default.temporaryDirectory.appending(path: "gate-\(UUID()).jsonl")

    @Test func autoAllowsWithoutAskingAndAudits() async throws {
        let approver = ScriptedApprover(false)
        let gate = Gate(audit: AuditLog(url: url), approver: approver)
        let auth = await gate.authorize(.readProject(path: "a"), by: .agent, context: PolicyContext())
        #expect(auth.token != nil && approver.seen.isEmpty)
        #expect(await AuditLog(url: url).entries().map(\.outcome) == [.allowed])
    }

    @Test func asksWithTheExactArtifact() async throws {
        let approver = ScriptedApprover(false)
        let gate = Gate(audit: AuditLog(url: url), approver: approver)
        let auth = await gate.authorize(.writeTracked(path: "a.ts"), by: .agent, artifact: "+ line", context: PolicyContext())
        #expect(auth.token == nil)
        #expect(approver.seen.first?.artifact == "+ line" && approver.seen.first?.tier == .ask)
        #expect(await AuditLog(url: url).entries().map(\.outcome) == [.rejected])
    }

    @Test func deniedNeverReachesTheApprover() async throws {
        let approver = ScriptedApprover(true)
        let gate = Gate(audit: AuditLog(url: url), approver: approver)
        let auth = await gate.authorize(.network(domain: "x.example"), by: .agent, context: PolicyContext(planeMode: true))
        #expect(auth.token == nil && approver.seen.isEmpty)
        #expect(await AuditLog(url: url).entries().map(\.outcome) == [.denied])
    }

    @Test func tokensAreScopedSingleUseAndExpire() async throws {
        let gate = Gate(audit: AuditLog(url: url), approver: ScriptedApprover(true), tokenLifetime: 60)
        let push = Action.gitPush(remote: "origin", branch: "main", force: false)
        let token = try #require(await gate.authorize(push, by: .user, context: PolicyContext()).token)
        #expect(await !gate.redeem(token, for: .gitPush(remote: "origin", branch: "main", force: true)))
        #expect(await !gate.redeem(token, for: push, now: .now.addingTimeInterval(61)))
        #expect(await gate.redeem(token, for: push))
        #expect(await !gate.redeem(token, for: push))

        // A token from another session (another key) doesn't verify.
        let other = Gate(audit: AuditLog(url: url), approver: ScriptedApprover(true))
        let foreign = try #require(await other.authorize(push, by: .user, context: PolicyContext()).token)
        #expect(await !gate.redeem(foreign, for: push))
    }
}
