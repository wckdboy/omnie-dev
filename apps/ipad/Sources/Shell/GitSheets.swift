// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

import SwiftUI
import DesignKit
import GitKit

/// Shows (or creates) this device's SSH key, ready to paste into a forge.
struct SSHKeySheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var palette
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    var body: some View {
        let git = model.workspace.git
        NavigationStack {
            Form {
                if let identity = git.identity {
                    Section {
                        Text(identity.signer.authorizedKeysLine(comment: "omnie-dev"))
                            .font(.system(size: 12, design: .monospaced))
                            .textSelection(.enabled)
                        Button(copied ? "Copied" : "Copy public key") {
                            UIPasteboard.general.string = identity.signer.authorizedKeysLine(comment: "omnie-dev")
                            copied = true
                        }
                    } header: {
                        Text("Public key")
                    } footer: {
                        Text("Add this in your forge's SSH keys settings (Forgejo, GitLab, GitHub…). It's safe to share.")
                    }
                    Section("Fingerprint") {
                        Text(identity.signer.fingerprint)
                            .font(.system(size: 12, design: .monospaced))
                            .textSelection(.enabled)
                    }
                    Section {
                        Label(identity.isHardwareBacked
                              ? "Stored in the Secure Enclave. The private key can't be read or exported, only used to sign on this device."
                              : "Software key in the Keychain (no Secure Enclave on this device). Use a real device for a hardware-backed key.",
                              systemImage: identity.isHardwareBacked ? "lock.shield" : "exclamationmark.triangle")
                            .font(.system(size: 13))
                            .foregroundStyle(identity.isHardwareBacked ? palette.text.secondary.color : palette.status.warn.color)
                    }
                } else {
                    Section {
                        Text("Omnie-dev signs git connections with a key kept in the Secure Enclave. Create it once, then add the public key to your forge.")
                            .font(.system(size: 13))
                        Button("Create SSH key") { git.createIdentity() }
                    }
                }
            }
            .navigationTitle("SSH key")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }
}

/// Clone any SSH remote into Documents/Projects and open it.
struct CloneSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var url = ""

    var body: some View {
        let git = model.workspace.git
        NavigationStack {
            Form {
                Section {
                    TextField("git@forgejo.example.net:you/project.git", text: $url)
                        .font(.system(size: 14, design: .monospaced))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                } header: {
                    Text("Repository URL")
                } footer: {
                    Text("SSH (git@host:owner/repo.git) or HTTPS (https://host/owner/repo.git). HTTPS asks for a token the first time.")
                }
                if git.isBusy {
                    HStack { ProgressView(); Text("Cloning…") }
                }
            }
            .navigationTitle("Clone")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Clone") {
                        Task {
                            if let folder = await git.clone(url.trimmingCharacters(in: .whitespaces)) {
                                model.workspace.open(folder: folder)
                                dismiss()
                            } else if git.pendingHostKey != nil || git.error != nil {
                                dismiss()
                            }
                        }
                    }
                    .disabled(url.trimmingCharacters(in: .whitespaces).isEmpty || git.isBusy)
                }
            }
        }
    }
}

/// Asks for an HTTPS username and token for one host, then retries the operation.
struct TokenSheet: View {
    @Environment(AppModel.self) private var model
    let request: GitModel.TokenRequest
    @State private var username = ""
    @State private var token = ""

    var body: some View {
        let git = model.workspace.git
        NavigationStack {
            Form {
                Section {
                    TextField("Username", text: $username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .textContentType(.username)
                    SecureField("Token", text: $token)
                        .textContentType(.password)
                } header: {
                    Text(request.host)
                } footer: {
                    Text((request.rejected ? "\(request.host) refused the saved token. " : "")
                         + HTTPSToken.usernameHint(for: request.host)
                         + " Stored in the Keychain on this device only; never sent to the agent.")
                }
            }
            .navigationTitle(request.rejected ? "Token refused" : "Sign in")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { git.cancelTokenRequest() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save and retry") {
                        Task { await git.saveToken(HTTPSToken(username: username, token: token)) }
                    }
                    .disabled(username.isEmpty || token.isEmpty)
                }
            }
        }
        .onAppear { username = HTTPSToken.load(host: request.host)?.username ?? "" }
    }
}

/// First connection to a host: show the fingerprint and let you compare it before trusting.
struct HostKeySheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var palette
    let key: HostKey

    var body: some View {
        let git = model.workspace.git
        NavigationStack {
            Form {
                Section {
                    Text("First connection to \(key.host). Compare this fingerprint with the one your forge publishes before trusting it.")
                        .font(.system(size: 13))
                }
                Section(key.keyType ?? "Host key") {
                    Text(key.fingerprint)
                        .font(.system(size: 13, design: .monospaced))
                        .textSelection(.enabled)
                }
            }
            .navigationTitle("Trust host?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Don't connect") { git.rejectPendingHostKey() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Trust and connect") { Task { await git.trustPendingHostKey() } }
                }
            }
        }
        .interactiveDismissDisabled()
    }
}

extension View {
    /// The git sheets any shell can present.
    func gitSheets(_ model: AppModel) -> some View {
        @Bindable var model = model
        @Bindable var git = model.workspace.git
        return self
            .sheet(isPresented: $model.commitSheetOpen) { CommitSheet() }
            .sheet(isPresented: $model.sshKeySheetOpen) { SSHKeySheet() }
            .sheet(isPresented: $model.cloneSheetOpen) { CloneSheet() }
            .sheet(item: $git.pendingHostKey) { HostKeySheet(key: $0) }
            .sheet(isPresented: $model.branchSheetOpen) { BranchSheet() }
            .fullScreenCover(isPresented: $model.editorSpikeOpen) { EditorSpikeView() }
            .fullScreenCover(isPresented: $model.modelSpikeOpen) { ModelSpikeView() }
            .fullScreenCover(isPresented: $model.webGPUSpikeOpen) { WebGPUSpikeView() }
            .sheet(item: $git.pendingTokenHost) { TokenSheet(request: $0) }
            .fullScreenCover(item: $git.mergeSession) { ConflictResolverView(session: $0) }
    }
}

extension HostKey: @retroactive Identifiable {
    public var id: String { host + fingerprint }
}
