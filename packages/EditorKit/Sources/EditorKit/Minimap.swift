// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

import DesignKit
import Runestone
import UIKit

/// The minimap's geometry (PLAN.md §5.1): one row per line, its indent and length as a bar, marks
/// as ticks, and the visible part of the editor as a band. Pure, so it's tested without a view.
public struct Minimap: Sendable, Equatable {
    public struct Line: Sendable, Equatable {
        public var indent: Int
        public var length: Int
        public var start: Int
    }

    public var lines: [Line]

    /// Rows are this tall while the file fits; longer files are squeezed to the map's height.
    public static let rowHeight: CGFloat = 2
    /// Characters across the map (longer lines are cut there).
    public static let columns = 100

    public init(text: String) {
        // indent and length are columns (a leading tab is 4); start is a UTF-16 offset.
        var lines: [Line] = []
        var start = 0, units = 0, indent = 0, length = 0, leading = true
        for unit in text.utf16 {
            if unit == 0x0A {
                lines.append(Line(indent: leading ? 0 : indent, length: leading ? 0 : length, start: start))
                start += units + 1
                units = 0; indent = 0; length = 0; leading = true
                continue
            }
            units += 1
            if leading, unit == 0x20 || unit == 0x09 {
                let width = unit == 0x09 ? 4 : 1
                indent += width; length += width
            } else {
                leading = false
                length += 1
            }
        }
        // A line of only spaces draws nothing.
        lines.append(Line(indent: leading ? 0 : indent, length: leading ? 0 : length, start: start))
        self.lines = lines
    }

    /// The row height for a map `height` points tall.
    public func rowHeight(in height: CGFloat) -> CGFloat {
        min(Self.rowHeight, height / CGFloat(max(lines.count, 1)))
    }

    /// The line holding UTF-16 offset `location`.
    public func line(at location: Int) -> Int {
        var low = 0, high = lines.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if lines[mid].start <= location { low = mid } else { high = mid - 1 }
        }
        return max(0, low)
    }

    /// The band showing what the editor shows: its top and height in the map.
    public func viewport(offset: CGFloat, contentHeight: CGFloat, visibleHeight: CGFloat, mapHeight: CGFloat) -> (y: CGFloat, height: CGFloat) {
        let drawn = CGFloat(lines.count) * rowHeight(in: mapHeight)
        guard contentHeight > 0 else { return (0, drawn) }
        let y = max(0, offset) / contentHeight * drawn
        return (y, max(8, min(drawn, visibleHeight / contentHeight * drawn)))
    }

    /// The editor offset that centres the band on map point `y` (a tap or a drag).
    public func offset(forMapY y: CGFloat, contentHeight: CGFloat, visibleHeight: CGFloat, mapHeight: CGFloat) -> CGFloat {
        let drawn = CGFloat(lines.count) * rowHeight(in: mapHeight)
        guard drawn > 0 else { return 0 }
        let fraction = min(max(y / drawn, 0), 1)
        return min(max(0, fraction * contentHeight - visibleHeight / 2), max(0, contentHeight - visibleHeight))
    }
}

/// The minimap beside the editor: tap or drag to scroll there. VoiceOver reads it as an adjustable
/// element that pages the editor.
public final class MinimapView: UIView {
    private weak var textView: TextView?
    private var map = Minimap(text: "")
    private var marks: [(line: Int, kind: EditorMark.Kind)] = []
    private var palette: Palette
    private var offsetObservation: NSKeyValueObservation?
    private var sizeObservation: NSKeyValueObservation?

