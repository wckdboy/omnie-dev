// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Runestone
import UIKit

/// A foldable block: its header row stays visible, rows `header + 1 ... last` fold away (0-based).
public struct FoldRegion: Sendable, Hashable {
    public let header: Int
    public let last: Int

    public init(header: Int, last: Int) {
        self.header = header
        self.last = last
    }
}

/// Where code folds, as VS Code finds it without a language server: by indentation (a line
/// followed by more-indented lines folds them; a closing brace at the header's indent stays
/// visible), and Markdown by headings (a heading folds everything up to the next heading of the
/// same or a higher level).
public enum FoldRegions {
    public static func compute(_ text: String, markdown: Bool = false, tabWidth: Int = 4) -> [FoldRegion] {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        return markdown ? headings(lines) : indentation(lines, tabWidth: tabWidth)
    }

    static func indent(_ line: String, tabWidth: Int) -> Int? {
        var width = 0
        for c in line {
            if c == " " { width += 1 } else if c == "\t" { width += tabWidth - width % tabWidth } else { return width }
        }
        return nil   // blank
    }

    static func indentation(_ lines: [String], tabWidth: Int) -> [FoldRegion] {
        let indents = lines.map { indent($0, tabWidth: tabWidth) }
        var regions: [FoldRegion] = []
        // Open headers: (row, indent), innermost last.
        var stack: [(row: Int, indent: Int)] = []
        var lastContent = -1
        func close(above indent: Int) {
            while let top = stack.last, top.indent >= indent {
                stack.removeLast()
                if lastContent > top.row { regions.append(FoldRegion(header: top.row, last: lastContent)) }
            }
        }
        for (row, level) in indents.enumerated() {
            guard let level else { continue }   // blank lines belong to whatever block they're in
            // A line at or left of an open header's indent ends that header's block.
            if let previous = stack.last, level <= previous.indent {
                close(above: level)
            }
            lastContent = row
            // Every content line may head a block; it's dropped if nothing indented follows.
            stack.append((row, level))
        }
        close(above: Int.min)
        // Only regions with something to hide, outermost first.
        return regions.filter { $0.last > $0.header }.sorted { ($0.header, -$0.last) < ($1.header, -$1.last) }
    }

    static func headings(_ lines: [String]) -> [FoldRegion] {
        var regions: [FoldRegion] = []
        var open: [(row: Int, level: Int)] = []
        var lastContent = -1
        var inFence = false
        for (row, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") { inFence.toggle() }
            let level = inFence ? 0 : line.prefix { $0 == "#" }.count
            if (1...6).contains(level), line.dropFirst(level).first == " " {
                while let top = open.last, top.level >= level {
                    open.removeLast()
                    if lastContent > top.row { regions.append(FoldRegion(header: top.row, last: lastContent)) }
                }
                open.append((row, level))
            }
            if !trimmed.isEmpty { lastContent = row }
        }
        while let top = open.popLast() {
            if lastContent > top.row { regions.append(FoldRegion(header: top.row, last: lastContent)) }
        }
        return regions.sorted { ($0.header, -$0.last) < ($1.header, -$1.last) }
    }

    /// UTF-16 offset of each row's start.
    public static func lineStarts(_ text: String) -> [Int] {
        var starts = [0], offset = 0
        for unit in text.utf16 {
            offset += 1
            if unit == 0x0A { starts.append(offset) }
        }
        return starts
    }

    /// The characters a region hides: its rows after the header, newline included.
    public static func range(of region: FoldRegion, lineStarts starts: [Int], length: Int) -> NSRange {
        let start = starts[min(region.header + 1, starts.count - 1)]
        let end = region.last + 1 < starts.count ? starts[region.last + 1] : length
        return NSRange(location: start, length: max(0, end - start))
    }

    /// The row containing a UTF-16 offset.
    public static func row(of location: Int, lineStarts starts: [Int]) -> Int {
        var low = 0, high = starts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if starts[mid] <= location { low = mid } else { high = mid - 1 }
        }
        return low
    }
}

// MARK: Folding in the editor

extension CodeEditorController {
    /// The open file's foldable blocks (recomputed after loads and edits).
    public var foldRegions: [FoldRegion] { folding.regions }

