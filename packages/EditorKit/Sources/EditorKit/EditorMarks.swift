// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

import DesignKit
import Foundation
import Runestone
import UIKit

/// What Omnie-dev draws on top of code: diagnostics, diff state and authorship (PLAN §3.8).
/// Ranges are UTF-16 offsets into the editor's text and move with edits.
public struct EditorMark: Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        case error, warning, info
        /// Lines the agent wrote: the violet author bar (the two-authors rule).
        case agentLines
        /// Diff state in the gutter.
        case added, modified, removed
        /// A changed hunk's background (added or removed text), for diff review.
        case addedText, removedText
    }

    public var id: String
    public var range: NSRange
    public var kind: Kind

    public init(id: String = UUID().uuidString, range: NSRange, kind: Kind) {
        self.id = id
        self.range = range
        self.kind = kind
    }

    func decoration(in palette: Palette) -> Decoration {
        let style: Decoration.Style = switch kind {
        case .error: .squiggle(palette.status.error.uiColor)
        case .warning: .dottedUnderline(palette.status.warn.uiColor)
        case .info: .gutterDot(palette.accent.ion.uiColor)
        case .agentLines: .gutterBar(palette.accent.agent.uiColor)
        case .added: .gutterBar(palette.status.ok.uiColor)
        case .modified: .gutterBar(palette.status.warn.uiColor)
        case .removed: .gutterBar(palette.status.error.uiColor)
        case .addedText: .background(palette.diff.addedBg.uiColor)
        case .removedText: .background(palette.diff.removedBg.uiColor)
        }
        return Decoration(id: id, range: range, style: style)
    }
}

extension CodeEditorController {
    /// Replaces all marks. Cheap to call often: only marks in view are laid out.
    public func setMarks(_ marks: [EditorMark]) {
        self.marks = marks
        textView.decorations = marks.map { $0.decoration(in: theme.palette) }
    }
}
