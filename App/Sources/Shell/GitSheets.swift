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
                    Text(git.identity == nil
                         ? "SSH needs a key. Create one in SSH key first."
                         : "Any SSH remote works: Forgejo, Gitea, GitLab, GitHub, Cursor Origin or your own server.")
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
    }
}

extension HostKey: @retroactive Identifiable {
    public var id: String { host + fingerprint }
}
