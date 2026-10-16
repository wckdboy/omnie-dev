// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

import DesignKit
import Foundation
import Testing
import UIKit
@testable import EditorKit

/// Budgets for the editor on a large file (PLAN.md §20). The numbers are deliberately generous —
/// this is a regression guard, not a benchmark — but a change that makes any of these linear in a
/// bad way (a per-region re-scan, an O(n²) fold, a full re-parse per keystroke) will blow past them.
/// Measured values are printed so a slow drift is visible in CI logs.
@MainActor
struct PerformanceTests {
    /// ~0.8 M characters, ~20 000 lines, ~2 000 foldable blocks ("needle" appears on most lines).
    static func largeFile(lines: Int = 20_000) -> String {
        var text = ""
        text.reserveCapacity(lines * 44)
        for i in 0..<lines {
            switch i % 10 {
            case 0: text += "function block\(i) {\n"
            case 9: text += "}\n"
            default: text += "  const value\(i) = compute(\(i), \"needle\");\n"
            }
        }
        return text
    }

    private func loadedEditor(_ text: String) async -> CodeEditorController {
        let editor = CodeEditorController(theme: EditorTheme(palette: .dark, density: .regular))
        editor.textView.frame = CGRect(x: 0, y: 0, width: 800, height: 600)
        var loaded = false
        editor.onLoaded = { loaded = true }
        editor.load(text, language: nil)
        for _ in 0..<600 where !loaded || editor.foldRegions.isEmpty { try? await Task.sleep(for: .milliseconds(10)) }
        return editor
    }

    @Test func foldAllOnALargeFileIsBounded() async {
        let editor = await loadedEditor(Self.largeFile())
        #expect(editor.foldRegions.count > 1_000, "the fixture should have many blocks")
        let elapsed = ContinuousClock().measure { editor.foldAll() }
        print("[perf] fold-all (\(editor.foldRegions.count) blocks, \(editor.foldedHeaders.count) folds): \(elapsed)")
        #expect(elapsed < .seconds(2))
    }

    @Test func findAllInALargeFileIsBounded() async {
        let editor = await loadedEditor(Self.largeFile())
        var matches = 0
        let elapsed = ContinuousClock().measure { matches = editor.searchRanges("needle", caseSensitive: false).count }
        print("[perf] find-all (\(matches) matches): \(elapsed)")
        #expect(matches > 10_000)
        #expect(elapsed < .seconds(1))
    }

    @Test func typingOneCharacterIsBounded() async {
        let editor = await loadedEditor(Self.largeFile())
        // Warm the layout, then time a single insert at the top.
        editor.selectedRange = NSRange(location: 0, length: 0)
        let elapsed = ContinuousClock().measure {
            for _ in 0..<20 { _ = editor.replace(NSRange(location: 0, length: 0), with: "x") }
        }
        print("[perf] 20 inserts: \(elapsed)")
        #expect(elapsed < .seconds(1), "a keystroke must not re-scan or re-parse the whole file")
    }

    @Test func theMinimapBuildsInBoundedTime() {
        let text = Self.largeFile()
        let elapsed = ContinuousClock().measure { _ = Minimap(text: text) }
        print("[perf] minimap rows: \(elapsed)")
        #expect(elapsed < .seconds(1))
    }

    @Test func bracketMatchingInALargeFileIsBounded() {
        let text = Self.largeFile() as NSString
        let caret = text.length / 2
        let elapsed = ContinuousClock().measure {
            for _ in 0..<50 { _ = Brackets.match(in: text, caret: caret) }
        }
        print("[perf] 50 bracket matches: \(elapsed)")
        #expect(elapsed < .seconds(1))
    }

    /// fold-all's cost is the engine hiding the ranges (layout), not ours: building all 2 000 ranges
    /// takes well under a millisecond. Kept so a regression on either side is visible.
    @Test func foldAllCostSplitsCleanly() async {
        let editor = await loadedEditor(Self.largeFile())
        let starts = FoldRegions.lineStarts(editor.text)
        let length = (editor.text as NSString).length
        let regions = editor.foldRegions.sorted { $0.header < $1.header }
        var covered = -1
        var ranges: [NSRange] = []
        let build = ContinuousClock().measure {
            for region in regions where region.header > covered {
                ranges.append(FoldRegions.range(of: region, lineStarts: starts, length: length))
                covered = region.last
            }
        }
        let hide = ContinuousClock().measure { editor.textView.foldedRanges = ranges }
        print("[perf] fold ranges build: \(build) (\(ranges.count) ranges); engine hide: \(hide)")
        #expect(build < .milliseconds(50), "building the fold ranges must stay cheap")
        #expect(hide < .seconds(2), "engine-side: hiding the ranges runs layout (see the engine repo)")
    }
}
