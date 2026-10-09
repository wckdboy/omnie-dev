// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

import DesignKit
import GitKit
import ModelKit
import SwiftUI

/// Settings: who you commit as, your SSH key, how the app looks, what it's allowed to do, and the
/// licenses of what it's built from.
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var model = model
        @Bindable var git = model.workspace.git
        @Bindable var policy = model.policy
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $git.fallbackName)
                        .textContentType(.name)
                    TextField("Email", text: $git.fallbackEmail)
                        .textContentType(.emailAddress)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("Commit as")
                } footer: {
                    Text("Used when a repository doesn't set user.name and user.email itself.")
                }

                SSHKeySection()

                Section("Appearance") {
                    Picker("Density", selection: $model.densityOverride) {
                        Text("Automatic").tag(Density?.none)
                        Text("Compact").tag(Density?.some(.compact))
                        Text("Regular").tag(Density?.some(.regular))
                        Text("Touch").tag(Density?.some(.touch))
                    }
                }

                ModelsSection()

                Section {
                    Toggle("Plane mode", isOn: $policy.planeMode)
                    NavigationLink("Audit log") { AuditLogList() }
                } header: {
                    Text("Safety")
                } footer: {
                    Text("Plane mode blocks every network action. Sync queues your push instead, and queued pushes wait until you turn it off.")
                }

                if !model.workspace.recentProjects.isEmpty {
                    Section("Recent projects") {
                        ForEach(model.workspace.recentProjects) { ref in
                            Text(ref.name)
                        }
                        .onDelete { offsets in
                            for i in offsets { model.workspace.forget(model.workspace.recentProjects[i]) }
                        }
                    }
                }

                Section {
                    LabeledContent("Version", value: Self.version)
                    LabeledContent("License", value: "Apache-2.0")
                    NavigationLink("Acknowledgements") { AcknowledgementsList() }
                } header: {
                    Text("About Omnie Dev")
                } footer: {
                    Text("The code is open source. The name and icon aren't covered by the license.")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }

    static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }
}

private struct SSHKeySection: View {
    @Environment(AppModel.self) private var model
    @State private var copied = false

    var body: some View {
        let git = model.workspace.git
        Section {
            if let identity = git.identity {
                LabeledContent("Fingerprint") {
                    Text(identity.signer.fingerprint)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                }
                Button(copied ? "Copied" : "Copy public key") {
                    UIPasteboard.general.string = identity.signer.authorizedKeysLine(comment: "omnie-dev")
                    copied = true
                }
            } else {
                Button("Create SSH key") { git.createIdentity() }
            }
        } header: {
            Text("SSH key")
        } footer: {
            if let identity = git.identity {
                Text(identity.isHardwareBacked
                     ? "In the Secure Enclave: it can't be read or exported, only used to sign on this device. Add the public key to your forge."
                     : "A software key (this device has no Secure Enclave). Add the public key to your forge.")
            } else {
                Text("For cloning and pushing over SSH.")
            }
        }
    }
}

/// Local models: download, progress, remove (PLAN.md §7). Files are checked against pinned
/// SHA-256 sums before they're used.
private struct ModelsSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let models = model.models
        Section {
            ForEach(ModelPack.catalog) { pack in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(pack.displayName)
                            Text("\(pack.role == .tiny ? "Commit messages and completion" : "The offline agent") · \(ByteCountFormatter.string(fromByteCount: pack.totalBytes, countStyle: .file))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if models.downloads[pack.id] != nil {
                            Button("Cancel") { models.cancel(pack) }
                        } else if models.isInstalled(pack) {
                            Menu("Installed") {
                                Button("Remove", role: .destructive) { models.remove(pack) }
                            }
                        } else {
                            Button(models.states[pack.id].map { if case .partial = $0 { "Resume" } else { "Download" } } ?? "Download") {
                                models.install(pack)
                            }
                        }
                    }
                    if let download = models.downloads[pack.id] {
                        ProgressView(value: download.fraction) {
                            Text("\(ByteCountFormatter.string(fromByteCount: download.done, countStyle: .file)) of \(ByteCountFormatter.string(fromByteCount: download.total, countStyle: .file))")
                                .font(.caption)
                        }
                    }
                }
                .accessibilityElement(children: .contain)
            }
            if models.isInstalled(.tiny) {
                @Bindable var models = models
                Toggle("Inline suggestions", isOn: $models.inlineSuggestions)
            }
            if let error = models.error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        } header: {
            Text("Models")
        } footer: {
            Text("Models run on this device; nothing you write is sent anywhere. Downloads come from Hugging Face and are checked against pinned checksums. Keep the app open while one downloads.")
        }
    }
}

/// The license of everything Omnie Dev ships, from Acknowledgements.json
/// (scripts/gen-acknowledgements.py).
struct AcknowledgementsList: View {
    struct Item: Decodable, Identifiable, Hashable {
        var id: String { name }
        let name: String
        let version: String
        let url: String
        let text: String
    }

    let items: [Item] = {
        guard let url = Bundle.main.url(forResource: "Acknowledgements", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([Item].self, from: data)) ?? []
    }()

    var body: some View {
        List(items) { item in
            NavigationLink {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if let link = URL(string: item.url), !item.url.isEmpty {
                            Link(item.url, destination: link).font(.footnote)
                        }
                        Text(item.text)
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                }
                .navigationTitle(item.name)
                .navigationBarTitleDisplayMode(.inline)
            } label: {
                LabeledContent(item.name, value: item.version)
            }
        }
        .navigationTitle("Acknowledgements")
        .overlay {
            if items.isEmpty { ContentUnavailableView("No acknowledgements bundled", systemImage: "doc.text") }
        }
    }
}
