// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

import EditorKit
import Foundation
import RunKit
import SwiftUI
import WorkspaceKit

/// Code intelligence for TypeScript and JavaScript (VS Code's features from the same TypeScript
/// language service, offline): go to definition, find references, rename, quick info and
/// completions as you type. One service per project, fed the editor's unsaved text.
@MainActor
@Observable
final class LanguageModel {
    @ObservationIgnored private let workspace: WorkspaceModel
    @ObservationIgnored private var service: LanguageService?
    @ObservationIgnored private var serviceRoot: URL?
    /// The editor text the service last saw, and the disk state it loaded (changeCount).
    @ObservationIgnored private var syncedText: (path: String, text: String)?
    @ObservationIgnored private var loadedChangeCount = -1
    @ObservationIgnored private var completionTask: Task<Void, Never>?

    init(workspace: WorkspaceModel) { self.workspace = workspace }

    // UI state
    var references: ReferenceList?
    var renaming: RenameRequest?
    var info: InfoCard?
    var completions: CompletionList?
    /// Off in Settings: no popup as you type (⌃Space still asks).
    var completesAsYouType = UserDefaults.standard.object(forKey: "editor.completions") as? Bool ?? true {
        didSet { UserDefaults.standard.set(completesAsYouType, forKey: "editor.completions") }
    }

    struct ReferenceList: Identifiable {
        let id = UUID()
        let title: String
        let locations: [SourceLocation]
    }

    struct RenameRequest: Identifiable {
        let id = UUID()
        let path: String
        let offset: Int
        let name: String
    }

    struct InfoCard: Equatable {
        let signature: String
        let documentation: String
    }

    struct CompletionList: Equatable {
        var items: [Completion]
        var selected = 0
        /// Where the caret was when they were asked for (they're dropped when it moves elsewhere).
        let offset: Int
        var detail: InfoCard?
    }

    /// The open file, if the service answers for it.
    private var target: (path: String, offset: Int)? {
        guard let file = workspace.openFile, workspace.rootURL != nil else { return nil }
        let path = workspace.relativePath(of: file)
        guard LanguageService.handles(path) else { return nil }
        return (path, workspace.editor.selectedRange.location)
    }

    var isAvailable: Bool { target != nil }

    /// The project's service, started on first use and caught up with the disk and the editor.
    private func ready() async throws -> LanguageService {
        guard let root = workspace.rootURL else { throw LanguageServiceError.notReady("no project open") }
        if serviceRoot != root {
            service?.stop()
            service = try LanguageService(root: root)
            serviceRoot = root
            syncedText = nil
            loadedChangeCount = workspace.changeCount
        }
        let service = service!
        // Files saved, added or changed outside the editor since it last loaded.
        if loadedChangeCount != workspace.changeCount {
            loadedChangeCount = workspace.changeCount
            try await service.reload()
            syncedText = nil
        }
        if let file = workspace.openFile {
            let path = workspace.relativePath(of: file)
            let text = workspace.editor.text
            if syncedText?.path != path || syncedText?.text != text {
                try await service.update(path, text: text)
                syncedText = (path, text)
            }
        }
        return service
    }

    /// Project closed or switched: the next request starts a fresh service.
    func reset() {
        service?.stop()
        service = nil
        serviceRoot = nil
        references = nil
        info = nil
        completions = nil
    }

