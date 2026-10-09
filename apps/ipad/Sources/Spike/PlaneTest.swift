// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

#if DEBUG
import Foundation
import GitKit
import RunKit
import WebKit

/// `-OmniePlaneTest` (with `-OmnieTestApprove`): the P3 exit test (PLAN.md §22), unattended on
/// the device. A Vite-style three.js project is cloned and prepared online, then in plane mode
/// the local agent fixes it, its tests and the type check pass, the preview and the Stage run, a
/// commit is made and the push queues; with plane mode off, the queued push lands.
/// The "remote" is a bare repo in Documents (`plane-remote.git`, or the name after the flag), so
/// nothing leaves the device.
@MainActor
enum PlaneTest {
    static func run(_ app: AppModel) async {
        var failures = 0
        let start = Date()
        func step(_ name: String, _ ok: Bool, _ detail: String) {
            if !ok { failures += 1 }
            print("[plane] \(ok ? "✓" : "✗") \(name) (\(Int(Date().timeIntervalSince(start))) s): \(detail)")
        }
        let args = ProcessInfo.processInfo.arguments
        let name = args.firstIndex(of: "-OmniePlaneTest").flatMap { args.indices.contains($0 + 1) && !args[$0 + 1].hasPrefix("-") ? args[$0 + 1] : nil } ?? "plane-remote.git"
        let remote = URL.documentsDirectory.appending(path: name)
        guard FileManager.default.fileExists(atPath: remote.path) else { print("[plane] ✗ no Documents/\(name)"); return }
        let git = app.workspace.git

        // Online: clone and prepare.
        app.policy.planeMode = false
        guard let folder = await git.clone(remote.absoluteString) else { step("clone", false, git.error ?? "failed"); return }
        app.workspace.open(folder: folder)
        try? await Task.sleep(for: .seconds(1))
        step("clone", git.repo != nil, folder.lastPathComponent)
        if await git.author() == nil { git.fallbackName = "Plane Test"; git.fallbackEmail = "plane-test@omnie.invalid" }
        do {
            let added = try await Packages.cache.installProject(folder)
            step("prepare offline (npm)", true, added.isEmpty ? "already cached" : added.map { "\($0.name)@\($0.version)" }.joined(separator: ", "))
        } catch { step("prepare offline (npm)", false, error.localizedDescription) }

        // Plane mode from here.
        app.policy.planeMode = true
        let before = await (try? JSRunner(root: folder))?.runAllTests()
        step("tests fail before the fix", before?.passed == false, "\(before?.tests.filter { !$0.passed }.count ?? -1) failing")

        let goal = "The tests in tests/orbit.test.ts fail. Fix orbitPosition in src/orbit.ts so they pass."
        await app.agent.start(goal)
        let phase = app.agent.current?.phase.rawValue ?? "none"
        step("agent (local model, plane mode)", phase == "review", "phase \(phase), \(app.agent.changes.count) changed file(s)\(app.agent.error.map { ", " + $0 } ?? "")")
        if phase == "review" {
            await app.agent.accept()
            step("agent changes merged", app.agent.current?.phase.rawValue == "merged", app.agent.error ?? "merged")
        }

        let tests = await (try? JSRunner(root: folder))?.runAllTests()
        step("tests", tests?.passed == true, tests.map { "\($0.tests.filter(\.passed).count)/\($0.tests.count) passed" } ?? "didn't run")
        let types = await (try? JSRunner(root: folder))?.typeCheck()
        step("type check", types?.failure == nil && types?.errors == 0, types?.report.replacingOccurrences(of: "\n", with: " | ") ?? "didn't run")

        // The preview: index.html with main.ts, three from the offline cache.
        var console: [(String, String)] = []
        if let config = try? Preview.configuration(root: folder, onConsole: { console.append(($0, $1)) }), let page = Preview.entry(in: folder) {
            let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 400, height: 300), configuration: config)
            webView.load(URLRequest(url: Preview.url(for: page)))
            for _ in 0..<100 where !console.contains(where: { $0.1.hasPrefix("scene ready") || $0.0 == "error" }) { try? await Task.sleep(for: .milliseconds(100)) }
            let errors = console.filter { $0.0 == "error" }.map(\.1)
            step("preview", console.contains { $0.1.hasPrefix("scene ready") } && errors.isEmpty, errors.first ?? (console.first?.1 ?? "no output"))
        } else { step("preview", false, "no index.html") }

        // The Stage, with the project's scene module.
        app.show(.stage)
        for _ in 0..<150 where (StageSnapshot.shared.stats?.fps ?? 0) == 0 || StageSnapshot.shared.nodes.count < 2 { try? await Task.sleep(for: .milliseconds(100)) }
        let snapshot = StageSnapshot.shared
        step("stage", snapshot.nodes.contains { $0.name == "Moon" } && snapshot.problems.isEmpty,
             "\(snapshot.file ?? "none"), \(snapshot.nodes.count) objects, \(snapshot.stats?.fps ?? 0) fps")

        // Your edit, a commit, and a push that queues.
        let readme = folder.appending(path: "README.md")
        try? ((try? String(contentsOf: readme, encoding: .utf8)) ?? "").appending("\nChecked in plane mode on the iPad.\n").write(to: readme, atomically: true, encoding: .utf8)
        let committed = await git.commit(message: "Note the plane test in the README", author: await git.author()!)
        let headSummary = (try? await git.repo?.log(limit: 1).first?.summary) ?? nil
        step("commit", committed, git.error ?? headSummary ?? "?")
        await git.sync(isOffline: app.networkUnavailable)
        step("push queued in plane mode", git.queuedPushes.count == 1, git.syncMessage ?? git.error ?? "nothing queued")

        // Back online: the queue sends itself.
        app.policy.planeMode = false
        await git.flushQueue()
        let local = try? await git.repo?.head().commit
        let remoteRepo = try? Repository.open(at: remote)
        let remoteHead = try? await remoteRepo?.head().commit
        step("queued push sent when back online", git.queuedPushes.isEmpty && local != nil && local == remoteHead,
             "remote main \(remoteHead?.short ?? "?"), local \(local?.short ?? "?")")
        let log = (try? await git.repo?.log(limit: 4)) ?? []
        for c in log { print("[plane]   \(c.id.short) \(c.summary)") }
        print("[plane] \(failures == 0 ? "PASS" : "FAIL: \(failures) step(s)") in \(Int(Date().timeIntervalSince(start))) s")
    }
}
#endif
