// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

import DesignKit
import GitKit
import HostKit
import SecretsKit
import SwiftUI

/// The forge behind the project's remote (PLAN.md §9.11): its open pull requests (merge requests on
/// GitLab) with their checks, and a new one from the current branch, pushed first through Sync's
/// approval. Optional by design: without a known forge or a token, git itself works the same.
struct PullRequestsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var palette
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    @State private var remote: RemoteInfo?
    @State private var kind: ForgeKind?
    @State private var user: String?
    @State private var pulls: [PullRequest] = []
    @State private var checks: [Int: CheckState] = [:]
    @State private var loading = false
    @State private var problem: String?
    // New pull request.
    @State private var branch: String?
    @State private var base = ""
    @State private var bases: [String] = []
    @State private var title = ""
    @State private var bodyText = ""
    @State private var commits: [CommitInfo] = []
    @State private var isDraft = false
    @State private var opening = false
    @State private var opened: PullRequest?

    private var forgeRepo: ForgeRepo? { remote.flatMap { ForgeRepo(remoteURL: $0.url, kind: kind) } }
    /// A remote that's a path (or `file://`), with no host to ask.
    private var isLocal: Bool { remote.map { RemoteInfo.host(of: $0.url) == nil || $0.url.hasPrefix("file:") } ?? false }
    private var requestName: String { (kind ?? .forgejo).requestName }

    var body: some View {
        @Bindable var git = model.workspace.git
        NavigationStack {
            Form {
                forgeSection
                if forgeRepo != nil {
                    if let problem {
                        Section { Text(problem).foregroundStyle(palette.status.error.color).accessibilityIdentifier("pr-problem") }
                    }
                    openSection
                    newSection
                }
            }
            .navigationTitle(kind == .gitlab ? "Merge Requests" : "Pull Requests")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button("Refresh", systemImage: "arrow.clockwise") { Task { await load() } }.disabled(loading || forgeRepo == nil)
                }
            }
            // Over this sheet, so a missing or refused token is asked for here.
            .sheet(item: $git.pendingTokenHost) { TokenSheet(request: $0) }
        }
        .task { await start() }
    }

    // MARK: Sections

    private var forgeSection: some View {
        Section {
            if let remote {
                VStack(alignment: .leading, spacing: 2) {
                    Text(remote.label).font(.subheadline.weight(.semibold))
                    if let forgeRepo {
                        Text(forgeRepo.fullName).font(.caption.monospaced()).foregroundStyle(palette.text.tertiary.color)
                    }
                }
                if isLocal {
                    Text("\(remote.name) is a folder on this device, not a forge, so it has no pull requests.")
                        .foregroundStyle(palette.text.secondary.color)
                } else {
                    Picker("Forge", selection: Binding(get: { kind }, set: { setKind($0) })) {
                        Text("Not a forge I know").tag(ForgeKind?.none)
                        ForEach(ForgeKind.allCases) { Text($0.displayName).tag(Optional($0)) }
                    }
                    .accessibilityIdentifier("pr-forge")
                }
                if let user { LabeledContent("Signed in as", value: user) }
            } else {
                Text("No remote yet. Add one in Remotes… to open pull requests.").foregroundStyle(palette.text.secondary.color)
            }
        } footer: {
            if remote != nil, forgeRepo == nil, !isLocal {
                Text("Choose the forge this host runs (Forgejo, Gitea, GitLab or GitHub) to see its \(requestName)s. Git works the same without it.")
            }
        }
    }

    private var openSection: some View {
        Section("Open") {
            if loading && pulls.isEmpty {
                ProgressView().frame(maxWidth: .infinity)
            } else if pulls.isEmpty && problem == nil {
                Text("No open \(requestName)s.").foregroundStyle(palette.text.secondary.color)
            }
            ForEach(pulls) { pull in
                Button {
                    if let url = pull.url { openURL(url) }
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        CheckBadge(state: checks[pull.number] ?? .none)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("#\(pull.number) \(pull.title)").font(.subheadline.weight(.medium)).foregroundStyle(palette.text.primary.color)
                            Text("\(pull.head) → \(pull.base)\(pull.author.isEmpty ? "" : " · \(pull.author)")\(pull.isDraft ? " · draft" : "")")
                                .font(.caption).foregroundStyle(palette.text.secondary.color)
                        }
                        Spacer()
                        if pull.head == branch { Text("this branch").font(.caption2).foregroundStyle(palette.accent.ion.color) }
                    }
                }
                .accessibilityIdentifier("pr-row-\(pull.number)")
            }
        }
    }

    @ViewBuilder private var newSection: some View {
        let existing = pulls.first { $0.head == branch && $0.base == base }
        Section {
            if let branch {
                LabeledContent("From", value: branch)
                Picker("Into", selection: $base) {
                    ForEach(bases, id: \.self) { Text($0).tag($0) }
                }
                .accessibilityIdentifier("pr-base")
                TextField("Title", text: $title).accessibilityIdentifier("pr-title")
                TextField("Description", text: $bodyText, axis: .vertical).lineLimit(3...8).accessibilityIdentifier("pr-body")
                Toggle("Draft", isOn: $isDraft)
                if let opened {
                    Button("Opened #\(opened.number): \(opened.title)", systemImage: "checkmark.circle") {
                        if let url = opened.url { openURL(url) }
                    }
                    .accessibilityIdentifier("pr-opened")
                } else if let existing {
                    Text("#\(existing.number) is already open for \(branch) → \(base).").foregroundStyle(palette.text.secondary.color)
                } else {
                    Button {
                        Task { await open() }
                    } label: {
                        HStack {
                            Text("Push and open \(requestName)")
                            if opening { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(opening || model.networkUnavailable || title.trimmingCharacters(in: .whitespaces).isEmpty || base.isEmpty || base == branch)
                    .accessibilityIdentifier("pr-open")
                }
            } else {
                Text("Switch to a branch to open a \(requestName).").foregroundStyle(palette.text.secondary.color)
            }
        } header: {
            Text("New \(requestName)")
        } footer: {
            if branch != nil, opened == nil {
                Text(commits.isEmpty
                     ? "\(branch ?? "") has no commits that \(base) doesn't have yet."
                     : "\(commits.count) commit\(commits.count == 1 ? "" : "s"). Sync pushes the branch first, with the usual approval.")
            }
        }
    }

    // MARK: Work

    private func start() async {
        let git = model.workspace.git
        await git.refreshRemotes()
        guard let repo = git.repo else { return }
        let upstream = (try? await repo.upstreamName())?.split(separator: "/").first.map(String.init)
        remote = git.remotes.first { $0.name == upstream } ?? git.remotes.first { $0.name == "origin" && !$0.isReadOnly }
            ?? git.remotes.first { !$0.isReadOnly }
        if let remote, let host = RemoteInfo.host(of: remote.url) {
            kind = UserDefaults.standard.string(forKey: Self.kindKey(host)).flatMap(ForgeKind.init(rawValue:)) ?? ForgeKind.guess(host: host)
        }
        branch = try? await repo.head().branch
        bases = git.branches.map(\.name).filter { $0 != branch && !$0.hasPrefix(Repository.agentBranchPrefix) }
        base = bases.first { $0 == "main" } ?? bases.first { $0 == "master" } ?? bases.first ?? ""
        await prefill()
        await load()
    }

    static func kindKey(_ host: String) -> String { "forge.kind.\(host)" }

    private func setKind(_ new: ForgeKind?) {
        kind = new
        if let remote, let host = RemoteInfo.host(of: remote.url) { UserDefaults.standard.set(new?.rawValue, forKey: Self.kindKey(host)) }
        problem = nil
        pulls = []
        Task { await load() }
    }

    /// Title and description from the branch's commits: one commit's message, or a list of them.
    private func prefill() async {
        guard let repo = model.workspace.git.repo, let remote, !base.isEmpty else { return }
        commits = (try? await repo.log(notIn: ["refs/heads/\(base)", "refs/remotes/\(remote.name)/\(base)"], limit: 50)) ?? []
        guard title.isEmpty, opened == nil else { return }
        if commits.count == 1, let only = commits.first {
            title = only.summary
            let lines = only.message.split(separator: "\n", omittingEmptySubsequences: false).dropFirst()
            bodyText = lines.filter { !$0.hasPrefix("Signed-off-by:") && !$0.hasPrefix("Co-Authored-By:") }
                .joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            title = (branch ?? "").replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ")
                .split(separator: "/").last.map { $0.prefix(1).uppercased() + $0.dropFirst() } ?? ""
            bodyText = commits.reversed().map { "- \($0.summary)" }.joined(separator: "\n")
        }
    }

    /// The forge client, or nil after asking for the host's token (and coming back here with it).
    private func forge() -> (any Forge)? {
        guard let forgeRepo else { return nil }
        guard let token = HTTPSToken.load(host: forgeRepo.host)?.token else {
            model.workspace.git.askForToken(host: forgeRepo.host, rejected: false) { await load() }
            return nil
        }
        return forgeRepo.forge(token: token)
    }

    private func load() async {
        // Plane mode and no network block forges like every other request (PLAN.md §12).
        if model.networkUnavailable {
            problem = model.policy.planeMode
                ? "Plane mode is on. \(kind == .gitlab ? "Merge" : "Pull") requests load when it's off."
                : "No network. \(kind == .gitlab ? "Merge" : "Pull") requests load when you're back online."
            return
        }
        guard let forge = forge() else { return }
        loading = true
        defer { loading = false }
        do {
            if user == nil { user = try await forge.currentUser() }
            if bases.isEmpty || !bases.contains(base), let fallback = try? await forge.defaultBranch() {
                if !bases.contains(fallback) { bases.append(fallback) }
                base = fallback
            }
            pulls = try await forge.pullRequests(state: .open)
            problem = nil
            // Checks per head commit, side by side.
            await withTaskGroup(of: (Int, CheckState).self) { group in
                for pull in pulls where !pull.headSHA.isEmpty {
                    group.addTask { (pull.number, (try? await forge.checks(sha: pull.headSHA)) ?? .none) }
                }
                for await (number, state) in group { checks[number] = state }
            }
        } catch {
            report(error) { await load() }
        }
    }

    private func open() async {
        guard let branch, !model.networkUnavailable, forge() != nil else { return }
        let git = model.workspace.git
        opening = true
        defer { opening = false }
        // Push the branch the way Sync does (approval, LFS, upstream). It reports its own errors.
        git.error = nil
        await git.sync(isOffline: model.networkUnavailable)
        if model.networkUnavailable {
            problem = "Opening a \(requestName) needs the network. The push is queued; open it when you're back online."
            return
        }
        guard git.error == nil, let forge = forge() else { return }
        do {
            let pull = try await forge.create(PullRequestDraft(title: title.trimmingCharacters(in: .whitespaces), body: bodyText,
                                                               head: branch, base: base, isDraft: isDraft))
            opened = pull
            problem = nil
            await load()
        } catch {
            report(error) { await open() }
        }
    }

    private func report(_ error: Error, retry: @escaping () async -> Void) {
        if case ForgeError.unauthorized(let host) = error {
            model.workspace.git.askForToken(host: host, rejected: true, retry: retry)
            return
        }
        problem = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}

/// CI on a pull request's head: a dot in the status colors, said aloud.
struct CheckBadge: View {
    let state: CheckState
    @Environment(\.palette) private var palette

    var body: some View {
        Image(systemName: symbol)
            .foregroundStyle(color)
            .imageScale(.small)
            .accessibilityLabel(label)
    }

    private var symbol: String {
        switch state {
        case .success: "checkmark.circle.fill"
        case .failure: "xmark.circle.fill"
        case .pending: "clock.fill"
        case .none: "circle.dashed"
        }
    }

    private var color: Color {
        switch state {
        case .success: palette.status.ok.color
        case .failure: palette.status.error.color
        case .pending: palette.status.warn.color
        case .none: palette.text.tertiary.color
        }
    }

    private var label: String {
        switch state {
        case .success: "Checks passed"
        case .failure: "Checks failed"
        case .pending: "Checks running"
        case .none: "No checks"
        }
    }
}
