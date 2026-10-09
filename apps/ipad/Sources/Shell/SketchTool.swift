// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

import AgentKit
import DesignKit
import PencilKit
import PhotosUI
import SwiftUI

/// Pencil whiteboard and screenshot → UI code (PLAN.md §11.2), in the Tools tab: draw a screen or
/// pick a picture, say what it is, and an online vision model writes it in the project's stack as
/// a changeset to review. Offline, the drawing waits in a queue.
struct SketchTool: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var palette
    @State private var drawing = false
    @State private var photo: PhotosPickerItem?
    @State private var instruction = ""

    var body: some View {
        let agent = model.agent
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Draw a screen with the Pencil, or pick a screenshot, and get it as code in this project's stack. The result is a changeset you review, like an agent task.")
                    .font(.footnote)
                    .foregroundStyle(palette.text.secondary.color)
                HStack(spacing: 10) {
                    Button { drawing = true } label: { Label("New sketch", systemImage: "pencil.and.scribble") }
                        .buttonStyle(.borderedProminent)
                    PhotosPicker(selection: $photo, matching: .images) {
                        Label("From image…", systemImage: "photo")
                    }
                    .buttonStyle(.bordered)
                }
                TextField("What is it? (optional for a sketch, e.g. “sign-in card”)", text: $instruction, axis: .vertical)
                    .font(.footnote)
                    .textFieldStyle(.roundedBorder)
                if model.policy.planeMode || model.isOffline {
                    Label("Offline: sketches wait here and go to \(model.models.online.provider) when you're back online.", systemImage: "clock")
                        .font(.footnote)
                        .foregroundStyle(palette.text.secondary.color)
                }
                if agent.isRunning, agent.current?.isSketch == true {
                    HStack { ProgressView().controlSize(.small); Text("Turning it into code…").font(.footnote) }
                }
                if let error = agent.error {
                    Text(error).font(.footnote).foregroundStyle(palette.status.warn.color)
                }
                let queued = agent.queuedSketches.filter { $0.repoPath == model.workspace.rootURL?.path }
                if !queued.isEmpty {
                    Text("Waiting to send").font(.footnote.weight(.semibold))
                    ForEach(queued) { item in
                        HStack {
                            Image(systemName: item.source == .sketch ? "pencil.and.scribble" : "photo")
                            Text(item.instruction.isEmpty ? "Sketch from \(item.created.formatted(date: .omitted, time: .shortened))" : item.instruction)
                                .font(.footnote).lineLimit(1)
                            Spacer()
                            Button("Delete", role: .destructive) { agent.dropQueued(item) }.font(.footnote)
                        }
                    }
                    if !model.policy.planeMode && !model.isOffline {
                        Button("Send now") { Task { await agent.sendQueuedSketches(); model.show(.agent) } }
                            .font(.footnote)
                    }
                }
            }
            .padding(14)
        }
        .fullScreenCover(isPresented: $drawing) {
            SketchSheet(instruction: $instruction) { png in
                Task {
                    await agent.startSketch(png: png, source: .sketch, instruction: instruction)
                    if agent.error == nil { model.show(.agent) }
                }
            }
            .environment(model)
        }
        .onChange(of: photo) {
            guard let photo else { return }
            Task {
                defer { self.photo = nil }
                guard let data = try? await photo.loadTransferable(type: Data.self), let png = SketchRender.png(image: data) else {
                    agent.error = "That image couldn't be read."
                    return
                }
                await agent.startSketch(png: png, source: .screenshot, instruction: instruction)
                if agent.error == nil { model.show(.agent) }
            }
        }
    }
}