    /// Folded blocks' header rows.
    public var foldedHeaders: [Int] {
        let starts = FoldRegions.lineStarts(textView.text)
        return textView.foldedRanges.map { FoldRegions.row(of: $0.location, lineStarts: starts) - 1 }
    }

    /// Recomputes the blocks from the text, off the main thread.
    func refreshFoldRegions(debounce: Bool) {
        folding.refresh?.cancel()
        let text = textView.text
        let markdown = isMarkdown
        folding.refresh = Task { [weak self] in
            if debounce { try? await Task.sleep(for: .milliseconds(300)) }
            guard !Task.isCancelled else { return }
            let regions = await Task.detached(priority: .utility) { FoldRegions.compute(text, markdown: markdown) }.value
            guard let self, !Task.isCancelled, self.textView.text == text else { return }
            self.folding.regions = regions
            if !self.folding.pending.isEmpty {
                let headers = Set(self.folding.pending)
                self.folding.pending = []
                let starts = FoldRegions.lineStarts(text)
                let length = (text as NSString).length
                // Outermost region per saved header; ones that no longer exist are skipped.
                var ranges: [NSRange] = []
                for header in headers.sorted() {
                    if let region = regions.filter({ $0.header == header }).max(by: { $0.last < $1.last }) {
                        ranges.append(FoldRegions.range(of: region, lineStarts: starts, length: length))
                    }
                }
                self.textView.foldedRanges = ranges
                self.keepCaretVisible()
            }
            self.applyFoldChevrons()
        }
    }

    /// The blocks now, if the background pass hasn't finished yet (a fold command right after a load).
    private func ensureRegions() {
        guard folding.regions.isEmpty, !isLoading else { return }
        folding.regions = FoldRegions.compute(textView.text, markdown: isMarkdown)
    }

    /// The innermost block whose header is `row`, or that contains it.
    func region(at row: Int, containing: Bool) -> FoldRegion? {
        ensureRegions()
        let candidates = folding.regions.filter { containing ? ($0.header <= row && row <= $0.last) : $0.header == row }
        return candidates.min { ($0.last - $0.header) < ($1.last - $1.header) }
    }

    private func range(of region: FoldRegion) -> NSRange {
        let text = textView.text
        return FoldRegions.range(of: region, lineStarts: FoldRegions.lineStarts(text), length: (text as NSString).length)
    }

    private func isFolded(_ region: FoldRegion) -> Bool {
        textView.foldedRanges.contains { $0.location == range(of: region).location }
    }

    /// Folds or unfolds the block headed at `row`; false when nothing folds there.
    @discardableResult
    public func toggleFold(atRow row: Int) -> Bool {
        guard let region = region(at: row, containing: false) else { return false }
        setFolded(region, !isFolded(region))
        return true
    }

    /// Folds the blocks headed by these rows once the file's blocks are known (a restored session,
    /// coming back to a tab).
    public func restoreFolds(_ headers: [Int]) {
        folding.pending = headers
    }

    /// ⌥⌘[: the innermost open block around the caret (or headed by its line).
    public func foldAtCaret() {
        ensureRegions()
        let row = caretRow
        let open = folding.regions.filter { ($0.header == row || ($0.header < row && row <= $0.last)) && !isFolded($0) }
        guard let region = open.min(by: { ($0.last - $0.header) < ($1.last - $1.header) }) else { return }
        // Folding a block the caret is inside moves the caret to its header first.
        if row > region.header {
            let starts = FoldRegions.lineStarts(textView.text)
            selectedRange = NSRange(location: starts[region.header], length: 0)
        }
        setFolded(region, true)
    }

    /// ⌥⌘]: the folded block headed by the caret's line.
    public func unfoldAtCaret() {
        let row = caretRow
        guard let region = folding.regions.first(where: { $0.header == row && isFolded($0) }) else { return }
        setFolded(region, false)
    }

    /// Folds every outermost block (as VS Code's Fold All shows the file's outline).
    public func foldAll() {
        ensureRegions()
        var covered = -1
        var ranges: [NSRange] = []
        for region in folding.regions.sorted(by: { $0.header < $1.header }) where region.header > covered {
            ranges.append(range(of: region))
            covered = region.last
        }
        textView.foldedRanges = ranges
        keepCaretVisible()
        applyFoldChevrons()
    }

