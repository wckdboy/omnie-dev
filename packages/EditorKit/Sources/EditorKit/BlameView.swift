// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

import DesignKit
import Runestone
import UIKit

/// One run of lines for the blame column: who and when, as the app words it.
public struct BlameEntry: Sendable, Hashable {
    public var startLine: Int
    public var lineCount: Int
    /// "Ana · 3 days" or "You · not committed".
    public var label: String
    /// The commit, for the tap; nil when not committed.
    public var commit: String?
    /// Written by the agent: the violet tint (PLAN.md §9.10).
    public var isAgent: Bool

    public init(startLine: Int, lineCount: Int, label: String, commit: String?, isAgent: Bool) {
        self.startLine = startLine; self.lineCount = lineCount; self.label = label; self.commit = commit; self.isAgent = isAgent
    }
}

/// The blame column beside the code, scrolled with it: each run's label at its first visible
/// line, and a bar down the run. Tap a run to open its commit.
public final class BlameView: UIView {
    private weak var textView: TextView?
    private var entries: [BlameEntry] = []
    private var palette: Palette
    private var font: UIFont
    /// Text y of a 1-based line, in the text view's content coordinates.
    var lineY: (Int) -> CGFloat? = { _ in nil }
    var onTap: ((String) -> Void)?
    private var observation: NSKeyValueObservation?

    init(textView: TextView, palette: Palette, font: UIFont) {
        self.textView = textView
        self.palette = palette
        self.font = font
        super.init(frame: .zero)
        isOpaque = true
        contentMode = .redraw
        observation = textView.observe(\.contentOffset, options: [.new]) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.setNeedsDisplay() }
        }
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped(_:))))
        isAccessibilityElement = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func update(entries: [BlameEntry]) {
        self.entries = entries
        setNeedsDisplay()
        updateAccessibility()
    }

    func update(palette: Palette, font: UIFont) {
        self.palette = palette
        self.font = font
        setNeedsDisplay()
    }

    /// The runs on screen, with their y range in this view.
    private func visibleRuns() -> [(entry: BlameEntry, top: CGFloat, bottom: CGFloat)] {
        guard let textView else { return [] }
        let offset = textView.contentOffset.y
        let height = bounds.height
        var runs: [(BlameEntry, CGFloat, CGFloat)] = []
        for entry in entries {
            guard let start = lineY(entry.startLine) else { continue }
            let end = lineY(entry.startLine + entry.lineCount) ?? (start + CGFloat(entry.lineCount) * font.lineHeight * 1.2)
            let top = start - offset, bottom = end - offset
            if bottom < 0 { continue }
            if top > height { break }
            runs.append((entry, top, bottom))
        }
        return runs
    }

    public override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        palette.surface.editor.uiColor.setFill()
        context.fill(bounds)
        let small = font.withSize(max(10, font.pointSize - 2))
        for (entry, top, bottom) in visibleRuns() {
            let color: UIColor = entry.isAgent ? palette.accent.agent.uiColor
                : entry.commit == nil ? palette.accent.ion.uiColor : palette.text.tertiary.uiColor
            color.withAlphaComponent(entry.isAgent || entry.commit == nil ? 0.9 : 0.35).setFill()
            context.fill(CGRect(x: bounds.width - 3, y: top + 1, width: 2, height: max(2, bottom - top - 2)))
            // The label at the run's first visible line.
            let y = max(top, 0)
            guard y + small.lineHeight <= bottom || entry.lineCount == 1 else { continue }
            let attributes: [NSAttributedString.Key: Any] = [
                .font: small,
                .foregroundColor: entry.isAgent ? palette.accent.agent.uiColor : palette.text.secondary.uiColor,
            ]
            (entry.label as NSString).draw(with: CGRect(x: 6, y: y + 2, width: bounds.width - 14, height: small.lineHeight),
                                           options: [.truncatesLastVisibleLine, .usesLineFragmentOrigin], attributes: attributes, context: nil)
        }
        palette.surface.hairline.uiColor.setFill()
        context.fill(CGRect(x: bounds.width - 1 / max(traitCollection.displayScale, 1), y: 0, width: 1 / max(traitCollection.displayScale, 1), height: bounds.height))
    }

    @objc private func tapped(_ gesture: UITapGestureRecognizer) {
        let y = gesture.location(in: self).y
        if let run = visibleRuns().first(where: { $0.top <= y && y < $0.bottom }), let commit = run.entry.commit { onTap?(commit) }
    }

    /// VoiceOver: one element per run on screen.
    private func updateAccessibility() {
        accessibilityElements = visibleRuns().map { run in
            let element = UIAccessibilityElement(accessibilityContainer: self)
            element.accessibilityLabel = "Lines \(run.entry.startLine) to \(run.entry.startLine + run.entry.lineCount - 1): \(run.entry.label)\(run.entry.isAgent ? ", written by the agent" : "")"
            element.accessibilityFrameInContainerSpace = CGRect(x: 0, y: max(0, run.top), width: bounds.width, height: max(20, run.bottom - max(0, run.top)))
            if run.entry.commit != nil { element.accessibilityTraits = .button }
            return element
        }
    }
}
