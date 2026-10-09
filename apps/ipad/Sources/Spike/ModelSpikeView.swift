// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

import SwiftUI

struct ModelSpikeView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var lines: [String] = []
    @State private var running = true

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(lines.joined(separator: "\n"))
                    .font(.system(.footnote, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding()
            }
            .navigationTitle("Model spike (P0) · \(EditorSpike.buildKind)")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    if running { ProgressView() } else { Button("Close") { dismiss() } }
                }
            }
        }
        .task {
            let spike = ModelSpike()
            spike.log = { line in
                print("[model]", line)
                lines.append(line)
            }
            await spike.run()
            running = false
        }
    }
}
