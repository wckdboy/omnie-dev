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
    func load(_ text: String, language: Language?)
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
    /// Marks as last set; their live ranges are in `textView.decorations`.
    var marks: [EditorMark] = []

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
    public func load(_ text: String, language: Language?) {
        self.language = language
        loadGeneration += 1
        let generation = loadGeneration
        let box = UncheckedState()
        box.theme = theme
        Task.detached(priority: .userInitiated) {
            guard let theme = box.theme else { return }
            box.state = TextViewState(text: text, theme: theme)
            await MainActor.run {
                guard generation == self.loadGeneration, let state = box.state else { return }
                self.textView.setState(state)
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

/// SwiftUI wrapper. The controller owns the text; the app reads `controller.text` when saving.
public struct CodeEditor: UIViewRepresentable {
    public let controller: CodeEditorController

    public init(controller: CodeEditorController) { self.controller = controller }

    public func makeUIView(context: Context) -> TextView { controller.textView }
    public func updateUIView(_ uiView: TextView, context: Context) {}
}
