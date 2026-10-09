// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

import DesignKit
import SwiftUI
import ToolsKit
import WorkspaceKit

/// Color + design-token picker (PLAN.md §11.2): a WCAG contrast checker, the project's
/// tokens.json as editable swatches with contrast problems flagged, and swatches from an image.
struct ColorsTool: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var palette
    @State private var mode = 0
    @State private var foreground = "#E6E8EB"
    @State private var background = "#111316"
    @State private var tokenFile: String?
    @State private var tokenFiles: [String] = []
    @State private var tokensJSON = ""
    @State private var theme = "dark"
    @State private var editing: ColorTools.Token?
    @State private var editHex = ""
    @State private var images: [String] = []
    @State private var image: String?
    @State private var swatches: [ColorTools.RGB] = []
    @State private var note: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Mode", selection: $mode) { Text("Contrast").tag(0); Text("Tokens").tag(1); Text("Image").tag(2) }
                .pickerStyle(.segmented).fixedSize()
            switch mode {
            case 0: contrast
            case 1: tokens
            default: imageSwatches
            }
            if let note { Text(note).font(.caption).foregroundStyle(palette.text.secondary.color) }
            Spacer(minLength: 0)
        }
        .padding(12)
        .task(id: model.workspace.rootURL) {
            #if DEBUG
            let args = ProcessInfo.processInfo.arguments
            if let i = args.firstIndex(of: "-OmnieColorsMode"), args.indices.contains(i + 1), let m = Int(args[i + 1]) { mode = m }
            #endif
            guard let root = model.workspace.rootURL else { return }
            let files = await Task.detached { ProjectSearch.files(in: root) }.value
            tokenFiles = files.filter { ($0 as NSString).lastPathComponent.hasSuffix("tokens.json") }
            images = files.filter { ["png", "jpg", "jpeg", "webp", "heic"].contains(($0 as NSString).pathExtension.lowercased()) }
            if tokenFile == nil, let first = tokenFiles.first { load(first) }
        }
    }

    // MARK: Contrast

    private var contrast: some View {
        let fg = ColorTools.RGB(hex: foreground), bg = ColorTools.RGB(hex: background)
        return VStack(alignment: .leading, spacing: 10) {
            colorRow("Text", $foreground)
            colorRow("Background", $background)
            if let fg, let bg {
                let rating = ColorTools.rate(fg, on: bg)
                VStack(alignment: .leading, spacing: 4) {
                    Text("The quick brown fox").font(.title3)
                    Text("Body text at 15 pt, the size most UI uses.").font(.subheadline)
                }
                .foregroundStyle(Color(hex: foreground))
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(hex: background), in: RoundedRectangle(cornerRadius: Metrics.Radius.sm))
                Text(rating.summary).font(.headline.monospacedDigit())
                HStack(spacing: 12) {
                    badge("AA", rating.aaNormal); badge("AA large", rating.aaLarge); badge("AAA", rating.aaaNormal); badge("AAA large", rating.aaaLarge)
                }
            } else {
                Text("Colors are hex: #RGB, #RRGGBB or #RRGGBBAA.").font(.caption).foregroundStyle(palette.status.warn.color)
            }
        }
    }

    private func colorRow(_ label: String, _ hex: Binding<String>) -> some View {
        HStack {
            Text(label).font(.footnote).frame(width: 90, alignment: .leading)
            ColorPicker(label, selection: Binding(get: { Color(hex: hex.wrappedValue) }, set: { hex.wrappedValue = $0.hexString }), supportsOpacity: true)
                .labelsHidden()
            TextField("#RRGGBB", text: hex)
                .font(.system(.footnote, design: .monospaced))
                .textInputAutocapitalization(.characters).autocorrectionDisabled()
        }
    }

    private func badge(_ title: String, _ pass: Bool) -> some View {
        Label(title, systemImage: pass ? "checkmark.circle.fill" : "xmark.circle")
            .font(.caption)
            .foregroundStyle(pass ? palette.status.ok.color : palette.status.error.color)
    }

    // MARK: Tokens

    @ViewBuilder
    private var tokens: some View {
        if tokenFiles.isEmpty {
            Text("No tokens.json in this project. The format is Omnie Dev's own (themes → group → name → hex); brand/tokens.json in the Omnie Dev repo is an example.")
                .font(.caption).foregroundStyle(palette.text.secondary.color)
        } else {
            let all = ColorTools.tokens(tokensJSON)
            let themes = Array(Set(all.map(\.theme))).sorted()
            HStack {
                Menu(tokenFile ?? "tokens.json") { ForEach(tokenFiles, id: \.self) { f in Button(f) { load(f) } } }.font(.caption)
                Picker("Theme", selection: $theme) { ForEach(themes, id: \.self) { Text($0).tag($0) } }.font(.caption)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    let problems = ColorTools.contrastProblems(all.filter { $0.theme == theme })
                    if !problems.isEmpty {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Below WCAG AA").font(.caption.weight(.semibold)).foregroundStyle(palette.status.warn.color)
                            ForEach(Array(problems.enumerated()), id: \.offset) { _, p in
                                Text("\(p.text.group).\(p.text.name) on \(p.surface.group).\(p.surface.name): \(String(format: "%.2f", p.rating.ratio)):1")
                                    .font(.system(.caption2, design: .monospaced))
                            }
                        }
                    }
                    ForEach(Array(Set(all.filter { $0.theme == theme }.map(\.group))).sorted(), id: \.self) { group in
                        Text(group).font(.caption.weight(.semibold))
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 84), spacing: 8)], alignment: .leading, spacing: 8) {
                            ForEach(all.filter { $0.theme == theme && $0.group == group }) { token in
                                Button { editing = token; editHex = token.hex } label: {
                                    VStack(alignment: .leading, spacing: 2) {
                                        RoundedRectangle(cornerRadius: 6).fill(Color(hex: token.hex)).frame(height: 30)
                                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(palette.surface.hairline.color))
                                        Text(token.name).font(.caption2).lineLimit(1)
                                        Text(token.hex).font(.system(.caption2, design: .monospaced)).foregroundStyle(palette.text.secondary.color)
                                    }
                                }
                                .buttonStyle(.plain)
                                .contextMenu {
                                    Button("Use as text color") { foreground = token.hex; mode = 0 }
                                    Button("Use as background") { background = token.hex; mode = 0 }
                                }
                            }
                        }
                    }
                }
            }
            if let token = editing {
                HStack {
                    Text(token.path).font(.system(.caption2, design: .monospaced)).lineLimit(1)
                    TextField("#RRGGBB", text: $editHex).font(.system(.caption, design: .monospaced)).frame(width: 100)
                        .textInputAutocapitalization(.characters).autocorrectionDisabled()
                    Button("Save") { save(token) }.buttonStyle(.borderedProminent).font(.caption)
                        .disabled(ColorTools.RGB(hex: editHex) == nil)
                    Button("Cancel") { editing = nil }.font(.caption)
                }
            }
        }
    }

    private func load(_ path: String) {
        guard let root = model.workspace.rootURL, let text = try? String(contentsOf: root.appending(path: path), encoding: .utf8) else { return }
        tokenFile = path
        tokensJSON = text
        let themes = Set(ColorTools.tokens(text).map(\.theme))
        if !themes.contains(theme), let first = themes.sorted().first { theme = first }
    }

    private func save(_ token: ColorTools.Token) {
        guard let root = model.workspace.rootURL, let file = tokenFile,
              let updated = ColorTools.setting(token.path, to: editHex.uppercased(), in: tokensJSON) else { note = "Couldn't change \(token.path)."; return }
        do {
            model.workspace.saveCurrent()
            try updated.write(to: root.appending(path: file), atomically: true, encoding: .utf8)
            tokensJSON = updated
            editing = nil
            note = "Saved \(token.path) = \(editHex.uppercased()) in \(file)."
            model.workspace.reloadFromDisk()
        } catch { note = error.localizedDescription }
    }

    // MARK: Image

    @ViewBuilder
    private var imageSwatches: some View {
        if images.isEmpty {
            Text("No images in this project (png, jpg, webp, heic).").font(.caption).foregroundStyle(palette.text.secondary.color)
        } else {
            Menu(image ?? "Pick an image") { ForEach(images.prefix(200), id: \.self) { p in Button(p) { extract(p) } } }.font(.caption)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 84), spacing: 8)], alignment: .leading, spacing: 8) {
                ForEach(swatches, id: \.self) { color in
                    Button { UIPasteboard.general.string = color.hex; note = "Copied \(color.hex)." } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            RoundedRectangle(cornerRadius: 6).fill(Color(hex: color.hex)).frame(height: 40)
                            Text(color.hex).font(.system(.caption2, design: .monospaced))
                        }
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("Use as text color") { foreground = color.hex; mode = 0 }
                        Button("Use as background") { background = color.hex; mode = 0 }
                    }
                }
            }
        }
    }

    /// Downsamples the image to 64×64 and finds its dominant colors.
    private func extract(_ path: String) {
        guard let root = model.workspace.rootURL, let ui = UIImage(contentsOfFile: root.appending(path: path).path), let cg = ui.cgImage else {
            note = "Couldn't read \(path)."; return
        }
        image = path
        let side = 64
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(cg, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        swatches = drawn ? ColorTools.dominantColors(rgba: pixels, count: 8) : []
        note = nil
    }
}

extension Color {
    init(hex: String) {
        let c = ColorTools.RGB(hex: hex) ?? ColorTools.RGB(r: 0, g: 0, b: 0)
        self.init(.sRGB, red: c.r, green: c.g, blue: c.b, opacity: c.a)
    }

    var hexString: String {
        let ui = UIColor(self)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ui.getRed(&r, green: &g, blue: &b, alpha: &a)
        return ColorTools.RGB(r: Double(max(0, min(1, r))), g: Double(max(0, min(1, g))), b: Double(max(0, min(1, b))), a: Double(a)).hex
    }
}