    public func unfoldAll() {
        textView.foldedRanges = []
        applyFoldChevrons()
    }

    private func setFolded(_ region: FoldRegion, _ folded: Bool) {
        let target = range(of: region)
        var ranges = textView.foldedRanges.filter { NSIntersectionRange($0, target).length == 0 || !folded && $0.location != target.location }
        if folded {
            // A fold inside this one is swallowed by it.
            ranges.removeAll { $0.location >= target.location && $0.upperBound <= target.upperBound }
            ranges.append(target)
        } else {
            ranges.removeAll { $0.location == target.location }
        }
        textView.foldedRanges = ranges
        applyFoldChevrons()
    }

    var caretRow: Int { FoldRegions.row(of: textView.selectedRange.location, lineStarts: FoldRegions.lineStarts(textView.text)) }

    /// Arrow keys step over a fold, as in VS Code: coming from above lands on the line after it,
    /// from below on its header, at the same column. Returns whether the caret was moved.
    func skipOverFold() -> Bool {
        defer { folding.lastCaret = textView.selectedRange.location }
        let caret = textView.selectedRange
        guard caret.length == 0, let previous = folding.lastCaret,
              let fold = textView.foldedRanges.first(where: { caret.location >= $0.location && caret.location < $0.upperBound }) else { return false }
        let text = textView.text
        let starts = FoldRegions.lineStarts(text)
        let length = (text as NSString).length
        let column = previous - starts[FoldRegions.row(of: previous, lineStarts: starts)]
        let targetRow: Int
        if previous < fold.location {
            targetRow = FoldRegions.row(of: min(fold.upperBound, length), lineStarts: starts)
            // The fold runs to the end of the file: stay on its header instead.
            if fold.upperBound >= length && (fold.upperBound == 0 || (text as NSString).character(at: length - 1) != 10) {
                return jump(toRow: FoldRegions.row(of: fold.location, lineStarts: starts) - 1, column: column, starts: starts, length: length)
            }
        } else {
            targetRow = FoldRegions.row(of: fold.location, lineStarts: starts) - 1
        }
        return jump(toRow: targetRow, column: column, starts: starts, length: length)
    }

    private func jump(toRow row: Int, column: Int, starts: [Int], length: Int) -> Bool {
        guard row >= 0, row < starts.count else { return false }
        let lineEnd = row + 1 < starts.count ? starts[row + 1] - 1 : length
        textView.selectedRange = NSRange(location: min(starts[row] + column, lineEnd), length: 0)
        return true
    }

    /// The caret never rests inside a fold: a jump into one (Go to Definition, Find) unfolds it.
    func unfoldAroundCaret() {
        guard !textView.foldedRanges.isEmpty else { return }
        let caret = textView.selectedRange
        let hit = textView.foldedRanges.filter { caret.location >= $0.location && caret.location < $0.upperBound
            || (caret.length > 0 && NSIntersectionRange(caret, $0).length > 0) }
        guard !hit.isEmpty else { return }
        textView.foldedRanges.removeAll { range in hit.contains(range) }
        applyFoldChevrons()
    }

    func keepCaretVisible() {
        guard let fold = textView.foldedRanges.first(where: { textView.selectedRange.location >= $0.location && textView.selectedRange.location < $0.upperBound }) else { return }
        selectedRange = NSRange(location: max(0, fold.location - 1), length: 0)
    }

    /// Chevrons in the gutter: › on folded blocks, a faint ⌄ on the open ones. Also where fold
    /// changes are reported (the app keeps them with the session).
    func applyFoldChevrons() {
        let headers = foldedHeaders
        if headers != folding.reported {
            folding.reported = headers
            onFoldsChanged?()
        }
        let text = textView.text
        let starts = FoldRegions.lineStarts(text)
        let length = (text as NSString).length
        let folded = Set(textView.foldedRanges.map(\.location))
        var seenHeaders = Set<Int>()
        folding.chevrons = folding.regions.compactMap { region -> Decoration? in
            guard region.header < starts.count, seenHeaders.insert(region.header).inserted else { return nil }
            let headerStart = starts[region.header]
            let isFolded = folded.contains(FoldRegions.range(of: region, lineStarts: starts, length: length).location)
            let color = isFolded ? theme.palette.accent.ion.uiColor : theme.palette.text.tertiary.uiColor.withAlphaComponent(0.55)
            return Decoration(id: "fold-\(region.header)", range: NSRange(location: headerStart, length: 0),
                              style: .gutterChevron(color, folded: isFolded),
                              accessibilityLabel: isFolded ? "Folded, \(region.last - region.header) lines" : nil)
        }
        // "⋯" after each folded block's first line.
        for fold in textView.foldedRanges where fold.location > 0 {
            folding.chevrons.append(Decoration(id: "fold-p-\(fold.location)", range: NSRange(location: fold.location - 1, length: 0),
                                               style: .foldPlaceholder(theme.palette.accent.ion.uiColor)))
        }
        let others = textView.decorations.filter { !$0.id.hasPrefix("fold-") }
        textView.decorations = others + folding.chevrons
    }

