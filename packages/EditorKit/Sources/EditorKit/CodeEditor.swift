// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

import DesignKit
import LangKit
import Runestone
import SwiftUI
import UIKit

/// The editor surface the rest of the app talks to (PLAN §5: `EditorView` is a protocol, so one
/// view could swap in the CodeMirror hedge later).
@MainActor
public protocol EditorView: AnyObject {
    /// The full text. O(n): read it to save, not per keystroke.
    var text: String { get }
    var selectedRange: NSRange { get set }
    func load(_ text: String, language: Language?, marks: [EditorMark])
    func scrollRangeToVisible(_ range: NSRange)
}

/// Runestone-engine implementation.
@MainActor
public final class CodeEditorController: NSObject, EditorView, @MainActor TextViewDelegate {
    public let textView = TextView()
    public var onChange: (() -> Void)?
    public var onSelectionChange: ((NSRange) -> Void)?
    /// Called on the main thread when a load finishes (for first-paint timing).
    public var onLoaded: (() -> Void)?
    private(set) public var language: Language?
    private var loadGeneration = 0

    public var theme: EditorTheme {
        didSet {
            minimapView?.update(palette: theme.palette)
            textView.theme = theme
            textView.backgroundColor = theme.palette.surface.editor.uiColor
            // Recolor marks for the new palette; ranges come from the engine, which moved them with edits.
            // The engine keeps decorations sorted by location, so match by id, not position.
            let liveRanges = Dictionary(textView.decorations.map { ($0.id, $0.range) }, uniquingKeysWith: { first, _ in first })
            textView.decorations = marks.map { mark in
                var recolored = mark
                recolored.range = liveRanges[mark.id] ?? mark.range
                return recolored.decoration(in: theme.palette)
            }
        }
    }
    /// The minimap, made when a view first shows it.
    private var minimapView: MinimapView?
    private var minimapRefresh: Task<Void, Never>?

    public var minimap: MinimapView {
        if let minimapView { return minimapView }
        let view = MinimapView(textView: textView, palette: theme.palette)
        minimapView = view
        refreshMinimap()
        return view
    }

    /// The file's symbols and the lines they span (breadcrumbs, sticky scroll), kept current
    /// 300 ms after edits.
    public private(set) var scopes: [Outline.Scope] = []
    /// Each scope's first line, as written (sticky scroll shows them).
    public private(set) var scopeHeaders: [Int: String] = [:]
    /// UTF-16 offset of each line's start.
    private var lineStarts: [Int] = [0]
    /// After `scopes` change.
    public var onStructureChange: (() -> Void)?
    /// The 1-based line at the top of the editor, when it changes while scrolling.
    public var onFirstVisibleLine: ((Int) -> Void)?
    public private(set) var firstVisibleLine = 1
    private var offsetObservation: NSKeyValueObservation?

    /// Redraws the minimap and re-reads the structure from the text; `debounce` while typing.
    func refreshMinimap(debounce: Bool = false) {
        minimapRefresh?.cancel()
        minimapRefresh = Task { [weak self] in
            if debounce { try? await Task.sleep(for: .milliseconds(300)) }
            guard let self, !Task.isCancelled else { return }
            let text = self.textView.text
            if let minimapView = self.minimapView {
                let live = Dictionary(self.textView.decorations.map { ($0.id, $0.range) }, uniquingKeysWith: { a, _ in a })
                minimapView.update(text: text, marks: self.marks.map { var m = $0; m.range = live[m.id] ?? m.range; return m })
            }
            let language = self.language
            let (starts, scopes, headers) = await Task.detached(priority: .utility) { () -> ([Int], [Outline.Scope], [Int: String]) in
                var starts = [0], offset = 0
                for unit in text.utf16 { offset += 1; if unit == 0x0A { starts.append(offset) } }
                let scopes = language.map { Outline.scopes(in: text, language: $0) } ?? []
                let ns = text as NSString
                var headers: [Int: String] = [:]
                for scope in scopes where scope.startLine <= starts.count {
                    let start = starts[scope.startLine - 1]
                    let end = scope.startLine < starts.count ? starts[scope.startLine] - 1 : ns.length
                    headers[scope.startLine] = ns.substring(with: NSRange(location: start, length: max(0, end - start)))
                }
                return (starts, scopes, headers)
            }.value
            guard !Task.isCancelled else { return }
            self.lineStarts = starts
            self.scopes = scopes
            self.scopeHeaders = headers
            self.onStructureChange?()
            self.updateFirstVisibleLine()
        }
    }

