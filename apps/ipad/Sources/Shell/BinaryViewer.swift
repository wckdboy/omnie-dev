// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

import DesignKit
import SwiftUI
import ToolsKit

/// Files the editor can't show (PLAN.md §11.2, §11.4): a WebAssembly summary for .wasm, and a hex
/// view for any binary.
struct BinaryViewer: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss
    @Environment(\.palette) private var palette
    @State private var data = Data()
    @State private var rows = 256

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file))
                        .font(.caption).foregroundStyle(palette.text.secondary.color)
                    if url.pathExtension.lowercased() == "wasm" { wasm }
                    Text("Bytes").font(.footnote.weight(.semibold))
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(HexDump.lines(data, count: rows).enumerated()), id: \.offset) { _, line in
                            Text(line).font(.system(.caption2, design: .monospaced))
                        }
                    }
                    .textSelection(.enabled)
                    if data.count > rows * 16 {
                        Button("Show more (\(ByteCountFormatter.string(fromByteCount: Int64(data.count - rows * 16), countStyle: .file)) left)") { rows += 1024 }
                            .font(.caption)
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle(url.lastPathComponent)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
        }
        .task { data = (try? Data(contentsOf: url, options: .mappedIfSafe)) ?? Data() }
    }

    @ViewBuilder
    private var wasm: some View {
        switch Result(catching: { try WasmInfo(data) }) {
        case .success(let info):
            VStack(alignment: .leading, spacing: 6) {
                Text("WebAssembly").font(.footnote.weight(.semibold))
                Text("\(info.functions) functions, \(info.imports.count) imports, \(info.exports.count) exports"
                     + (info.memory.map { ", memory \($0.min)\($0.max.map { "–\($0)" } ?? "+") pages of 64 KB" } ?? "")
                     + (info.dataSegments > 0 ? ", \(info.dataSegments) data segments" : ""))
                    .font(.caption)
                let largest = max(1, info.sections.map(\.size).max() ?? 1)
                ForEach(info.sections) { section in
                    HStack(spacing: 8) {
                        Text(section.name).font(.system(.caption2, design: .monospaced)).frame(width: 150, alignment: .leading)
                        GeometryReader { geo in
                            Rectangle().fill(palette.accent.ion.color.opacity(0.6))
                                .frame(width: max(2, geo.size.width * CGFloat(section.size) / CGFloat(largest)))
                        }
                        .frame(height: 8)
                        Text(ByteCountFormatter.string(fromByteCount: Int64(section.size), countStyle: .file))
                            .font(.caption2).foregroundStyle(palette.text.secondary.color).frame(width: 70, alignment: .trailing)
                    }
                }
                if !info.imports.isEmpty {
                    Text("Imports").font(.caption.weight(.semibold)).padding(.top, 4)
                    ForEach(info.imports, id: \.self) { e in Text("\(e.module).\(e.name)  \(e.kind)").font(.system(.caption2, design: .monospaced)) }
                }
                if !info.exports.isEmpty {
                    Text("Exports").font(.caption.weight(.semibold)).padding(.top, 4)
                    ForEach(info.exports, id: \.self) { e in Text("\(e.name)  \(e.kind)").font(.system(.caption2, design: .monospaced)) }
                }
            }
        case .failure:
            Text("Not a valid WebAssembly module.").font(.caption).foregroundStyle(palette.status.warn.color)
        }
    }
}