    /// A tap in the gutter on a block's header folds or unfolds it.
    func installFoldGesture() {
        let tap = UITapGestureRecognizer(target: folding, action: #selector(FoldingState.gutterTapped(_:)))
        tap.delegate = folding
        tap.cancelsTouchesInView = false
        folding.controller = self
        textView.addGestureRecognizer(tap)
    }

    /// Where a fold's "⋯" is drawn, in the text view's coordinates.
    func placeholderRect(for fold: NSRange) -> CGRect? {
        guard fold.location > 0, let position = textView.position(from: textView.beginningOfDocument, offset: fold.location - 1) else { return nil }
        let caret = textView.caretRect(for: position)
        return CGRect(x: caret.maxX + 2, y: caret.minY - 4, width: 32, height: caret.height + 8)
    }

    /// The fold whose "⋯" is at a point.
    func fold(atPlaceholder point: CGPoint) -> NSRange? {
        textView.foldedRanges.first { placeholderRect(for: $0)?.contains(point) == true }
    }

    /// A chevron (in the gutter, on a block's header) or a "⋯".
    func isFoldTarget(_ point: CGPoint) -> Bool {
        if fold(atPlaceholder: point) != nil { return true }
        guard point.x < textView.gutterWidth,
              let position = textView.closestPosition(to: CGPoint(x: textView.gutterWidth + 4, y: point.y)) else { return false }
        let offset = textView.offset(from: textView.beginningOfDocument, to: position)
        return region(at: FoldRegions.row(of: offset, lineStarts: FoldRegions.lineStarts(textView.text)), containing: false) != nil
    }

    func handleGutterTap(at point: CGPoint) -> Bool {
        if let fold = fold(atPlaceholder: point) {
            textView.foldedRanges.removeAll { $0 == fold }
            applyFoldChevrons()
            return true
        }
        guard point.x < textView.gutterWidth, let position = textView.closestPosition(to: CGPoint(x: textView.gutterWidth + 4, y: point.y)) else { return false }
        let offset = textView.offset(from: textView.beginningOfDocument, to: position)
        return toggleFold(atRow: FoldRegions.row(of: offset, lineStarts: FoldRegions.lineStarts(textView.text)))
    }
}

/// The controller's folding state (regions, chevrons, the gutter tap's target).
final class FoldingState: NSObject, UIGestureRecognizerDelegate {
    var regions: [FoldRegion] = []
    var chevrons: [Decoration] = []
    /// Folds to apply when the regions are next computed (by header row).
    var pending: [Int] = []
    /// The folds last reported through `onFoldsChanged`.
    var reported: [Int] = []
    /// Where the caret was before the latest move (to tell which way it entered a fold).
    var lastCaret: Int?
    var refresh: Task<Void, Never>?
    weak var controller: CodeEditorController?

    @MainActor @objc func gutterTapped(_ recognizer: UITapGestureRecognizer) {
        guard let controller else { return }
        _ = controller.handleGutterTap(at: recognizer.location(in: controller.textView))
    }

    /// Only touches on a chevron (the gutter, on a line that heads a block) or a "⋯" reach it, so
    /// taps anywhere else go straight to the editor, with no delay.
    nonisolated func gestureRecognizer(_ recognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        MainActor.assumeIsolated {
            guard let controller, let view = recognizer.view else { return false }
            return controller.isFoldTarget(touch.location(in: view))
        }
    }

    /// It runs beside the editor's own tap (which may put the caret on that line: never inside the fold).
    nonisolated func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
}