    private func report(_ error: Error) {
        workspace.banner = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    // MARK: Go to definition, references, quick info

    func goToDefinition() async {
        guard let (path, offset) = target else { return }
        do {
            let found = try await ready().definition(path, offset: offset)
            switch found.count {
            case 0: workspace.banner = "No definition found here."
            case 1: open(found[0])
            default: references = ReferenceList(title: "Definitions", locations: found)
            }
        } catch { report(error) }
    }

    func findReferences() async {
        guard let (path, offset) = target else { return }
        do {
            let found = try await ready().references(path, offset: offset)
            if found.isEmpty { workspace.banner = "No references found here." }
            else { references = ReferenceList(title: "\(found.count) reference\(found.count == 1 ? "" : "s")", locations: found) }
        } catch { report(error) }
    }

    func showInfo() async {
        guard let (path, offset) = target else { return }
        do {
            if let found = try await ready().quickInfo(path, offset: offset) {
                info = InfoCard(signature: found.signature, documentation: ([found.documentation] + found.tags).filter { !$0.isEmpty }.joined(separator: "\n"))
            } else {
                info = nil
                workspace.banner = "Nothing known about the code here."
            }
        } catch { report(error) }
    }

    func open(_ location: SourceLocation) {
        guard let root = workspace.rootURL else { return }
        references = nil
        workspace.open(file: root.appending(path: location.path), select: NSRange(location: location.start, length: location.length))
    }

    // MARK: Rename

    func startRename() async {
        guard let (path, offset) = target else { return }
        do {
            let name = try await ready().renameTarget(path, offset: offset)
            renaming = RenameRequest(path: path, offset: offset, name: name)
        } catch { report(error) }
    }

    /// Every place, in every file: the open file through the editor (one undo step, unsaved like
    /// any edit), the others on disk.
    func rename(_ request: RenameRequest, to newName: String) async {
        renaming = nil
        let newName = newName.trimmingCharacters(in: .whitespaces)
        guard !newName.isEmpty, newName != request.name, let root = workspace.rootURL else { return }
        do {
            let plan = try await ready().rename(request.path, offset: request.offset, to: newName)
            let openPath = workspace.openFile.map { workspace.relativePath(of: $0) }
            for file in plan.files {
                let edits = plan.edits.filter { $0.location.path == file }.sorted { $0.location.start > $1.location.start }
                if file == openPath {
                    for edit in edits {
                        workspace.editor.replace(NSRange(location: edit.location.start, length: edit.location.length), with: edit.newText)
                    }
                } else {
                    let url = root.appending(path: file)
                    let text = NSMutableString(string: try String(contentsOf: url, encoding: .utf8))
                    for edit in edits { text.replaceCharacters(in: NSRange(location: edit.location.start, length: edit.location.length), with: edit.newText) }
                    try (text as String).write(to: url, atomically: true, encoding: .utf8)
                }
            }
            workspace.saveCurrent()
            workspace.reloadFromDisk()
            workspace.banner = "Renamed \(request.name) to \(newName): \(plan.edits.count) place\(plan.edits.count == 1 ? "" : "s") in \(plan.files.count) file\(plan.files.count == 1 ? "" : "s")."
        } catch { report(error) }
    }

    // MARK: Completions

    /// After an edit: ask again after a short pause when the caret ends a word or follows a dot.
    func edited() {
        completionTask?.cancel()
        info = nil
        guard completesAsYouType, target != nil else { completions = nil; return }
        let text = workspace.editor.text as NSString
        let caret = workspace.editor.selectedRange.location
        guard caret > 0, caret <= text.length else { completions = nil; return }
        let before = Character(UnicodeScalar(text.character(at: caret - 1)) ?? " ")
        let wordChar = before.isLetter || before.isNumber || before == "_" || before == "$"
        guard before == "." || wordChar else { completions = nil; return }
        // Two letters of a word (or a dot) before it's worth a list.
        if before != "." {
            var start = caret
            while start > 0, let c = UnicodeScalar(text.character(at: start - 1)).map(Character.init), c.isLetter || c.isNumber || c == "_" || c == "$" { start -= 1 }
            guard caret - start >= 2 else { completions = nil; return }
        }
        completionTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }
            await self?.complete()
        }
    }

    /// ⌃Space, or a pause while typing.
    func complete() async {
        guard let (path, offset) = target else { return }
        do {
            let items = try await ready().completions(path, offset: offset, limit: 50)
            // The caret moved on while it thought: this list is stale.
            guard workspace.editor.selectedRange.location == offset, !items.isEmpty else {
                if workspace.editor.selectedRange.location == offset { completions = nil }
                return
            }
            // A single exact match for what's typed isn't worth a list.
            if items.count == 1, items[0].length == (items[0].insertText as NSString).length,
               (workspace.editor.text as NSString).substring(with: NSRange(location: items[0].start, length: items[0].length)) == items[0].insertText {
                completions = nil
                return
            }
            workspace.editor.clearGhostText()
            completions = CompletionList(items: items, offset: offset)
            await loadDetail()
        } catch {
            completions = nil
        }
    }

    func moveSelection(_ step: Int) {
        guard var list = completions, !list.items.isEmpty else { return }
        list.selected = (list.selected + step + list.items.count) % list.items.count
        list.detail = nil
        completions = list
        Task { await loadDetail() }
    }

    private func loadDetail() async {
        guard let list = completions, let (path, _) = target else { return }
        let item = list.items[list.selected]
        let detail = try? await ready().completionDetails(path, offset: list.offset, name: item.name)
        guard completions?.items == list.items, completions?.selected == list.selected, let detail else { return }
        completions?.detail = InfoCard(signature: detail.signature, documentation: detail.documentation)
    }

    func accept(_ index: Int? = nil) {
        guard let list = completions else { return }
        let item = list.items[index ?? list.selected]
        completions = nil
        completionTask?.cancel()
        // The word typed since the list came up is replaced too.
        let caret = workspace.editor.selectedRange.location
        let end = max(item.start + item.length, caret)
        workspace.editor.replace(NSRange(location: item.start, length: end - item.start), with: item.insertText)
    }

    func dismiss() {
        completions = nil
        info = nil
        completionTask?.cancel()
    }
}

// MARK: Views