    /// The line at the top of the editor, from the scroll position.
    private func updateFirstVisibleLine() {
        let top = CGPoint(x: textView.textContainerInset.left + 40, y: textView.contentOffset.y + textView.textContainerInset.top + 2)
        guard let position = textView.closestPosition(to: top) else { return }
        let offset = textView.offset(from: textView.beginningOfDocument, to: position)
        var low = 0, high = lineStarts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if lineStarts[mid] <= offset { low = mid } else { high = mid - 1 }
        }
        let line = low + 1
        guard line != firstVisibleLine else { return }
        firstVisibleLine = line
        onFirstVisibleLine?(line)
    }

    /// Scrolls so `line` (1-based) is at the top.
    public func scrollToLine(_ line: Int) {
        let index = min(max(line - 1, 0), lineStarts.count - 1)
        guard let start = textView.position(from: textView.beginningOfDocument, offset: lineStarts[index]) else { return }
        let rect = textView.caretRect(for: start)
        textView.setContentOffset(CGPoint(x: textView.contentOffset.x, y: max(0, rect.minY - textView.textContainerInset.top)), animated: true)
    }

    /// Marks as last set; their live ranges are in `textView.decorations`.
    var marks: [EditorMark] = []
    /// Bumped by every setMarks, so a load doesn't apply marks that were replaced while it ran.
    var marksVersion = 0

    /// An inline suggestion drawn after the caret (PLAN.md §7 ghost text). It isn't part of the
    /// text: Tab inserts it, and any edit or caret move clears it.
    public private(set) var ghostText: String?
    private var ghostLocation = 0
    /// Called with the text after Tab inserts a suggestion.
    public var onGhostAccepted: ((String) -> Void)?
    private lazy var ghostLabel: UILabel = {
        let label = UILabel()
        label.isUserInteractionEnabled = false
        label.isAccessibilityElement = false
        label.isHidden = true
        textView.addSubview(label)
        return label
    }()

    public init(theme: EditorTheme) {
        self.theme = theme
        super.init()
        textView.editorDelegate = self
        textView.theme = theme
        textView.backgroundColor = theme.palette.surface.editor.uiColor
        textView.showLineNumbers = true
        textView.lineSelectionDisplayType = .line
        textView.isLineWrappingEnabled = false
        textView.autocorrectionType = .no
        textView.autocapitalizationType = .none
        textView.smartQuotesType = .no
        textView.smartDashesType = .no
        textView.spellCheckingType = .no
        textView.inlinePredictionType = .no
        textView.writingToolsBehavior = .none
        textView.isFindInteractionEnabled = true
        textView.characterPairs = Self.pairs
        textView.alwaysBounceVertical = true
        textView.contentInsetAdjustmentBehavior = .never
        textView.textContainerInset = UIEdgeInsets(top: 8, left: 4, bottom: 8, right: 8)
        offsetObservation = textView.observe(\.contentOffset, options: [.new]) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.updateFirstVisibleLine() }
        }
    }

    public var text: String { textView.text }

    public var selectedRange: NSRange {
        get { textView.selectedRange }
        set { textView.selectedRange = newValue }
    }

    /// Called on the main thread when highlighting for the loaded text is ready.
    public var onHighlighted: (() -> Void)?

    /// Shows text first, highlighting second: line data is built off the main thread and shown as plain
    /// text (first paint), then the tree-sitter language mode is attached and parses on its own
    /// background queue, coloring the visible lines when it finishes. Later loads cancel earlier ones.
    /// Loads a file's text; `marks` (its diagnostics) replace the previous file's.
    public func load(_ text: String, language: Language?, marks: [EditorMark] = []) {
        self.language = language
        loadGeneration += 1
        let generation = loadGeneration
        let marksAtStart = marksVersion
        let box = UncheckedState()
        box.theme = theme
        Task.detached(priority: .userInitiated) {
            guard let theme = box.theme else { return }
            box.state = TextViewState(text: text, theme: theme)
            await MainActor.run {
                guard generation == self.loadGeneration, let state = box.state else { return }
                self.textView.setState(state)
                // Newer marks (set while this loaded) win over the ones passed in.
                self.setMarks(self.marksVersion == marksAtStart ? marks : self.marks)
                self.refreshMinimap()
                self.onLoaded?()
                guard let language else {
                    self.onHighlighted?()
                    return
                }
                let mode = TreeSitterLanguageMode(language: Self.treeSitterLanguage(language))
                self.textView.setLanguageMode(mode) { [weak self] _ in
                    guard let self, generation == self.loadGeneration else { return }
                    self.onHighlighted?()
                }
            }
        }
    }

    public func scrollRangeToVisible(_ range: NSRange) { textView.scrollRangeToVisible(range) }

    // MARK: Ghost text

    /// Shows `text` after the caret, if the caret is still an insertion point at `location` with
    /// nothing but whitespace after it on its line. Single line only.
    public func showGhostText(_ text: String, at location: Int) {
        let selection = textView.selectedRange
        guard !text.isEmpty, !text.contains(where: \.isNewline), selection.length == 0, selection.location == location,
              let start = textView.position(from: textView.beginningOfDocument, offset: location),
              Self.restOfLineIsBlank(textView.text as NSString, from: location) else { return }
        let caret = textView.caretRect(for: start)
        ghostText = text
        ghostLocation = location
        ghostLabel.font = theme.font
        ghostLabel.textColor = theme.palette.text.tertiary.uiColor
        ghostLabel.text = text
        ghostLabel.sizeToFit()
        ghostLabel.frame.origin = CGPoint(x: caret.maxX + 1, y: caret.midY - ghostLabel.frame.height / 2)
        ghostLabel.isHidden = false
        UIAccessibility.post(notification: .announcement, argument: "Suggestion: \(text). Press Tab to accept.")
    }

    public func clearGhostText() {
        guard ghostText != nil else { return }
        ghostText = nil
        ghostLabel.isHidden = true
    }

    public static func restOfLineIsBlank(_ text: NSString, from location: Int) -> Bool {
        guard location <= text.length else { return false }
        let line = text.lineRange(for: NSRange(location: location, length: 0))
        let rest = text.substring(with: NSRange(location: location, length: NSMaxRange(line) - location))
        return rest.allSatisfy(\.isWhitespace)
    }

    // MARK: TextViewDelegate

    public func textViewDidChange(_ textView: TextView) {
        clearGhostText()
        refreshMinimap(debounce: true)
        onChange?()
    }

    public func textViewDidChangeSelection(_ textView: TextView) {
        if ghostText != nil, textView.selectedRange != NSRange(location: ghostLocation, length: 0) { clearGhostText() }
        onSelectionChange?(textView.selectedRange)
    }

    /// Tab with a suggestion showing inserts the suggestion instead of a tab.
    public func textView(_ textView: TextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
        guard text == "\t", let ghost = ghostText, range == NSRange(location: ghostLocation, length: 0) else { return true }
        clearGhostText()
        // Insert outside this callback; the engine is mid-edit.
        DispatchQueue.main.async { [weak self] in
            self?.textView.insertText(ghost)
            self?.onGhostAccepted?(ghost)
        }
        return false
    }

    // MARK: Helpers

    static let pairs: [CharacterPair] = [("(", ")"), ("[", "]"), ("{", "}"), ("\"", "\""), ("'", "'"), ("`", "`")]
        .map { SimplePair(leading: $0.0, trailing: $0.1) }

    static func treeSitterLanguage(_ language: Language) -> TreeSitterLanguage {
        TreeSitterLanguage(language.grammar,
                           highlightsQuery: language.highlightsQuery.map { .init(string: $0) },
                           injectionsQuery: language.injectionsQuery.map { .init(string: $0) })
    }
}

private struct SimplePair: CharacterPair {
    let leading: String
    let trailing: String
}

/// Runestone's types aren't Sendable. The theme is immutable once built, and the
/// state is built on one task and handed to the main actor once, so a single handoff box is safe.
private final class UncheckedState: @unchecked Sendable {
    var theme: EditorTheme?
    var state: TextViewState?
}

/// The editor's minimap, for placing beside `CodeEditor`.
public struct MinimapStrip: UIViewRepresentable {
    public let controller: CodeEditorController
    public init(controller: CodeEditorController) { self.controller = controller }
    public func makeUIView(context: Context) -> MinimapView { controller.minimap }
    public func updateUIView(_ uiView: MinimapView, context: Context) {}
}

/// SwiftUI wrapper. The controller owns the text; the app reads `controller.text` when saving.
public struct CodeEditor: UIViewRepresentable {
    public let controller: CodeEditorController

    public init(controller: CodeEditorController) { self.controller = controller }

    public func makeUIView(context: Context) -> TextView { controller.textView }
    public func updateUIView(_ uiView: TextView, context: Context) {}
}
