// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

import DesignKit
import GitKit
import SwiftUI

/// First run (PLAN.md §22, v1.0 onboarding): three ways to start, and the setup that makes the
/// first commit and the first agent task work. Shown once; Help › Welcome brings it back.
struct WelcomeView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var palette
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var email = ""
    @State private var preparingSample = false

    static let doneKey = "onboarding.done"

    var body: some View {
        let git = model.workspace.git
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Omnie Dev").font(.largeTitle.weight(.semibold))
                    Text("Write, run and commit code on this iPad. The agent works on its own branch, on this device or online, and nothing lands until you review it.")
                        .font(.body)
                        .foregroundStyle(palette.text.secondary.color)
                }

                VStack(alignment: .leading, spacing: 12) {
                    Text("Start").font(.headline)
                    start("Try the sample project", detail: "A three.js scene with a failing test: run it, then ask the agent to fix it.",
                          symbol: "sparkles", busy: preparingSample) { Task { await openSample() } }
                    start("Open a folder", detail: "Any folder in Files, iCloud Drive or another app.", symbol: "folder") {
                        finish { model.workspace.isPickingFolder = true }
                    }
                    start("Clone a repository", detail: "From GitHub, GitLab, Codeberg or your own server, over HTTPS or SSH.", symbol: "arrow.down.circle") {
                        finish { model.cloneSheetOpen = true }
                    }
                }

                VStack(alignment: .leading, spacing: 12) {
                    Text("Set up (optional)").font(.headline)
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Name and email for your commits", systemImage: "person.crop.circle")
                        HStack {
                            TextField("Name", text: $name).textContentType(.name)
                            TextField("Email", text: $email).textContentType(.emailAddress).keyboardType(.emailAddress).textInputAutocapitalization(.never)
                        }
                        .textFieldStyle(.roundedBorder)
                        Text("Used when a repository doesn't set its own. Kept on this iPad.")
                            .font(.caption).foregroundStyle(palette.text.tertiary.color)
                    }
                    setup(model.models.isInstalled(.standard) ? "Local model installed" : "Download the local model (4.3 GB)",
                          detail: "Qwen2.5-Coder 7B runs the agent with no network, in plane mode too.",
                          symbol: model.models.isInstalled(.standard) ? "checkmark.circle.fill" : "cpu") { model.settingsOpen = true }
                    setup(model.models.hasOnlineKey ? "Online model ready" : "Add an online model",
                          detail: "Optional: bigger tasks go to the provider you choose, after you agree per project.",
                          symbol: model.models.hasOnlineKey ? "checkmark.circle.fill" : "network") { model.settingsOpen = true }
                }

                HStack {
                    Text("Keys: ⌘K commands, ⌘P files, ⌘I ask the agent, ⌘1 ⌘3 ⌘J the docks.")
                        .font(.caption).foregroundStyle(palette.text.tertiary.color)
                    Spacer()
                    Button("Close") { finish {} }
                        .keyboardShortcut(.cancelAction)
                }
            }
            .padding(32)
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity)
        }
        .background(palette.surface.chrome.color)
        .onAppear {
            name = git.fallbackName
            email = git.fallbackEmail
        }
    }

    private func start(_ title: String, detail: String, symbol: String, busy: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: symbol).font(.title2).frame(width: 36).foregroundStyle(palette.accent.ion.color)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.body.weight(.semibold)).foregroundStyle(palette.text.primary.color)
                    Text(detail).font(.footnote).foregroundStyle(palette.text.secondary.color).multilineTextAlignment(.leading)
                }
                Spacer()
                if busy { ProgressView() } else { Image(systemName: "chevron.right").foregroundStyle(palette.text.tertiary.color) }
            }
            .padding(14)
            .frame(minHeight: 64)
            .background(palette.surface.raised.color, in: RoundedRectangle(cornerRadius: 12))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(busy)
    }

    private func setup(_ title: String, detail: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: symbol).frame(width: 24).foregroundStyle(palette.accent.ion.color)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).foregroundStyle(palette.text.primary.color)
                    Text(detail).font(.caption).foregroundStyle(palette.text.secondary.color).multilineTextAlignment(.leading)
                }
                Spacer()
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Saves the author, marks the welcome as seen, closes it, then does `next`.
    private func finish(_ next: @escaping () -> Void) {
        let git = model.workspace.git
        let (n, e) = (name.trimmingCharacters(in: .whitespaces), email.trimmingCharacters(in: .whitespaces))
        if !n.isEmpty { git.fallbackName = n }
        if e.contains("@") { git.fallbackEmail = e }
        UserDefaults.standard.set(true, forKey: Self.doneKey)
        dismiss()
        // After the cover is gone, so the picker or sheet presents from the IDE.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { next() }
    }

    /// Copies the bundled sample into Projects as a git repository with one commit, and opens it.
    private func openSample() async {
        preparingSample = true
        defer { preparingSample = false }
        do {
            let folder = try await SampleProject.install()
            finish {
                model.workspace.open(folder: folder)
                // Its README says what to try first.
                model.workspace.open(file: folder.appending(path: "README.md"), preview: false)
            }
        } catch {
            model.workspace.banner = "Couldn't set up the sample: \(error.localizedDescription)"
            finish {}
        }
    }
}

enum SampleProject {
    /// The plane test's project (fixtures/plane-demo), bundled with the app.
    static var bundled: URL? { Bundle.main.url(forResource: "plane-demo", withExtension: nil) }

    /// Projects/Sample (Sample 2, … if taken), committed once so the timeline and Undo work from
    /// the first edit.
    static func install() async throws -> URL {
        guard let source = bundled else { throw CocoaError(.fileNoSuchFile) }
        var folder = AppPaths.projects.appendingPathComponent("Sample", isDirectory: true)
        var n = 2
        while FileManager.default.fileExists(atPath: folder.path(percentEncoded: false)) {
            folder = AppPaths.projects.appendingPathComponent("Sample \(n)", isDirectory: true)
            n += 1
        }
        try FileManager.default.createDirectory(at: AppPaths.projects, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: source, to: folder)
        let repo = try Repository.create(at: folder)
        try await repo.commitAll(message: "Sample project\n", author: Signature(name: "Omnie Dev", email: "sample@omnie.invalid"))
        return folder
    }
}