/// The completion list beside the caret: ↑ ↓ to choose, ⏎ or ⇥ to insert, ⎋ to close; tap works
/// too. The chosen one's signature and docs below it.
struct CompletionPopup: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var palette
    let list: LanguageModel.CompletionList

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(list.items.enumerated()), id: \.offset) { index, item in
                            Button { model.language.accept(index) } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: Self.symbol(item.kind))
                                        .font(.caption)
                                        .frame(width: 16)
                                        .foregroundStyle(palette.accent.ion.color)
                                    Text(item.name).font(.system(.callout, design: .monospaced)).lineLimit(1)
                                    Spacer(minLength: 8)
                                    Text(item.kind).font(.caption2).foregroundStyle(palette.text.tertiary.color)
                                }
                                .padding(.horizontal, 8)
                                .frame(height: 26)
                                .background(index == list.selected ? palette.surface.selection.color : .clear)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(palette.text.primary.color)
                            .id(index)
                            .accessibilityLabel("\(item.name), \(item.kind)")
                            .accessibilityAddTraits(index == list.selected ? .isSelected : [])
                        }
                    }
                }
                .frame(maxHeight: 26 * 8)
                .onChange(of: list.selected) { proxy.scrollTo(list.selected) }
            }
            if let detail = list.detail, !detail.signature.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 4) {
                    Text(detail.signature).font(.system(.caption, design: .monospaced)).lineLimit(3)
                    if !detail.documentation.isEmpty {
                        Text(detail.documentation).font(.caption).foregroundStyle(palette.text.secondary.color).lineLimit(4)
                    }
                }
                .padding(8)
            }
        }
        .frame(width: 380)
        .fixedSize(horizontal: false, vertical: true)
        .background(palette.surface.raised.color, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(palette.surface.hairline.color))
        .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
        .accessibilityIdentifier("completions")
    }

    static func symbol(_ kind: String) -> String {
        switch kind {
        case "method", "function", "local function", "construct": "f.cursive"
        case "property", "getter", "setter": "p.square"
        case "class", "local class": "c.square"
        case "interface", "type", "type parameter", "alias": "t.square"
        case "enum", "enum member": "e.square"
        case "module", "external module name", "directory", "script": "shippingbox"
        case "keyword": "k.square"
        case "const", "let", "var", "local var", "parameter": "v.square"
        case "string": "textformat"
        default: "circle"
        }
    }
}

/// What the language service knows about the code at the caret: its signature and docs.
struct InfoCardView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var palette
    let card: LanguageModel.InfoCard

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 6) {
                Text(card.signature).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                if !card.documentation.isEmpty {
                    Text(card.documentation).font(.footnote).foregroundStyle(palette.text.secondary.color).textSelection(.enabled)
                }
            }
            Spacer()
            Button { model.language.info = nil } label: { Image(systemName: "xmark") }
                .buttonStyle(.plain)
                .foregroundStyle(palette.text.tertiary.color)
                .accessibilityLabel("Close")
        }
        .padding(12)
        .background(palette.surface.raised.color, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(palette.surface.hairline.color))
        .shadow(color: .black.opacity(0.2), radius: 10, y: 3)
        .padding(12)
        .accessibilityIdentifier("info-card")
    }
}

/// References (or several definitions), grouped by file with each line, as VS Code's peek list.
struct ReferencesSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var palette
    @Environment(\.dismiss) private var dismiss
    let list: LanguageModel.ReferenceList

    var body: some View {
        let files = Dictionary(grouping: list.locations, by: \.path)
        NavigationStack {
            List {
                ForEach(files.keys.sorted(), id: \.self) { path in
                    Section(path) {
                        ForEach(files[path]!.sorted { $0.start < $1.start }) { location in
                            Button { model.language.open(location) } label: {
                                HStack(alignment: .firstTextBaseline, spacing: 10) {
                                    Text("\(location.line)").font(.caption.monospacedDigit()).foregroundStyle(palette.text.tertiary.color)
                                        .frame(width: 36, alignment: .trailing)
                                    Text(location.preview).font(.system(.callout, design: .monospaced)).lineLimit(1)
                                    Spacer()
                                    if location.isDefinition { Text("definition").font(.caption2).foregroundStyle(palette.accent.ion.color) }
                                    else if location.isWrite { Text("write").font(.caption2).foregroundStyle(palette.text.secondary.color) }
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(palette.text.primary.color)
                        }
                    }
                }
            }
            .navigationTitle(list.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
        }
        .accessibilityIdentifier("references")
    }
}

/// Rename: the new name, then every place across the project.
struct RenameSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let request: LanguageModel.RenameRequest
    @State private var name = ""
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("New name", text: $name)
                        .font(.system(.body, design: .monospaced))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focused)
                        .submitLabel(.done)
                        .onSubmit { go() }
                        .accessibilityIdentifier("rename-field")
                } footer: {
                    Text("Every use in the project changes; the open file's change can be undone with ⌘Z.")
                }
            }
            .navigationTitle("Rename \(request.name)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { model.language.renaming = nil } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Rename") { go() }.disabled(name.isEmpty || name == request.name).accessibilityIdentifier("rename-go")
                }
            }
            .onAppear { name = request.name; focused = true }
        }
        .presentationDetents([.height(220)])
    }

    private func go() {
        let newName = name
        Task { await model.language.rename(request, to: newName) }
    }
}
