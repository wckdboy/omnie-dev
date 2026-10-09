// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

import LocalAuthentication
import PolicyKit
import SwiftUI

/// The app's side of PolicyKit: one Gate and one audit log per process, approvals shown on top of
/// whatever is on screen, and the context (project rules, plane mode) for each decision.
@MainActor
@Observable
final class PolicyModel {
    let audit = AuditLog(url: AppPaths.support.appending(path: "audit.jsonl"))
    @ObservationIgnored private var gate: Gate?
    /// The open project, whose `.omnie/policy.json` tightens agent actions.
    @ObservationIgnored var projectRoot: URL?
    /// Deny-all networking, local models only (PLAN.md §12). Remembered across launches.
    var planeMode = UserDefaults.standard.bool(forKey: "policy.planeMode") {
        didSet { UserDefaults.standard.set(planeMode, forKey: "policy.planeMode") }
    }
    /// Why the last authorization was refused, for a banner.
    private(set) var lastRefusal: String?

    init() {
        gate = Gate(audit: audit, approver: AppApprover(present: { request in
            await ApprovalPresenter.present(request)
        }))
    }

    var context: PolicyContext {
        PolicyContext(planeMode: planeMode, approvedProviders: projectRoot.map(approvedProviders(for:)) ?? [],
                      project: projectRoot.map { ProjectPolicy.load(projectRoot: $0) } ?? .none)
    }

    /// Providers you've agreed to send this project's code to (PLAN.md §12: the first time is
    /// Ask + Face ID). Kept per project on this device.
    func approvedProviders(for root: URL) -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: "policy.providers." + root.standardizedFileURL.path) ?? [])
    }

    func approve(_ provider: String, for root: URL) {
        var set = approvedProviders(for: root)
        set.insert(provider)
        UserDefaults.standard.set(Array(set).sorted(), forKey: "policy.providers." + root.standardizedFileURL.path)
    }

    /// Decides, asks if needed, audits, and returns whether `action` may happen now.
    /// The token is redeemed here: callers act immediately after a true. `later`: the action is
    /// queued to happen once the network is back (a push in plane mode), so plane mode doesn't
    /// refuse it now; it's still asked for and audited.
    func authorize(_ action: Action, by actor: Actor = .user, artifact: String? = nil, later: Bool = false) async -> Bool {
        guard let gate else { return false }
        var context = context
        if later { context.planeMode = false }
        switch await gate.authorize(action, by: actor, artifact: artifact, context: context) {
        case .granted(let token):
            lastRefusal = nil
            return await gate.redeem(token, for: action)
        case .refused(let reason):
            lastRefusal = reason
            return false
        }
    }
}

struct AppApprover: Approver {
    let present: @Sendable @MainActor (ApprovalRequest) async -> Bool

    func approve(_ request: ApprovalRequest) async -> Bool {
        #if DEBUG
        // Unattended device runs (-OmniePlaneTest) can't answer Face ID. Debug builds only; the
        // decision is still audited.
        if ProcessInfo.processInfo.arguments.contains("-OmnieTestApprove") { return true }
        #endif
        // Your own outward action: pressing the button was the ask, so only Face ID remains.
        if request.actor == .user && request.tier == .askWithBiometrics {
            return await Biometrics.confirm(request.action.summary)
        }
        guard await present(request) else { return false }
        if request.tier == .askWithBiometrics {
            return await Biometrics.confirm(request.action.summary)
        }
        return true
    }
}

enum Biometrics {
    /// Face ID (or the passcode). Devices with no passcode can't authenticate anyone, so it passes there.
    static func confirm(_ reason: String) async -> Bool {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            return (error as? LAError)?.code == .passcodeNotSet
        }
        return (try? await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)) ?? false
    }
}

/// Presents approval prompts from UIKit, above any sheet that's already up (SwiftUI can't present
/// a second sheet from a view that's presenting one).
@MainActor
enum ApprovalPresenter {
    static func present(_ request: ApprovalRequest) async -> Bool {
        guard let top = topViewController() else { return false }
        return await withCheckedContinuation { continuation in
            var resumed = false
            let host = UIHostingController(rootView: AnyView(EmptyView()))
            let finish: (Bool) -> Void = { answer in
                guard !resumed else { return }
                resumed = true
                host.dismiss(animated: true)
                continuation.resume(returning: answer)
            }
            host.rootView = AnyView(ApprovalSheet(request: request, finish: finish))
            host.isModalInPresentation = true
            if let sheet = host.sheetPresentationController {
                sheet.detents = [.medium(), .large()]
                sheet.prefersGrabberVisible = true
            }
            top.present(host, animated: true)
        }
    }

    static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let window = scenes.filter { $0.activationState == .foregroundActive }.flatMap(\.windows).first(where: \.isKeyWindow)
            ?? scenes.flatMap(\.windows).first(where: \.isKeyWindow)
        var top = window?.rootViewController
        while let presented = top?.presentedViewController, !presented.isBeingDismissed { top = presented }
        return top
    }
}

/// Shows exactly what will happen and why it needs you (PLAN.md §12: "Approvals show the exact
/// artifact, never the model's summary of it").
struct ApprovalSheet: View {
    let request: ApprovalRequest
    let finish: (Bool) -> Void

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                Label(request.actor == .agent ? "The agent wants to" : "You're about to",
                      systemImage: request.actor == .agent ? "text.bubble" : "person")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text(request.action.summary)
                    .font(.title3.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                Text(request.reasons.joined(separator: " · "))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if let artifact = request.artifact {
                    ScrollView {
                        Text(artifact)
                            .font(.system(.caption, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                            .padding(10)
                    }
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                }
                Spacer(minLength: 0)
            }
            .padding()
            .navigationTitle("Approve")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Don't allow") { finish(false) }
                        .keyboardShortcut(.cancelAction)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(request.tier == .askWithBiometrics ? "Allow with Face ID" : "Allow") { finish(true) }
                }
            }
        }
    }
}

/// The audit log as its own sheet (the "Show audit log" command).
struct AuditLogView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            AuditLogList()
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}

/// Every policy decision, newest first, and whether the hash chain checks out.
struct AuditLogList: View {
    @Environment(AppModel.self) private var model
    @State private var entries: [AuditEntry] = []
    @State private var verification: AuditLog.Verification?

    var body: some View {
            List {
                Section {
                    switch verification {
                    case .intact(let n):
                        Label("Chain intact: \(n) entr\(n == 1 ? "y" : "ies") verified", systemImage: "checkmark.seal")
                    case .broken(let line):
                        Label("Chain broken at entry \(line): the log was edited outside Omnie-dev", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    case nil:
                        ProgressView()
                    }
                } footer: {
                    Text("Each entry includes the hash of the one before it, so a past entry can't be changed or removed unnoticed.")
                }
                Section("Decisions") {
                    if entries.isEmpty { Text("Nothing yet.").foregroundStyle(.secondary) }
                    ForEach(entries.reversed()) { entry in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.action.summary)
                            Text("\(entry.actor == .agent ? "Agent" : "You") · \(Self.label(entry.outcome)) · \(entry.date.formatted(date: .abbreviated, time: .standard))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
            .navigationTitle("Audit log")
            .task {
                entries = await model.policy.audit.entries(last: 500)
                verification = await model.policy.audit.verify()
            }
    }

    static func label(_ outcome: AuditEntry.Outcome) -> String {
        switch outcome {
        case .allowed: "Allowed by policy"
        case .approved: "Approved"
        case .rejected: "Declined"
        case .denied: "Blocked by policy"
        }
    }
}
