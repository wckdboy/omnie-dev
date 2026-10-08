// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

import DesignKit
import SwiftUI
import UIKit

/// Runs the editor spike full-screen: the editor under test fills the view, the log sits on top.
struct EditorSpikeView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.palette) private var palette
    @State private var lines: [String] = []
    @State private var running = false
    @State private var host = UIView()

    var body: some View {
        ZStack(alignment: .bottom) {
            HostView(view: host).ignoresSafeArea()
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Editor spike (PLAN §5.1.5), tests 1–4 · \(EditorSpike.buildKind) build")
                        .font(.system(size: 13, weight: .semibold))
                    Spacer()
                    if running { ProgressView() }
                    Button("Close") { dismiss() }.disabled(running)
                }
                if EditorSpike.buildKind == "debug" {
                    Text("Debug build: numbers check the harness only. Decide on a release build on the iPad.")
                        .font(.system(size: 12))
                        .foregroundStyle(palette.status.warn.color)
                }
                ScrollView {
                    Text(lines.joined(separator: "\n"))
                        .font(.system(size: 12, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(maxHeight: 260)
            }
            .padding(12)
            .background(.ultraThinMaterial)
        }
        .task {
            running = true
            let spike = EditorSpike(host: host)
            spike.log = { line in
                print("[spike]", line)
                lines.append(line)
            }
            _ = await spike.runAll()
            lines.append("Done. Results are in Files › On My iPad › Omnie-dev.")
            running = false
        }
    }

    private struct HostView: UIViewRepresentable {
        let view: UIView
        func makeUIView(context: Context) -> UIView { view }
        func updateUIView(_ uiView: UIView, context: Context) {}
    }
}
