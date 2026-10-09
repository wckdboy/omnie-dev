// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

import DesignKit
import SwiftUI

/// One terminal command's cost, for the profiler (PLAN.md §11.2).
struct RunRecord: Identifiable, Equatable {
    let id = UUID()
    let command: String
    let date: Date
    let ms: Int
    var fuel: Int64?
    var memory: Int?
    let ok: Bool
}

/// The profiler (PLAN.md §11.2): what each command cost this session, the latest run against the
/// one before (wall clock, and fuel and memory for WASI programs). Preview `performance.measure`s
/// are in the preview's DevTools; Stage frame times in its HUD.
struct RunsTool: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var palette

    var body: some View {
        let groups = Dictionary(grouping: model.runLog, by: \.command)
        let commands = groups.keys.sorted { (groups[$0]!.last!.date) > (groups[$1]!.last!.date) }
        VStack(alignment: .leading, spacing: 8) {
            if commands.isEmpty {
                Text("Nothing run yet. Commands you run in the terminal are timed here; run one twice to compare.")
                    .font(.caption).foregroundStyle(palette.text.secondary.color)
            }
            List(commands, id: \.self) { command in
                let runs = groups[command]!
                let last = runs.last!, previous = runs.dropLast().last
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Image(systemName: last.ok ? "checkmark.circle" : "xmark.circle")
                            .foregroundStyle(last.ok ? palette.status.ok.color : palette.status.error.color)
                        Text(command).font(.system(.footnote, design: .monospaced)).lineLimit(1)
                        Spacer()
                        Text("×\(runs.count)").font(.caption2).foregroundStyle(palette.text.secondary.color)
                    }
                    HStack(spacing: 14) {
                        metric("time", "\(last.ms) ms", previous.map { change(Double(last.ms), Double($0.ms)) })
                        if let fuel = last.fuel { metric("fuel", fuel.formatted(), previous?.fuel.map { change(Double(fuel), Double($0)) }) }
                        if let memory = last.memory {
                            metric("memory", ByteCountFormatter.string(fromByteCount: Int64(memory), countStyle: .memory),
                                   previous?.memory.map { change(Double(memory), Double($0)) })
                        }
                    }
                    if runs.count > 2 {
                        // The last ten times, as a tiny bar chart.
                        let recent = runs.suffix(10).map(\.ms), top = max(1, recent.max() ?? 1)
                        HStack(alignment: .bottom, spacing: 2) {
                            ForEach(Array(recent.enumerated()), id: \.offset) { _, ms in
                                Rectangle().fill(palette.accent.ion.color.opacity(0.7)).frame(width: 6, height: max(2, 22 * CGFloat(ms) / CGFloat(top)))
                            }
                        }
                        .frame(height: 22)
                        .accessibilityLabel("Last \(recent.count) times: " + recent.map { "\($0) ms" }.joined(separator: ", "))
                    }
                }
                .listRowBackground(Color.clear)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            if !commands.isEmpty {
                Button("Clear") { model.runLog.removeAll() }.font(.caption)
            }
        }
        .padding(12)
    }

    /// "+12%" (slower is red) or "−8%".
    private func change(_ now: Double, _ before: Double) -> Double { before > 0 ? (now - before) / before * 100 : 0 }

    private func metric(_ label: String, _ value: String, _ delta: Double?) -> some View {
        HStack(spacing: 4) {
            Text(label).foregroundStyle(palette.text.secondary.color)
            Text(value).monospacedDigit()
            if let delta, abs(delta) >= 1 {
                Text(String(format: "%@%.0f%%", delta > 0 ? "+" : "−", abs(delta)))
                    .foregroundStyle(delta > 0 ? palette.status.error.color : palette.status.ok.color)
            }
        }
        .font(.caption)
    }
}