    init(textView: TextView, palette: Palette) {
        self.textView = textView
        self.palette = palette
        super.init(frame: .zero)
        isOpaque = true
        contentMode = .redraw
        isAccessibilityElement = true
        accessibilityLabel = "Minimap"
        accessibilityTraits = .adjustable
        accessibilityHint = "Swipe up or down to page through the file"
        offsetObservation = textView.observe(\.contentOffset, options: [.new]) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.setNeedsDisplay() }
        }
        sizeObservation = textView.observe(\.contentSize, options: [.new]) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.setNeedsDisplay() }
        }
        addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(scrollTo(_:))))
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(scrollTo(_:))))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func update(text: String, marks: [EditorMark]) {
        map = Minimap(text: text)
        self.marks = marks.compactMap { mark in
            switch mark.kind {
            case .error, .warning, .added, .modified, .agentLines: (map.line(at: mark.range.location), mark.kind)
            default: nil
            }
        }
        updateAccessibility()
        setNeedsDisplay()
    }

    func update(palette: Palette) {
        self.palette = palette
        setNeedsDisplay()
    }

    @objc private func scrollTo(_ gesture: UIGestureRecognizer) {
        guard let textView else { return }
        let y = gesture.location(in: self).y
        let offset = map.offset(forMapY: y, contentHeight: textView.contentSize.height,
                                visibleHeight: textView.bounds.height, mapHeight: bounds.height)
        textView.setContentOffset(CGPoint(x: textView.contentOffset.x, y: offset), animated: gesture is UITapGestureRecognizer)
    }

    public override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        palette.surface.editor.uiColor.setFill()
        context.fill(bounds)
        let row = map.rowHeight(in: bounds.height)
        let unit = (bounds.width - 6) / CGFloat(Minimap.columns)
        let first = max(0, Int(rect.minY / row)), last = min(map.lines.count, Int(rect.maxY / row) + 1)
        palette.text.tertiary.uiColor.withAlphaComponent(0.55).setFill()
        if first < last {
            for i in first..<last {
                let line = map.lines[i]
                guard line.length > line.indent else { continue }
                let x = 3 + CGFloat(min(line.indent, Minimap.columns)) * unit
                let width = CGFloat(min(line.length, Minimap.columns) - min(line.indent, Minimap.columns)) * unit
                context.fill(CGRect(x: x, y: CGFloat(i) * row, width: max(width, 1), height: max(row * 0.7, 0.5)))
            }
        }
        // Marks: a tick at the right edge, full row height at least 2 pt so a squeezed map still shows them.
        for mark in marks {
            let color: UIColor = switch mark.kind {
            case .error: palette.status.error.uiColor
            case .warning: palette.status.warn.uiColor
            case .agentLines: palette.accent.agent.uiColor
            default: palette.status.ok.uiColor
            }
            color.setFill()
            context.fill(CGRect(x: bounds.width - 4, y: CGFloat(mark.line) * row, width: 3, height: max(row, 2)))
        }
        if let textView {
            let band = map.viewport(offset: textView.contentOffset.y, contentHeight: textView.contentSize.height,
                                    visibleHeight: textView.bounds.height, mapHeight: bounds.height)
            palette.text.primary.uiColor.withAlphaComponent(0.08).setFill()
            context.fill(CGRect(x: 0, y: band.y, width: bounds.width, height: band.height))
        }
        palette.surface.hairline.uiColor.setFill()
        context.fill(CGRect(x: 0, y: 0, width: 1 / max(traitCollection.displayScale, 1), height: bounds.height))
    }

    public override func accessibilityIncrement() { page(by: 1) }
    public override func accessibilityDecrement() { page(by: -1) }

    private func page(by direction: CGFloat) {
        guard let textView else { return }
        let maxOffset = max(0, textView.contentSize.height - textView.bounds.height)
        let target = min(max(0, textView.contentOffset.y + direction * textView.bounds.height * 0.9), maxOffset)
        textView.setContentOffset(CGPoint(x: textView.contentOffset.x, y: target), animated: false)
        updateAccessibility()
    }

    private func updateAccessibility() {
        guard let textView, textView.contentSize.height > 0 else { return }
        let first = Int(textView.contentOffset.y / textView.contentSize.height * CGFloat(map.lines.count)) + 1
        accessibilityValue = "Line \(max(1, min(first, map.lines.count))) of \(map.lines.count)"
    }
}
