// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

#if DEBUG
import DesignKit
import Foundation
import os

/// The memory soak (PLAN.md §21, the v1.0 bar): a 7B agent turn with the preview, Stage and the
/// test runner all working at once, round after round. Logs the footprint jetsam counts and what
/// the system says is left, so growth between rounds (a leak) or a kill (jetsam) shows.
/// `-OmnieSoak <rounds>` with a project open (the sample).
@MainActor
enum SoakTest {
    static let goals = [
        "add a one-line comment above orbitPosition saying the angle is in radians",
        "add a JSDoc @param line for radius to orbitPosition",
        "rename the parameter radius to distance in orbitPosition and its uses",
    ]

    static func run(_ model: AppModel, rounds: Int) async {
        // Preview and Stage in groups of their own so both render, the terminal below.
        typealias G = PaneLayout.Group
        model.panes = PaneLayout(left: [G(panels: ["Files"])],
                                 right: [G(panels: ["Preview"]), G(panels: ["Stage"])],
                                 bottom: [G(panels: ["Terminal"])], rightWidth: 460)
        for _ in 0..<200 where !model.launchFolderReady { try? await Task.sleep(for: .milliseconds(100)) }
        // The project's repository, not a stale one from before the folder opened.
        for _ in 0..<100 where model.workspace.git.repo == nil || model.workspace.git.repo?.workdir.lastPathComponent != model.workspace.rootURL?.lastPathComponent {
            try? await Task.sleep(for: .milliseconds(100))
        }
        try? await Task.sleep(for: .seconds(2))
        let start = Date()
        var baseline = EditorSpike.footprintMB()
        print("[soak] start: \(Int(baseline)) MB, \(available()) MB available")
        var afterRounds: [Double] = []
        for round in 1...rounds {
            let goal = goals[(round - 1) % goals.count]
            let roundStart = Date()
            var peak = EditorSpike.footprintMB(), least = available()
            let agent = Task { await model.agent.start(goal) }
            // While the 7B works: tests every 4 s, a file switch every 3 s, samples every second.
            var tick = 0
            while !agent.isCancelled, model.agent.isRunning || tick < 3 {
                try? await Task.sleep(for: .seconds(1))
                tick += 1
                peak = max(peak, EditorSpike.footprintMB())
                least = min(least, available())
                if tick % 4 == 0 { model.terminalRequest = "npm test" }
                if tick % 3 == 0, let root = model.workspace.rootURL {
                    let files = ["src/orbit.ts", "src/scene.ts", "src/planets.stage.ts", "tests/orbit.test.ts"]
                    model.workspace.open(file: root.appending(path: files[(tick / 3) % files.count]), preview: false)
                }
                if tick > 600 { break }
            }
            await agent.value
            let phase = model.agent.current?.phase.rawValue ?? "none: \(model.agent.error ?? "no error")"
            await model.agent.reject()
            try? await Task.sleep(for: .seconds(3))
            let after = EditorSpike.footprintMB()
            afterRounds.append(after)
            print("[soak] round \(round): \(Int(Date().timeIntervalSince(roundStart))) s, agent \(phase), peak \(Int(peak)) MB, least available \(least) MB, after \(Int(after)) MB")
        }
        let growth = (afterRounds.last ?? baseline) - (afterRounds.first ?? baseline)
        print("[soak] done: \(rounds) rounds in \(Int(Date().timeIntervalSince(start))) s; after-round footprint \(afterRounds.map { Int($0) }) MB, growth from round 1 \(Int(growth)) MB")
        baseline = 0
    }

    /// What the system says this process can still allocate before jetsam, in MB.
    static func available() -> Int { Int(os_proc_available_memory() / 1_048_576) }
}
#endif
