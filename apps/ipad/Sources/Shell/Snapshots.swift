// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

import DesignKit
import SwiftUI
import WorkspaceKit

/// Local project snapshots: a copy of the project kept outside it, so it works in any folder and
/// doesn't touch git. Take one before a risky change; restore puts the files back (and snapshots
/// the current state first, so the restore is itself undoable).
@MainActor
@Observable
final class SnapshotsModel {
    private(set) var snapshots: [ProjectSnapshot] = []
    private(set) var isWorking = false
    var error: String?

    @ObservationIgnored weak var workspace: WorkspaceModel?

    /// Where every project's snapshots live, in Application Support.
    static let base = AppPaths.support.appending(path: "Snapshots", directoryHint: .isDirectory)

    private var store: SnapshotStore? {
        guard let root = workspace?.rootURL else { return nil }
        return SnapshotStore(root: root, base: Self.base)
    }

    func refresh() { snapshots = store?.list() ?? [] }

    /// Saves the open file, then snapshots the project; returns the snapshot taken.
    @discardableResult
    func take(reason: String) -> ProjectSnapshot? {
        guard let store else {
            error = "Open a folder first."
            return nil
        }
        workspace?.saveCurrent()
        isWorking = true
        defer { isWorking = false }
        do {
            let snapshot = try store.take(reason: reason)
            refresh()
            error = nil
            return snapshot
        } catch {
            self.error = "Snapshot failed: \(error.localizedDescription)"
            return nil
        }
    }

    func restore(_ snapshot: ProjectSnapshot) {
        guard let store else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            _ = try store.restore(snapshot)
            refresh()
            workspace?.reloadFromDisk()
            error = nil
        } catch {
            self.error = "Restore failed: \(error.localizedDescription)"
        }
    }

    func delete(_ snapshot: ProjectSnapshot) {
        guard let store else { return }
        try? store.delete(snapshot)
        refresh()
    }

    /// Opening the sheet: save first (so what you see is in the snapshot), then list.
    func opening() {
        workspace?.saveCurrent()
        refresh()
    }

    var totalBytes: Int { snapshots.reduce(0) { $0 + $1.byteCount } }
}

/// The Snapshots sheet: take one, and restore or delete the ones you have.
struct SnapshotsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var palette
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let snapshots = model.snapshots
        NavigationStack {
            Group {
                if snapshots.snapshots.isEmpty {
                    ContentUnavailableView("No snapshots", systemImage: "clock.arrow.circlepath",
                        description: Text("A snapshot is a copy of the project kept outside it, so it works in any folder and doesn't touch git. Take one before a risky change."))
                } else {
                    List {
                        ForEach(snapshots.snapshots) { snapshot in
                            row(snapshot)
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                }
            }
            .navigationTitle("Snapshots")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Take snapshot") { _ = snapshots.take(reason: "Manual") }
                        .disabled(snapshots.isWorking)
                }
            }
            .tint(palette.accent.ion.color)
            .toolbarBackground(palette.surface.pane.color, for: .navigationBar)
            .safeAreaInset(edge: .bottom) {
                if let error = snapshots.error {
                    Text(error).font(.footnote).foregroundStyle(palette.status.error.color)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                        .background(palette.surface.raised.color)
                }
            }
        }
        .onAppear { snapshots.opening() }
    }

    private func row(_ snapshot: ProjectSnapshot) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(snapshot.date.formatted(.relative(presentation: .named, unitsStyle: .abbreviated)))
                    .font(.callout.weight(.medium))
                Text("\(snapshot.reason) · \(snapshot.fileCount) files · \(Self.size(snapshot.byteCount))")
                    .font(.caption)
                    .foregroundStyle(palette.text.secondary.color)
            }
            Spacer()
            Button("Restore") { model.snapshots.restore(snapshot) }
                .buttonStyle(.borderless)
                .font(.footnote)
                .foregroundStyle(palette.accent.ion.color)
                .disabled(model.snapshots.isWorking)
            Button(role: .destructive) { model.snapshots.delete(snapshot) } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .font(.footnote)
        }
        .padding(.vertical, 2)
        .listRowBackground(Color.clear)
    }

    static func size(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}