/// The whiteboard: a full-screen PencilKit canvas with the tool picker.
struct SketchSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.palette) private var palette
    @Binding var instruction: String
    let make: (Data) -> Void
    @State private var canvas = PKCanvasView()

    var body: some View {
        NavigationStack {
            SketchCanvas(canvas: canvas)
                .ignoresSafeArea(edges: .bottom)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                    ToolbarItemGroup(placement: .principal) {
                        TextField("What is it?", text: $instruction)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 360)
                    }
                    ToolbarItemGroup(placement: .primaryAction) {
                        Button { canvas.undoManager?.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                            .accessibilityLabel("Undo")
                        Button { canvas.drawing = PKDrawing() } label: { Image(systemName: "trash") }
                            .accessibilityLabel("Clear")
                        Button("Make code") {
                            guard let png = SketchRender.png(drawing: canvas.drawing) else { return }
                            make(png)
                            dismiss()
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
                .navigationBarTitleDisplayMode(.inline)
        }
    }
}

struct SketchCanvas: UIViewRepresentable {
    let canvas: PKCanvasView
    @State private var picker = PKToolPicker()

    func makeUIView(context: Context) -> PKCanvasView {
        // Pencil draws; a finger draws too when there's no Pencil (and scrolls with two).
        canvas.drawingPolicy = .default
        canvas.tool = PKInkingTool(.pen, color: .label, width: 4)
        canvas.backgroundColor = .systemBackground
        canvas.isOpaque = true
        canvas.accessibilityLabel = "Whiteboard"
        picker.setVisible(true, forFirstResponder: canvas)
        picker.addObserver(canvas)
        DispatchQueue.main.async { canvas.becomeFirstResponder() }
        return canvas
    }

    func updateUIView(_ view: PKCanvasView, context: Context) {}
}

enum SketchRender {
    /// The longest side the vision models use without scaling down (Anthropic's guidance).
    static let maxSide: CGFloat = 1568

    /// The drawing as a PNG: dark ink on white, cropped to what's drawn, at most 1568 px a side.
    static func png(drawing: PKDrawing) -> Data? {
        guard !drawing.strokes.isEmpty else { return nil }
        let bounds = drawing.bounds.insetBy(dx: -32, dy: -32)
        let scale = min(2, maxSide / max(bounds.width, bounds.height))
        var image = UIImage()
        // PencilKit inverts ink in dark mode; the model gets the light rendering.
        UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
            image = drawing.image(from: bounds, scale: scale)
        }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let size = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        return UIGraphicsImageRenderer(size: size, format: format).pngData { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }

    /// A picked image, scaled to at most 1568 px a side, as PNG.
    static func png(image data: Data) -> Data? {
        guard let image = UIImage(data: data) else { return nil }
        let scale = min(1, maxSide / max(image.size.width * image.scale, image.size.height * image.scale))
        let size = CGSize(width: image.size.width * image.scale * scale, height: image.size.height * image.scale * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).pngData { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
    }

    #if DEBUG
    /// A wireframe drawn in code (`-OmnieSketchDemo`): a card with a title, two fields and a
    /// filled button, the way a quick sketch would look.
    static func demoDrawing() -> PKDrawing {
        let ink = PKInk(.pen, color: .black)
        func stroke(_ points: [CGPoint]) -> PKStroke {
            let path = PKStrokePath(controlPoints: points.enumerated().map { i, p in
                PKStrokePoint(location: p, timeOffset: Double(i) * 0.01, size: CGSize(width: 4, height: 4),
                              opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
            }, creationDate: .now)
            return PKStroke(ink: ink, path: path)
        }
        func line(_ a: CGPoint, _ b: CGPoint) -> PKStroke {
            stroke((0...20).map { t in CGPoint(x: a.x + (b.x - a.x) * Double(t) / 20, y: a.y + (b.y - a.y) * Double(t) / 20) })
        }
        func box(_ r: CGRect) -> [PKStroke] {
            [line(CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY)), line(CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.maxX, y: r.maxY)),
             line(CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY)), line(CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.minX, y: r.minY))]
        }
        var strokes = box(CGRect(x: 100, y: 100, width: 420, height: 380))              // the card
        strokes.append(line(CGPoint(x: 140, y: 150), CGPoint(x: 300, y: 150)))           // a title
        strokes.append(line(CGPoint(x: 140, y: 158), CGPoint(x: 300, y: 158)))
        strokes += box(CGRect(x: 140, y: 200, width: 340, height: 50))                   // field
        strokes += box(CGRect(x: 140, y: 280, width: 340, height: 50))                   // field
        let button = CGRect(x: 140, y: 380, width: 340, height: 56)
        strokes += box(button)                                                            // filled button
        for x in stride(from: button.minX + 8, to: button.maxX - 8, by: 14) {
            strokes.append(line(CGPoint(x: x, y: button.minY + 6), CGPoint(x: x + 10, y: button.maxY - 6)))
        }
        return PKDrawing(strokes: strokes)
    }
    #endif
}
